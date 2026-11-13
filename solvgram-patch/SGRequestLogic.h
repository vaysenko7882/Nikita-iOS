#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const SGRequestLogicErrorDomain;
FOUNDATION_EXPORT NSString * const SGGiftStyleDefaultsKey;

typedef NS_ENUM(NSInteger, SGRequestLogicError) {
    SGRequestLogicInvalidJSON = 1,
    SGRequestLogicInvalidSelection = 2,
    SGRequestLogicInvalidText = 3,
    SGRequestLogicTextTooLong = 4,
};

// These helpers never read or retain request headers, authentication or tokens.
FOUNDATION_EXPORT BOOL SGIsGiftRequest(NSURLRequest *request);
FOUNDATION_EXPORT NSDictionary * _Nullable SGParseRequest(NSURLRequest *request);

// Select -1 independently for the model/backdrop that should remain random.
// Fixed selections are 0...4095. The original JSON dictionary is preserved,
// apart from styling metadata in its existing text field. No unsupported
// model/backdrop network parameters are introduced.
FOUNDATION_EXPORT NSData * _Nullable SGPrepareSendBody(
    NSData *originalBody,
    NSInteger model,
    NSInteger backdrop,
    NSError * _Nullable * _Nullable error);

// A valid styling suffix is stripped from cleanText; invalid suffixes remain.
// The result has exactly model/backdrop NSNumber values (-1 means random).
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> * _Nullable SGDecodeGiftStyle(
    NSString *text,
    NSString * _Nullable * _Nullable cleanText);

// Only gift IDs and style indexes are stored under SGGiftStyleDefaultsKey.
// A pair of random selections removes an earlier local style for that gift.
FOUNDATION_EXPORT void SGRememberGiftStyle(NSString *giftID, NSInteger model, NSInteger backdrop);

// Recursive JSON rewrite supports individual gifts, gift lists and envelopes.
// A valid in-text style has priority over caller fallbacks, then saved styles.
// Malformed/non-JSON responses and JSON without relevant changes are returned
// byte-for-byte as supplied. Input dictionaries/data are never mutated.
FOUNDATION_EXPORT NSData *SGRewriteGiftResponse(
    NSData *data,
    NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> * _Nullable fallbackStyles);

NS_ASSUME_NONNULL_END
