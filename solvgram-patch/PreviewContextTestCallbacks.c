#include "PreviewContextTestCallbacks.h"

static unsigned result_count;
static unsigned finished_count;
static uint64_t last_identifier;
static int json_was_null;

void SGPreviewResult(uint64_t identifier, const char *json) {
    ++result_count;
    last_identifier = identifier;
    json_was_null = json == 0;
}

void SGPreviewFinished(uint64_t identifier) {
    ++finished_count;
    last_identifier = identifier;
}

unsigned SGPreviewTestResultCount(void) { return result_count; }
unsigned SGPreviewTestFinishedCount(void) { return finished_count; }
uint64_t SGPreviewTestIdentifier(void) { return last_identifier; }
int SGPreviewTestJSONWasNull(void) { return json_was_null; }
