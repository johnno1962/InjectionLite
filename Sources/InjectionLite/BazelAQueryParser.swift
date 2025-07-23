//
//  BazelAQueryParser.swift
//  InjectionLite
//
//  Bazel AQuery parser implementing LiteParser protocol for hot reloading
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

public class BazelAQueryParser: LiteParser {
    private let workspaceRoot: String
    private let bazelExecutable: String
    private let bazelInterface: BazelInterface
    private let actionQueryHandler: BazelActionQueryHandler
    private let pathNormalizer: BazelPathNormalizer
    
    // Cache for compilation commands
    private var commandCache: [String: String] = [:]
    private let cacheQueue = DispatchQueue(label: "BazelAQueryParser.cache", attributes: .concurrent)
    
    public init(workspaceRoot: String, bazelExecutable: String = "bazel") throws {
        self.workspaceRoot = workspaceRoot
        self.bazelExecutable = bazelExecutable
        
        // Initialize Bazel components
        self.bazelInterface = try BazelInterface(
            workspaceRoot: workspaceRoot,
            bazelExecutable: bazelExecutable
        )
        
        self.actionQueryHandler = BazelActionQueryHandler(
            workspaceRoot: workspaceRoot,
            bazelExecutable: bazelExecutable
        )
        
        self.pathNormalizer = BazelPathNormalizer(
            workspaceRoot: workspaceRoot,
            bazelExecutable: bazelExecutable
        )
        
        log("✅ BazelAQueryParser initialized for workspace: \(workspaceRoot)")
    }
    
    // MARK: - LiteParser Implementation
    
    public func command(for source: String, platformFilter: String,
                       found: inout (logDir: String, scanner: Popen?)?) -> String? {
        log("🔍 BazelAQueryParser: Getting command for \(source)")
        
        // Check cache first
        let cacheKey = "\(source):\(platformFilter)"
        if let cachedCommand = getCachedCommand(for: cacheKey) {
            log("💾 Using cached Bazel command for \(source)")
            return cachedCommand
        }
        
        // Use synchronous wrapper for async operations to conform to LiteParser protocol
        let command = findCompilationCommandSync(for: source, platformFilter: platformFilter)
        
        if let command = command {
            // Cache the successful result
            setCachedCommand(command, for: cacheKey)
            log("✅ Found Bazel compilation command for \(source)")
        } else {
            log("❌ No Bazel compilation command found for \(source)")
        }
        
        return command
    }
    
    // MARK: - Private Implementation
    
    private func findCompilationCommandSync(for sourcePath: String, platformFilter: String) -> String? {
        do {
            let command = try actionQueryHandler.findCompilationCommand(
                for: sourcePath,
                strategy: .mostSpecific
            )
            
            // Normalize paths in the command for local execution
            let normalizedCommand = try pathNormalizer.normalizeCompilationCommand(command)
            
            // Apply platform filter if specified
            let filteredCommand = applyPlatformFilter(normalizedCommand, filter: platformFilter)
            
            return filteredCommand
        } catch {
            log("⚠️ BazelAQueryParser error: \(error)")
            return nil
        }
    }
    
    private func applyPlatformFilter(_ command: String, filter: String) -> String {
        guard !filter.isEmpty else { return command }
        
        // Apply platform-specific filtering if needed
        // This could involve modifying SDK paths, target architectures, etc.
        var filteredCommand = command
        
        // Example: Filter by platform in SDK paths
        if filter.contains("Simulator") {
            filteredCommand = filteredCommand.replacingOccurrences(
                of: "iPhoneOS.platform",
                with: "iPhoneSimulator.platform"
            )
        }
        
        log("🎯 Applied platform filter '\(filter)' to Bazel command")
        return filteredCommand
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
    
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.commandCache.removeAll()
        }
        
        // Clear caches in components
        actionQueryHandler.clearCache()
        bazelInterface.clearCache()
        pathNormalizer.clearPathInfo()
        
        log("🗑️ BazelAQueryParser cache cleared")
    }
    
    // MARK: - Validation
    
    public func validateWorkspace() throws {
        try bazelInterface.validateWorkspace()
        log("✅ Bazel workspace validation passed")
    }
    
    // MARK: - Convenience Methods
    
    /// Check if the given source file exists in a Bazel target
    public func isSourceInBazelTarget(_ sourcePath: String) -> Bool {
        // Simplified synchronous implementation
        // In a real implementation, this would use Bazel query commands
        return true // Placeholder
    }
}