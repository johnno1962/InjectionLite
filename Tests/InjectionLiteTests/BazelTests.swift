//
//  BazelTests.swift
//  InjectionLiteTests
//
//  Tests for Bazel AQuery integration functionality
//

import XCTest
@testable import InjectionLite

final class BazelTests: XCTestCase {
    
    private var tempWorkspaceURL: URL!
    private var workspacePath: String!
    
    override func setUp() {
        super.setUp()
        
        // Create temporary Bazel workspace for testing
        tempWorkspaceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BazelTestWorkspace_\(UUID().uuidString)")
        
        try! FileManager.default.createDirectory(at: tempWorkspaceURL, 
                                               withIntermediateDirectories: true)
        workspacePath = tempWorkspaceURL.path
    }
    
    override func tearDown() {
        // Clean up temporary workspace
        if let tempWorkspaceURL = tempWorkspaceURL {
            try? FileManager.default.removeItem(at: tempWorkspaceURL)
        }
        super.tearDown()
    }
    
    // MARK: - Workspace Detection Tests
    
    func testBazelWorkspaceDetectionWithMODULE() {
        // Create MODULE.bazel file
        let moduleFile = tempWorkspaceURL.appendingPathComponent("MODULE.bazel")
        try! "module(name = \"test\")".write(to: moduleFile, atomically: true, encoding: .utf8)
        
        // Test detection
        XCTAssertTrue(BazelInterface.isBazelWorkspace(containing: workspacePath))
        
        let foundRoot = BazelInterface.findWorkspaceRoot(containing: workspacePath)
        XCTAssertEqual(foundRoot, workspacePath)
    }
    
    func testBazelWorkspaceDetectionWithWORKSPACE() {
        // Create WORKSPACE file
        let workspaceFile = tempWorkspaceURL.appendingPathComponent("WORKSPACE")
        try! "workspace(name = \"test\")".write(to: workspaceFile, atomically: true, encoding: .utf8)
        
        // Test detection
        XCTAssertTrue(BazelInterface.isBazelWorkspace(containing: workspacePath))
        
        let foundRoot = BazelInterface.findWorkspaceRoot(containing: workspacePath)
        XCTAssertEqual(foundRoot, workspacePath)
    }
    
    func testBazelWorkspaceDetectionWithWORKSPACEBazel() {
        // Create WORKSPACE.bazel file
        let workspaceFile = tempWorkspaceURL.appendingPathComponent("WORKSPACE.bazel")
        try! "workspace(name = \"test\")".write(to: workspaceFile, atomically: true, encoding: .utf8)
        
        // Test detection
        XCTAssertTrue(BazelInterface.isBazelWorkspace(containing: workspacePath))
        
        let foundRoot = BazelInterface.findWorkspaceRoot(containing: workspacePath)
        XCTAssertEqual(foundRoot, workspacePath)
    }
    
    func testNonBazelWorkspaceDetection() {
        // No Bazel files - should not be detected as Bazel workspace
        XCTAssertFalse(BazelInterface.isBazelWorkspace(containing: workspacePath))
        XCTAssertNil(BazelInterface.findWorkspaceRoot(containing: workspacePath))
    }
    
    func testNestedWorkspaceDetection() {
        // Create nested directory structure
        let nestedDir = tempWorkspaceURL.appendingPathComponent("src/main/swift")
        try! FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        
        // Create MODULE.bazel at root
        let moduleFile = tempWorkspaceURL.appendingPathComponent("MODULE.bazel")
        try! "module(name = \"test\")".write(to: moduleFile, atomically: true, encoding: .utf8)
        
        // Test detection from nested directory
        let nestedPath = nestedDir.path
        XCTAssertTrue(BazelInterface.isBazelWorkspace(containing: nestedPath))
        
        let foundRoot = BazelInterface.findWorkspaceRoot(containing: nestedPath)
        XCTAssertEqual(foundRoot, workspacePath)
    }
    
    // MARK: - BazelInterface Tests
    
    func testBazelInterfaceInitialization() {
        // Create valid workspace
        let moduleFile = tempWorkspaceURL.appendingPathComponent("MODULE.bazel")
        try! "module(name = \"test\")".write(to: moduleFile, atomically: true, encoding: .utf8)
        
        // Test initialization
        XCTAssertNoThrow(try BazelInterface(workspaceRoot: workspacePath, bazelExecutable: "echo"))
    }
    
    func testBazelInterfaceInitializationFailure() {
        // No Bazel files - should fail initialization
        XCTAssertThrowsError(try BazelInterface(workspaceRoot: workspacePath)) { error in
            XCTAssertTrue(error is BazelError)
            if case BazelError.workspaceNotFound(let path) = error {
                XCTAssertEqual(path, workspacePath)
            } else {
                XCTFail("Expected workspaceNotFound error")
            }
        }
    }
    
    // MARK: - BazelPathResolver Tests
    
    func testPathResolverInitialization() {
        let resolver = BazelPathResolver(workspaceRoot: workspacePath)
        XCTAssertNotNil(resolver)
    }
    
