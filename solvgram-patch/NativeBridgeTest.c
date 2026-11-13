#include "NativeBridgeTest.h"
#include <stdlib.h>
#include <string.h>

// This symbol is emitted by a Swift instance method. It is deliberately never
// called using this C declaration; only its address is passed to Native.S.
extern void SGTestSignalStart(void);

static unsigned results;
static unsigned finishes;
static uint64_t identifier;
static char *last_json;

void SGPreviewResult(uint64_t value, const char *json) {
    ++results;
    identifier = value;
    free(last_json);
    last_json = json ? strdup(json) : 0;
}

void SGPreviewFinished(uint64_t value) {
    ++finishes;
    identifier = value;
}

void *SGTestSignalStartAddress(void) { return (void *)&SGTestSignalStart; }
void *SGTestNextAddress(void) { return (void *)&SGNativePreviewNext; }
void *SGTestCompletedAddress(void) { return (void *)&SGNativePreviewCompleted; }
unsigned SGNativeBridgeResultCount(void) { return results; }
unsigned SGNativeBridgeFinishedCount(void) { return finishes; }
uint64_t SGNativeBridgeIdentifier(void) { return identifier; }
const char *SGNativeBridgeLastJSON(void) { return last_json; }
void SGNativeBridgeResetJSON(void) { free(last_json); last_json = 0; }
