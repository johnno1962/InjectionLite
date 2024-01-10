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
#import "InjectionLiteC.h"
#import <XCTest/XCTest.h>
#import <objc/runtime.h>

@interface InjectionLite: NSObject
@end

@implementation NSObject(InjectionBoot)

/// This will be called as soon as the package is loaded into memory.
+ (void)load {
    static InjectionLite *singleton;
    singleton = [[InjectionLite alloc] init];
}

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
