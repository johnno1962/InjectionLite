//
//  GitIgnoreTests.swift
//  InjectionLiteTests
//
//  Tests for GitIgnoreParser functionality
//

import XCTest
@testable import InjectionLite

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
    
    func testCacheStatistics() {
        let gitignoreContent = "*.log\nnode_modules/\n**/*.tmp"
        let parser = GitIgnoreParser(content: gitignoreContent)
        
        // Trigger some pattern matching to populate cache
        _ = parser.shouldIgnore(path: "debug.log")
        _ = parser.shouldIgnore(path: "node_modules/package.json")
        
        let stats = GitIgnoreParser.getCacheStats()
        XCTAssertGreaterThan(stats.count, 0, "Cache should contain entries")
    }
}