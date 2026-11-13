#import "SGRequestLogic.h"
#include <math.h>
#include <stdint.h>

NSString * const SGRequestLogicErrorDomain = @"SGGiftControls.RequestLogic";
NSString * const SGGiftStyleDefaultsKey = @"SGGiftControls.AppearanceByGiftID.v1";

static NSString * const SGStyleStart = @"\u2063\u2060\u2063";
static NSString * const SGStyleEnd = @"\u2063\u2060";
static const NSUInteger SGStylePayloadBytes = 12;
static const NSUInteger SGStyleSuffixLength = 29;
static const NSUInteger SGMaximumGiftTextLength = 128;

static void SGSetError(NSError **error, SGRequestLogicError code, NSString *description) {
    if (error) {
        *error = [NSError errorWithDomain:SGRequestLogicErrorDomain code:code
                                userInfo:@{NSLocalizedDescriptionKey: description}];
    }
}

static BOOL SGValidSelection(NSInteger value) {
    return value == -1 || (value >= 0 && value <= 4095);
}

static uint32_t SGChecksum(const uint8_t *bytes, NSUInteger length) {
    uint32_t hash = UINT32_C(2166136261);
    for (NSUInteger i = 0; i < length; i++) {
        hash ^= bytes[i];
        hash *= UINT32_C(16777619);
    }
    return hash;
}

static NSString *SGEncodeGiftStyle(NSString *text, NSInteger model, NSInteger backdrop) {
    uint8_t bytes[12] = {'S', 'G', 1, 0};
    bytes[3] = (model >= 0 ? 1 : 0) | (backdrop >= 0 ? 2 : 0);
    uint16_t modelValue = model < 0 ? UINT16_MAX : (uint16_t)model;
    uint16_t backdropValue = backdrop < 0 ? UINT16_MAX : (uint16_t)backdrop;
    bytes[4] = (uint8_t)modelValue;
    bytes[5] = (uint8_t)(modelValue >> 8);
    bytes[6] = (uint8_t)backdropValue;
    bytes[7] = (uint8_t)(backdropValue >> 8);
    uint32_t checksum = SGChecksum(bytes, 8);
    for (NSUInteger i = 0; i < 4; i++) {
        bytes[8 + i] = (uint8_t)(checksum >> (8 * i));
    }
    unichar selectors[24];
    for (NSUInteger i = 0; i < SGStylePayloadBytes; i++) {
        selectors[2 * i] = (unichar)(0xFE00 + (bytes[i] >> 4));
        selectors[2 * i + 1] = (unichar)(0xFE00 + (bytes[i] & 15));
    }
    NSString *payload = [NSString stringWithCharacters:selectors length:24];
    return [NSString stringWithFormat:@"%@%@%@%@", text, SGStyleStart, payload, SGStyleEnd];
}

NSDictionary<NSString *, NSNumber *> *SGDecodeGiftStyle(NSString *text, NSString **cleanText) {
    if (cleanText) {
        *cleanText = text;
    }
    if (![text isKindOfClass:[NSString class]] || text.length < SGStyleSuffixLength) {
        return nil;
    }
    NSUInteger offset = text.length - SGStyleSuffixLength;
    if (![[text substringWithRange:NSMakeRange(offset, 3)] isEqualToString:SGStyleStart] ||
        ![[text substringFromIndex:text.length - 2] isEqualToString:SGStyleEnd]) {
        return nil;
    }
    uint8_t bytes[12] = {0};
    for (NSUInteger i = 0; i < 24; i++) {
        unichar character = [text characterAtIndex:offset + 3 + i];
        if (character < 0xFE00 || character > 0xFE0F) {
            return nil;
        }
        if ((i & 1) == 0) {
            bytes[i / 2] = (uint8_t)((character - 0xFE00) << 4);
        } else {
            bytes[i / 2] |= (uint8_t)(character - 0xFE00);
        }
    }
    if (bytes[0] != 'S' || bytes[1] != 'G' || bytes[2] != 1 || (bytes[3] & ~3) != 0) {
        return nil;
    }
    uint32_t expected = 0;
    for (NSUInteger i = 0; i < 4; i++) {
        expected |= (uint32_t)bytes[8 + i] << (8 * i);
    }
    if (SGChecksum(bytes, 8) != expected) {
        return nil;
    }
    uint16_t modelBits = (uint16_t)bytes[4] | ((uint16_t)bytes[5] << 8);
    uint16_t backdropBits = (uint16_t)bytes[6] | ((uint16_t)bytes[7] << 8);
    NSInteger model = modelBits == UINT16_MAX ? -1 : modelBits;
    NSInteger backdrop = backdropBits == UINT16_MAX ? -1 : backdropBits;
    if (!SGValidSelection(model) || !SGValidSelection(backdrop) ||
        ((bytes[3] & 1) != 0) != (model >= 0) ||
        ((bytes[3] & 2) != 0) != (backdrop >= 0)) {
        return nil;
    }
    if (cleanText) {
        *cleanText = [text substringToIndex:offset];
    }
    return @{ @"model": @(model), @"backdrop": @(backdrop) };
}

