import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi show NativeApi;
import 'dart:isolate';
import 'dart:io';

import '../logger.dart';
import '../utils.dart';
import 'bindings.dart';
import 'event_bridge.dart';

class NativeMethodCall {
  NativeMethodCall(this.method, this.arguments);

  final String method;
  final dynamic arguments;
}

typedef NativeMethodCallHandler =
    FutureOr<void> Function(NativeMethodCall call);

class NativeInvocation {
  NativeInvocation.completed(this.result)
    : operationID = null,
      isCompleted = true;

  NativeInvocation.pending(this.operationID)
    : result = null,
      isCompleted = false;

  final bool isCompleted;
  final Object? result;
  final String? operationID;
}

class NativeBridge {
  NativeBridge();

  NativeMethodCallHandler? _handler;
  final _pending = <String, Completer<dynamic>>{};
  final _pendingByMethod = <String, List<Completer<dynamic>>>{};
  final _requestWaiters = <int, Completer<dynamic>>{};
  int _nextRequestID = 0;
  _MacFfiWorker? _macWorker;

  void setMethodCallHandler(NativeMethodCallHandler handler) {
    _handler = handler;
    if (_useWorker) {
      (_macWorker ??= _MacFfiWorker(_handleWorkerMessage)).updateCallback(
        _handleWorkerMessage,
      );
    } else {
      EventBridge.instance.setHandler(_handleNativeEvent);
    }
  }

  Future<T?> invokeMethod<T>(String method, Map<String, dynamic> arguments) {
    final operationID =
        arguments['operationID'] as String? ?? Utils.checkOperationID(null);
    arguments['operationID'] = operationID;
    final cleaned = Utils.cleanMap(arguments);
    if (_useWorker) {
      final worker = _macWorker ??= _MacFfiWorker(_handleWorkerMessage);
      final requestID = _nextRequestID++;
      return worker.invokeMethod<T>(
        requestID: requestID,
        method: method,
        arguments: cleaned,
        onRegister: (id, completer) {
          _requestWaiters[id] = completer;
        },
      );
    }
    final invocation = NativeInvoker.instance.invoke(
      method,
      cleaned,
      operationID,
    );
    if (invocation.isCompleted) {
      return Future.value(invocation.result as T?);
    }
    final completer = Completer<T?>();
    final opKey = invocation.operationID!;
    _pending[opKey] = completer;
    final queue = _pendingByMethod.putIfAbsent(
      method,
      () => <Completer<dynamic>>[],
    );
    queue.add(completer);
    return completer.future;
  }

  bool get _useWorker => Platform.isMacOS;

  void _handleNativeEvent(Map<String, dynamic> envelope) {
    try {
      // ignore: avoid_print
      print('FFI Event: ${jsonEncode(envelope)}');
    } catch (_) {
      // ignore: avoid_print
      print('FFI Event (fallback): $envelope');
    }

    try {
      final method = envelope['method'] as String?;
      if (method == null) {
        // ignore: avoid_print
        print('FFI Event missing method, keys=${envelope.keys}');
        return;
      }
      _handler?.call(NativeMethodCall(method, envelope));

      final opID = envelope['operationID'] as String?;
      final completer = _takePendingCompleter(method, opID);
      if (completer != null) {
        final normalized = _normalizeNativeResult(envelope);
        if (normalized.errCode != null && normalized.errCode != 0) {
          completer.completeError(
            OpenIMNativeException(normalized.errCode!, normalized.errMsg),
          );
        } else {
          completer.complete(normalized.data);
        }
      }
    } catch (error, stackTrace) {
      // ignore: avoid_print
      print('FFI handler error: $error\n$stackTrace');
    }
  }

