//
//  iTermExpressionEvaluator.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 2/28/19.
//

#import "iTermExpressionEvaluator.h"

#import "iTermAPIHelper.h"
#import "iTermFunctionCallParser.h"
#import "iTermScriptFunctionCall.h"
#import "iTermScriptHistory.h"
#import "iTermVariableScope.h"
#import "NSArray+iTerm.h"
#import "NSDictionary+iTerm.h"
#import "NSJSONSerialization+iTerm.h"
#import "NSObject+iTerm.h"
#import "NSStringITerm.h"

@implementation iTermExpressionEvaluator {
    id _value;
    id _object;
    iTermVariableScope *_scope;
    NSMutableArray<iTermExpressionEvaluator *> *_innerEvaluators;
}

- (instancetype)initWithObject:(id)object
                         scope:(iTermVariableScope *)scope {
    self = [super init];
    if (self) {
        _object = object;
        _scope = scope;
        _innerEvaluators = [NSMutableArray array];
    }
    return self;
}

- (instancetype)initWithExpressionString:(NSString *)expressionString
                                   scope:(iTermVariableScope *)scope {
    iTermParsedExpression *parsedExpression =
    [[iTermFunctionCallParser expressionParser] parse:expressionString
                                                scope:self->_scope];
    return [self initWithObject:parsedExpression scope:scope];
}

- (id)value {
    if (!_value) {
        [self evaluateObject:_object
                  withTimeout:0
                  completion:^(id result, NSError *error, NSSet<NSString *> *missing) {
            self->_value = result;
            self->_error = error;
            self->_missingValues = missing;
        }];
    }
    return _value;
}

- (void)evaluateWithTimeout:(NSTimeInterval)timeout
                 completion:(void (^)(iTermExpressionEvaluator *))completion {
    [self evaluateObject:_object
             withTimeout:timeout
              completion:^(id result, NSError *error, NSSet<NSString *> *missing) {
                  if (error) {
                      self->_value = nil;
                  } else {
                      self->_value = result ?: [NSNull null];
                  }
                  self->_error = error;
                  self->_missingValues = missing;
                  completion(self);
              }];
}

- (void)evaluateObject:(id)object
           withTimeout:(NSTimeInterval)timeout
            completion:(void (^)(id, NSError *, NSSet<NSString *> *))completion {
    if (!object) {
        completion([NSNull null], nil, nil);
        return;
    }

    iTermParsedExpression *parsedExpression = [iTermParsedExpression castFrom:object];
    if (parsedExpression) {
        [self evaluateParsedExpression:parsedExpression
                           withTimeout:timeout
                            completion:completion];
        return;
    }

    NSArray *array = [NSArray castFrom:object];
    if (array) {
        [self evaluateArray:array
                withTimeout:timeout
                 completion:completion];
        return;
    }

    if ([object isKindOfClass:[NSString class]]) {
        [self evaluateSwiftyString:object
                       withTimeout:timeout
                        completion:completion];
        return;
    }

    NSArray<Class> *classes = @[ [NSNumber class], [NSNull class] ];
    for (Class theClass in classes) {
        if ([object isKindOfClass:theClass]) {
            completion(object, nil, nil);
            return;
        }
    }

    NSError *error = [NSError errorWithDomain:@"com.iterm2.expression-evaluator"
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unrecognized type %@", [object class]]}];
    completion(nil, error, nil);
}

- (void)evaluateSwiftyString:(NSString *)string
                 withTimeout:(NSTimeInterval)timeout
                  completion:(void (^)(id, NSError *, NSSet<NSString *> *))completion {
    NSMutableArray *parts = [NSMutableArray array];
    __block NSError *firstError = nil;
    dispatch_group_t group = dispatch_group_create();
    NSMutableSet<NSString *> *missingFunctionSignatures = [NSMutableSet set];
    [string enumerateSwiftySubstrings:^(NSUInteger index, NSString *substring, BOOL isLiteral, BOOL *stop) {
        if (isLiteral) {
            [parts addObject:[substring it_stringByExpandingBackslashEscapedCharacters]];
        } else {
            dispatch_group_enter(group);
            [parts addObject:@""];

            iTermParsedExpression *parsedExpression =
            [[iTermFunctionCallParser expressionParser] parse:substring
                                                        scope:self->_scope];
            iTermExpressionEvaluator *innerEvaluator = [[iTermExpressionEvaluator alloc] initWithObject:parsedExpression scope:self->_scope];
            [self->_innerEvaluators addObject:innerEvaluator];
            [innerEvaluator evaluateWithTimeout:timeout completion:^(iTermExpressionEvaluator *evaluator) {
                [missingFunctionSignatures unionSet:evaluator.missingValues];
                if (evaluator.error) {
                    firstError = evaluator.error;
                } else {
                    parts[index] = [self stringFromJSONObject:evaluator.value];
                }
                dispatch_group_leave(group);
            }];
        }
    }];
    if (timeout == 0) {
        completion([parts componentsJoinedByString:@""],
                   firstError,
                   missingFunctionSignatures);
    } else {
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            completion([parts componentsJoinedByString:@""],
                       firstError,
                       missingFunctionSignatures);
        });
    }
}

