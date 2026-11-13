#import <Foundation/Foundation.h>
#import "SGRequestLogic.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^SGGiftSendCompletion)(
    NSData * _Nullable data,
    NSURLResponse * _Nullable response,
    NSError * _Nullable error);

// The returned operation is owned by the async shim until completion/cancellation.
// The review callback must complete exactly once on every path.
FOUNDATION_EXPORT id SGReviewGiftSend(
    NSURLSession *session,
    NSURLRequest *request,
    SGGiftSendCompletion completion);
FOUNDATION_EXPORT void SGCancelGiftSend(id operation);

// id adapters make the Swift bridge explicit and avoid Foundation importer
// differences for custom C functions taking NSData / NSURLRequest pointers.
static inline id SGReviewGiftSendObject(id session, id request, SGGiftSendCompletion completion) {
    return SGReviewGiftSend((NSURLSession *)session, (NSURLRequest *)request, completion);
}
static inline id SGRewriteGiftResponseObject(id data) {
    return SGRewriteGiftResponse((NSData *)data, nil);
}

NS_ASSUME_NONNULL_END
