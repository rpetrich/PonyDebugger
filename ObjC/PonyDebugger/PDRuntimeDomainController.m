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

// Values are arrays of object references.
@property (nonatomic, strong) NSMutableDictionary *objectGroups;

+ (NSString *)_generateUUID;

- (void)_releaseObjectID:(NSString *)objectID;
- (void)_releaseObjectGroup:(NSString *)objectGroup;

@end


@implementation PDRuntimeDomainController {
    JSGlobalContextRef context;
    JSStringRef underscorePropertyName;
    size_t maxInspectedDepth;
}

@dynamic domain;

@synthesize objectReferences = _objectReferences;
@synthesize objectGroups = _objectGroups;

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

- (id)init;
{
    if (!(self = [super init])) {
        return nil;
    }
    
    self.objectReferences = [[NSMutableDictionary alloc] init];
    self.objectGroups = [[NSMutableDictionary alloc] init];

    context = JSGlobalContextCreate(NULL);
    CydgetSetupContext(context);
    underscorePropertyName = JSStringCreateWithUTF8CString("_");
    
    return self;
}

- (void)dealloc;
{
    JSStringRelease(underscorePropertyName);
    JSGlobalContextRelease(context);
    self.objectReferences = nil;
    self.objectGroups = nil;
}

#pragma mark - PDRuntimeCommandDelegate

- (void)domain:(PDRuntimeDomain *)domain getPropertiesWithObjectId:(NSString *)objectId ownProperties:(NSNumber *)ownProperties callback:(void (^)(NSArray *result, id error))callback;
{
    NSObject *object = [self.objectReferences objectForKey:objectId];
    if (!object) {
        NSString *errorMessage = [NSString stringWithFormat:@"Object with objectID '%@' does not exist.", objectId];
        NSError *error = [NSError errorWithDomain:PDDebuggerErrorDomain code:100 userInfo:[NSDictionary dictionaryWithObject:errorMessage forKey:NSLocalizedDescriptionKey]];
        
        callback(nil, error);
        return;
    }
    
    NSArray *properties = [object PD_propertyDescriptors];
    callback(properties, nil);
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
            NSString *result = (__bridge_transfer NSString *)JSStringCopyCFString(kCFAllocatorDefault, string);
            JSStringRelease(string);
            return result;
        }
    }
}

- (void)domain:(PDRuntimeDomain *)domain evaluateWithExpression:(NSString *)expression objectGroup:(NSString *)objectGroup includeCommandLineAPI:(NSNumber *)includeCommandLineAPI doNotPauseOnExceptionsAndMuteConsole:(NSNumber *)doNotPauseOnExceptionsAndMuteConsole contextId:(NSNumber *)contextId returnByValue:(NSNumber *)returnByValue callback:(void (^)(PDRuntimeRemoteObject *result, NSNumber *wasThrown, id error))callback
{
    if (![objectGroup isEqualToString:@"completion"]) {
        // Convert from Cycript to JavaScript
        size_t length = [expression length];
        unichar *buffer = malloc(length * sizeof(unichar));
        [expression getCharacters:buffer range:NSMakeRange(0, length)];
        const uint16_t *characters = buffer;
        apr_pool_t *pool = NULL;
        apr_pool_create(&pool, NULL);
        CydgetPoolParse(pool, &characters, &length);
        //JSStringRef jsExpression = JSStringCreateWithCFString((__bridge CFStringRef)expression);
        JSStringRef jsExpression = JSStringCreateWithCharacters(characters, length);
        free(buffer);
        apr_pool_destroy(pool);

        JSValueRef exception = NULL;
        JSValueRef value = JSEvaluateScript(context, jsExpression, NULL, NULL, 0, &exception);
        JSStringRelease(jsExpression);
        if (value) {
            NSString *result = NSObjectFromJSValue(context, value);
            callback([NSObject PD_remoteObjectRepresentationForObject:result], nil, nil);
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
    if (![self.objectReferences objectForKey:objectID]) {
        return;
    }
    
    [self.objectReferences removeObjectForKey:objectID];
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
