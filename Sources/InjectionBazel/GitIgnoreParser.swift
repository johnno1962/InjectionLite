//
//  GitIgnoreParser.swift
//  InjectionLite
//
//  Gitignore parser using swift-filename-matcher with NSCache for thread-safe caching
//

import Foundation
#if os(macOS)
#if canImport(PopenD)
import PopenD
#else
import Popen
#endif
#endif

/// Wrapper class for FilenameMatcher to use with NSCache
private final class MatcherWrapper {
    let matcher: FilenameMatcher
    
    init(matcher: FilenameMatcher) {
        self.matcher = matcher
    }
}

/// Parses .gitignore files and provides pattern matching functionality
public final class GitIgnoreParser {
    private static let matcherCache = NSCache<NSString, MatcherWrapper>()
    private static let ignoreCache = NSCache<NSString, NSNumber>()
    private static let monitoredDirectoriesLock = NSLock()
    private static var monitoredDirectories: [String] = []
    private var patterns: [GitIgnorePattern] = []
    
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
                self.pattern = GitIgnorePattern.normalizePattern(negatedPattern)
                self.isDirectory = negatedPattern.hasSuffix("/")
            } else {
                self.isNegation = false
                self.pattern = GitIgnorePattern.normalizePattern(trimmed)
                self.isDirectory = trimmed.hasSuffix("/")
            }
            
            // Get cached matcher or create new one
            self.matcher = GitIgnorePattern.getMatcher(for: self.pattern)
        }
        
        /// Normalize gitignore patterns to handle leading slash with dot cases
        private static func normalizePattern(_ pattern: String) -> String {
            // Handle patterns like "/.bazel-*" -> ".bazel-*"
            // This allows /.bazel-grpc-logs to match .bazel-grpc-logs
            if pattern.hasPrefix("/.") {
                return String(pattern.dropFirst()) // Remove leading slash
            }
            return pattern
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
    public func shouldIgnore(path: String, isDirectory: Bool = false) -> Bool {
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
    public static func findGitIgnoreFiles(startingFrom directory: String) -> [GitIgnoreParser] {
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

    public static func monitor(directory: String) {
        let monitoredDirectory = URL(fileURLWithPath: directory)
            .standardizedFileURL.path

        monitoredDirectoriesLock.lock()
        defer { monitoredDirectoriesLock.unlock() }

        guard !monitoredDirectories.contains(monitoredDirectory) else { return }
        monitoredDirectories.append(monitoredDirectory)
        monitoredDirectories.sort { $0.count > $1.count }
    }

    static public func shouldExclude(file filePath: String) -> String? {
        return shouldExclude(files: [filePath])[filePath]
    }

    static public func shouldExclude(files filePaths: [String]) -> [String: String] {
        var exclusions: [String: String] = [:]
        var filesToCheck: [String] = []

        for filePath in filePaths {
            // Early exit: Only process relevant source files
            guard isValidSourceFile(filePath) else {
                exclusions[filePath] = "not a valid source file"
                continue
            }

            // Use cached result if available
            if let cachedResult = ignoreCache.object(forKey: filePath as NSString) {
                if cachedResult.boolValue {
                    exclusions[filePath] = "gitignore rule"
                }
                continue
            }

            filesToCheck.append(filePath)
        }

        let filesByDirectory = Dictionary(grouping: filesToCheck,
                                          by: gitCheckDirectory(for:))
        for (directory, files) in filesByDirectory {
            guard let ignoredFiles = gitCheckIgnore(filePaths: files, in: directory) else {
                for file in files {
                    ignoreCache.setObject(NSNumber(value: false),
                                          forKey: file as NSString)
                }
                continue
            }
            for file in files {
                let shouldIgnore = ignoredFiles.contains(file)
                ignoreCache.setObject(NSNumber(value: shouldIgnore),
                                      forKey: file as NSString)
                if shouldIgnore {
                    exclusions[file] = "gitignore rule"
                }
            }
        }

        return exclusions
    }

    public static var  validExtensions = Set([
        ".swift", ".m", ".mm", ".h", ".c", ".cpp", ".cc"])

    private static func isValidSourceFile(_ filePath: String) -> Bool {
        let pathExtension = (filePath as NSString).pathExtension.lowercased()
        guard !pathExtension.isEmpty else {
            return false
        }
        let fileExtension = "." + pathExtension
        return validExtensions.contains(fileExtension)
    }

#if os(macOS)
    private static func gitCheckIgnore(filePaths: [String], in directory: String) -> Set<String>? {
        guard !filePaths.isEmpty else { return [] }

        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InjectionLiteCheckIgnore-\(UUID().uuidString)")
        let input = filePaths.joined(separator: "\n") + "\n"
        do {
            try input.write(to: inputURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let gitProcess = Topen(exec: "/bin/bash",
                               arguments: [
                                   "-c",
                                   #"exec /usr/bin/git -C "$1" check-ignore --stdin < "$2""#,
                                   "git-check-ignore",
                                   directory,
                                   inputURL.path
                               ],
                               cd: directory)
        let output = Set(gitProcess)
        _ = gitProcess.terminatedOK()
        guard gitProcess.exitStatus == EXIT_SUCCESS || gitProcess.exitStatus == 1 else {
            return nil
        }

        return output
    }
#else
    private static func gitCheckIgnore(filePaths: [String], in directory: String) -> Set<String>? {
        return nil
    }
#endif

    private static func gitCheckDirectory(for filePath: String) -> String {
        let standardizedPath = URL(fileURLWithPath: filePath).standardizedFileURL.path

        monitoredDirectoriesLock.lock()
        let directories = monitoredDirectories
        monitoredDirectoriesLock.unlock()

        if let monitoredDirectory = directories.first(where: {
            standardizedPath == $0 || standardizedPath.hasPrefix($0 + "/")
        }) {
            return monitoredDirectory
        }

        return (filePath as NSString).deletingLastPathComponent
    }
}
