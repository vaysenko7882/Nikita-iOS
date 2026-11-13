#import "SessionShimTestMocks.h"

@interface SGShimMockOperation : NSObject
@property(copy) SGGiftSendCompletion completion;
@property BOOL cancelled;
@end
@implementation SGShimMockOperation @end

static NSInteger SGMode;
static NSInteger SGReviewCalls;
static NSInteger SGCancelCalls;
static NSLock *SGTestLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}
void SGShimTestSetMode(NSInteger mode) {
    NSLock *lock = SGTestLock();
    [lock lock];
    SGMode = mode;
    SGReviewCalls = 0;
    SGCancelCalls = 0;
    [lock unlock];
    [NSUserDefaults.standardUserDefaults setObject:@{@"12": @{@"model": @8, @"backdrop": @9}}
                                           forKey:SGGiftStyleDefaultsKey];
}
NSInteger SGShimTestReviewCalls(void) {
    NSLock *lock = SGTestLock(); [lock lock]; NSInteger value = SGReviewCalls; [lock unlock]; return value;
}
NSInteger SGShimTestCancelCalls(void) {
    NSLock *lock = SGTestLock(); [lock lock]; NSInteger value = SGCancelCalls; [lock unlock]; return value;
}
NSData *SGShimTestResponseData(void) {
    return [@"{\"id\":12,\"gift\":\"123\",\"owner\":\"456\",\"text\":\"test\",\"unique\":{\"model\":3,\"backdrop\":4}}"
            dataUsingEncoding:NSUTF8StringEncoding];
}
id SGReviewGiftSend(NSURLSession *session, NSURLRequest *request, SGGiftSendCompletion completion) {
    NSLock *lock = SGTestLock();
    [lock lock]; SGReviewCalls++; NSInteger mode = SGMode; [lock unlock];
    SGShimMockOperation *operation = [SGShimMockOperation new];
    operation.completion = completion;
    NSURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200
                                                     HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    if (mode == 0 || mode == 5) {
        completion(SGShimTestResponseData(), response, nil);
        if (mode == 5) completion(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:nil]);
    } else if (mode == 1) {
        completion(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]);
    } else if (mode == 2) {
        completion(nil, nil, nil);
    } else if (mode == 4) {
        // Make cancellation arrive while SGReviewGiftSend is still creating its
        // operation, before the async shim can call install(_:).
        [NSThread sleepForTimeInterval:0.05];
    }
    return operation;
}
void SGCancelGiftSend(id value) {
    SGShimMockOperation *operation = value;
    NSLock *lock = SGTestLock();
    [lock lock];
    if (operation.cancelled) { [lock unlock]; return; }
    operation.cancelled = YES;
    SGCancelCalls++;
    [lock unlock];
    operation.completion(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
}
