//
//  BazelPathNormalizer.swift
//  InjectionLite
//
//  Normalizes Bazel execution paths to filesystem paths for hot reloading
//

import Foundation
#if canImport(InjectionImpl)
import InjectionImpl
#endif
#if canImport(PopenD)
import PopenD
#else
import Popen
#endif

public enum PathNormalizationError: Error, CustomStringConvertible {
    case invalidPath(String)
    case bazelInfoFailed(String)
    case executionRootNotFound
    case pathNotFound(String)
    case normalizationFailed(String)
    
    public var description: String {
        switch self {
        case .invalidPath(let path):
            return "Invalid path provided: \(path)"
        case .bazelInfoFailed(let error):
            return "Failed to get Bazel info: \(error)"
        case .executionRootNotFound:
            return "Bazel execution root not found"
        case .pathNotFound(let path):
            return "Path not found: \(path)"
        case .normalizationFailed(let path):
            return "Failed to normalize path: \(path)"
        }
    }
}

public struct BazelPathInfo {
    let executionRoot: String
    let outputBase: String
    let workspaceRoot: String
    let bazelBin: String
    let bazelGenfiles: String
    let bazelOut: String
    
    public init(executionRoot: String, outputBase: String, workspaceRoot: String) {
        self.executionRoot = executionRoot
        self.outputBase = outputBase
        self.workspaceRoot = workspaceRoot
        self.bazelBin = (outputBase as NSString).appendingPathComponent("execroot/_main/bazel-out/darwin-fastbuild/bin")
        self.bazelGenfiles = (outputBase as NSString).appendingPathComponent("execroot/_main/bazel-out/darwin-fastbuild/genfiles")
        self.bazelOut = (outputBase as NSString).appendingPathComponent("execroot/_main/bazel-out")
    }
}

public class BazelPathNormalizer {
    private let workspaceRoot: String
    private let bazelExecutable: String
    private var pathInfo: BazelPathInfo?
    private let infoQueue = DispatchQueue(label: "BazelPathNormalizer.info", attributes: .concurrent)
    
    public init(workspaceRoot: String, bazelExecutable: String = "bazel") {
        self.workspaceRoot = workspaceRoot
        self.bazelExecutable = bazelExecutable
    }
    
    // MARK: - Public Interface
    
    /// Initialize Bazel path information
    public func initializeBazelInfo() throws {
        log("🔧 Initializing Bazel path information")
        
        let executionRoot = try getBazelInfo("execution_root")
        let outputBase = try getBazelInfo("output_base")
        
        let pathInfo = BazelPathInfo(
            executionRoot: executionRoot,
            outputBase: outputBase,
            workspaceRoot: workspaceRoot
        )
        
        setPathInfo(pathInfo)
        log("✅ Bazel path information initialized")
    }
    
    /// Normalize a single path from Bazel execution context to filesystem path
    public func normalizePath(_ path: String) throws -> String {
        guard let pathInfo = getPathInfo() else {
            throw PathNormalizationError.executionRootNotFound
        }
        
        log("🔄 Normalizing path: \(path)")
        
        // Handle different Bazel path formats
        let normalizedPath: String
        
        if path.hasPrefix("bazel-out/") {
            // bazel-out paths are relative to execution root
            normalizedPath = (pathInfo.executionRoot as NSString).appendingPathComponent(path)
        } else if path.hasPrefix("external/") {
            // External dependencies are in execution root
            normalizedPath = (pathInfo.executionRoot as NSString).appendingPathComponent(path)
        } else if path.hasPrefix("/") {
            // Absolute paths - check if they exist
            normalizedPath = path
        } else if path.contains("/") {
            // Relative paths from workspace root
            normalizedPath = (workspaceRoot as NSString).appendingPathComponent(path)
        } else {
            // Simple filenames - try workspace root first
            normalizedPath = (workspaceRoot as NSString).appendingPathComponent(path)
        }
        
        // Verify the normalized path exists
        if FileManager.default.fileExists(atPath: normalizedPath) {
            log("✅ Normalized path: \(normalizedPath)")
            return normalizedPath
        }
        
        // Try alternative locations if the primary doesn't exist
        let alternatives = generateAlternativePaths(for: path, pathInfo: pathInfo)
        for alternative in alternatives {
            if FileManager.default.fileExists(atPath: alternative) {
                log("✅ Found alternative path: \(alternative)")
                return alternative
            }
        }
        
        log("⚠️ Path not found after normalization: \(path)")
        return normalizedPath // Return even if not found, let caller handle
    }
    
    /// Normalize multiple paths
    public func normalizePaths(_ paths: [String]) throws -> [String] {
        return try paths.map { try normalizePath($0) }
    }
    
    /// Normalize paths in a compilation command
    public func normalizeCompilationCommand(_ command: String) throws -> String {
        guard let pathInfo = getPathInfo() else {
            throw PathNormalizationError.executionRootNotFound
        }
        
        log("🔧 Normalizing compilation command")
        
        var normalizedCommand = command
        
        // Common Bazel path patterns to normalize
        let patterns = [
            ("bazel-out/[^\\s]+", pathInfo.executionRoot),
            ("external/[^\\s]+", pathInfo.executionRoot)
        ]
        
        for (pattern, basePath) in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(normalizedCommand.startIndex..., in: normalizedCommand)
            
            let matches = regex.matches(in: normalizedCommand, range: range)
            for match in matches.reversed() { // Reverse to maintain ranges
                if let range = Range(match.range, in: normalizedCommand) {
                    let relativePath = String(normalizedCommand[range])
                    let absolutePath = (basePath as NSString).appendingPathComponent(relativePath)
                    normalizedCommand.replaceSubrange(range, with: absolutePath)
                }
            }
        }
        
        log("✅ Normalized compilation command")
        return normalizedCommand
    }
    
    // MARK: - Private Helpers
    
    private func getBazelInfo(_ key: String) throws -> String {
        let command = "cd '\(workspaceRoot)' && \(bazelExecutable) info \(key)"
        
        guard let result = Popen(cmd: command) else {
            throw PathNormalizationError.bazelInfoFailed("Failed to execute bazel info")
        }
        
        let output = result.readAll().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        // Check if command was successful by looking for error indicators
        if output.contains("ERROR:") || output.contains("FATAL:") {
            throw PathNormalizationError.bazelInfoFailed("Bazel error: \(output)")
        }
        
        return output
    }
    
    private func generateAlternativePaths(for path: String, pathInfo: BazelPathInfo) -> [String] {
        var alternatives: [String] = []
        
        // Try different base paths
        let basePaths = [
            pathInfo.bazelBin,
            pathInfo.bazelGenfiles,
            pathInfo.bazelOut,
            pathInfo.outputBase,
            pathInfo.executionRoot
        ]
        
        for basePath in basePaths {
            alternatives.append((basePath as NSString).appendingPathComponent(path))
        }
        
        return alternatives
    }
    
    // MARK: - Thread-Safe Path Info Management
    
    private func getPathInfo() -> BazelPathInfo? {
        return infoQueue.sync {
            pathInfo
        }
    }
    
    private func setPathInfo(_ info: BazelPathInfo) {
        infoQueue.async(flags: .barrier) {
            self.pathInfo = info
        }
    }
    
    public func clearPathInfo() {
        infoQueue.async(flags: .barrier) {
            self.pathInfo = nil
        }
        log("🗑️ Bazel path info cleared")
    }
}