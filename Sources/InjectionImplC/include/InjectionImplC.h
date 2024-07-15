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

#if __cplusplus
extern "C" {
#endif
extern void hookKeyPaths(void *original, void *replacement);
extern const void *swift_getKeyPath(void *, const void *);
extern const void *injection_getKeyPath(void *, const void *);
#if __cplusplus
}
#endif
#endif
