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
    
    // Cache for compilation commands using NSCache for thread-safety and memory management
    private static let commandCache = NSCache<NSString, NSString>()
    
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
            
            // Clean and prepare command for hot reloading execution
            let cleanedCommand = cleanBazelCommand(normalizedCommand)
            
            // Apply platform filter if specified
            let filteredCommand = applyPlatformFilter(cleanedCommand, filter: platformFilter)
            
            return filteredCommand
        } catch {
            log("⚠️ BazelAQueryParser error: \(error)")
            return nil
        }
    }
    
    /// Clean Bazel compilation command for hot reloading execution
    private func cleanBazelCommand(_ command: String) -> String {
        log("🔧 Cleaning Bazel command for hot reloading")
        
        var cleanedCommand = command
        
        // Remove Bazel-specific flags that interfere with hot reloading
        let flagsToRemove = [
            "-const-gather-protocols-file",
            "-emit-const-values-path", 
            "-emit-module-path",
            "-index-store-path",
            "-index-ignore-system-modules"
        ]
        
        for flag in flagsToRemove {
            // Remove flag and its argument (if it takes one)
            cleanedCommand = removeFlagAndArgument(from: cleanedCommand, flag: flag)
        }
        
        // Extract SDK path and Developer directory for environment variables
        let sdkPath = extractSDKPath(from: cleanedCommand)
        let developerDir = extractDeveloperDir(from: cleanedCommand)
        
        // Prepend environment variable exports
        var envVars: [String] = []
        if let sdkPath = sdkPath {
            envVars.append("export SDKROOT=\"\(sdkPath)\"")
        }
        if let developerDir = developerDir {
            envVars.append("export DEVELOPER_DIR=\"\(developerDir)\"")
        }
        
        // Prepend cd to workspace directory
        let workspaceCommand = "cd \"\(workspaceRoot)\""
        
        // Combine all parts
        let finalCommand = ([workspaceCommand] + envVars + [cleanedCommand]).joined(separator: " && ")
        
        log("✅ Cleaned Bazel command ready for execution")
        return finalCommand
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
    
    // MARK: - Command Cleaning Helpers
    
    private func removeFlagAndArgument(from command: String, flag: String) -> String {
        // Create regex to match flag and its argument (if any)
        // Handles both "-flag value" and "-flag=value" formats
        let patterns = [
            "\\s+\(NSRegularExpression.escapedPattern(for: flag))\\s+\\S+", // -flag value
            "\\s+\(NSRegularExpression.escapedPattern(for: flag))=\\S+",     // -flag=value
            "\\s+\(NSRegularExpression.escapedPattern(for: flag))(?=\\s|$)"  // -flag alone
        ]
        
        var result = command
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }
        
        return result
    }
    
    private func extractSDKPath(from command: String) -> String? {
        // Look for -isysroot or -sdk flags
        let patterns = [
            "-isysroot\\s+(\\S+)",
            "-sdk\\s+(\\S+)"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
               let range = Range(match.range(at: 1), in: command) {
                return String(command[range])
            }
        }
        
        // Fallback: try to extract from typical Xcode paths
        if command.contains(".platform/Developer/SDKs/") {
            let components = command.components(separatedBy: " ")
            for component in components {
                if component.contains(".platform/Developer/SDKs/") && component.hasSuffix(".sdk") {
                    return component
                }
            }
        }
        
        return nil
    }
    
    private func extractDeveloperDir(from command: String) -> String? {
        // Look for Xcode developer directory in paths
        if let sdkPath = extractSDKPath(from: command) {
            // Extract developer dir from SDK path
            // e.g., /Applications/Xcode.app/Contents/Developer/Platforms/...
            if let range = sdkPath.range(of: "/Contents/Developer") {
                let developerDir = String(sdkPath[..<range.upperBound])
                return developerDir
            }
        }
        
        // Fallback to standard Xcode location
        return "/Applications/Xcode.app/Contents/Developer"
    }
    
    // MARK: - Cache Management
    
    private func getCachedCommand(for key: String) -> String? {
        return BazelAQueryParser.commandCache.object(forKey: key as NSString) as String?
    }
    
    private func setCachedCommand(_ command: String, for key: String) {
        BazelAQueryParser.commandCache.setObject(command as NSString, forKey: key as NSString)
    }
    
    public func clearCache() {
        BazelAQueryParser.commandCache.removeAllObjects()
        
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