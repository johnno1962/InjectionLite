//
//  InjectionBoot.m
//
//  This has to be in Objective-C. Creates an
//  instance of InjectionLite which is enough
//  to start a file watcher to inject files.
// 
//  Created by John Holdsworth on 25/02/2023.
//
#if DEBUG
#import "InjectionImplC.h"
#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@implementation NSObject(InjectionBoot)

/// This will be called as soon as the package is loaded into memory.
+ (void)load {
    // Hook Swift runtime's swift_getKeyPath
    typedef void (*HKP)();
    if (getenv("INJECTION_KEYPATHS") ||
        dlsym(RTLD_DEFAULT, "$s22ComposableArchitecture6LoggerCN"))
        #if SWIFT_PACKAGE
        if (HKP hookKeyPaths = (HKP)dlsym(RTLD_DEFAULT, "hookKeyPaths"))
        #endif
            hookKeyPaths();
    // If InjectionLite clas present, start it up.
    static NSObject *singleton;
    if (Class InjectionLite = objc_getClass("InjectionLite"))
        singleton = [[InjectionLite alloc] init];
}

/// Run the tests in a XCTest subclass
+ (void)runXCTestCase:(Class)aTestCase {
    Class _XCTestSuite = objc_getClass("XCTestSuite");
    XCTestSuite *suite0 = [_XCTestSuite testSuiteWithName: @"InjectedTest"];
    XCTestSuite *suite = [aTestCase defaultTestSuite];
    Class _XCTestSuiteRun = objc_getClass("XCTestSuiteRun");
    XCTestSuiteRun *tr = [_XCTestSuiteRun testRunWithTest: suite];
    [suite0 addTest:suite];
    [suite0 performTest:tr];
    if (NSUInteger failed = tr.totalFailureCount)
        printf("\n" APP_PREFIX"*** %lu/%lu tests have FAILED ***\n",
               failed, tr.testCaseCount);
}

@end
#endif
