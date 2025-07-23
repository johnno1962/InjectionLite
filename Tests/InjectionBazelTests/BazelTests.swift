//
//  BazelTests.swift
//  InjectionBazelTests
//
//  Tests for Bazel AQuery integration functionality
//

import XCTest
@testable import InjectionBazel

final class BazelTests: XCTestCase {
    
    private var tempWorkspaceURL: URL!
    private var workspacePath: String!
    
    override func setUp() {
        super.setUp()
        
        // Create temporary workspace for testing
        tempWorkspaceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BazelTestWorkspace_\(UUID().uuidString)")
        workspacePath = tempWorkspaceURL.path
        
        // Create workspace directory
        try! FileManager.default.createDirectory(at: tempWorkspaceURL, 
                                                withIntermediateDirectories: true, 
                                                attributes: nil)
        
        // Create a basic WORKSPACE file to make it a valid Bazel workspace
        let workspaceFile = tempWorkspaceURL.appendingPathComponent("WORKSPACE")
        try! "workspace(name = \"test\")".write(to: workspaceFile, atomically: true, encoding: .utf8)
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
        XCTAssertNoThrow(try "module(name = \"test\")".write(to: moduleFile, atomically: true, encoding: .utf8))
        
        // Test detection
        XCTAssertTrue(BazelInterface.isBazelWorkspace(containing: workspacePath))
        
        let foundRoot = BazelInterface.findWorkspaceRoot(containing: workspacePath)
        XCTAssertEqual(foundRoot, workspacePath)
    }
    
    func testBazelWorkspaceDetectionWithPlainMODULE() {
        // Create plain MODULE file (no .bazel extension)
        let moduleFile = tempWorkspaceURL.appendingPathComponent("MODULE")
        XCTAssertNoThrow(try "module(name = \"test\")".write(to: moduleFile, atomically: true, encoding: .utf8))
        
        // Test detection
        XCTAssertTrue(BazelInterface.isBazelWorkspace(containing: workspacePath))
        
        let foundRoot = BazelInterface.findWorkspaceRoot(containing: workspacePath)
        XCTAssertEqual(foundRoot, workspacePath)
    }
    
    func testBazelWorkspaceDetectionWithWORKSPACE() {
        // WORKSPACE file already exists from setUp
        
        // Test detection
        XCTAssertTrue(BazelInterface.isBazelWorkspace(containing: workspacePath))
        
        let foundRoot = BazelInterface.findWorkspaceRoot(containing: workspacePath)
        XCTAssertEqual(foundRoot, workspacePath)
    }
    
    func testBazelWorkspaceDetectionWithWORKSPACEBazel() {
        // Remove existing WORKSPACE and create WORKSPACE.bazel
        try! FileManager.default.removeItem(at: tempWorkspaceURL.appendingPathComponent("WORKSPACE"))
        let workspaceBazelFile = tempWorkspaceURL.appendingPathComponent("WORKSPACE.bazel")
        XCTAssertNoThrow(try "workspace(name = \"test\")".write(to: workspaceBazelFile, atomically: true, encoding: .utf8))
        
        // Test detection
        XCTAssertTrue(BazelInterface.isBazelWorkspace(containing: workspacePath))
        
        let foundRoot = BazelInterface.findWorkspaceRoot(containing: workspacePath)
        XCTAssertEqual(foundRoot, workspacePath)
    }
    
    func testNestedWorkspaceDetection() {
        // Create nested directory structure
        let nestedDir = tempWorkspaceURL.appendingPathComponent("src/main/swift")
        try! FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        
        let nestedPath = nestedDir.path
        
        // Should find the root workspace
        let foundRoot = BazelInterface.findWorkspaceRoot(containing: nestedPath)
        XCTAssertEqual(foundRoot, workspacePath)
    }
    
    func testNonBazelWorkspaceDetection() {
        // Create a directory without Bazel workspace files
        let nonBazelURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NonBazelProject_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: nonBazelURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonBazelURL) }
        
        let nonBazelPath = nonBazelURL.path
        
        // Should not detect as Bazel workspace
        XCTAssertFalse(BazelInterface.isBazelWorkspace(containing: nonBazelPath))
        XCTAssertNil(BazelInterface.findWorkspaceRoot(containing: nonBazelPath))
    }
    
    // MARK: - BazelInterface Tests
    
    func testBazelInterfaceInitialization() {
        XCTAssertNoThrow(try {
            let interface = try BazelInterface(workspaceRoot: workspacePath)
            XCTAssertNotNil(interface)
        }())
    }
    
    func testBazelInterfaceInitializationFailure() {
        let invalidPath = "/non/existent/path"
        
        XCTAssertThrowsError(try BazelInterface(workspaceRoot: invalidPath)) { error in
            XCTAssertTrue(error is BazelError)
            if case BazelError.workspaceNotFound(let path) = error {
                XCTAssertEqual(path, invalidPath)
            } else {
                XCTFail("Expected workspaceNotFound error")
            }
        }
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
            XCTAssertFalse(description.isEmpty)
            XCTAssertTrue(description.contains("path") || 
                         description.contains("workspace") || 
                         description.contains("Bazel") ||
                         description.contains("target") ||
                         description.contains("query") ||
                         description.contains("build"))
        }
    }
    
    func testBazelActionQueryErrorDescriptions() {
        let errors = [
            BazelActionQueryError.workspaceNotFound,
            BazelActionQueryError.bazelExecutableNotFound,
            BazelActionQueryError.queryExecutionFailed("execution failed"),
            BazelActionQueryError.noTargetsFound("source.swift"),
            BazelActionQueryError.noCompilationCommandFound("//target:name"),
            BazelActionQueryError.invalidQuery("invalid query"),
            BazelActionQueryError.cacheError("cache error")
        ]
        
        for error in errors {
            let description = error.description
            XCTAssertFalse(description.isEmpty)
        }
    }
    
    // MARK: - BazelAQueryParser Tests
    
    func testBazelAQueryParserInitialization() {
        XCTAssertNoThrow(try {
            let parser = try BazelAQueryParser(workspaceRoot: workspacePath)
            XCTAssertNotNil(parser)
        }())
    }
}