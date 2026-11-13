#ifndef SG_NATIVE_BRIDGE_TEST_H
#define SG_NATIVE_BRIDGE_TEST_H

#include "PreviewCallbacks.h"

typedef struct { void * _Nullable object; void * _Nullable witness; } SGTestDisposablePair;

SGTestDisposablePair SGNativeStart(void *signal, void *next, void *completed, void *context, void *startAddress);
void SGNativeDispose(void *object, void *witness);
void SGNativePreviewNext(void);
void SGNativePreviewCompleted(void);
void *SGTestSignalStartAddress(void);
void *SGTestNextAddress(void);
void *SGTestCompletedAddress(void);
unsigned SGNativeBridgeResultCount(void);
unsigned SGNativeBridgeFinishedCount(void);
uint64_t SGNativeBridgeIdentifier(void);
const char * _Nullable SGNativeBridgeLastJSON(void);
void SGNativeBridgeResetJSON(void);

#endif
