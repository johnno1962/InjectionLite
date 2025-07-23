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
            let command = try actionQueryHandler.findCompilationCommand(for: sourcePath)
            
            // Clean and prepare command for hot reloading execution
            let cleanedCommand = cleanBazelCommand(command)
            
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
        
        // Also remove -Xwrapped-swift flags which have a different pattern
        let xWrappedSwiftPattern = "\\s+'-Xwrapped-swift=[^']*'"
        
        for flag in flagsToRemove {
            // Remove flag and its argument (if it takes one)
            cleanedCommand = removeFlagAndArgument(from: cleanedCommand, flag: flag)
        }
        
        // Remove -Xwrapped-swift flags with special handling
        if let regex = try? NSRegularExpression(pattern: xWrappedSwiftPattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(cleanedCommand.startIndex..., in: cleanedCommand)
            cleanedCommand = regex.stringByReplacingMatches(in: cleanedCommand, options: [], range: range, withTemplate: "")
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
        var result = command
        let escapedFlag = NSRegularExpression.escapedPattern(for: flag)
        
        // Handle different flag patterns:
        // 1. -Xfrontend -const-gather-protocols-file -Xfrontend /path/to/file
        // 2. -emit-const-values-path /path/to/file  
        // 3. -index-ignore-system-modules (standalone)
        
        let patterns = [
            // Pattern 1: -Xfrontend -flag -Xfrontend argument
            "\\s+-Xfrontend\\s+\(escapedFlag)\\s+-Xfrontend\\s+\\S+",
            // Pattern 2: -flag argument (with potential line breaks and whitespace)
            "\\s+\(escapedFlag)\\s+[^\\s-][^\\\\]*?(?=\\s+-|$)",
            // Pattern 3: -flag alone
            "\\s+\(escapedFlag)(?=\\s|$)",
            // Pattern 4: -flag=value
            "\\s+\(escapedFlag)=\\S+"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                let range = NSRange(result.startIndex..., in: result)
                let matches = regex.matches(in: result, options: [], range: range)
                
                // Process matches in reverse order to maintain indices
                for match in matches.reversed() {
                    if let range = Range(match.range, in: result) {
                        result.replaceSubrange(range, with: "")
                    }
                }
            }
        }
        
        // Clean up extra whitespace and line breaks
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
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
        
        log("🗑️ BazelAQueryParser cache cleared")
    }
    
    // MARK: - Validation
    
    public func validateWorkspace() throws {
        try bazelInterface.validateWorkspace()
        log("✅ Bazel workspace validation passed")
    }
    
}