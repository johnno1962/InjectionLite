//
//  BazelActionQueryHandler.swift
//  InjectionLite
//
//  Handles Bazel AQuery operations for extracting Swift compilation commands
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

public enum BazelActionQueryError: Error, CustomStringConvertible {
    case workspaceNotFound
    case bazelExecutableNotFound
    case queryExecutionFailed(String)
    case noTargetsFound(String)
    case noCompilationCommandFound(String)
    case invalidQuery(String)
    case cacheError(String)
    
    public var description: String {
        switch self {
        case .workspaceNotFound:
            return "Bazel workspace not found"
        case .bazelExecutableNotFound:
            return "Bazel executable not found in PATH"
        case .queryExecutionFailed(let error):
            return "AQuery execution failed: \(error)"
        case .noTargetsFound(let source):
            return "No targets found for source: \(source)"
        case .noCompilationCommandFound(let target):
            return "No compilation command found for target: \(target)"
        case .invalidQuery(let query):
            return "Invalid query: \(query)"
        case .cacheError(let error):
            return "Cache error: \(error)"
        }
    }
}

public enum TargetSelectionStrategy {
    case first              // Select the first target found
    case mostSpecific       // Select the most specific target (longest path)
    case primaryTarget      // Select primary target based on heuristics
}

public class BazelActionQueryHandler {
    private let workspaceRoot: String
    private let bazelExecutable: String
    private var commandCache: [String: String] = [:]
    private var targetCache: [String: [String]] = [:]
    private let cacheQueue = DispatchQueue(label: "BazelActionQueryHandler.cache", attributes: .concurrent)
    
    public init(workspaceRoot: String, bazelExecutable: String = "bazel") {
        self.workspaceRoot = workspaceRoot
        self.bazelExecutable = bazelExecutable
    }
    
    // MARK: - Public Interface
    
    /// Find compilation command for a given source file
    public func findCompilationCommand(
        for sourcePath: String,
        strategy: TargetSelectionStrategy = .mostSpecific
    ) throws -> String {
        log("🔍 Finding compilation command for: \(sourcePath)")
        
        // Check cache first
        let cacheKey = "\(sourcePath):\(strategy)"
        if let cachedCommand = getCachedCommand(for: cacheKey) {
            log("💾 Using cached compilation command")
            return cachedCommand
        }
        
        // Find targets that contain this source file
        let targets = try findTargets(for: sourcePath)
        guard !targets.isEmpty else {
            throw BazelActionQueryError.noTargetsFound(sourcePath)
        }
        
        // Select target based on strategy
        let selectedTarget = selectTarget(from: targets, for: sourcePath, strategy: strategy)
        
        // Get compilation command for the selected target
        let command = try getCompilationCommand(for: selectedTarget, sourcePath: sourcePath)
        
        // Cache the result
        setCachedCommand(command, for: cacheKey)
        
        log("✅ Found compilation command for \(sourcePath)")
        return command
    }
    
