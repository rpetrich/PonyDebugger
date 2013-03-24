//
//  PDRuntimeDomainController.m
//  PonyDebugger
//
//  Created by Wen-Hao Lue on 8/7/12.
//
//  Licensed to Square, Inc. under one or more contributor license agreements.
//  See the LICENSE file distributed with this work for the terms under
//  which Square, Inc. licenses this file to you.
//

#import "PDRuntimeDomainController.h"
#import "PDRuntimeTypes.h"
#import "PDDOMDomainController.h"

#import "NSObject+PDRuntimePropertyDescriptor.h"
#import "NSManagedObject+PDRuntimePropertyDescriptor.h"
#import "NSArray+PDRuntimePropertyDescriptor.h"
#import "NSSet+PDRuntimePropertyDescriptor.h"
#import "NSOrderedSet+PDRuntimePropertyDescriptor.h"
#import "NSDictionary+PDRuntimePropertyDescriptor.h"

#import <JavaScriptCore/JSContextRef.h>
#import <JavaScriptCore/JSStringRef.h>
#import <JavaScriptCore/JSStringRefCF.h>
#import <JavaScriptCore/JSValueRef.h>

#import <apr-1/apr_pools.h>
#import <cycript.h>

@interface PDRuntimeDomainController () <PDRuntimeCommandDelegate>

// Dictionary where key is a unique objectId, and value is a reference of the value.
@property (nonatomic, strong) NSMutableDictionary *objectReferences;

// Dictionary where key is a unique objectId, and value is a JSObjectRef of the value.
@property (nonatomic, assign) CFMutableDictionaryRef jsValueReferences;

// Values are arrays of object references.
@property (nonatomic, strong) NSMutableDictionary *objectGroups;

+ (NSString *)_generateUUID;

- (void)_releaseObjectID:(NSString *)objectID;
- (void)_releaseObjectGroup:(NSString *)objectGroup;

@end


@implementation PDRuntimeDomainController {
    JSGlobalContextRef context;
    JSStringRef underscorePropertyName;
    JSStringRef lengthPropertyName;
    JSStringRef UTF8StringPropertyName;
    JSStringRef __prettyPrintableOfPropertyPropertyName;
    JSStringRef __prettyPrintablePropertyName;
    size_t maxInspectedDepth;
    JSValueRef DateRef;
    JSValueRef RegExpRef;
    bool hasRunDebugScripts;
}

@dynamic domain;

@synthesize objectReferences = _objectReferences;
@synthesize objectGroups = _objectGroups;
@synthesize debugScriptPath = _debugScriptPath;

- (void)setDebugScriptPath:(NSString *)newValue
{
    _debugScriptPath = newValue;
    hasRunDebugScripts = false;
}

#pragma mark - Statics

+ (PDRuntimeDomainController *)defaultInstance;
{
    static PDRuntimeDomainController *defaultInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        apr_initialize();
        defaultInstance = [[PDRuntimeDomainController alloc] init];
    });
    
    return defaultInstance;
}

+ (Class)domainClass;
{
    return [PDRuntimeDomain class];
}

+ (NSString *)_generateUUID;
{
	CFUUIDRef UUIDRef = CFUUIDCreate(nil);
    NSString *newGuid = (__bridge_transfer NSString *) CFUUIDCreateString(nil, UUIDRef);
    CFRelease(UUIDRef);
    return newGuid;
}

#pragma mark - Initialization

static const void *JSValueRetainCallback(CFAllocatorRef allocator, const void *value)
{
    JSValueProtect([PDRuntimeDomainController defaultInstance]->context, value);
    return value;
}

static void JSValueReleaseCallback(CFAllocatorRef allocator, const void *value)
{
    JSValueUnprotect([PDRuntimeDomainController defaultInstance]->context, value);
}

