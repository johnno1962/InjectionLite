import XCTest

#if os(macOS)
@testable import InjectionBazel

final class BazelAQueryParserTests: XCTestCase {

    // rules_xcodeproj may produce multiple config dirs for the same aquery
    // config, so we choose the one that contains the requested module artifact.
    func testPathSpecificConfigCandidateUsesArtifactExistence() {
        let aqueryConfig = "ios_sim_arm64-dbg-ios-sim_arm64-min16.0-ST-aquery"
        let genericConfig = "ios_sim_arm64-dbg-ios-sim_arm64-min16.0-ST-zgeneric"
        let artifactConfig = "ios_sim_arm64-dbg-ios-sim_arm64-min16.0-ST-artifact"
        let pathTail = "bin/sample_app/Features/PrimaryFeature/PrimaryFeature"
        let rxpBazelOut = "/rxp/execroot/_main/bazel-out"

        let candidate = BazelAQueryParser.rxpConfigCandidate(
            for: aqueryConfig,
            pathTail: pathTail,
            entries: [genericConfig, artifactConfig],
            rxpBazelOut: rxpBazelOut,
            fileExists: { path in
                path == "\(rxpBazelOut)/\(artifactConfig)/\(pathTail)"
            })

        XCTAssertEqual(candidate?.config, artifactConfig)
    }

    // Swift plugin executable args are encoded as
    // "<path-to-plugin-executable>#<plugin-module-name>". The part before "#"
    // is the file that exists in bazel-out; the part after "#" is metadata for
    // Swift's plugin loader. Config selection must probe only the filesystem
    // path, otherwise valid plugin executable paths look missing.
    func testPathSpecificConfigCandidateIgnoresPluginExecutableNameSuffix() {
        let aqueryConfig = "darwin_arm64-opt-exec-ST-aquery"
        let pluginConfig = "darwin_arm64-opt-exec-ST-plugin"
        let pathTail = "bin/sample_app/Tools/Macros/Macros#SampleMacros"
        let filesystemPathTail = "bin/sample_app/Tools/Macros/Macros"
        let rxpBazelOut = "/rxp/execroot/_main/bazel-out"

        let candidate = BazelAQueryParser.rxpConfigCandidate(
            for: aqueryConfig,
            pathTail: pathTail,
            entries: [pluginConfig],
            rxpBazelOut: rxpBazelOut,
            fileExists: { path in
                path == "\(rxpBazelOut)/\(pluginConfig)/\(filesystemPathTail)"
            })

        XCTAssertEqual(candidate?.config, pluginConfig)
    }

    // A single compiler command can reference artifacts that live in different
    // rules_xcodeproj config dirs, so rewriting must happen per path segment.
    func testRewriteRulesXcodeprojPathsUsesDifferentConfigsPerArtifact() {
        let aqueryConfig = "ios_sim_arm64-dbg-ios-sim_arm64-min16.0-ST-aquery"
        let moduleATail = "bin/sample_app/Features/PrimaryFeature/PrimaryFeature"
        let moduleBTail = "bin/sample_app/Libraries/Support/Support"
        let rxpExecRoot = "/rxp/execroot/_main"
        let command = """
        -I/Users/me/out/execroot/_main/bazel-out/\(aqueryConfig)/\(moduleATail) \
        -I bazel-out/\(aqueryConfig)/\(moduleBTail)
        """

        let rewritten = BazelAQueryParser.rewriteBazelOutPathsForRulesXcodeproj(
            command,
            rxpExecRoot: rxpExecRoot,
            resolveConfig: { _, pathTail in
                if pathTail == moduleATail {
                    return "ios_sim_arm64-dbg-ios-sim_arm64-min16.0-ST-module-a"
                }
                if pathTail == moduleBTail {
                    return "ios_sim_arm64-dbg-ios-sim_arm64-min16.0-ST-module-b"
                }
                return nil
            })

        XCTAssertTrue(rewritten.contains(
            "-I\(rxpExecRoot)/bazel-out/ios_sim_arm64-dbg-ios-sim_arm64-min16.0-ST-module-a/\(moduleATail)"))
        XCTAssertTrue(rewritten.contains(
            "-I \(rxpExecRoot)/bazel-out/ios_sim_arm64-dbg-ios-sim_arm64-min16.0-ST-module-b/\(moduleBTail)"))
        XCTAssertFalse(rewritten.contains("bazel-out/\(aqueryConfig)"))
    }
}
#endif
