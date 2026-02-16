//
//  InjectionBoot.m
//
//  This has to be in Objective-C. Creates an
//  instance of InjectionLite which is enough
//  to start a file watcher to inject files.
// 
//  Created by John Holdsworth on 25/02/2023.
//
#if DEBUG || !SWIFT_PACKAGE
#import "InjectionImplC.h"
#import <XCTest/XCTest.h>
#import <objc/runtime.h>

extern "C" {
extern void hookKeyPaths(void *original, void *replacement);
extern const void *swift_getKeyPath(void *, const void *);
extern const void *injection_getKeyPath(void *, const void *);
extern void injection_hookGenerics(void *original, void *replacement);
extern Class swift_allocateGenericClassMetadata(void *, void *, void *);
extern Class injection_allocateGenericClassMetadata(void *, void *, void *);
extern const void *DLKit_appImagesContain(const char *symbol);
}

@implementation NSObject(InjectionBoot)

+ (BOOL)InjectionBoot_inPreview { // inhibit injection in Xcode previews
    // See: https://forums.developer.apple.com/forums/thread/761439
    return getenv("XCODE_RUNNING_FOR_PREVIEWS")
      || getenv("XCTestBundlePath") || getenv("XCTestSessionIdentifier")
      || getenv("XCTestConfigurationFilePath"); // or when running tests
    // See: https://github.com/pointfreeco/swift-issue-reporting/blob/main/Sources/IssueReporting/IsTesting.swift#L29
}

/// This will be called as soon as the package is loaded into memory.
+ (void)load {
    if ([self InjectionBoot_inPreview])
        return;
    // Hook Swift runtime's swift_getKeyPath to support pointfree.co's TCA
    if (!getenv(INJECTION_NOKEYPATHS) &&
        (getenv(INJECTION_KEYPATHS) || DLKit_appImagesContain(TCA_SYMBOL)))
        hookKeyPaths((void *)swift_getKeyPath,
                     (void *)injection_getKeyPath);
    if (!getenv(INJECTION_NOGENERICS) && !getenv(INJECTION_OF_GENERICS))
        injection_hookGenerics((void *)swift_allocateGenericClassMetadata,
                               (void *)injection_allocateGenericClassMetadata);
    // If InjectionLite class present, start it up.
    static NSObject *singleton;
    if (objc_getClass("InjectionNext")) return;
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
