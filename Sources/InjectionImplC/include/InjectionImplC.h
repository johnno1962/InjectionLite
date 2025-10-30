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
#define TCA_SYMBOL "_$s22ComposableArchitecture6LoggerCN"

// Environment variables that can be used in schemes.
/// Default list of directories fo watch, should include ~/Library/Developer.
#define INJECTION_DIRECTORIES "INJECTION_DIRECTORIES"
/// The root directory(s) to file watch of the project being injected.
#define INJECTION_PROJECT_ROOT "INJECTION_PROJECT_ROOT"
/// Preserve the value of top level and static variables over an injection.
#define INJECTION_PRESERVE_STATICS "INJECTION_PRESERVE_STATICS"
/// Directory containing Bazel workspace.
#define BUILD_WORKSPACE_DIRECTORY "BUILD_WORKSPACE_DIRECTORY"
/// Regex of types to exclude from sweep to implement @objc func injected().
#define INJECTION_SWEEP_EXCLUDE "INJECTION_SWEEP_EXCLUDE"
/// Enable verbose logging of types as they are swept  to localise problems.
#define INJECTION_SWEEP_DETAIL "INJECTION_SWEEP_DETAIL"
/// Don't run "standalone" injection in the simulator after failing to connect.
#define INJECTION_NOSTANDALONE "INJECTION_NOSTANDALONE"
/// Opt-into legacy injection of generics classes using the object sweep.
#define INJECTION_OF_GENERICS "INJECTION_OF_GENERICS"
/// Opt-out of new injection of generic classes not using the sweep.
#define INJECTION_NOGENERICS "INJECTION_NOGENERICS"
/// Opt-out of "hook" enabling injection of code that uses key paths.
#define INJECTION_NOKEYPATHS "INJECTION_NOKEYPATHS"
/// Opt-into enabling injection of key paths when not using TCA.
#define INJECTION_KEYPATHS "INJECTION_KEYPATHS"
/// Verbose logging of steps binding injected code into your app.
#define INJECTION_DETAIL "INJECTION_DETAIL"
/// Set bazel target to optimize source to bazel target matching
#define INJECTION_BAZEL_TARGET "INJECTION_BAZEL_TARGET"
/// Enable selected benchmarking of some operations.
#define INJECTION_BENCH "INJECTION_BENCH"
/// Enable tracing of function that have been injected..
#define INJECTION_TRACE "INJECTION_TRACE"
/// Enable lookup of function arguments of custom type..
#define INJECTION_DECORATE "INJECTION_DECORATE"
/// IP or hostname of developer's machine for connecting from device.
#define INJECTION_HOST "INJECTION_HOST"

/// Notification on injection.
#define INJECTION_BUNDLE_NOTIFICATION "INJECTION_BUNDLE_NOTIFICATION"
/// Notification posted with injection timing metrics.
#define INJECTION_METRICS_NOTIFICATION "INJECTION_METRICS_NOTIFICATION"

@interface NSObject(InjectionBoot)
+ (BOOL)InjectionBoot_inPreview;
+ (void)runXCTestCase:(Class)aTestCase;
@end
#endif
