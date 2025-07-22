//
//  GitIgnoreParser.swift
//  InjectionLite
//
//  Gitignore parser using swift-filename-matcher with UnfairLock caching
//

import Foundation
import FilenameMatcher
import os.lock

/// Parses .gitignore files and provides pattern matching functionality
final class GitIgnoreParser {
    private var patterns: [GitIgnorePattern] = []
    private static var matcherCache: [String: FilenameMatcher] = [:]
    private static var cacheLock = os_unfair_lock()
    
    struct GitIgnorePattern {
        let pattern: String
        let isNegation: Bool
        let isDirectory: Bool
        let matcher: FilenameMatcher?
        
        init(pattern: String) {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Handle negation patterns (starting with !)
            if trimmed.hasPrefix("!") {
                self.isNegation = true
                let negatedPattern = String(trimmed.dropFirst())
                self.pattern = negatedPattern
                self.isDirectory = negatedPattern.hasSuffix("/")
            } else {
                self.isNegation = false
                self.pattern = trimmed
                self.isDirectory = trimmed.hasSuffix("/")
            }
            
            // Get cached matcher or create new one
            self.matcher = GitIgnorePattern.getMatcher(for: self.pattern)
        }
        
        private static func getMatcher(for pattern: String) -> FilenameMatcher? {
            let cacheKey = pattern
            
            os_unfair_lock_lock(&cacheLock)
            defer { os_unfair_lock_unlock(&cacheLock) }
            
            if let cached = matcherCache[cacheKey] {
                return cached
            }
            
            var matcherPattern = pattern
            
            // Remove trailing slash for directory patterns
            if matcherPattern.hasSuffix("/") {
                matcherPattern = String(matcherPattern.dropLast())
            }
            
            // Create FilenameMatcher with globstar support
            let matcher = FilenameMatcher(pattern: matcherPattern, options: [.globstar])
            matcherCache[cacheKey] = matcher
            
            // Prevent cache from growing too large
            if matcherCache.count > 5_000_000 {
                // Remove half the entries (simple cleanup)
                let keysToRemove = Array(matcherCache.keys.prefix(matcherCache.count / 2))
                for key in keysToRemove {
                    matcherCache.removeValue(forKey: key)
                }
            }
            
            return matcher
        }
    }
    
    /// Initialize with gitignore file path
    init(gitignoreFile: String) {
        loadGitIgnore(from: gitignoreFile)
    }
    
    /// Initialize with gitignore content
    init(content: String) {
        parseContent(content)
    }
    
    private func loadGitIgnore(from filePath: String) {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return
        }
        parseContent(content)
    }
    
    private func parseContent(_ content: String) {
        patterns = content
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip empty lines and comments
                guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { return nil }
                return GitIgnorePattern(pattern: trimmed)
            }
    }
    
    /// Check if a file path should be ignored according to gitignore rules
    func shouldIgnore(path: String, isDirectory: Bool = false) -> Bool {
        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var ignored = false
        
        for pattern in patterns {
            guard let matcher = pattern.matcher else { continue }
            
            var matches = false
            
            if pattern.isDirectory {
                // For directory patterns like "build/", match:
                // - The directory itself: "build" or "build/"
                // - Files within the directory: "build/file.txt"
                if isDirectory {
                    // For directories, check both with and without trailing slash
                    let pathWithoutSlash = relativePath.hasSuffix("/") ? String(relativePath.dropLast()) : relativePath
                    matches = matcher.match(filename: pathWithoutSlash) || matcher.match(filename: relativePath)
                } else {
                    // For files, check if path starts with the directory pattern
                    let pathWithoutSlash = pattern.pattern.hasSuffix("/") ? String(pattern.pattern.dropLast()) : pattern.pattern
                    matches = relativePath.hasPrefix(pathWithoutSlash + "/") || matcher.match(filename: relativePath)
                }
            } else {
                // Regular pattern matching
                matches = matcher.match(filename: relativePath)
            }
            
            if matches {
                ignored = !pattern.isNegation
            }
        }
        
        return ignored
    }
    
    /// Find and parse .gitignore files in directory hierarchy
    static func findGitIgnoreFiles(startingFrom directory: String) -> [GitIgnoreParser] {
        var parsers: [GitIgnoreParser] = []
        var currentDir = directory
        
        // Walk up the directory tree looking for .gitignore files
        while currentDir != "/" && currentDir != "" {
            let gitignorePath = (currentDir as NSString).appendingPathComponent(".gitignore")
            if FileManager.default.fileExists(atPath: gitignorePath) {
                let parser = GitIgnoreParser(gitignoreFile: gitignorePath)
                parsers.append(parser)
            }
            currentDir = (currentDir as NSString).deletingLastPathComponent
        }
        
        return parsers
    }
    
    /// Clear the matcher cache (useful for memory management)
    static func clearCache() {
        os_unfair_lock_lock(&cacheLock)
        defer { os_unfair_lock_unlock(&cacheLock) }
        matcherCache.removeAll()
    }
}