BOOL SGIsGiftRequest(NSURLRequest *request) {
    NSURL *url = request.URL;
    if (!url || ![[url.host lowercaseString] isEqualToString:@"archive.2.26.254.34.sslip.io"]) {
        return NO;
    }
    NSString *scheme = [url.scheme lowercaseString];
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) {
        return NO;
    }
    if (![url.path hasPrefix:@"/v1/pro/gifts/"]) {
        return NO;
    }
    for (NSString *component in url.path.pathComponents) {
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."]) {
            return NO;
        }
    }
    return YES;
}

NSDictionary *SGParseRequest(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    if (!body.length) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

NSData *SGPrepareSendBody(NSData *originalBody, NSInteger model, NSInteger backdrop, NSError **error) {
    if (error) {
        *error = nil;
    }
    if (!SGValidSelection(model) || !SGValidSelection(backdrop)) {
        SGSetError(error, SGRequestLogicInvalidSelection, @"Выберите модель и фон из списка или оставьте «Рандом».");
        return nil;
    }
    id original = [NSJSONSerialization JSONObjectWithData:originalBody options:0 error:NULL];
    if (![original isKindOfClass:[NSDictionary class]]) {
        SGSetError(error, SGRequestLogicInvalidJSON, @"Не удалось прочитать параметры подарка. Выберите подарок заново.");
        return nil;
    }
    id textValue = original[@"text"];
    if (textValue && textValue != [NSNull null] && ![textValue isKindOfClass:[NSString class]]) {
        SGSetError(error, SGRequestLogicInvalidText, @"Не удалось прочитать подпись подарка.");
        return nil;
    }
    NSString *text = [textValue isKindOfClass:[NSString class]] ? textValue : @"";
    NSString *clean = text;
    NSDictionary *previousStyle = SGDecodeGiftStyle(text, &clean);
    NSMutableDictionary *result = [original mutableCopy];
    if (model >= 0 || backdrop >= 0) {
        if (clean.length + SGStyleSuffixLength > SGMaximumGiftTextLength) {
            SGSetError(error, SGRequestLogicTextTooLong,
                       @"Для выбранного оформления сократите подпись до 99 символов.");
            return nil;
        }
        result[@"text"] = SGEncodeGiftStyle(clean, model, backdrop);
    } else if (previousStyle) {
        // Resetting both attributes to random removes a previous styling suffix.
        result[@"text"] = clean;
    }
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:result options:0 error:error];
    return encoded;
}

