//
//  GitIgnoreTests.swift
//  InjectionLiteTests
//
//  Tests for GitIgnoreParser functionality
//

import XCTest
@testable import InjectionBazel

final class GitIgnoreTests: XCTestCase {
    
    func testBasicPatterns() {
        let gitignoreContent = """
        *.log
        build/
        node_modules
        temp/*.tmp
        """
        
        let parser = GitIgnoreParser(content: gitignoreContent)
        
        // Test file patterns
        XCTAssertTrue(parser.shouldIgnore(path: "error.log"))
        XCTAssertTrue(parser.shouldIgnore(path: "logs/debug.log"))
        XCTAssertFalse(parser.shouldIgnore(path: "readme.txt"))
        
        // Test directory patterns
        XCTAssertTrue(parser.shouldIgnore(path: "build/", isDirectory: true))
        XCTAssertTrue(parser.shouldIgnore(path: "build/output.bin"))
        XCTAssertTrue(parser.shouldIgnore(path: "node_modules"))
        
        // Test wildcard patterns
        XCTAssertTrue(parser.shouldIgnore(path: "temp/cache.tmp"))
        XCTAssertFalse(parser.shouldIgnore(path: "temp/data.json"))
    }
    
    func testNegationPatterns() {
        let gitignoreContent = """
        *.log
        !important.log
        build/
        !build/keep.txt
        """
        
        let parser = GitIgnoreParser(content: gitignoreContent)
        
        // Test negation
        XCTAssertTrue(parser.shouldIgnore(path: "debug.log"))
        XCTAssertFalse(parser.shouldIgnore(path: "important.log"))
        XCTAssertTrue(parser.shouldIgnore(path: "build/temp.bin"))
        XCTAssertFalse(parser.shouldIgnore(path: "build/keep.txt"))
    }
    
    func testCommentAndEmptyLines() {
        let gitignoreContent = """
        # This is a comment
        *.log
        
        # Another comment
        build/
        """
        
        let parser = GitIgnoreParser(content: gitignoreContent)
        
        XCTAssertTrue(parser.shouldIgnore(path: "error.log"))
        XCTAssertTrue(parser.shouldIgnore(path: "build/", isDirectory: true))
    }
    
    func testSourceFileFiltering() {
        let gitignoreContent = """
        *.o
        *.a
        build/
        .git/
        """
        
        let parser = GitIgnoreParser(content: gitignoreContent)
        
        // These should be ignored
        XCTAssertTrue(parser.shouldIgnore(path: "main.o"))
        XCTAssertTrue(parser.shouldIgnore(path: "libtest.a"))
        XCTAssertTrue(parser.shouldIgnore(path: "build/Debug/"))
        XCTAssertTrue(parser.shouldIgnore(path: ".git/config"))
        
        // These should not be ignored
        XCTAssertFalse(parser.shouldIgnore(path: "main.swift"))
        XCTAssertFalse(parser.shouldIgnore(path: "ViewController.m"))
        XCTAssertFalse(parser.shouldIgnore(path: "Header.h"))
    }
    
    func testComplexGlobstarPatterns() {
        let gitignoreContent = """
        **/*.cache
        **/logs/**/*.log
        src/**/*.min.js
        **/node_modules/**
        **/.git/**
        """
        
        let parser = GitIgnoreParser(content: gitignoreContent)
        
        // Test globstar patterns
        XCTAssertTrue(parser.shouldIgnore(path: "deep/nested/file.cache"))
        XCTAssertTrue(parser.shouldIgnore(path: "project/logs/debug/error.log"))
        XCTAssertTrue(parser.shouldIgnore(path: "src/components/bundle.min.js"))
        XCTAssertTrue(parser.shouldIgnore(path: "project/node_modules/package/index.js"))
        XCTAssertTrue(parser.shouldIgnore(path: "repo/.git/config"))
        
        // These should not match
        XCTAssertFalse(parser.shouldIgnore(path: "src/main.js"))
        XCTAssertFalse(parser.shouldIgnore(path: "logs/info.txt"))
    }
    
