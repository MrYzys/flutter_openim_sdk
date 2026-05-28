# flutter_openim_sdk

A Flutter plugin that mirrors the `flutter_openim_sdk` Dart API while sourcing its native implementation from the OpenIM C++ SDK (`openim-sdk-cpp-3.8.3-patch.10`). The FFI layer links against platform builds of the OpenIM native library and exposes the same surface area as the existing SDK package so that projects can adopt the C++ pipeline without rewriting Dart code.

## Development Notes

- Regenerate FFI bindings with `dart run ffigen --config ffigen.yaml`.
- Native sources live under `src/` with third-party code vendored in `third_party/openim-sdk-cpp-3.8.3-patch.10`.
- Provide the platform-specific OpenIM binaries under `third_party/.../shared/<platform>/` (or continue to use the fallbacks under `android/libs`, `ios/`, `macos/`, `windows/`, and `linux/`).
- Keep the Dart layer in sync with `plugin/flutter_openim_sdk` to preserve runtime compatibility.

## Example

The bundled example imports `package:flutter_openim_sdk/flutter_openim_sdk.dart` and exercises a minimal subset of the API. Update the `example/pubspec.yaml` dependency to point at your local plugin path or a published version before running `flutter run`.