  _NativeResult _normalizeNativeResult(Map<String, dynamic> envelope) {
    int? errCode = envelope['errCode'] as int?;
    String? errMsg = envelope['errMsg'] as String?;
    dynamic data = envelope['data'];

    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        data = decoded;
      } catch (_) {
        // keep raw string when decoding fails
      }
    }

    if (data is Map) {
      final map = Map<String, dynamic>.from(data as Map);
      errCode ??= Utils.toInt(map['errCode']);
      errMsg ??= Utils.stringValue(map['errMsg']);
      if (map.containsKey('data')) {
        data = map['data'];
      } else if (map.containsKey('result')) {
        data = map['result'];
      } else {
        data = map;
      }
    }

    return _NativeResult(data: data, errCode: errCode, errMsg: errMsg);
  }

  Completer<dynamic>? _takePendingCompleter(String method, String? opID) {
    Completer<dynamic>? completer;
    if (opID != null) {
      completer = _pending.remove(opID);
      if (completer != null) {
        _removePendingByMethod(method, completer);
        return completer;
      }
    }
    final queue = _pendingByMethod[method];
    if (queue != null && queue.isNotEmpty) {
      completer = queue.removeAt(0);
      if (queue.isEmpty) {
        _pendingByMethod.remove(method);
      }
    }
    return completer;
  }

  void _removePendingByMethod(String method, Completer<dynamic> completer) {
    final queue = _pendingByMethod[method];
    if (queue == null) return;
    queue.remove(completer);
    if (queue.isEmpty) {
      _pendingByMethod.remove(method);
    }
  }

  void _handleWorkerMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    switch (type) {
      case 'result':
      case 'error':
        final id = message['id'] as int?;
        if (id == null) return;
        final completer = _requestWaiters.remove(id);
        if (completer == null) return;
        if (type == 'error') {
          final error = message['error'] ?? 'FFI worker error';
          final stackRaw = message['stackTrace'];
          StackTrace stackTrace;
          if (stackRaw is String && stackRaw.isNotEmpty) {
            stackTrace = StackTrace.fromString(stackRaw);
          } else {
            stackTrace = StackTrace.current;
          }
          completer.completeError(error, stackTrace);
        } else {
          completer.complete(message['data']);
        }
        break;
      case 'pending':
        final id = message['id'] as int?;
        final opID = message['operationID'] as String?;
        final method = message['method'] as String?;
        if (id == null || opID == null) return;
        final completer = _requestWaiters.remove(id);
        if (completer == null) return;
        _pending[opID] = completer;
        if (method != null) {
          final queue = _pendingByMethod.putIfAbsent(
            method,
            () => <Completer<dynamic>>[],
          );
          queue.add(completer);
        }
        break;
      case 'event':
        final event = message['event'];
        if (event is Map<String, dynamic>) {
          _handleNativeEvent(event);
        } else if (event is Map) {
          _handleNativeEvent(Map<String, dynamic>.from(event));
        }
        break;
      default:
        break;
    }
  }
}

class _NativeResult {
  const _NativeResult({this.data, this.errCode, this.errMsg});

  final dynamic data;
  final int? errCode;
  final String? errMsg;
}

class _MacFfiWorker {
  _MacFfiWorker(void Function(Map<String, dynamic>) onMessage)
    : _onMessage = onMessage;

  void Function(Map<String, dynamic>) _onMessage;
  SendPort? _workerPort;
  ReceivePort? _receivePort;
  Future<void>? _startFuture;

  void updateCallback(void Function(Map<String, dynamic>) onMessage) {
    _onMessage = onMessage;
  }

  Future<void> ensureStarted() {
    return _startFuture ??= _start();
  }

  Future<void> _start() async {
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    final ready = Completer<void>();
    receivePort.listen((message) {
      if (message is Map) {
        final map = Map<String, dynamic>.from(message);
        final type = map['type'] as String?;
        if (type == 'ready') {
          _workerPort = map['sendPort'] as SendPort?;
          if (!ready.isCompleted) {
            ready.complete();
          }
        } else {
          _onMessage(map);
        }
      }
    });

    await Isolate.spawn(
      _macFfiWorkerMain,
      receivePort.sendPort,
      errorsAreFatal: false,
    );
    await ready.future;
  }

  Future<T?> invokeMethod<T>({
    required int requestID,
    required String method,
    required Map<String, dynamic> arguments,
    required void Function(int requestID, Completer<dynamic> completer)
    onRegister,
  }) async {
    await ensureStarted();
    final port = _workerPort;
    if (port == null) {
      throw StateError('FFI worker not ready');
    }
    final completer = Completer<T?>();
    onRegister(requestID, completer);
    port.send({
      'type': 'invoke',
      'id': requestID,
      'method': method,
      'arguments': Map<String, dynamic>.from(arguments),
    });
    return completer.future;
  }
}