- (id)init;
{
    if (!(self = [super init])) {
        return nil;
    }
    
    self.objectReferences = [[NSMutableDictionary alloc] init];
    CFDictionaryValueCallBacks valueCallbacks = { 0, JSValueRetainCallback, JSValueReleaseCallback, NULL, NULL };
    self.jsValueReferences = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &valueCallbacks);
    self.objectGroups = [[NSMutableDictionary alloc] init];

    context = JSGlobalContextCreate(NULL);
    CydgetSetupContext(context);
    underscorePropertyName = JSStringCreateWithUTF8CString("_");
    lengthPropertyName = JSStringCreateWithUTF8CString("length");
    UTF8StringPropertyName = JSStringCreateWithUTF8CString("UTF8String");
    __prettyPrintableOfPropertyPropertyName = JSStringCreateWithUTF8CString("__prettyPrintableOfProperty");
    __prettyPrintablePropertyName = JSStringCreateWithUTF8CString("__prettyPrintable");
    JSObjectRef global = JSContextGetGlobalObject(context);

    JSStringRef DateString = JSStringCreateWithUTF8CString("Date");
    DateRef = JSObjectGetProperty(context, global, DateString, NULL);
    JSValueProtect(context, DateRef);
    JSStringRelease(DateString);
    
    JSStringRef RegExpString = JSStringCreateWithUTF8CString("RegExp");
    RegExpRef = JSObjectGetProperty(context, global, RegExpString, NULL);
    JSValueProtect(context, RegExpRef);
    JSStringRelease(RegExpString);

    return self;
}

- (void)dealloc;
{
    JSValueUnprotect(context, RegExpRef);
    JSValueUnprotect(context, DateRef);
    JSStringRelease(underscorePropertyName);
    JSStringRelease(lengthPropertyName);
    JSStringRelease(UTF8StringPropertyName);
    JSStringRelease(__prettyPrintableOfPropertyPropertyName);
    JSStringRelease(__prettyPrintablePropertyName);
    JSGlobalContextRelease(context);
    self.objectReferences = nil;
    CFRelease(self.jsValueReferences);
    self.objectGroups = nil;
}

- (NSString *)prettyPrintableStringValueForObject:(JSObjectRef)object exception:(JSValueRef *)exception;
{
    JSValueRef prettyPrintableValue = JSObjectGetProperty(context, object, __prettyPrintablePropertyName, NULL);
    if (prettyPrintableValue) {
        JSObjectRef prettyPrintable = JSValueToObject(context, prettyPrintableValue, NULL);
        if (prettyPrintable) {
            JSValueRef localException = NULL;
            JSValueRef description = JSObjectCallAsFunction(context, prettyPrintable, object, 0, NULL, &localException);
            if (localException) {
                if (exception) {
                    *exception = localException;
                }
                return nil;
            }
            JSStringRef string = JSValueToStringCopy(context, description, &localException);
            if (localException) {
                if (exception) {
                    *exception = localException;
                }
                return nil;
            }
            if (string) {
                NSString *result = (__bridge_transfer NSString *)JSStringCopyCFString(kCFAllocatorDefault, string);
                JSStringRelease(string);
                return result;
            }
        }
    }
    return nil;
}

#pragma mark - PDRuntimeCommandDelegate