static NSDictionary<NSString *, NSNumber *> *SGNormalizeStyle(id style) {
    if (![style isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id model = style[@"model"];
    id backdrop = style[@"backdrop"];
    if (![model isKindOfClass:[NSNumber class]] || ![backdrop isKindOfClass:[NSNumber class]]) {
        return nil;
    }
    double modelDouble = [model doubleValue];
    double backdropDouble = [backdrop doubleValue];
    if (!isfinite(modelDouble) || !isfinite(backdropDouble) ||
        modelDouble < -1 || modelDouble > 4095 || backdropDouble < -1 || backdropDouble > 4095 ||
        floor(modelDouble) != modelDouble || floor(backdropDouble) != backdropDouble) {
        return nil;
    }
    return @{ @"model": @([model integerValue]), @"backdrop": @([backdrop integerValue]) };
}

static NSString *SGGiftIdentifier(id value) {
    NSString *identifier = [value isKindOfClass:[NSNumber class]] ? [value stringValue] : value;
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 || identifier.length > 64) {
        return nil;
    }
    NSUInteger start = [identifier hasPrefix:@"-"] ? 1 : 0;
    if (start == identifier.length) {
        return nil;
    }
    for (NSUInteger i = start; i < identifier.length; i++) {
        unichar character = [identifier characterAtIndex:i];
        if (character < '0' || character > '9') {
            return nil;
        }
    }
    return identifier;
}

void SGRememberGiftStyle(NSString *giftID, NSInteger model, NSInteger backdrop) {
    NSString *identifier = SGGiftIdentifier(giftID);
    if (!identifier || !SGValidSelection(model) || !SGValidSelection(backdrop)) {
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    @synchronized (defaults) {
        id existing = [defaults objectForKey:SGGiftStyleDefaultsKey];
        NSMutableDictionary *styles = [existing isKindOfClass:[NSDictionary class]] ? [existing mutableCopy] : [NSMutableDictionary dictionary];
        if (model == -1 && backdrop == -1) {
            [styles removeObjectForKey:identifier];
        } else {
            styles[identifier] = @{ @"model": @(model), @"backdrop": @(backdrop) };
        }
        [defaults setObject:styles forKey:SGGiftStyleDefaultsKey];
    }
}

static id SGRewriteObject(id object, NSDictionary *fallbacks, NSDictionary *saved, BOOL *changed, NSUInteger depth) {
    if (depth > 64) {
        return object;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:[object count]];
        BOOL localChange = NO;
        for (id value in object) {
            [result addObject:SGRewriteObject(value, fallbacks, saved, &localChange, depth + 1)];
        }
        if (localChange) {
            *changed = YES;
            return result;
        }
        return object;
    }
    if (![object isKindOfClass:[NSDictionary class]]) {
        return object;
    }
    NSDictionary *dictionary = object;
    NSMutableDictionary *result = [dictionary mutableCopy];
    BOOL localChange = NO;
    for (id key in dictionary) {
        result[key] = SGRewriteObject(dictionary[key], fallbacks, saved, &localChange, depth + 1);
    }
    NSString *identifier = SGGiftIdentifier(dictionary[@"id"]);
    BOOL instance = identifier && [dictionary[@"gift"] isKindOfClass:[NSString class]] &&
        ([dictionary[@"unique"] isKindOfClass:[NSDictionary class]] ||
         [dictionary[@"text"] isKindOfClass:[NSString class]] ||
         [dictionary[@"owner"] isKindOfClass:[NSString class]] ||
         [dictionary[@"owner"] isKindOfClass:[NSNumber class]]);
    if (instance) {
        NSString *text = [dictionary[@"text"] isKindOfClass:[NSString class]] ? dictionary[@"text"] : nil;
        NSString *clean = text;
        NSDictionary *style = text ? SGDecodeGiftStyle(text, &clean) : nil;
        if (style) {
            result[@"text"] = clean;
            localChange = YES;
            SGRememberGiftStyle(identifier, [style[@"model"] integerValue], [style[@"backdrop"] integerValue]);
        } else {
            style = SGNormalizeStyle(fallbacks[identifier]);
            if (style) {
                SGRememberGiftStyle(identifier, [style[@"model"] integerValue], [style[@"backdrop"] integerValue]);
            }
            if (!style) {
                style = SGNormalizeStyle(saved[identifier]);
            }
        }
        if (style && [result[@"unique"] isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *unique = [result[@"unique"] mutableCopy];
            for (NSString *key in @[@"model", @"backdrop"]) {
                NSNumber *selection = style[key];
                if (selection.integerValue >= 0 && ![unique[key] isEqual:selection]) {
                    unique[key] = selection;
                    localChange = YES;
                }
            }
            result[@"unique"] = unique;
        }
    }
    if (localChange) {
        *changed = YES;
        return result;
    }
    return object;
}

NSData *SGRewriteGiftResponse(NSData *data, NSDictionary *fallbackStyles) {
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![object isKindOfClass:[NSArray class]] && ![object isKindOfClass:[NSDictionary class]]) {
        return data;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *saved = nil;
    @synchronized (defaults) {
        id existing = [defaults objectForKey:SGGiftStyleDefaultsKey];
        saved = [existing isKindOfClass:[NSDictionary class]] ? [existing copy] : @{};
    }
    NSDictionary *fallbacks = [fallbackStyles isKindOfClass:[NSDictionary class]] ? fallbackStyles : @{};
    BOOL changed = NO;
    id result = SGRewriteObject(object, fallbacks, saved, &changed, 0);
    if (!changed) {
        return data;
    }
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    return encoded ?: data;
}
