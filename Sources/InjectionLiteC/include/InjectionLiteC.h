//
//  InjectionLiteC.h
//
//  Created by John Holdsworth on 13/03/2023.
//
#if DEBUG
#import <Foundation/Foundation.h>
#define APP_NAME "InjectionLite"
#define APP_PREFIX "🔥 "
#define VAPOR_SYMBOL "$s10RoutingKit10ParametersVN"

@interface NSObject(InjectionBoot)
+ (void)runXCTestCase:(Class)aTestCase;
@end
#endif
