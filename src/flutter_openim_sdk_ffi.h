#include "./include/dart_api_dl.h"

#if _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

typedef struct
{
    void (*onMethodChannel)(Dart_Port_DL port, char *);
} Openim_Listener;

typedef struct
{
    Dart_Port_DL port;
    char *message;
} ThreadArgs;

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT
#endif

FFI_PLUGIN_EXPORT Openim_Listener getIMListener();