- (PDRuntimeRemoteObject *)remoteObjectForJSValue:(JSValueRef)value;
{
    if (!value)
        return nil;
    PDRuntimeRemoteObject *remoteValueObject = [[PDRuntimeRemoteObject alloc] init];
    switch (JSValueGetType(context, value)) {
        case kJSTypeUndefined:
            remoteValueObject.type = @"undefined";
            break;
        case kJSTypeNull:
            remoteValueObject.type = @"object";
            remoteValueObject.subtype = @"null";
            remoteValueObject.value = [NSNull null];
            break;
        case kJSTypeBoolean:
            remoteValueObject.type = @"boolean";
            remoteValueObject.value = JSValueToBoolean(context, value) ? (__bridge id)kCFBooleanTrue : (__bridge id)kCFBooleanFalse;
            break;
        case kJSTypeNumber: {
            remoteValueObject.type = @"number";
            double doubleValue = JSValueToNumber(context, value, NULL);
            switch (fpclassify(doubleValue)) {
                case FP_NAN:
                    remoteValueObject.value = @"NaN";
                    break;
                case FP_INFINITE:
                    remoteValueObject.value = isinf(doubleValue) < 0 ? @"-Infinity" : @"Infinity";
                    break;
                case FP_ZERO:
                case FP_SUBNORMAL:
                case FP_NORMAL:
                    remoteValueObject.value = [NSNumber numberWithDouble:doubleValue];
                    break;
            }
            break;
        }
        case kJSTypeString: {
            remoteValueObject.type = @"string";
            JSStringRef string = JSValueToStringCopy(context, value, NULL);
            if (string) {
                remoteValueObject.value = (__bridge_transfer NSString *)JSStringCopyCFString(kCFAllocatorDefault, string);
                JSStringRelease(string);
            }
            break;
        }
        case kJSTypeObject: {
            remoteValueObject.type = @"object";
            if (JSValueIsInstanceOfConstructor(context, value, JSValueToObject(context, DateRef, NULL), NULL)) {
                remoteValueObject.subtype = @"date";
            } else if (JSValueIsInstanceOfConstructor(context, value, JSValueToObject(context, RegExpRef, NULL), NULL)) {
                remoteValueObject.subtype = @"regexp";
            } else {
                JSObjectRef object = JSValueToObject(context, value, NULL);
                if (JSObjectHasProperty(context, object, UTF8StringPropertyName)) {
                    remoteValueObject.type = @"string";
                }
                remoteValueObject.objectDescription = [self prettyPrintableStringValueForObject:(JSObjectRef)value exception:NULL];
                NSString *key = [PDRuntimeDomainController _generateUUID];
                remoteValueObject.objectId = key;
                CFDictionarySetValue(self.jsValueReferences, (__bridge const void *)key, object);
            }
            if (remoteValueObject.objectDescription == nil) {
                JSStringRef string = JSValueToStringCopy(context, value, NULL);
                if (string) {
                    remoteValueObject.objectDescription = (__bridge_transfer NSString *)JSStringCopyCFString(kCFAllocatorDefault, string);
                    JSStringRelease(string);
                }
            }
            break;
        }
    }

    return remoteValueObject;
}

- (void)domain:(PDRuntimeDomain *)domain getPropertiesWithObjectId:(NSString *)objectId ownProperties:(NSNumber *)ownProperties callback:(void (^)(NSArray *result, id error))callback;
{
    JSValueRef value = CFDictionaryGetValue(self.jsValueReferences, (__bridge const void *)objectId);
    if (value) {
        NSMutableArray *result = [[NSMutableArray alloc] init];
        JSObjectRef object = JSValueToObject(context, value, NULL);
        JSValueRef lengthValue = JSObjectGetProperty(context, object, lengthPropertyName, NULL);
        double length;
        JSValueRef prettyPrintableOfPropertyValue = JSObjectGetProperty(context, object, __prettyPrintableOfPropertyPropertyName, NULL);
        JSObjectRef prettyPrintableOfProperty = prettyPrintableOfPropertyValue ? JSValueToObject(context, prettyPrintableOfPropertyValue, NULL) : 0;
        if (lengthValue && !isnan(length = JSValueToNumber(context, lengthValue, NULL))) {
            unsigned intLength = (unsigned)length;
            for (unsigned i = 0; i < intLength; i++) {
                NSString *name = [[NSNumber numberWithUnsignedInt:i] description];
                JSValueRef value;
                if (prettyPrintableOfProperty) {
                    JSStringRef propertyName = JSStringCreateWithCFString((__bridge CFStringRef)name);
                    const JSValueRef arguments[] = { JSValueMakeString(context, propertyName) };
                    JSValueRef exception = NULL;
                    value = JSObjectCallAsFunction(context, prettyPrintableOfProperty, object, 1, arguments, &exception);
                    JSStringRelease(propertyName);
                    if (exception) {
                        // Exception means we don't want this property to show up
                        continue;
                    }
                } else {
                    value = JSObjectGetPropertyAtIndex(context, object, i, NULL);
                }
                PDRuntimeRemoteObject *remoteObject = [self remoteObjectForJSValue:value];
                if (!remoteObject) {
                    continue;
                }
                PDRuntimePropertyDescriptor *descriptor = [[PDRuntimePropertyDescriptor alloc] init];
                descriptor.name = name;
                descriptor.value = remoteObject;
                descriptor.writable = [NSNumber numberWithBool:NO];
                descriptor.configurable = [NSNumber numberWithBool:NO];
                descriptor.enumerable = [NSNumber numberWithBool:YES];
                descriptor.wasThrown = [NSNumber numberWithBool:NO];
                [result addObject:descriptor];
            }
        } else {
            JSPropertyNameArrayRef properties = JSObjectCopyPropertyNames(context, object);
            size_t count = JSPropertyNameArrayGetCount(properties);
            for (size_t i = 0; i < count; i++) {
                JSStringRef propertyName = JSPropertyNameArrayGetNameAtIndex(properties, i);
                NSString *name = (__bridge_transfer NSString *)JSStringCopyCFString(kCFAllocatorDefault, propertyName);
                JSValueRef value;
                if (prettyPrintableOfProperty) {
                    const JSValueRef arguments[] = { JSValueMakeString(context, propertyName) };
                    JSValueRef exception = NULL;
                    value = JSObjectCallAsFunction(context, prettyPrintableOfProperty, object, 1, arguments, &exception);
                    if (exception) {
                        // Exception means we don't want this property to show up
                        continue;
                    }
                } else {
                    value = JSObjectGetProperty(context, object, propertyName, NULL);
                }
                PDRuntimeRemoteObject *remoteObject = [self remoteObjectForJSValue:value];
                if (!remoteObject) {
                    continue;
                }
                PDRuntimePropertyDescriptor *descriptor = [[PDRuntimePropertyDescriptor alloc] init];
                descriptor.name = name;
                descriptor.value = remoteObject;
                descriptor.wasThrown = [NSNumber numberWithBool:NO];
                descriptor.writable = [NSNumber numberWithBool:NO];
                descriptor.configurable = [NSNumber numberWithBool:NO];
                descriptor.enumerable = [NSNumber numberWithBool:YES];
                [result addObject:descriptor];
            }
            JSPropertyNameArrayRelease(properties);
        }
        callback(result, nil);
        return;
    }

    NSObject *object = [self.objectReferences objectForKey:objectId];
    if (object) {
        NSArray *properties = [object PD_propertyDescriptors];
        callback(properties, nil);
        return;
    }

    NSString *errorMessage = [NSString stringWithFormat:@"Object with objectID '%@' does not exist.", objectId];
    NSError *error = [NSError errorWithDomain:PDDebuggerErrorDomain code:100 userInfo:[NSDictionary dictionaryWithObject:errorMessage forKey:NSLocalizedDescriptionKey]];
    
    callback(nil, error);
}

