#import <Foundation/Foundation.h>
#import "SGRequestLogic.h"
#include <stdio.h>

static NSUInteger failures = 0;
#define CHECK(condition, message) do { \
    if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, (message)); failures++; } \
} while (0)

static NSData *JSON(id object) {
    NSError *error = nil;
    NSData *result = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    CHECK(result != nil && error == nil, "test JSON must serialize");
    return result;
}

static id Parse(NSData *data) {
    NSError *error = nil;
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    CHECK(result != nil && error == nil, "result JSON must parse");
    return result;
}

static NSString *Repeat(NSString *value, NSUInteger count) {
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < count; i++) {
        [result appendString:value];
    }
    return result;
}

static NSDictionary *Request(NSString *text) {
    NSMutableDictionary *result = [@{
        @"gift": @"PlushPepe", @"to": @"7100373090", @"hidden": @YES,
        @"upgrade": @YES, @"edition": @3,
        @"other": @{ @"nested": @[@1, @"keep", NSNull.null] }
    } mutableCopy];
    if (text) result[@"text"] = text;
    return result;
}

static NSString *Tagged(NSString *human, NSInteger model, NSInteger backdrop) {
    NSError *error = nil;
    NSData *body = SGPrepareSendBody(JSON(Request(human)), model, backdrop, &error);
    CHECK(body != nil && error == nil, "styling metadata must encode");
    return Parse(body)[@"text"];
}

static NSDictionary *Gift(NSNumber *identifier, NSString *text) {
    NSMutableDictionary *gift = [@{
        @"id": identifier, @"gift": @"PlushPepe", @"owner": @"7100373090",
        @"date": @1780000000, @"number": @42, @"saved": @YES, @"pinned": @NO,
        @"hidden": @NO, @"sender": @"9876543210", @"prepaid": @NO,
        @"unique": @{ @"slug": @"PlushPepe-42", @"number": @42, @"issued": @10000,
                       @"date": @1780000001, @"model": @2, @"backdrop": @3,
                       @"pattern": @4 },
        @"history": @[@{ @"from": @"123", @"to": @"7100373090", @"date": @1779999999 }]
    } mutableCopy];
    if (text) gift[@"text"] = text;
    return gift;
}