void _macFfiWorkerMain(SendPort uiSendPort) {
  final receivePort = ReceivePort();
  uiSendPort.send({'type': 'ready', 'sendPort': receivePort.sendPort});

  final openim = OpenIMFFI.instance;
  openim.dartInitializeApiDL(ffi.NativeApi.initializeApiDLData);

  EventBridge.instance.ensureInitialized();
  EventBridge.instance.setHandler((event) {
    uiSendPort.send({'type': 'event', 'event': event});
  });

  receivePort.listen((message) {
    if (message is! Map) return;
    final map = Map<String, dynamic>.from(message);
    final type = map['type'] as String?;
    if (type != 'invoke') return;
    final id = map['id'] as int?;
    final method = map['method'] as String?;
    final rawArgs = map['arguments'];
    if (id == null || method == null || rawArgs is! Map) return;
    final args = Map<String, dynamic>.from(rawArgs);
    try {
      final operationID =
          args['operationID'] as String? ?? Utils.checkOperationID(null);
      args['operationID'] = operationID;
      final invocation = NativeInvoker.instance.invoke(
        method,
        args,
        operationID,
      );
      if (invocation.isCompleted) {
        uiSendPort.send({
          'type': 'result',
          'id': id,
          'data': invocation.result,
        });
      } else {
        uiSendPort.send({
          'type': 'pending',
          'id': id,
          'operationID': invocation.operationID,
          'method': method,
        });
      }
    } catch (error, stack) {
      uiSendPort.send({
        'type': 'error',
        'id': id,
        'error': error.toString(),
        'stackTrace': stack.toString(),
      });
    }
  });
}

class OpenIMNativeException implements Exception {
  OpenIMNativeException(this.code, this.message);

  final int code;
  final String? message;

  @override
  String toString() => 'OpenIMNativeException(code: $code, message: $message)';
}

class NativeInvoker {
  NativeInvoker._();

  static final NativeInvoker instance = NativeInvoker._();

  NativeInvocation invoke(
    String method,
    Map<String, dynamic> arguments,
    String operationID,
  ) {
    switch (method) {
      case 'initSDK':
        final listener = OpenIMFFI.instance.getIMListener();
        final nativePort = EventBridge.instance.nativePort;
        final configJson = Utils.toJson(arguments);
        final ok = OpenIMFFI.instance.initSDK(
          listener,
          nativePort,
          operationID,
          configJson,
        );
        return NativeInvocation.completed(ok);
      case 'login':
        final userID = arguments['userID'] as String?;
        final token = arguments['token'] as String?;
        if (userID == null || token == null) {
          throw ArgumentError('login requires userID & token');
        }
        OpenIMFFI.instance.login(operationID, userID, token);
        return NativeInvocation.pending(operationID);
      case 'logout':
        OpenIMFFI.instance.logout(operationID);
        return NativeInvocation.pending(operationID);
      case 'getLoginStatus':
        final status = OpenIMFFI.instance.getLoginStatus(operationID);
        return NativeInvocation.completed(status);
      case 'getLoginUserID':
        final userID = OpenIMFFI.instance.getLoginUserID();
        return NativeInvocation.completed(userID);
      case 'acceptFriendApplication':
        OpenIMFFI.instance.acceptFriendApplication(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments),
        );
        return NativeInvocation.pending(operationID);

      case 'acceptGroupApplication':
        OpenIMFFI.instance.acceptGroupApplication(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          _stringArg(arguments, 'userID'),
          _stringArg(arguments, 'handleMsg'),
        );
        return NativeInvocation.pending(operationID);

      case 'addBlacklist':
        OpenIMFFI.instance.addBlack(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'userID'),
          _stringArg(arguments, 'ex'),
        );
        return NativeInvocation.pending(operationID);