    func testPathOutsideWorkspace() {
        let resolver = BazelPathResolver(workspaceRoot: workspacePath)
        let outsidePath = "/tmp/some_other_file.swift"
        
        XCTAssertThrowsError(try resolver.convertToLabel(outsidePath)) { error in
            XCTAssertTrue(error is BazelPathError)
            if case BazelPathError.pathOutsideWorkspace(let path) = error {
                XCTAssertEqual(path, outsidePath)
            } else {
                XCTFail("Expected pathOutsideWorkspace error")
            }
        }
    }
    
    func testLabelGenerationForRootFile() {
        // Create BUILD file at root
        let buildFile = tempWorkspaceURL.appendingPathComponent("BUILD")
        try! "swift_library(name = \"test\")".write(to: buildFile, atomically: true, encoding: .utf8)
        
        // Create source file at root
        let sourceFile = tempWorkspaceURL.appendingPathComponent("main.swift")
        let sourcePath = sourceFile.path
        try! "print(\"Hello\")".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let resolver = BazelPathResolver(workspaceRoot: workspacePath)
        
        XCTAssertNoThrow(try {
            let label = try resolver.convertToLabel(sourcePath)
            XCTAssertEqual(label, "//:main.swift")
        }())
    }
    
    func testLabelGenerationForNestedFile() {
        // Create nested package structure
        let packageDir = tempWorkspaceURL.appendingPathComponent("src/main")
        try! FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        
        let buildFile = packageDir.appendingPathComponent("BUILD")
        try! "swift_library(name = \"main\")".write(to: buildFile, atomically: true, encoding: .utf8)
        
        // Create source file in nested package
        let sourceFile = packageDir.appendingPathComponent("App.swift")
        let sourcePath = sourceFile.path
        try! "class App {}".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let resolver = BazelPathResolver(workspaceRoot: workspacePath)
        
        XCTAssertNoThrow(try {
            let label = try resolver.convertToLabel(sourcePath)
            XCTAssertEqual(label, "//src/main:App.swift")
        }())
    }
    
    // MARK: - Recompiler Integration Tests
    
    func testRecompilerBazelDetection() {
        // Create Bazel workspace
        let moduleFile = tempWorkspaceURL.appendingPathComponent("MODULE.bazel")
        try! "module(name = \"test\")".write(to: moduleFile, atomically: true, encoding: .utf8)
        
        // Create source file
        let sourceFile = tempWorkspaceURL.appendingPathComponent("test.swift")
        let sourcePath = sourceFile.path
        try! "print(\"test\")".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let recompiler = Recompiler()
        let parser = recompiler.parser(forProjectContaining: sourcePath)
        
        // Should return BazelAQueryParser for Bazel projects
        XCTAssertTrue(parser is BazelAQueryParser)
    }
    
    func testRecompilerXcodeDetection() {
        // Create non-Bazel source file
        let sourceFile = tempWorkspaceURL.appendingPathComponent("test.swift")
        let sourcePath = sourceFile.path
        try! "print(\"test\")".write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let recompiler = Recompiler()
        let parser = recompiler.parser(forProjectContaining: sourcePath)
        
        // Should return LogParser for non-Bazel projects
        XCTAssertTrue(parser is LogParser)
    }
    
    // MARK: - Error Handling Tests
    
    func testBazelErrorDescriptions() {
        let errors = [
            BazelError.workspaceNotFound("/path/to/workspace"),
            BazelError.bazelNotFound,
            BazelError.queryFailed("query error"),
            BazelError.buildFailed("build error"),
            BazelError.targetNotFound("//target:name"),
            BazelError.invalidPath("/invalid/path"),
            BazelError.pathResolutionFailed("/path")
        ]
        
        for error in errors {
            let description = error.description
            XCTAssertFalse(description.isEmpty, "Error description should not be empty")
            XCTAssertTrue(description.count > 10, "Error description should be meaningful")
        }
    }
    
    func testBazelPathErrorDescriptions() {
        let errors = [
            BazelPathError.invalidPath("/path"),
            BazelPathError.packageNotFound("/path"),
            BazelPathError.workspaceNotFound,
            BazelPathError.buildFileNotFound("/path"),
            BazelPathError.pathOutsideWorkspace("/path"),
            BazelPathError.labelGenerationFailed("/path")
        ]
        
        for error in errors {
            let description = error.description
            XCTAssertFalse(description.isEmpty, "Error description should not be empty")
            XCTAssertTrue(description.count > 10, "Error description should be meaningful")
        }
    }
    
    // MARK: - Cache Tests
    
    func testBazelInterfaceCacheClearing() {
        // Create valid workspace
        let moduleFile = tempWorkspaceURL.appendingPathComponent("MODULE.bazel")
        try! "module(name = \"test\")".write(to: moduleFile, atomically: true, encoding: .utf8)
        
        XCTAssertNoThrow(try {
            let interface = try BazelInterface(workspaceRoot: workspacePath, bazelExecutable: "echo")
            
            // Cache clearing should not throw
            interface.clearCache()
        }())
    }
    
    func testPathResolverCacheInvalidation() {
        let resolver = BazelPathResolver(workspaceRoot: workspacePath)
        
        // Cache invalidation should not throw
        XCTAssertNoThrow(resolver.invalidateCache())
        XCTAssertNoThrow(resolver.invalidateCache(for: "/some/path"))
    }
}