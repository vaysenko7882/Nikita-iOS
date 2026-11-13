#ifndef SG_PREVIEW_CALLBACKS_H
#define SG_PREVIEW_CALLBACKS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Implemented by Controls.m. JSON is borrowed and valid only during the call;
// callers that dispatch asynchronously must copy it before returning.
// NULL means the native preview did not contain a usable model/backdrop catalog.
void SGPreviewResult(uint64_t identifier, const char * _Nullable json);
void SGPreviewFinished(uint64_t identifier);

#ifdef __cplusplus
}
#endif

#endif