      case 'addFriend':
        OpenIMFFI.instance.addFriend(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments),
        );
        return NativeInvocation.pending(operationID);

      case 'changeGroupMemberMute':
        OpenIMFFI.instance.changeGroupMemberMute(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          _stringArg(arguments, 'userID'),
          Utils.toInt(arguments['seconds']),
        );
        return NativeInvocation.pending(operationID);

      case 'changeGroupMute':
        OpenIMFFI.instance.changeGroupMute(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          Utils.toBool(arguments['mute']),
        );
        return NativeInvocation.pending(operationID);

      case 'changeInputStates':
        OpenIMFFI.instance.changeInputStates(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
          Utils.toBool(arguments['focus']),
        );
        return NativeInvocation.pending(operationID);

      case 'checkFriend':
        OpenIMFFI.instance.checkFriend(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['userIDList']),
        );
        return NativeInvocation.pending(operationID);

      case 'clearConversationAndDeleteAllMsg':
        OpenIMFFI.instance.clearConversationAndDeleteAllMsg(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'createAdvancedQuoteMessage':
        final result = OpenIMFFI.instance.createAdvancedQuoteMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'quoteText'),
          Utils.toJsonString(arguments['quoteMessage']),
          Utils.toJsonString(arguments['richMessageInfoList']),
        );
        return NativeInvocation.completed(result);

      case 'createAdvancedTextMessage':
        final result = OpenIMFFI.instance.createAdvancedTextMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'text'),
          Utils.toJsonString(arguments['richMessageInfoList']),
        );
        return NativeInvocation.completed(result);

      case 'createCardMessage':
        final result = OpenIMFFI.instance.createCardMessage(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['cardMessage']),
        );
        return NativeInvocation.completed(result);

      case 'createCustomMessage':
        final result = OpenIMFFI.instance.createCustomMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'data'),
          _stringArg(arguments, 'extension'),
          _stringArg(arguments, 'description'),
        );
        return NativeInvocation.completed(result);

      case 'createFaceMessage':
        final result = OpenIMFFI.instance.createFaceMessage(
          _stringArg(arguments, 'operationID'),
          Utils.toInt(arguments['index']),
          _stringArg(arguments, 'data'),
        );
        return NativeInvocation.completed(result);

      case 'createFileMessage':
        final result = OpenIMFFI.instance.createFileMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'filePath'),
          _stringArg(arguments, 'fileName'),
        );
        return NativeInvocation.completed(result);

      case 'createFileMessageByURL':
        final result = OpenIMFFI.instance.createFileMessageByURL(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['fileElem']),
        );
        return NativeInvocation.completed(result);

      case 'createFileMessageFromFullPath':
        final result = OpenIMFFI.instance.createFileMessageFromFullPath(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'filePath'),
          _stringArg(arguments, 'fileName'),
        );
        return NativeInvocation.completed(result);

      case 'createForwardMessage':
        final result = OpenIMFFI.instance.createForwardMessage(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['message']),
        );
        return NativeInvocation.completed(result);

      case 'createGroup':
        OpenIMFFI.instance.createGroup(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments),
        );
        return NativeInvocation.pending(operationID);

      case 'createImageMessage':
        final result = OpenIMFFI.instance.createImageMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'imagePath'),
        );
        return NativeInvocation.completed(result);

      case 'createImageMessageByURL':
        final result = OpenIMFFI.instance.createImageMessageByURL(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'sourcePath'),
          Utils.toJsonString(arguments['sourcePicture']),
          Utils.toJsonString(arguments['bigPicture']),
          Utils.toJsonString(arguments['snapshotPicture']),
        );
        return NativeInvocation.completed(result);

      case 'createImageMessageFromFullPath':
        final result = OpenIMFFI.instance.createImageMessageFromFullPath(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'imagePath'),
        );
        return NativeInvocation.completed(result);

      case 'createLocationMessage':
        final result = OpenIMFFI.instance.createLocationMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'description'),
          Utils.toDouble(arguments['longitude']),
          Utils.toDouble(arguments['latitude']),
        );
        return NativeInvocation.completed(result);

      case 'createMergerMessage':
        final result = OpenIMFFI.instance.createMergerMessage(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['messageList']),
          _stringArg(arguments, 'title'),
          Utils.toJsonString(arguments['summaryList']),
        );
        return NativeInvocation.completed(result);

      case 'createQuoteMessage':
        final result = OpenIMFFI.instance.createQuoteMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'quoteText'),
          Utils.toJsonString(arguments['quoteMessage']),
        );
        return NativeInvocation.completed(result);

      case 'createSoundMessage':
        final result = OpenIMFFI.instance.createSoundMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'soundPath'),
          Utils.toInt(arguments['duration']),
        );
        return NativeInvocation.completed(result);

      case 'createSoundMessageByURL':
        final result = OpenIMFFI.instance.createSoundMessageByURL(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['soundElem']),
        );
        return NativeInvocation.completed(result);

      case 'createSoundMessageFromFullPath':
        final result = OpenIMFFI.instance.createSoundMessageFromFullPath(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'soundPath'),
          Utils.toInt(arguments['duration']),
        );
        return NativeInvocation.completed(result);

      case 'createTextAtMessage':
        final result = OpenIMFFI.instance.createTextAtMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'text'),
          Utils.toJsonString(arguments['atUserIDList']),
          Utils.toJsonString(arguments['atUserInfoList']),
          Utils.toJsonString(arguments['quoteMessage']),
        );
        return NativeInvocation.completed(result);

      case 'createTextMessage':
        final result = OpenIMFFI.instance.createTextMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'text'),
        );
        return NativeInvocation.completed(result);

      case 'createVideoMessage':
        final result = OpenIMFFI.instance.createVideoMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'videoPath'),
          _stringArg(arguments, 'videoType'),
          Utils.toInt(arguments['duration']),
          _stringArg(arguments, 'snapshotPath'),
        );
        return NativeInvocation.completed(result);

      case 'createVideoMessageByURL':
        final result = OpenIMFFI.instance.createVideoMessageByURL(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['videoElem']),
        );
        return NativeInvocation.completed(result);

      case 'createVideoMessageFromFullPath':
        final result = OpenIMFFI.instance.createVideoMessageFromFullPath(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'videoPath'),
          _stringArg(arguments, 'videoType'),
          Utils.toInt(arguments['duration']),
          _stringArg(arguments, 'snapshotPath'),
        );
        return NativeInvocation.completed(result);

      case 'sendMessage':
        if (Utils.toBool(arguments['isOnlineOnly'])) {
          Logger.print(
            'sendMessage: isOnlineOnly is not supported via FFI bridge',
          );
        }
        OpenIMFFI.instance.sendMessage(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['message']),
          _stringArg(arguments, 'userID'),
          _stringArg(arguments, 'groupID'),
          Utils.toJsonString(arguments['offlinePushInfo']),
        );
        return NativeInvocation.pending(operationID);

      case 'sendMessageNotOss':
        if (Utils.toBool(arguments['isOnlineOnly'])) {
          Logger.print(
            'sendMessageNotOss: isOnlineOnly is not supported via FFI bridge',
          );
        }
        OpenIMFFI.instance.sendMessageNotOss(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['message']),
          _stringArg(arguments, 'userID'),
          _stringArg(arguments, 'groupID'),
          Utils.toJsonString(arguments['offlinePushInfo']),
        );
        return NativeInvocation.pending(operationID);

      case 'deleteAllMsgFromLocal':
        OpenIMFFI.instance.deleteAllMsgFromLocal(
          _stringArg(arguments, 'operationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'deleteAllMsgFromLocalAndSvr':
        OpenIMFFI.instance.deleteAllMsgFromLocalAndSvr(
          _stringArg(arguments, 'operationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'deleteConversationAndDeleteAllMsg':
        OpenIMFFI.instance.deleteConversationAndDeleteAllMsg(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'deleteFriend':
        OpenIMFFI.instance.deleteFriend(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'userID'),
        );
        return NativeInvocation.pending(operationID);

      case 'deleteMessageFromLocalAndSvr':
        OpenIMFFI.instance.deleteMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
          _stringArg(arguments, 'clientMsgID'),
        );
        return NativeInvocation.pending(operationID);

      case 'deleteMessageFromLocalStorage':
        OpenIMFFI.instance.deleteMessageFromLocalStorage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
          _stringArg(arguments, 'clientMsgID'),
        );
        return NativeInvocation.pending(operationID);

      case 'dismissGroup':
        OpenIMFFI.instance.dismissGroup(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
        );
        return NativeInvocation.pending(operationID);

      case 'findMessageList':
        OpenIMFFI.instance.findMessageList(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['searchParams']),
        );
        return NativeInvocation.pending(operationID);

      case 'getAdvancedHistoryMessageList':
        OpenIMFFI.instance.getAdvancedHistoryMessageList(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments),
        );
        return NativeInvocation.pending(operationID);

      case 'getAdvancedHistoryMessageListReverse':
        OpenIMFFI.instance.getAdvancedHistoryMessageListReverse(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments),
        );
        return NativeInvocation.pending(operationID);

      case 'getAllConversationList':
        OpenIMFFI.instance.getAllConversationList(
          _stringArg(arguments, 'operationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'getAtAllTag':
        final result = OpenIMFFI.instance.getAtAllTag(
          _stringArg(arguments, 'operationID'),
        );
        return NativeInvocation.completed(result);

      case 'getBlacklist':
        OpenIMFFI.instance.getBlackList(_stringArg(arguments, 'operationID'));
        return NativeInvocation.pending(operationID);

      case 'getConversationIDBySessionType':
        final result = OpenIMFFI.instance.getConversationIDBySessionType(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'sourceID'),
          Utils.toInt(arguments['sessionType']),
        );
        return NativeInvocation.completed(result);

      case 'getConversationListSplit':
        OpenIMFFI.instance.getConversationListSplit(
          _stringArg(arguments, 'operationID'),
          Utils.toInt(arguments['offset']),
          Utils.toInt(arguments['count']),
        );
        return NativeInvocation.pending(operationID);

      case 'getFriendApplicationListAsApplicant':
        OpenIMFFI.instance.getFriendApplicationListAsApplicant(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['req']),
        );
        return NativeInvocation.pending(operationID);

      case 'getFriendApplicationListAsRecipient':
        OpenIMFFI.instance.getFriendApplicationListAsRecipient(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['req']),
        );
        return NativeInvocation.pending(operationID);

      case 'getFriendList':
        OpenIMFFI.instance.getFriendList(
          _stringArg(arguments, 'operationID'),
          Utils.toBool(arguments['filterBlack']),
        );
        return NativeInvocation.pending(operationID);

      case 'getFriendListPage':
        OpenIMFFI.instance.getFriendListPage(
          _stringArg(arguments, 'operationID'),
          Utils.toInt(arguments['offset']),
          Utils.toInt(arguments['count']),
          Utils.toBool(arguments['filterBlack']),
        );
        return NativeInvocation.pending(operationID);

      case 'getFriendsInfo':
        OpenIMFFI.instance.getSpecifiedFriendsInfo(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['userIDList']),
          Utils.toBool(arguments['filterBlack']),
        );
        return NativeInvocation.pending(operationID);

      case 'getGroupMemberList':
        OpenIMFFI.instance.getGroupMemberList(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          Utils.toInt(arguments['filter']),
          Utils.toInt(arguments['offset']),
          Utils.toInt(arguments['count']),
        );
        return NativeInvocation.pending(operationID);

      case 'getGroupApplicationListAsApplicant':
        OpenIMFFI.instance.getGroupApplicationListAsApplicant(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['req']),
        );
        return NativeInvocation.pending(operationID);

      case 'getGroupApplicationListAsRecipient':
        OpenIMFFI.instance.getGroupApplicationListAsRecipient(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['req']),
        );
        return NativeInvocation.pending(operationID);

      case 'getGroupMemberListByJoinTimeFilter':
        OpenIMFFI.instance.getGroupMemberListByJoinTimeFilter(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          Utils.toInt(arguments['offset']),
          Utils.toInt(arguments['count']),
          Utils.toInt(arguments['joinTimeBegin']),
          Utils.toInt(arguments['joinTimeEnd']),
          Utils.toJsonString(arguments['excludeUserIDList']),
        );
        return NativeInvocation.pending(operationID);

      case 'getGroupMemberOwnerAndAdmin':
        OpenIMFFI.instance.getGroupMemberOwnerAndAdmin(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
        );
        return NativeInvocation.pending(operationID);

      case 'getGroupMembersInfo':
        OpenIMFFI.instance.getSpecifiedGroupMembersInfo(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          Utils.toJsonString(arguments['userIDList']),
        );
        return NativeInvocation.pending(operationID);

      case 'getGroupsInfo':
        OpenIMFFI.instance.getSpecifiedGroupsInfo(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['groupIDList']),
        );
        return NativeInvocation.pending(operationID);

      case 'getInputStates':
        OpenIMFFI.instance.getInputStates(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
          _stringArg(arguments, 'userID'),
        );
        return NativeInvocation.pending(operationID);

      case 'getJoinedGroupList':
        OpenIMFFI.instance.getJoinedGroupList(
          _stringArg(arguments, 'operationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'getJoinedGroupListPage':
        OpenIMFFI.instance.getJoinedGroupListPage(
          _stringArg(arguments, 'operationID'),
          Utils.toInt(arguments['offset']),
          Utils.toInt(arguments['count']),
        );
        return NativeInvocation.pending(operationID);

      case 'getMultipleConversation':
        OpenIMFFI.instance.getMultipleConversation(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['conversationIDList']),
        );
        return NativeInvocation.pending(operationID);

      case 'getOneConversation':
        OpenIMFFI.instance.getOneConversation(
          _stringArg(arguments, 'operationID'),
          Utils.toInt(arguments['sessionType']),
          _stringArg(arguments, 'sourceID'),
        );
        return NativeInvocation.pending(operationID);

      case 'getSelfUserInfo':
        OpenIMFFI.instance.getSelfUserInfo(
          _stringArg(arguments, 'operationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'getSubscribeUsersStatus':
        OpenIMFFI.instance.getSubscribeUsersStatus(
          _stringArg(arguments, 'operationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'getTotalUnreadMsgCount':
        OpenIMFFI.instance.getTotalUnreadMsgCount(
          _stringArg(arguments, 'operationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'getUsersInGroup':
        OpenIMFFI.instance.getUsersInGroup(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          Utils.toJsonString(arguments['userIDs']),
        );
        return NativeInvocation.pending(operationID);

      case 'getUsersInfo':
        OpenIMFFI.instance.getUsersInfo(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['userIDList']),
        );
        return NativeInvocation.pending(operationID);

      case 'hideAllConversations':
        OpenIMFFI.instance.hideAllConversations(
          _stringArg(arguments, 'operationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'hideConversation':
        OpenIMFFI.instance.hideConversation(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'insertGroupMessageToLocalStorage':
        OpenIMFFI.instance.insertGroupMessageToLocalStorage(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['message']),
          _stringArg(arguments, 'groupID'),
          _stringArg(arguments, 'senderID'),
        );
        return NativeInvocation.pending(operationID);

      case 'insertSingleMessageToLocalStorage':
        OpenIMFFI.instance.insertSingleMessageToLocalStorage(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['message']),
          _stringArg(arguments, 'receiverID'),
          _stringArg(arguments, 'senderID'),
        );
        return NativeInvocation.pending(operationID);

      case 'inviteUserToGroup':
        OpenIMFFI.instance.inviteUserToGroup(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          _stringArg(arguments, 'reason'),
          Utils.toJsonString(arguments['userIDList']),
        );
        return NativeInvocation.pending(operationID);

      case 'isJoinGroup':
        OpenIMFFI.instance.isJoinGroup(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
        );
        return NativeInvocation.pending(operationID);

      case 'joinGroup':
        OpenIMFFI.instance.joinGroup(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          _stringArg(arguments, 'reason'),
          Utils.toInt(arguments['joinSource']),
          _stringArg(arguments, 'ex'),
        );
        return NativeInvocation.pending(operationID);

      case 'kickGroupMember':
        OpenIMFFI.instance.kickGroupMember(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          _stringArg(arguments, 'reason'),
          Utils.toJsonString(arguments['userIDList']),
        );
        return NativeInvocation.pending(operationID);

      case 'logs':
        OpenIMFFI.instance.logs(
          _stringArg(arguments, 'operationID'),
          Utils.toInt(arguments['logLevel']),
          _stringArg(arguments, 'file'),
          Utils.toInt(arguments['line']),
          _stringArg(arguments, 'msgs'),
          _stringArg(arguments, 'err'),
          _stringArg(arguments, 'keyAndValue'),
        );
        return NativeInvocation.pending(operationID);

      case 'markConversationMessageAsRead':
        OpenIMFFI.instance.markConversationMessageAsRead(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'markMessagesAsReadByMsgID':
        OpenIMFFI.instance.markMessagesAsReadByMsgID(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
          Utils.toJsonString(arguments['messageIDList']),
        );
        return NativeInvocation.pending(operationID);

      case 'networkStatusChanged':
        OpenIMFFI.instance.networkStatusChanged(
          _stringArg(arguments, 'operationID'),
        );
        return NativeInvocation.pending(operationID);

      case 'quitGroup':
        OpenIMFFI.instance.quitGroup(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
        );
        return NativeInvocation.pending(operationID);

      case 'refuseFriendApplication':
        OpenIMFFI.instance.refuseFriendApplication(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments),
        );
        return NativeInvocation.pending(operationID);

      case 'refuseGroupApplication':
        OpenIMFFI.instance.refuseGroupApplication(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          _stringArg(arguments, 'userID'),
          _stringArg(arguments, 'handleMsg'),
        );
        return NativeInvocation.pending(operationID);

      case 'removeBlacklist':
        OpenIMFFI.instance.removeBlack(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'userID'),
        );
        return NativeInvocation.pending(operationID);

      case 'revokeMessage':
        OpenIMFFI.instance.revokeMessage(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
          _stringArg(arguments, 'clientMsgID'),
        );
        return NativeInvocation.pending(operationID);

      case 'searchConversation':
        OpenIMFFI.instance.searchConversation(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'name'),
        );
        return NativeInvocation.pending(operationID);

      case 'searchConversations':
        OpenIMFFI.instance.searchConversation(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'name'),
        );
        return NativeInvocation.pending(operationID);

      case 'searchFriends':
        OpenIMFFI.instance.searchFriends(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['searchParam']),
        );
        return NativeInvocation.pending(operationID);

      case 'searchGroupMembers':
        OpenIMFFI.instance.searchGroupMembers(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['searchParam']),
        );
        return NativeInvocation.pending(operationID);

      case 'searchGroups':
        OpenIMFFI.instance.searchGroups(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['searchParam']),
        );
        return NativeInvocation.pending(operationID);

      case 'searchLocalMessages':
        OpenIMFFI.instance.searchLocalMessages(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['filter']),
        );
        return NativeInvocation.pending(operationID);

      case 'setAppBackgroundStatus':
        OpenIMFFI.instance.setAppBackgroundStatus(
          _stringArg(arguments, 'operationID'),
          Utils.toBool(arguments['isBackground']),
        );
        return NativeInvocation.pending(operationID);

      case 'setAppBadge':
        OpenIMFFI.instance.setAppBadge(
          _stringArg(arguments, 'operationID'),
          Utils.toInt(arguments['count']),
        );
        return NativeInvocation.pending(operationID);

      case 'setConversation':
        OpenIMFFI.instance.setConversation(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
          Utils.toJsonString(arguments['req']),
        );
        return NativeInvocation.pending(operationID);

      case 'setConversationDraft':
        OpenIMFFI.instance.setConversationDraft(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
          _stringArg(arguments, 'draftText'),
        );
        return NativeInvocation.pending(operationID);

      case 'setGroupInfo':
        OpenIMFFI.instance.setGroupInfo(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['groupInfo']),
        );
        return NativeInvocation.pending(operationID);

      case 'setGroupMemberInfo':
        OpenIMFFI.instance.setGroupMemberInfo(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['info']),
        );
        return NativeInvocation.pending(operationID);

      case 'setMessageLocalEx':
        OpenIMFFI.instance.setMessageLocalEx(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'conversationID'),
          _stringArg(arguments, 'clientMsgID'),
          _stringArg(arguments, 'localEx'),
        );
        return NativeInvocation.pending(operationID);

      case 'setSelfInfo':
        OpenIMFFI.instance.setSelfInfo(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments),
        );
        return NativeInvocation.pending(operationID);

      case 'subscribeUsersStatus':
        OpenIMFFI.instance.subscribeUsersStatus(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['userIDs']),
        );
        return NativeInvocation.pending(operationID);

      case 'transferGroupOwner':
        OpenIMFFI.instance.transferGroupOwner(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'groupID'),
          _stringArg(arguments, 'userID'),
        );
        return NativeInvocation.pending(operationID);

      case 'typingStatusUpdate':
        OpenIMFFI.instance.typingStatusUpdate(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'userID'),
          _stringArg(arguments, 'msgTip'),
        );
        return NativeInvocation.pending(operationID);

      case 'unsubscribeUsersStatus':
        OpenIMFFI.instance.unsubscribeUsersStatus(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['userIDs']),
        );
        return NativeInvocation.pending(operationID);

      case 'uploadFile':
        OpenIMFFI.instance.uploadFile(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments),
          _stringArg(arguments, 'id'),
        );
        return NativeInvocation.pending(operationID);

      case 'uploadLogs':
        OpenIMFFI.instance.uploadLogs(
          _stringArg(arguments, 'operationID'),
          Utils.toInt(arguments['line']),
          _stringArg(arguments, 'ex'),
          _stringArg(arguments, 'id'),
        );
        return NativeInvocation.pending(operationID);

      case 'updateFcmToken':
        OpenIMFFI.instance.updateFcmToken(
          _stringArg(arguments, 'operationID'),
          _stringArg(arguments, 'fcmToken'),
          Utils.toInt(arguments['expireTime']),
        );
        return NativeInvocation.pending(operationID);

      case 'updateFriends':
        OpenIMFFI.instance.updateFriends(
          _stringArg(arguments, 'operationID'),
          Utils.toJsonString(arguments['req']),
        );
        return NativeInvocation.pending(operationID);

      case 'unInitSDK':
        EventBridge.instance.dispose();
        return NativeInvocation.completed(null);

      case 'setAdvancedMsgListener':
      case 'setConversationListener':
      case 'setCustomBusinessListener':
      case 'setFriendListener':
      case 'setGroupListener':
      case 'setListenerForService':
      case 'setUserListener':
        Logger.print(
          'Listener registration via FFI is handled natively; treating "$method" as a no-op.',
        );
        return NativeInvocation.completed(null);

      default:
        throw UnimplementedError('FFI method "$method" not implemented yet');
    }
  }

  static String? _stringArg(Map<String, dynamic> args, String key) =>
      Utils.stringValue(args[key]);
}