static NSURLRequest *URLRequest(NSString *url) {
    return [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
}

static void TestScopeAndParsing(void) {
    CHECK(SGIsGiftRequest(URLRequest(@"https://archive.2.26.254.34.sslip.io/v1/pro/gifts/send")), "real send endpoint");
    CHECK(SGIsGiftRequest(URLRequest(@"https://archive.2.26.254.34.sslip.io/v1/pro/gifts/list?owner=123")), "real list endpoint");
    CHECK(!SGIsGiftRequest(URLRequest(@"https://api.telegram.org/v1/pro/gifts/send")), "Telegram requests excluded");
    CHECK(!SGIsGiftRequest(URLRequest(@"https://archive.2.26.254.34.sslip.io.evil.test/v1/pro/gifts/send")), "host suffix spoof excluded");
    CHECK(!SGIsGiftRequest(URLRequest(@"https://evil.archive.2.26.254.34.sslip.io/v1/pro/gifts/send")), "subdomains excluded");
    CHECK(!SGIsGiftRequest(URLRequest(@"https://archive.2.26.254.34.sslip.io@evil.test/v1/pro/gifts/send")), "userinfo host spoof excluded");
    CHECK(!SGIsGiftRequest(URLRequest(@"https://archive.2.26.254.34.sslip.io/v1/pro/gifts")), "bare prefix excluded");
    CHECK(!SGIsGiftRequest(URLRequest(@"https://archive.2.26.254.34.sslip.io/v1/pro/gifts-other/send")), "similar endpoint excluded");
    CHECK(!SGIsGiftRequest(URLRequest(@"https://archive.2.26.254.34.sslip.io/v1/pro/gifts/../sessions")), "path traversal excluded");
    CHECK(!SGIsGiftRequest(URLRequest(@"file://archive.2.26.254.34.sslip.io/v1/pro/gifts/send")), "nonnetwork URL excluded");
    NSMutableURLRequest *request = [URLRequest(@"https://archive.2.26.254.34.sslip.io/v1/pro/gifts/send") mutableCopy];
    NSDictionary *original = Request(@"Сообщение 🎁");
    request.HTTPBody = JSON(original);
    [request setValue:@"test-authorization-do-not-persist" forHTTPHeaderField:@"Authorization"];
    CHECK([SGParseRequest(request) isEqual:original], "parse body without altering content");
    CHECK([[request valueForHTTPHeaderField:@"Authorization"] isEqualToString:@"test-authorization-do-not-persist"], "request header unchanged");
    request.HTTPBody = [@"[1,2,3]" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK(SGParseRequest(request) == nil, "array request rejected");
    request.HTTPBody = [@"not-json" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK(SGParseRequest(request) == nil, "invalid request rejected");
    request.HTTPBody = nil;
    CHECK(SGParseRequest(request) == nil, "empty request rejected");
}

static void TestMetadataAndRequestPreservation(void) {
    for (NSArray<NSNumber *> *pair in @[@[@7, @9], @[@7, @(-1)], @[@(-1), @9], @[@0, @4095]]) {
        NSInteger model = pair[0].integerValue, backdrop = pair[1].integerValue;
        NSString *human = @"Привет 🎁";
        NSDictionary *original = Request(human);
        NSData *originalBytes = JSON(original);
        NSError *error = nil;
        NSDictionary *prepared = Parse(SGPrepareSendBody(originalBytes, model, backdrop, &error));
        CHECK(error == nil, "valid selection accepted");
        CHECK(prepared[@"model"] == nil && prepared[@"backdrop"] == nil, "unsupported style parameters are not introduced");
        CHECK([[NSSet setWithArray:prepared.allKeys] isEqual:[NSSet setWithArray:original.allKeys]], "native request schema preserved");
        for (NSString *key in original) {
            if (![key isEqualToString:@"text"]) CHECK([prepared[key] isEqual:original[key]], "unrelated request field preserved");
        }
        NSString *clean = nil;
        NSDictionary *decoded = SGDecodeGiftStyle(prepared[@"text"], &clean);
        CHECK([clean isEqualToString:human], "original human message recovered");
        CHECK([decoded[@"model"] isEqual:@(model)] && [decoded[@"backdrop"] isEqual:@(backdrop)], "metadata model/background roundtrip");
        CHECK([prepared[@"text"] length] == human.length + 29, "metadata has exact 29 UTF16 units");
        CHECK([Parse(originalBytes) isEqual:original], "input bytes not changed");
    }
    NSDictionary *noText = Parse(SGPrepareSendBody(JSON(Request(nil)), -1, -1, NULL));
    CHECK(noText[@"text"] == nil, "random/random preserves missing text");
    CHECK([noText isEqual:Request(nil)], "random/random leaves all original request fields unchanged");
    NSDictionary *random = Parse(SGPrepareSendBody(JSON(Request(@"plain")), -1, -1, NULL));
    CHECK([random[@"text"] isEqualToString:@"plain"], "random/random adds no suffix");
    NSMutableDictionary *nullRequest = [Request(nil) mutableCopy]; nullRequest[@"text"] = NSNull.null;
    NSDictionary *nullPrepared = Parse(SGPrepareSendBody(JSON(nullRequest), -1, -1, NULL));
    CHECK(nullPrepared[@"text"] == NSNull.null, "random/random preserves null text");
    NSMutableDictionary *unknownRequest = [Request(@"preserve") mutableCopy];
    unknownRequest[@"model"] = @123;
    unknownRequest[@"backdrop"] = @321;
    unknownRequest[@"future_parameter"] = @{@"keep": @YES};
    NSDictionary *unknownPrepared = Parse(SGPrepareSendBody(JSON(unknownRequest), 7, 9, NULL));
    CHECK([unknownPrepared[@"model"] isEqual:@123] && [unknownPrepared[@"backdrop"] isEqual:@321], "preexisting unknown style fields preserved rather than replaced");
    CHECK([unknownPrepared[@"future_parameter"] isEqual:unknownRequest[@"future_parameter"]], "preexisting future parameter preserved");
    CHECK([[NSSet setWithArray:unknownPrepared.allKeys] isEqual:[NSSet setWithArray:unknownRequest.allKeys]], "no additional unknown request fields");
    NSString *old = Tagged(@"message", 1, 2);
    NSString *retagged = Parse(SGPrepareSendBody(JSON(Request(old)), 3, -1, NULL))[@"text"];
    CHECK(retagged.length == @"message".length + 29, "retagging does not stack suffixes");
    NSString *clean = nil;
    CHECK([SGDecodeGiftStyle(retagged, &clean)[@"model"] isEqual:@3], "new choice replaces old model");
    CHECK([clean isEqualToString:@"message"], "retagging preserves message");
    NSDictionary *cleared = Parse(SGPrepareSendBody(JSON(Request(retagged)), -1, -1, NULL));
    CHECK([cleared[@"text"] isEqualToString:@"message"], "random/random clears prior suffix");
}

static void TestMessageBoundariesAndErrors(void) {
    NSError *error = nil;
    NSData *accepted = SGPrepareSendBody(JSON(Request(Repeat(@"a", 99))), 2, -1, &error);
    CHECK(accepted != nil && error == nil, "99 UTF16 units accepted for fixed style");
    CHECK([Parse(accepted)[@"text"] length] == 128, "max message includes exact metadata budget");
    error = nil;
    CHECK(SGPrepareSendBody(JSON(Request(Repeat(@"a", 100))), -1, 2, &error) == nil && error.code == SGRequestLogicTextTooLong, "100 UTF16 units rejected without truncation");
    NSString *emojiBoundary = [Repeat(@"a", 97) stringByAppendingString:@"🎁"];
    CHECK(emojiBoundary.length == 99 && SGPrepareSendBody(JSON(Request(emojiBoundary)), 1, 2, NULL) != nil, "surrogate pair counted as two UTF16 units");
    CHECK(SGPrepareSendBody(JSON(Request(Repeat(@"a", 128))), -1, -1, NULL) != nil, "random style retains original full message capacity");
    error = nil;
    CHECK(SGPrepareSendBody([@"not-json" dataUsingEncoding:NSUTF8StringEncoding], 0, 0, &error) == nil && error.code == SGRequestLogicInvalidJSON, "malformed request returns error");
    error = nil;
    CHECK(SGPrepareSendBody(JSON(@[]), 0, 0, &error) == nil && error.code == SGRequestLogicInvalidJSON, "array request returns error");
    error = nil;
    CHECK(SGPrepareSendBody(JSON(Request(@"ok")), -2, 0, &error) == nil && error.code == SGRequestLogicInvalidSelection, "model below random sentinel rejected");
    error = nil;
    CHECK(SGPrepareSendBody(JSON(Request(@"ok")), 0, 4096, &error) == nil && error.code == SGRequestLogicInvalidSelection, "background above allowed index rejected");
    NSMutableDictionary *badText = [Request(nil) mutableCopy]; badText[@"text"] = @42;
    error = nil;
    CHECK(SGPrepareSendBody(JSON(badText), 0, 0, &error) == nil && error.code == SGRequestLogicInvalidText, "nonstring message rejected");
}

static void TestMalformedMetadata(void) {
    NSString *valid = Tagged(@"keep", 7, 9);
    NSMutableString *badChecksum = [valid mutableCopy];
    NSUInteger payloadIndex = @"keep".length + 3 + 23;
    unichar old = [badChecksum characterAtIndex:payloadIndex];
    unichar altered = old == 0xFE0F ? 0xFE00 : old + 1;
    [badChecksum replaceCharactersInRange:NSMakeRange(payloadIndex, 1) withString:[NSString stringWithCharacters:&altered length:1]];
    NSMutableString *badSelector = [valid mutableCopy];
    [badSelector replaceCharactersInRange:NSMakeRange(@"keep".length + 3, 1) withString:@"x"];
    NSString *notAtEnd = [valid stringByAppendingString:@"ordinary text"];
    for (NSString *text in @[badChecksum, badSelector, notAtEnd, @"ordinary ☺️", @"\u2063\u2060\u2063short\u2063\u2060"]) {
        NSString *clean = nil;
        CHECK(SGDecodeGiftStyle(text, &clean) == nil, "malformed/nonmetadata not decoded");
        CHECK([clean isEqualToString:text], "invalid suffix preserved byte-for-byte as text");
    }
}

static void TestResponsesAndPersistence(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:SGGiftStyleDefaultsKey];
    NSDictionary *original = Gift(@101, Tagged(@"Hello", 11, -1));
    NSData *originalBytes = JSON(original);
    NSDictionary *rewritten = Parse(SGRewriteGiftResponse(originalBytes, nil));
    CHECK([rewritten[@"text"] isEqualToString:@"Hello"], "response message metadata stripped");
    CHECK([rewritten[@"unique"][@"model"] isEqual:@11], "fixed model applied");
    CHECK([rewritten[@"unique"][@"backdrop"] isEqual:@3], "random background retains backend selection");
    CHECK([rewritten[@"unique"][@"pattern"] isEqual:@4], "pattern unchanged");
    for (NSString *key in @[@"id", @"gift", @"owner", @"date", @"number", @"saved", @"pinned", @"hidden", @"sender", @"prepaid", @"history"]) {
        CHECK([rewritten[key] isEqual:original[key]], "unrelated gift fields preserved");
    }
    CHECK([Parse(originalBytes) isEqual:original], "original response remains unchanged");
    NSDictionary *stored = [defaults dictionaryForKey:SGGiftStyleDefaultsKey];
    CHECK(([stored[@"101"] isEqual:@{@"model": @11, @"backdrop": @(-1)}]), "only style indexes remembered by gift ID");

    NSDictionary *plainGift = Gift(@101, @"Hello");
    NSDictionary *persisted = Parse(SGRewriteGiftResponse(JSON(plainGift), nil));
    CHECK([persisted[@"unique"][@"model"] isEqual:@11], "style survives refetch without metadata");
    NSDictionary *callerOverride = @{ @"101": @{ @"model": @(-1), @"backdrop": @22 } };
    NSDictionary *fallback = Parse(SGRewriteGiftResponse(JSON(plainGift), callerOverride));
    CHECK([fallback[@"unique"][@"model"] isEqual:@2] && [fallback[@"unique"][@"backdrop"] isEqual:@22], "caller fallback independently overrides saved style");
    NSDictionary *afterFallbackRefetch = Parse(SGRewriteGiftResponse(JSON(plainGift), nil));
    CHECK([afterFallbackRefetch[@"unique"][@"backdrop"] isEqual:@22] && [afterFallbackRefetch[@"unique"][@"model"] isEqual:@2], "caller fallback persists if server removed metadata");
    NSDictionary *metadataPriority = Parse(SGRewriteGiftResponse(JSON(original), callerOverride));
    CHECK([metadataPriority[@"unique"][@"model"] isEqual:@11] && [metadataPriority[@"unique"][@"backdrop"] isEqual:@3], "valid metadata takes priority over all fallbacks");

    NSMutableDictionary *generic = [Gift(@103, Tagged(@"generic", -1, 23)) mutableCopy];
    generic[@"unique"] = NSNull.null;
    NSDictionary *list = @{ @"gifts": @[original, Gift(@102, Tagged(@"second", -1, 12)), generic],
                            @"count": @3, @"next": @4, @"unrelated": @[@"preserve", NSNull.null] };
    NSDictionary *listResult = Parse(SGRewriteGiftResponse(JSON(list), nil));
    CHECK([listResult[@"count"] isEqual:@3] && [listResult[@"next"] isEqual:@4], "list pagination preserved");
    CHECK([listResult[@"unrelated"] isEqual:list[@"unrelated"]], "unrelated response payload preserved");
    CHECK([listResult[@"gifts"][1][@"unique"][@"model"] isEqual:@2] && [listResult[@"gifts"][1][@"unique"][@"backdrop"] isEqual:@12], "random model plus fixed background");
    CHECK(listResult[@"gifts"][2][@"unique"] == NSNull.null && [listResult[@"gifts"][2][@"text"] isEqualToString:@"generic"], "generic gift remains generic and metadata is hidden");
    NSDictionary *envelope = @{ @"ok": @YES, @"gift": Gift(@104, Tagged(@"sent", 1, 2)), @"balance": @12345 };
    NSDictionary *envelopeResult = Parse(SGRewriteGiftResponse(JSON(envelope), nil));
    CHECK([envelopeResult[@"gift"][@"unique"][@"model"] isEqual:@1] && [envelopeResult[@"balance"] isEqual:@12345], "single send envelope rewritten safely");
    NSArray *rootArray = Parse(SGRewriteGiftResponse(JSON(@[Gift(@105, Tagged(@"array", 5, 6))]), nil));
    CHECK([rootArray[0][@"unique"][@"backdrop"] isEqual:@6], "root array supported");

    NSDictionary *unrelated = @{ @"id": @111, @"gift": @{ @"title": @"not a gift instance" }, @"text": Tagged(@"leave", 2, 4) };
    NSData *unrelatedBytes = JSON(unrelated);
    CHECK([SGRewriteGiftResponse(unrelatedBytes, nil) isEqualToData:unrelatedBytes], "unrelated dictionary unchanged");
    NSData *formatted = [@"{ \"unrelated\" : [1, 2], \"text\" : \"same\" }\n" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([SGRewriteGiftResponse(formatted, nil) isEqualToData:formatted], "untouched JSON retains original formatting bytes");
    NSData *invalid = [@"not JSON\0binary" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([SGRewriteGiftResponse(invalid, nil) isEqualToData:invalid], "invalid response returned intact");
    NSDictionary *invalidStyle = @{ @"101": @{ @"model": @2.5, @"backdrop": @8 } };
    NSDictionary *invalidFallback = Parse(SGRewriteGiftResponse(JSON(plainGift), invalidStyle));
    CHECK([invalidFallback[@"unique"][@"model"] isEqual:@11], "invalid caller style falls back to saved valid choice");
    SGRememberGiftStyle(@"101", -1, -1);
    CHECK([defaults dictionaryForKey:SGGiftStyleDefaultsKey][@"101"] == nil, "random/random removes prior saved choice");
    NSDictionary *before = [defaults dictionaryForKey:SGGiftStyleDefaultsKey];
    SGRememberGiftStyle(@"not-an-id-or-a-token", 1, 2);
    SGRememberGiftStyle(@"999", -2, 2);
    CHECK([[defaults dictionaryForKey:SGGiftStyleDefaultsKey] isEqual:before], "invalid identity/style not persisted");
}

int main(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id originalStyles = [defaults objectForKey:SGGiftStyleDefaultsKey];
        @try {
            TestScopeAndParsing();
            TestMetadataAndRequestPreservation();
            TestMessageBoundariesAndErrors();
            TestMalformedMetadata();
            TestResponsesAndPersistence();
        } @finally {
            if (originalStyles) [defaults setObject:originalStyles forKey:SGGiftStyleDefaultsKey];
            else [defaults removeObjectForKey:SGGiftStyleDefaultsKey];
        }
        if (failures) {
            fprintf(stderr, "%lu request logic check(s) failed\n", (unsigned long)failures);
            return 1;
        }
        puts("PASS: scoped gift requests, independent styles, metadata integrity, text boundaries, response envelopes and persistence");
        return 0;
    }
}