- (void)domain:(PDRuntimeDomain *)domain releaseObjectWithObjectId:(NSString *)objectId callback:(void (^)(id error))callback;
{
    callback(nil);
    
    [self _releaseObjectID:objectId];
}

- (void)domain:(PDRuntimeDomain *)domain releaseObjectGroupWithObjectGroup:(NSString *)objectGroup callback:(void (^)(id error))callback;
{
    callback(nil);
    
    [self _releaseObjectGroup:objectGroup];
}

static inline id NSObjectFromJSValue(JSContextRef context, JSValueRef value) {
    if (!value)
        return nil;
    switch (JSValueGetType(context, value)) {
        case kJSTypeUndefined:
            return nil;
        case kJSTypeNull:
            return [NSNull null];
        case kJSTypeBoolean:
            return JSValueToBoolean(context, value) ? (__bridge id)kCFBooleanTrue : (__bridge id)kCFBooleanFalse;
        case kJSTypeNumber:
            return [NSNumber numberWithDouble:JSValueToNumber(context, value, NULL)];
        case kJSTypeString:
        case kJSTypeObject: {
            JSStringRef string = JSValueToStringCopy(context, value, NULL);
            NSString *result;
            if (string) {
                result = (__bridge_transfer NSString *)JSStringCopyCFString(kCFAllocatorDefault, string);
                JSStringRelease(string);
            } else {
                result = nil;
            }
            return result;
        }
    }
}

static JSStringRef CreateJSStringForCycriptExpression(NSString *expression)
{
    // Convert from Cycript to JavaScript
    size_t length = [expression length];
    unichar *buffer = malloc(length * sizeof(unichar));
    [expression getCharacters:buffer range:NSMakeRange(0, length)];
    const uint16_t *characters = buffer;
    apr_pool_t *pool = NULL;
    apr_pool_create(&pool, NULL);
    CydgetPoolParse(pool, &characters, &length);
    JSStringRef jsExpression = JSStringCreateWithCharacters(characters, length);
    free(buffer);
    apr_pool_destroy(pool);
    return jsExpression;
}

