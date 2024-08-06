//
//  InjectionLiteC.h
//
//  Created by John Holdsworth on 13/03/2023.
//
#if DEBUG || !SWIFT_PACKAGE
#import <Foundation/Foundation.h>
#define APP_NAME "InjectionLite"
#define APP_PREFIX "🔥 "
#define VAPOR_SYMBOL "$s10RoutingKit10ParametersVN"

@interface NSObject(InjectionBoot)
+ (BOOL)InjectionBoot_inPreview;
+ (void)runXCTestCase:(Class)aTestCase;
@end
#endif
