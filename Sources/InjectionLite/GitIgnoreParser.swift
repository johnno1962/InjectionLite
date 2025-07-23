//
//  GitIgnoreParser.swift
//  InjectionLite
//
//  Gitignore parser using swift-filename-matcher with NSCache for thread-safe caching
//

import Foundation

/// Wrapper class for FilenameMatcher to use with NSCache
private final class MatcherWrapper {
    let matcher: FilenameMatcher
    
    init(matcher: FilenameMatcher) {
        self.matcher = matcher
    }
}

/// Parses .gitignore files and provides pattern matching functionality
final class GitIgnoreParser {
    private var patterns: [GitIgnorePattern] = []
    private static let matcherCache = NSCache<NSString, MatcherWrapper>()
    
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
            let cacheKey = pattern as NSString
            
            // Check cache first
            if let cached = matcherCache.object(forKey: cacheKey) {
                return cached.matcher
            }
            
            var matcherPattern = pattern
            
            // Remove trailing slash for directory patterns
            if matcherPattern.hasSuffix("/") {
                matcherPattern = String(matcherPattern.dropLast())
            }
            
            // Create FilenameMatcher with globstar support
            let matcher = FilenameMatcher(pattern: matcherPattern, options: [.globstar])
            
            // Store in cache - NSCache handles memory management automatically
            matcherCache.setObject(MatcherWrapper(matcher: matcher), forKey: cacheKey)
            
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
        matcherCache.removeAllObjects()
    }
}