    func testLeadingSlashDotPatterns() {
        // Test that patterns like "/.bazel-*" properly match ".bazel-*" directories
        let gitignoreContent = """
        /.bazel-*
        /.git/
        /.vscode/
        /build/
        """
        
        let parser = GitIgnoreParser(content: gitignoreContent)
        
        // Test that leading slash + dot patterns match hidden directories
        XCTAssertTrue(parser.shouldIgnore(path: ".bazel-grpc-logs/", isDirectory: true))
        XCTAssertTrue(parser.shouldIgnore(path: ".bazel-bin/", isDirectory: true))
        XCTAssertTrue(parser.shouldIgnore(path: ".bazel-out/ios_arm64-dbg/bin/", isDirectory: true))
        XCTAssertTrue(parser.shouldIgnore(path: ".git/", isDirectory: true))
        XCTAssertTrue(parser.shouldIgnore(path: ".git/config"))
        XCTAssertTrue(parser.shouldIgnore(path: ".vscode/", isDirectory: true))
        
        // Test that /build/ still matches build/ (no dot normalization needed)
        XCTAssertTrue(parser.shouldIgnore(path: "build/", isDirectory: true))
        
        // Test that source files are not ignored
        XCTAssertFalse(parser.shouldIgnore(path: "main.swift"))
        XCTAssertFalse(parser.shouldIgnore(path: ".bazel-other-file.swift")) // Edge case: .bazel- prefix but not matching pattern
    }

    func testShouldExcludeUsesGitCheckIgnore() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))

        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("InjectionLiteGitIgnoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }

        try withIsolatedGitEnvironment(at: repo) {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try runGit(["init"], in: repo)
            try "/.tmp\n".write(to: repo.appendingPathComponent(".gitignore"),
                                atomically: true,
                                encoding: .utf8)

            let ignoredSource = repo
                .appendingPathComponent(".tmp/bazel_output_base/external/foo.cpp")
            try FileManager.default.createDirectory(at: ignoredSource.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "int main() { return 0; }\n".write(to: ignoredSource,
                                                   atomically: true,
                                                   encoding: .utf8)

            let trackedSource = repo
                .appendingPathComponent("Sources/App/ViewController.swift")
            try FileManager.default.createDirectory(at: trackedSource.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "struct ViewController {}\n".write(to: trackedSource,
                                                   atomically: true,
                                                   encoding: .utf8)

            XCTAssertEqual(GitIgnoreParser.shouldExclude(file: ignoredSource.path), "gitignore rule")
            XCTAssertNil(GitIgnoreParser.shouldExclude(file: trackedSource.path))
        }
    }

    func testShouldExcludeFilesBatchesGitCheckIgnore() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))

        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("InjectionLiteGitIgnoreBatchTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }

        try withIsolatedGitEnvironment(at: repo) {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try runGit(["init"], in: repo)
            try "/.tmp\n*.generated.swift\n".write(to: repo.appendingPathComponent(".gitignore"),
                                                   atomically: true,
                                                   encoding: .utf8)
            GitIgnoreParser.monitor(directory: repo.path)

            let ignoredCpp = repo
                .appendingPathComponent(".tmp/bazel_output_base/external/foo.cpp")
            let ignoredSwift = repo
                .appendingPathComponent("Sources/App/View.generated.swift")
            let trackedSwift = repo
                .appendingPathComponent("Sources/App/View.swift")
            for source in [ignoredCpp, ignoredSwift, trackedSwift] {
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try "source\n".write(to: source, atomically: true, encoding: .utf8)
            }

            let exclusions = GitIgnoreParser.shouldExclude(files: [
                ignoredCpp.path,
                ignoredSwift.path,
                trackedSwift.path
            ])

            XCTAssertEqual(exclusions[ignoredCpp.path], "gitignore rule")
            XCTAssertEqual(exclusions[ignoredSwift.path], "gitignore rule")
            XCTAssertNil(exclusions[trackedSwift.path])
        }
    }

    private func withIsolatedGitEnvironment(at repo: URL, _ body: () throws -> Void) throws {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_NOSYSTEM"]
        let previousValues = keys.reduce(into: [String: String]()) { values, key in
            values[key] = environment[key]
        }
        defer {
            for key in keys {
                if let previousValue = previousValues[key] {
                    setenv(key, previousValue, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        setenv("HOME", repo.path, 1)
        setenv("XDG_CONFIG_HOME", repo.appendingPathComponent(".config").path, 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        try body()
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let readOutput = readPipeInBackground(outputPipe)
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       "git \(arguments.joined(separator: " ")) failed:\n\(readOutput())")
    }

    private func readPipeInBackground(_ pipe: Pipe) -> () -> String {
        final class OutputBox {
            var data = Data()
        }

        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                box.data.append(data)
            }
        }

        return {
            group.wait()
            return String(data: box.data, encoding: .utf8) ?? ""
        }
    }
    
}