    /// Find all targets that contain the given source file
    public func findTargets(for sourcePath: String) throws -> [String] {
        log("🎯 Finding targets for source: \(sourcePath)")
        
        // Check cache first
        if let cachedTargets = getCachedTargets(for: sourcePath) {
            log("💾 Using cached targets: \(cachedTargets)")
            return cachedTargets
        }
        
        // Convert absolute path to relative path from workspace root
        guard sourcePath.hasPrefix(workspaceRoot) else {
            throw BazelActionQueryError.invalidQuery("Source path must be within workspace")
        }
        
        let relativePath = String(sourcePath.dropFirst(workspaceRoot.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Query Bazel for targets containing this source file
        let query = "attr(srcs, \(relativePath), //...)"
        let targets = try executeBazelQuery(query)
        
        // Cache the results
        setCachedTargets(targets, for: sourcePath)
        
        log("✅ Found \(targets.count) targets for \(sourcePath)")
        return targets
    }
    
    // MARK: - Private Implementation
    
    private func selectTarget(
        from targets: [String],
        for sourcePath: String,
        strategy: TargetSelectionStrategy
    ) -> String {
        switch strategy {
        case .first:
            return targets.first!
            
        case .mostSpecific:
            // Select target with the longest path (most specific)
            return targets.max { $0.count < $1.count } ?? targets.first!
            
        case .primaryTarget:
            // Use heuristics to find the primary target
            // Prefer targets that end with the file name (without extension)
            let fileName = (sourcePath as NSString).lastPathComponent
            let baseName = (fileName as NSString).deletingPathExtension
            
            // Look for targets that end with the base name
            if let primaryTarget = targets.first(where: { $0.hasSuffix(":\(baseName)") }) {
                return primaryTarget
            }
            
            // Fallback to most specific
            return targets.max { $0.count < $1.count } ?? targets.first!
        }
    }
    
    private func getCompilationCommand(for target: String, sourcePath: String) throws -> String {
        log("⚙️ Getting compilation command for target: \(target)")
        
        // Use aquery to get the compilation action for this target
        let query = "mnemonic('SwiftCompile', deps(\(target)))"
        
        let command = "cd '\(workspaceRoot)' && \(bazelExecutable) aquery '\(query)' --output=textproto"
        
        guard let result = Popen(cmd: command) else {
            throw BazelActionQueryError.queryExecutionFailed("Failed to execute aquery")
        }
        
        let output = result.readAll()
        
        if output.contains("ERROR:") || output.contains("FAILED:") {
            throw BazelActionQueryError.queryExecutionFailed("AQuery failed: \(output)")
        }
        
        // Parse the textproto output to extract the Swift compilation command
        let compilationCommand = try parseSwiftCompilationCommand(from: output, sourcePath: sourcePath)
        
        log("✅ Extracted compilation command")
        return compilationCommand
    }
    
    private func parseSwiftCompilationCommand(from textproto: String, sourcePath: String) throws -> String {
        // Parse the textproto output to find Swift compilation actions
        let lines = textproto.components(separatedBy: .newlines)
        var currentAction: [String: String] = [:]
        var inAction = false
        var arguments: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("actions {") {
                inAction = true
                currentAction = [:]
                arguments = []
            } else if trimmed == "}" && inAction {
                // End of action, check if it's a Swift compilation for our source
                if currentAction["mnemonic"] == "SwiftCompile" && 
                   arguments.contains(where: { $0.contains(sourcePath) }) {
                    // Reconstruct the compilation command
                    return arguments.joined(separator: " ")
                }
                inAction = false
            } else if inAction {
                if trimmed.hasPrefix("mnemonic: ") {
                    currentAction["mnemonic"] = String(trimmed.dropFirst("mnemonic: ".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                } else if trimmed.hasPrefix("arguments: ") {
                    let arg = String(trimmed.dropFirst("arguments: ".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    arguments.append(arg)
                }
            }
        }
        
        throw BazelActionQueryError.noCompilationCommandFound(sourcePath)
    }
    
    private func executeBazelQuery(_ query: String) throws -> [String] {
        let command = "cd '\(workspaceRoot)' && \(bazelExecutable) query '\(query)'"
        
        guard let result = Popen(cmd: command) else {
            throw BazelActionQueryError.queryExecutionFailed("Failed to execute query")
        }
        
        let output = result.readAll()
        
        if output.contains("ERROR:") || output.contains("FAILED:") {
            throw BazelActionQueryError.queryExecutionFailed("Query failed: \(output)")
        }
        
        return output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.newlines)
            .filter { !$0.isEmpty }
    }
    
    // MARK: - Cache Management
    
    private func getCachedCommand(for key: String) -> String? {
        return cacheQueue.sync {
            commandCache[key]
        }
    }
    
    private func setCachedCommand(_ command: String, for key: String) {
        cacheQueue.async(flags: .barrier) {
            self.commandCache[key] = command
        }
    }
    
    private func getCachedTargets(for sourcePath: String) -> [String]? {
        return cacheQueue.sync {
            targetCache[sourcePath]
        }
    }
    
    private func setCachedTargets(_ targets: [String], for sourcePath: String) {
        cacheQueue.async(flags: .barrier) {
            self.targetCache[sourcePath] = targets
        }
    }
    
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.commandCache.removeAll()
            self.targetCache.removeAll()
        }
        log("🗑️ AQuery handler cache cleared")
    }
    
    public func getCacheStats() -> (commands: Int, targets: Int) {
        return cacheQueue.sync {
            (commandCache.count, targetCache.count)
        }
    }
}