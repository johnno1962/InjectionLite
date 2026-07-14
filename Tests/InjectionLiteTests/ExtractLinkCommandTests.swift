import XCTest

#if os(macOS)
import InjectionImpl

final class ExtractLinkCommandTests: XCTestCase {

    let sdkArgument = "-sdk /Applications/Xcode.app/Contents/Developer" +
        "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

    override func setUp() {
        Reloader.platform = "MacOSX"
    }

    func testExtractsTargetFromCompileCommand() {
        Reloader.extractLinkCommand(from: """
            /Applications/Xcode.app/Contents/Developer/Toolchains\
            /XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend \
            -c /path/to/Source.swift \(sdkArgument) \
            -target arm64-apple-macos15.0 -enable-batch-mode -Onone \
            -module-name App -o /path/to/Source.o
            """)

        XCTAssertTrue(Reloader.linkCommand.contains(
            "-mmacosx-version-min=10.11 -target arm64-apple-macos15.0"))
        XCTAssertFalse(Reloader.linkCommand.contains("swift-frontend"))
    }

    // Compile commands can contain newlines. The anchored replace
    // ^.*( -target \S+).*$ never matched those ("." does not match line
    // separators) and returned its input unchanged, splicing the entire
    // compile command into the link command after -mmacosx-version-min.
    func testCompileCommandWithNewlinesDoesNotLeakIntoLinkCommand() {
        Reloader.extractLinkCommand(from: """
            /Applications/Xcode.app/Contents/Developer/Toolchains\
            /XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend \
            -c /path/to/Source.swift \(sdkArgument) \
            -target arm64-apple-macos15.0 -enable-batch-mode -Onone
            -filelist /var/folders/xx/T/TemporaryDirectory.abc/sources
            -module-name App -o /path/to/Source.o
            """)

        XCTAssertTrue(Reloader.linkCommand.contains(
            "-mmacosx-version-min=10.11 -target arm64-apple-macos15.0"))
        XCTAssertFalse(Reloader.linkCommand.contains("swift-frontend"))
        XCTAssertFalse(Reloader.linkCommand.contains("-filelist"))
    }
}
#endif