- (void)domain:(PDRuntimeDomain *)domain evaluateWithExpression:(NSString *)expression objectGroup:(NSString *)objectGroup includeCommandLineAPI:(NSNumber *)includeCommandLineAPI doNotPauseOnExceptionsAndMuteConsole:(NSNumber *)doNotPauseOnExceptionsAndMuteConsole contextId:(NSNumber *)contextId returnByValue:(NSNumber *)returnByValue callback:(void (^)(PDRuntimeRemoteObject *result, NSNumber *wasThrown, id error))callback
{
    if (![objectGroup isEqualToString:@"completion"]) {
        if (!hasRunDebugScripts && _debugScriptPath) {
            hasRunDebugScripts = YES;
            for (NSString *subpath in [[[NSFileManager alloc] init] contentsOfDirectoryAtPath:_debugScriptPath error:NULL]) {
                NSString *pathExtension = [[subpath pathExtension] lowercaseString];
                BOOL isCycript;
                if ([pathExtension isEqualToString:@"js"]) {
                    isCycript = NO;
                } else if ([pathExtension isEqualToString:@"cy"]) {
                    isCycript = YES;
                } else {
                    continue;
                }
                NSString *input = [NSString stringWithContentsOfFile:[_debugScriptPath stringByAppendingPathComponent:subpath] encoding:NSUTF8StringEncoding error:nil];
                if (!input)
                    continue;
                JSStringRef expression = isCycript ? CreateJSStringForCycriptExpression(input) : JSStringCreateWithCFString((__bridge CFStringRef)input);
                JSEvaluateScript(context, expression, NULL, NULL, 0, NULL);
                JSStringRelease(expression);
            }
        }
        JSStringRef jsExpression = CreateJSStringForCycriptExpression(expression);
        JSValueRef exception = NULL;
        JSValueRef value = JSEvaluateScript(context, jsExpression, NULL, NULL, 0, &exception);
        JSStringRelease(jsExpression);
        if (value) {
            callback([self remoteObjectForJSValue:value], nil, nil);
            JSObjectSetProperty(context, JSContextGetGlobalObject(context), underscorePropertyName, value, kJSClassAttributeNone, NULL);
            return;
        }
        if (exception) {
            NSString *result = NSObjectFromJSValue(context, exception);
            callback([NSObject PD_remoteObjectRepresentationForObject:result], (__bridge id)kCFBooleanTrue, nil);
        }
    }
    callback(nil, nil, nil);
}

#pragma mark - Public Methods

- (NSString *)registerAndGetKeyForObject:(id)object;
{
    NSString *key = [PDRuntimeDomainController _generateUUID];
    
    [self.objectReferences setObject:object forKey:key];
    
    return key;
}

- (void)clearAllObjectReferences;
{
    [self.objectReferences removeAllObjects];
    [self.objectGroups removeAllObjects];
}

- (void)inspectNodeWithId:(NSNumber *)nodeId;
{
    id object = [[PDDOMDomainController defaultInstance] objectForNodeId:nodeId];
    size_t i = 0;
    while (object || i < maxInspectedDepth) {
        NSString *expression = object ? [NSString stringWithFormat:@"$%zd = new Instance(%p)", i, object] : [NSString stringWithFormat:@"delete $%zd", i];
        JSStringRef jsExpression = JSStringCreateWithCFString((__bridge CFStringRef)expression);
        JSEvaluateScript(context, jsExpression, NULL, NULL, 0, NULL);
        JSStringRelease(jsExpression);
        object = [object isKindOfClass:[UIView class]] ? [object superview] : nil;
        i++;
        if (maxInspectedDepth < i)
            maxInspectedDepth = i;
    }
}

#pragma mark - Private Methods

- (void)_releaseObjectID:(NSString *)objectID;
{
    [self.objectReferences removeObjectForKey:objectID];
    CFDictionaryRemoveValue(self.jsValueReferences, (__bridge const void *)objectID);
}

- (void)_releaseObjectGroup:(NSString *)objectGroup;
{
    NSArray *objectIDs = [self.objectGroups objectForKey:objectGroup];
    if (objectIDs) {
        for (NSString *objectID in objectIDs) {
            [self _releaseObjectID:objectID];
        }
        
        [self.objectGroups removeObjectForKey:objectGroup];
    }
}

@end