- (void)evaluateParsedExpression:(iTermParsedExpression *)parsedExpression
                     withTimeout:(NSTimeInterval)timeout
                      completion:(void (^)(id, NSError *, NSSet<NSString *> *))completion {
    switch (parsedExpression.expressionType) {
        case iTermParsedExpressionTypeFunctionCall: {
            [self performFunctionCall:parsedExpression.functionCall
                          withTimeout:timeout
                           completion:completion];
            return;
        }

        case iTermParsedExpressionTypeInterpolatedString: {
            [self evaluateInterpolatedStringParts:parsedExpression.interpolatedStringParts
                                      withTimeout:timeout
                                       completion:completion];
            return;
        }

        case iTermParsedExpressionTypeArray: {
            [self evaluateArray:parsedExpression.array
                    withTimeout:timeout
                     completion:completion];
            return;
        }
        case iTermParsedExpressionTypeString:
        case iTermParsedExpressionTypeNumber:
            completion(parsedExpression.object, nil, nil);
            return;

        case iTermParsedExpressionTypeError:
            completion(nil, parsedExpression.error, nil);
            return;

        case iTermParsedExpressionTypeNil:
            completion(nil, nil, nil);
            return;
    }

    NSString *reason = [NSString stringWithFormat:@"Invalid parsed expression type %@", @(parsedExpression.expressionType)];
    NSError *error = [NSError errorWithDomain:@"com.iterm2.expression-evaluator"
                                         code:2
                                     userInfo:@{ NSLocalizedDescriptionKey: reason}];
    completion(nil, error, nil);
}

- (void)performFunctionCall:(iTermScriptFunctionCall *)functionCall
                withTimeout:(NSTimeInterval)timeInterval
                 completion:(void (^)(id, NSError *, NSSet<NSString *> *))completion {
    [iTermScriptFunctionCall performFunctionCall:functionCall
                                  fromInvocation:[_object description]
                                           scope:_scope
                                         timeout:timeInterval
                                      completion:completion];
}

- (void)evaluateInterpolatedStringParts:(NSArray *)interpolatedStringParts
                            withTimeout:(NSTimeInterval)timeout
                             completion:(void (^)(id, NSError *, NSSet<NSString *> *))completion {
    dispatch_group_t group = NULL;
    __block NSError *firstError = nil;
    NSMutableArray *parts = [NSMutableArray array];
    NSMutableSet<NSString *> *missingFunctionSignatures = [NSMutableSet set];
    if (timeout > 0) {
        group = dispatch_group_create();
    }
    [interpolatedStringParts enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [parts addObject:@""];
        iTermExpressionEvaluator *innerEvaluator = [[iTermExpressionEvaluator alloc] initWithObject:obj scope:self->_scope];
        [self->_innerEvaluators addObject:innerEvaluator];
        if (group) {
            dispatch_group_enter(group);
        }
        [innerEvaluator evaluateWithTimeout:timeout completion:^(iTermExpressionEvaluator *evaluator){
            [missingFunctionSignatures unionSet:evaluator.missingValues];
            if (evaluator.error) {
                firstError = evaluator.error;
                [self logError:evaluator.error object:obj];
            } else {
                parts[idx] = [self stringFromJSONObject:evaluator.value];
            }
            if (group) {
                dispatch_group_leave(group);
            }
        }];
    }];
    if (!group) {
        completion([parts componentsJoinedByString:@""],
                   firstError,
                   missingFunctionSignatures);
    } else {
        dispatch_notify(group, dispatch_get_main_queue(), ^{
            completion(firstError ? nil : [parts componentsJoinedByString:@""],
                       firstError,
                       missingFunctionSignatures);
        });
    }
}

- (void)evaluateArray:(NSArray *)array
          withTimeout:(NSTimeInterval)timeInterval
           completion:(void (^)(id, NSError *, NSSet<NSString *> *))completion {
    __block NSError *errorOut = nil;
    NSMutableSet<NSString *> *missing = [NSMutableSet set];
    NSMutableArray *populatedArray = [array mutableCopy];
    dispatch_group_t group = nil;
    if (timeInterval > 0) {
        group = dispatch_group_create();
    }
    [array enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        iTermExpressionEvaluator *innerEvaluator = [[iTermExpressionEvaluator alloc] initWithObject:obj scope:self->_scope];
        [self->_innerEvaluators addObject:innerEvaluator];
        dispatch_group_enter(group);
        __block BOOL alreadyRun = NO;
        [innerEvaluator evaluateWithTimeout:timeInterval completion:^(iTermExpressionEvaluator *evaluator){
            assert(!alreadyRun);
            alreadyRun = YES;
            [missing unionSet:evaluator.missingValues];
            if (evaluator.error) {
                errorOut = evaluator.error;
            } else {
                populatedArray[idx] = evaluator.value;
            }
            if (group) {
                dispatch_group_leave(group);
            }
        }];
    }];
    if (group) {
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            completion(populatedArray, errorOut, missing);
        });
    } else {
        completion(populatedArray, errorOut, missing);
    }
}

- (NSString *)stringFromJSONObject:(id)jsonObject {
    NSString *string = [NSString castFrom:jsonObject];
    if (string) {
        return string;
    }
    NSNumber *number = [NSNumber castFrom:jsonObject];
    if (number) {
        return [number stringValue];
    }
    NSArray *array = [NSArray castFrom:jsonObject];
    if (array) {
        return [NSString stringWithFormat:@"[%@]", [[array mapWithBlock:^id(id anObject) {
            return [self stringFromJSONObject:anObject];
        }] componentsJoinedByString:@", "]];
    }

    if ([NSNull castFrom:jsonObject] || !jsonObject) {
        return @"";
    }

    return [NSJSONSerialization it_jsonStringForObject:jsonObject];
}

- (void)logError:(NSError *)error object:(id)obj {
    NSString *message =
    [NSString stringWithFormat:@"Error evaluating expression %@: %@",
     obj, error.localizedDescription];
    [[iTermScriptHistoryEntry globalEntry] addOutput:message];
}

@end
