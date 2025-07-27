//
//  BazelAQueryParser.swift
//  InjectionBazel
//
//  Bazel AQuery parser implementing LiteParser protocol for hot reloading
//

#if DEBUG || !SWIFT_PACKAGE
import Foundation
#if canImport(InjectionImpl)
import InjectionImpl
import DLKitD
#endif
#if canImport(PopenD)
import PopenD
#else
import Popen
#endif

extension String {
    public var unescape: String {
        return self[#"\\(.)"#, "$1"]
    }
}

public protocol LiteParser {
  func command(for source: String, platformFilter: String,
               found: inout (logDir: String, scanner: Popen?)?) -> String?
  func prepareFinalCommand(command: String, source: String, objectFile: String, tmpdir: String, injectionNumber: Int) -> String
}

public class BazelAQueryParser: LiteParser {
    private let workspaceRoot: String
    private let bazelExecutable: String
    private let bazelInterface: BazelInterface
    private let actionQueryHandler: BazelActionQueryHandler
    
    // Cache for compilation commands using NSCache for thread-safety and memory management
    private static let commandCache = NSCache<NSString, NSString>()
    
    // App target detection for optimized queries
    private var detectedAppTarget: String?
    
    public init(workspaceRoot: String, bazelExecutable: String = "/opt/homebrew/bin/bazelisk") throws {
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
    
    // MARK: - App Target Management
    
    /// Auto-discover and cache the app target for optimized compilation queries
    public func autoDiscoverAppTarget(for sourcePath: String) {
        do {
            detectedAppTarget = try actionQueryHandler.discoverAppTarget(for: sourcePath)
            log("✅ App target auto-discovered and cached: \(detectedAppTarget!)")
        } catch {
            log("⚠️ Failed to auto-discover app target for \(sourcePath): \(error)")
            detectedAppTarget = nil
        }
    }
    
    /// Get the currently detected app target
    public func getAppTarget() -> String? {
        return detectedAppTarget
    }
    
    // MARK: - LiteParser Implementation
    
    public func command(for source: String, platformFilter: String,
                       found: inout (logDir: String, scanner: Popen?)?) -> String? {
        log("🔍 BazelAQueryParser: Getting command for \(source)")
        
        // Check cache first - include app target in cache key for session-based caching
        let appTargetKey = detectedAppTarget ?? "no-target"
        let cacheKey = "\(source):\(platformFilter):\(appTargetKey)"
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
    
    public func prepareFinalCommand(command: String, source: String, objectFile: String, tmpdir: String, injectionNumber: Int) -> String {
        // Replace bazel-out with workspace-absolute paths
        let commandWithAbsolutePaths = makeBazelOutPathsAbsolute(in: command)
        
        // Handle Bazel's output-file-map if present
        let outputFileMapRegex = #" -output-file-map ([^\s\\]*(?:\\.[^\s\\]*)*)"#
        if let outputFileMapPath = (commandWithAbsolutePaths[outputFileMapRegex] as String?)?.unescape {
            return createMinimalOutputFileMapCommand(command: commandWithAbsolutePaths, source: source, objectFile: objectFile, outputFileMapPath: outputFileMapPath, tmpdir: tmpdir, injectionNumber: injectionNumber)
        } else {
            // Fallback to traditional -o flag
            return commandWithAbsolutePaths + " -o \(objectFile)"
        }
    }
    
    /// Replace bazel-out paths with absolute paths from workspace root
    private func makeBazelOutPathsAbsolute(in command: String) -> String {
        let workspaceAbsolutePath = workspaceRoot + "/bazel-out"
        let updatedCommand = command.replacingOccurrences(of: "bazel-out", with: workspaceAbsolutePath)
        
        if updatedCommand != command {
            log("🔗 Replaced bazel-out paths with absolute paths from workspace root")
        }
        
        return updatedCommand
    }
    
    // MARK: - Private Implementation
    
    private func findCompilationCommandSync(for sourcePath: String, platformFilter: String) -> String? {
        do {
            // Auto-discover app target on first use if not already cached
            if detectedAppTarget == nil {
                log("🔍 Auto-discovering app target for first source file: \(sourcePath)")
                autoDiscoverAppTarget(for: sourcePath)
            }
            
            // Use the auto-discovery logic in findCompilationCommand
            // This will use cached app target if available, or auto-discover it
            let command = try actionQueryHandler.findCompilationCommand(for: sourcePath, appTarget: detectedAppTarget)
            
            // Update our cached app target if one was discovered
            if detectedAppTarget == nil, let cachedTarget = actionQueryHandler.currentAppTarget {
                detectedAppTarget = cachedTarget
                log("📱 Updated cached app target from discovery: \(cachedTarget)")
            }
            
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
            "-index-ignore-system-modules",
            "-module-cache-path",
            "-num-threads"
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
        
        // Replace Bazel placeholders in the command with actual values
        var finalCommand = replaceBazelPlaceholders(in: cleanedCommand)
        
        // Detect and override whole module optimization for hot reloading
        if finalCommand.contains("-whole-module-optimization") || finalCommand.contains("-wmo") {
            finalCommand = finalCommand.replacingOccurrences(
                of: " -whole-module-optimization", with: ""
            )
            finalCommand += " -no-whole-module-optimization"
            finalCommand += " -enable-batch-mode"
            log("🔧 Added -no-whole-module-optimization to override WMO for hot reloading")
        }
        
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
    
    /// Replace Bazel placeholders in the command with actual values
    private func replaceBazelPlaceholders(in command: String) -> String {
        var result = command
        
        // Replace __BAZEL_XCODE_SDKROOT__ with actual SDK path
        if result.contains("__BAZEL_XCODE_SDKROOT__") {
            // Use xcrun to get the simulator SDK path (preferred for development)
            if let output = Popen.task(exec: "/usr/bin/xcrun", 
                                      arguments: ["--sdk", "iphonesimulator", "--show-sdk-path"],
                                      cd: workspaceRoot) {
                let sdkPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sdkPath.isEmpty && !sdkPath.contains("error") {
                    result = result.replacingOccurrences(of: "__BAZEL_XCODE_SDKROOT__", with: sdkPath)
                    log("✅ Replaced __BAZEL_XCODE_SDKROOT__ with \(sdkPath)")
                }
            }
        }
        
        // Replace __BAZEL_XCODE_DEVELOPER_DIR__ with actual developer directory  
        if result.contains("__BAZEL_XCODE_DEVELOPER_DIR__") {
            let developerDir = "/Applications/Xcode.app/Contents/Developer"
            result = result.replacingOccurrences(of: "__BAZEL_XCODE_DEVELOPER_DIR__", with: developerDir)
            log("✅ Replaced __BAZEL_XCODE_DEVELOPER_DIR__ with \(developerDir)")
        }
        
        return result
    }
    
    /// Create a minimal output-file-map for single source file compilation
    private func createMinimalOutputFileMapCommand(command: String, source: String, objectFile: String, outputFileMapPath: String, tmpdir: String, injectionNumber: Int) -> String {
        do {
            log("🗂️ Creating minimal output-file-map for single source compilation")
            
            // Convert absolute source path to relative path from workspace root
            let relativePath: String
            if source.hasPrefix(workspaceRoot) {
                relativePath = String(source.dropFirst(workspaceRoot.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                // If already relative, use as-is
                relativePath = source
            }
            
            // Create minimal output-file-map JSON with only the source file mapping
            let minimalMap: [String: Any] = [
                relativePath: [
                    "object": objectFile
                ]
            ]
            
            // Write the minimal map to a temporary file with unescaped forward slashes
            let tempMapPath = tmpdir + "eval\(injectionNumber)_output_map.json"
            let mapData = try JSONSerialization.data(withJSONObject: minimalMap, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try mapData.write(to: URL(fileURLWithPath: tempMapPath))
            
            // Replace the output-file-map path in the command
            let modifiedCommand = command.replacingOccurrences(of: outputFileMapPath, with: tempMapPath)
            
            log("✅ Created minimal output-file-map: \(tempMapPath)")
            log("📁 Mapping: \(relativePath) -> \(objectFile)")
            return modifiedCommand
            
        } catch {
            log("⚠️ Error creating minimal output-file-map: \(error), falling back to -o flag")
            return command + " -o \(objectFile)"
        }
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
    
    
}
#endif
