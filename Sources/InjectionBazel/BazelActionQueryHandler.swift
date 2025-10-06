//
//  BazelActionQueryHandler.swift
//  InjectionBazel
//
//  Handles Bazel AQuery operations for extracting Swift compilation commands
//

#if (DEBUG || !SWIFT_PACKAGE) && os(macOS)
import Foundation
#if canImport(InjectionImpl)
import InjectionImpl
#endif
#if canImport(PopenD)
import PopenD
#else
import Popen
#endif

#if !os(macOS)
extension Popen {
  class func task(exec: String, arguments: [String] = [],
                  cd: String = "/tmp", errors: Bool? = false) -> String? {
      var cmd = "cd \(cd) && \(exec)"
      for arg in arguments {
          cmd += " '\(arg)'"
      }
      return system(cmd, errors: errors)
  }
}
#endif

public enum BazelActionQueryError: Error, CustomStringConvertible {
    case workspaceNotFound
    case queryExecutionFailed(String)
    case noTargetsFound(String)
    case noCompilationCommandFound(String)
    case invalidQuery(String)
    case cacheError(String)
    
    public var description: String {
        switch self {
        case .workspaceNotFound:
            return "Bazel workspace not found"
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


public class BazelActionQueryHandler {
    private let workspaceRoot: String
    private let bazelExecutable: String
    private static let commandCache = NSCache<NSString, NSString>()
    private var cachedExecutionRoot: String?
    public static var cachedAppTarget: String?
    
    public init(workspaceRoot: String) throws {
        self.workspaceRoot = workspaceRoot
        // Resolve the actual bazel executable path with fallback logic
        self.bazelExecutable = try BinaryResolver.shared.resolveBazelExecutable()
    }
    
    /// Get the currently cached app target
    public var currentAppTarget: String? {
        return Self.cachedAppTarget
    }
    
    // MARK: - Public Interface
    
    /// Discover and validate the app target for a given source file
    public func discoverAppTarget(for sourcePath: String) throws -> String {
        // Check cache first
        if let cachedTarget = Self.cachedAppTarget {
            log("💾 Using cached app target: \(cachedTarget)")
            return cachedTarget
        }
        
        // Query for all iOS application targets
        let candidateTargets = try findAllAppTargets()
        guard !candidateTargets.isEmpty else {
            throw BazelActionQueryError.noTargetsFound("No ios_application targets found in workspace")
        }
        
        // Test each candidate to see if it generates SwiftCompile actions for this source file
        for candidate in candidateTargets {
            do {
                let hasActionsForSource = try validateTargetHasActionsForSource(candidate, sourcePath: sourcePath)
                if hasActionsForSource {
                    Self.cachedAppTarget = candidate
                    return candidate
                }
            } catch {
                continue
            }
        }
        
        throw BazelActionQueryError.noCompilationCommandFound("No candidate targets can compile source file: \(sourcePath)")
    }
    
    /// Find compilation command for a given source file using optimized app target approach
    public func findCompilationCommand(for sourcePath: String, appTarget: String? = nil) throws -> String {
        // Check cache first
        let cacheKey = appTarget != nil ? "\(sourcePath):\(appTarget!)" : sourcePath
        if let cachedCommand = getCachedCommand(for: cacheKey) {
            return cachedCommand
        }
        
        // If app target is provided, use it directly
        if let appTarget = appTarget {
            return try findCompilationCommandWithAppTarget(for: sourcePath, appTarget: appTarget, cacheKey: cacheKey)
        }
        
        // Auto-discover app target that works for this source file
        do {
            let discoveredTarget = try discoverAppTarget(for: sourcePath)
            let newCacheKey = "\(sourcePath):\(discoveredTarget)"
            return try findCompilationCommandWithAppTarget(for: sourcePath, appTarget: discoveredTarget, cacheKey: newCacheKey)
        } catch {
            log("⚠️ App target discovery failed, falling back to legacy approach: \(error)")
            throw BazelActionQueryError.noCompilationCommandFound("Couldn't find an ios_application that has a compilation action for this file")
        }
    }
    
    /// Optimized compilation command finding using app target dependencies
    private func findCompilationCommandWithAppTarget(for sourcePath: String, appTarget: String, cacheKey: String) throws -> String {
        // Convert absolute path to relative path from workspace root
        let relativePath = try convertToRelativePath(sourcePath)

        // Use the optimized aquery pattern with relative path
        let query = "mnemonic(\"SwiftCompile\", inputs(\"\(relativePath)\", deps(\"\(appTarget)\")))"
        
        guard let output = Popen.task(exec: bazelExecutable,
                                     arguments: ["aquery", query, "--output=text"],
                                     cd: workspaceRoot) else {
            throw BazelActionQueryError.queryExecutionFailed("Failed to execute optimized aquery")
        }
        
        if output.contains("ERROR:") || output.contains("FAILED:") {
            throw BazelActionQueryError.queryExecutionFailed("Optimized aquery failed: \(output)")
        }
        
        // Parse the textproto output to extract Swift compilation commands
        let compilationCommands = try parseAllSwiftCompilationCommands(from: output, sourcePath: sourcePath)
        
        guard !compilationCommands.isEmpty else {
            throw BazelActionQueryError.noCompilationCommandFound("No SwiftCompile actions found for \(relativePath) in app target \(appTarget)")
        }
        
        // Look for iOS configuration first (check for ios_ prefix)  
        let iosConfig = compilationCommands.first { $0.configuration.hasPrefix("ios_") }
        if let config = iosConfig {
            setCachedCommand(config.command, for: cacheKey)
            return config.command
        }
        
        // Fallback to first available configuration if no iOS found
        if let config = compilationCommands.first {
            log("⚠️ No iOS configuration found, using first available configuration: \(config.configuration) for app target \(appTarget)")
            setCachedCommand(config.command, for: cacheKey)
            log("✅ Using optimized fallback compilation command for \(relativePath)")
            return config.command
        }
        
        throw BazelActionQueryError.noCompilationCommandFound("No valid compilation commands found for \(relativePath) in app target \(appTarget)")
    }
    
    // MARK: - Private Implementation
    
    /// Find all iOS application targets in the workspace, sorted by package path length (shortest first)
    private func findAllAppTargets() throws -> [String] {
        log("🔍 Querying all iOS application targets in workspace")
        
        let query = "kind(ios_application, //...)"
        guard let output = Popen.task(exec: bazelExecutable,
                                     arguments: ["query", query],
                                     cd: workspaceRoot) else {
            throw BazelActionQueryError.queryExecutionFailed("Failed to execute target query")
        }
        
        if output.contains("ERROR:") || output.contains("FAILED:") {
            throw BazelActionQueryError.queryExecutionFailed("Target query failed: \(output)")
        }
        
        let targets = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty && $0.hasPrefix("//") }
            .sorted { target1, target2 in
                // Sort by package path length (shorter paths first)
                // Extract package path (everything before the colon)
                let packagePath1 = extractPackagePath(from: target1)
                let packagePath2 = extractPackagePath(from: target2)
                
                // Shorter package paths come first (top-level apps)
                if packagePath1.count != packagePath2.count {
                    return packagePath1.count < packagePath2.count
                }
                
                // If same length, sort alphabetically for consistency
                return target1 < target2
            }
        
        return targets
    }
    
    /// Extract package path from a Bazel target label (everything before the colon)
    private func extractPackagePath(from target: String) -> String {
        guard let colonIndex = target.firstIndex(of: ":") else {
            // No colon means it's a simple target, treat as root
            return target.hasPrefix("//") ? String(target.dropFirst(2)) : target
        }
        
        let packagePart = String(target[..<colonIndex])
        return packagePart.hasPrefix("//") ? String(packagePart.dropFirst(2)) : packagePart
    }
    
    /// Validate that a target has SwiftCompile actions for the specific source file using aquery
    private func validateTargetHasActionsForSource(_ target: String, sourcePath: String) throws -> Bool {
        // Convert absolute path to relative path from workspace root
        let relativePath = try convertToRelativePath(sourcePath)
        
        let query = "mnemonic(\"SwiftCompile\", inputs(\"\(relativePath)\", deps(\"\(target)\")))"
        guard let output = Popen.task(exec: bazelExecutable,
                                     arguments: ["aquery", query, "--output=text"],
                                     cd: workspaceRoot) else {
            throw BazelActionQueryError.queryExecutionFailed("Failed to execute validation aquery")
        }
        
        if output.contains("ERROR:") || output.contains("FAILED:") {
            return false
        }
        
        // Check if output contains any SwiftCompile actions for this source file
        let hasActionsForSource = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && 
                                 output.contains("SwiftCompile")
        
        return hasActionsForSource
    }
    
    /// Convert absolute source path to relative path from workspace root
    private func convertToRelativePath(_ sourcePath: String) throws -> String {
        guard sourcePath.hasPrefix(workspaceRoot) else {
            throw BazelActionQueryError.invalidQuery("Source path must be within workspace: \(sourcePath)")
        }
        
        let relativePath = String(sourcePath.dropFirst(workspaceRoot.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "+", with: "\\+")
        
        return relativePath
    }
    
    private func parseAllSwiftCompilationCommands(from textproto: String, sourcePath: String) throws -> [(command: String, configuration: String)] {
        // Split the textproto into individual actions
        let actionBlocks = textproto.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        var commands: [(command: String, configuration: String)] = []
        
        for actionBlock in actionBlocks {
            let actionText = "action {" + actionBlock
            
            do {
                let command = try parseSwiftCompilationCommand(from: actionText, sourcePath: sourcePath)
                let configuration = extractConfiguration(from: actionText)
                commands.append((command: command, configuration: configuration))
            } catch {
                continue
            }
        }
        
        if commands.isEmpty {
            log("⚠️ Couldn't find any compilation command for source file")
        }
        
        return commands
    }
    
    private func extractConfiguration(from actionText: String) -> String {
        let lines = actionText.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Configuration: ") {
                let configValue = String(trimmed.dropFirst("Configuration: ".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return configValue
            }
        }
        return "unknown"
    }
    
    private func parseSwiftCompilationCommand(from textproto: String, sourcePath: String) throws -> String {
        // Parse the human-readable aquery output format
        let lines = textproto.components(separatedBy: .newlines)
        var mnemonic = ""
        var commandLine = ""
        var environment: [String: String] = [:]
        var inputs: [String] = []
        
        var inCommandLine = false
        var inEnvironment = false
        var commandLineBuffer = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Parse Mnemonic
            if trimmed.hasPrefix("Mnemonic: ") {
                mnemonic = String(trimmed.dropFirst("Mnemonic: ".count))
            }
            // Parse Environment section
            else if trimmed.hasPrefix("Environment: [") {
                inEnvironment = true
                let envContent = String(trimmed.dropFirst("Environment: [".count))
                if envContent.hasSuffix("]") {
                    // Single line environment
                    let envString = String(envContent.dropLast(1))
                    environment = parseEnvironmentString(envString)
                    inEnvironment = false
                }
            }
            else if inEnvironment {
                if trimmed.hasSuffix("]") {
                    // End of multi-line environment
                    let envContent = String(trimmed.dropLast(1))
                    if !envContent.isEmpty {
                        let envDict = parseEnvironmentString(envContent)
                        environment.merge(envDict) { _, new in new }
                    }
                    inEnvironment = false
                } else {
                    // Continue parsing environment
                    let envDict = parseEnvironmentString(trimmed)
                    environment.merge(envDict) { _, new in new }
                }
            }
            // Parse Inputs to check if our source file is included
            else if trimmed.hasPrefix("Inputs: [") {
                let inputsContent = String(trimmed.dropFirst("Inputs: [".count))
                if inputsContent.hasSuffix("]") {
                    let inputsString = String(inputsContent.dropLast(1))
                    inputs = inputs + parseInputsList(inputsString)
                }
            }
            // Parse Command Line section
            else if trimmed.hasPrefix("Command Line: (exec ") {
                inCommandLine = true
                commandLineBuffer = String(trimmed.dropFirst("Command Line: (exec ".count))
                if commandLineBuffer.hasSuffix(")") {
                    // Single line command
                    commandLine = String(commandLineBuffer.dropLast(1))
                    inCommandLine = false
                }
            }
            else if inCommandLine {
                if trimmed.hasSuffix(")") {
                    // End of multi-line command
                    commandLineBuffer += " " + String(trimmed.dropLast(1))
                    commandLine = commandLineBuffer
                    inCommandLine = false
                } else {
                    // Continue building command line
                    commandLineBuffer += " " + trimmed
                }
            }
        }
        
        // Check if this is a SwiftCompile action for our source file
        guard mnemonic == "SwiftCompile" else {
            throw BazelActionQueryError.noCompilationCommandFound("Not a SwiftCompile action")
        }
        
        // Check if our source file is in the inputs
        let sourceFileName = (sourcePath as NSString).lastPathComponent
        let hasSourceFile = inputs.contains { input in
            input.contains(sourceFileName) || input.hasSuffix(sourceFileName)
        }
        
        guard hasSourceFile else {
            throw BazelActionQueryError.noCompilationCommandFound("Source file not found in inputs")
        }
        
        // Clean up the command line and combine with environment
        let cleanedCommand = cleanupCommandLine(commandLine)
        let finalCommand = combineEnvironmentAndCommand(environment: environment, command: cleanedCommand)
        
        return finalCommand
    }
    
    private func parseEnvironmentString(_ envString: String) -> [String: String] {
        var environment: [String: String] = [:]
        
        // Split by comma and parse KEY=VALUE pairs
        let envPairs = envString.components(separatedBy: ", ")
        for pair in envPairs {
            let trimmedPair = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPair.isEmpty { continue }
            
            if let equalIndex = trimmedPair.firstIndex(of: "=") {
                let key = String(trimmedPair[..<equalIndex])
                let value = String(trimmedPair[trimmedPair.index(after: equalIndex)...])
                environment[key] = value
            }
        }
        
        return environment
    }
    
    private func parseInputsList(_ inputsString: String) -> [String] {
        // Split by comma and clean up
        return inputsString.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    private func cleanupCommandLine(_ commandLine: String) -> String {
        // Remove line continuation backslashes and normalize whitespace
        return commandLine
            .replacingOccurrences(of: " \\\n", with: " ")
            .replacingOccurrences(of: " \\", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func combineEnvironmentAndCommand(environment: [String: String], command: String) -> String {
        var allEnvironment = environment
        
        // Extract and add SDKROOT if not already present
        if allEnvironment["SDKROOT"] == nil {
            if let sdkPath = extractSDKPath(from: command) {
                allEnvironment["SDKROOT"] = sdkPath
            }
        }
        
        // Convert environment dictionary to export statements
        let envExports = allEnvironment.map { key, value in
            "export \(key)=\"\(value)\""
        }.joined(separator: " && ")
        
        // Use Bazel execution root instead of workspace root
        let executionRoot = getBazelExecutionRoot()
        if executionRoot == nil {
            log("⚠️ Could not get Bazel execution root, falling back to workspace root")
        }
        let cdCommand = "cd \"\(executionRoot ?? workspaceRoot)\""
        
        // Combine cd, environment exports, and command
        let components = [cdCommand] + (envExports.isEmpty ? [] : [envExports]) + [command]
        return components.joined(separator: " && ")
    }
    
    private func getBazelExecutionRoot() -> String? {
        // Return cached value if available
        if let cached = cachedExecutionRoot {
            log("💾 Using cached Bazel execution root: \(cached)")
            return cached
        }
        
        guard let output = Popen.task(exec: bazelExecutable,
                                     arguments: ["info", "execution_root"],
                                     cd: workspaceRoot) else {
            log("⚠️ Failed to execute Bazel info execution_root command")
            return nil
        }
        
        if output.contains("ERROR:") || output.contains("FAILED:") {
            log("⚠️ Bazel execution root query failed: \(output)")
            return nil
        }
        
        let executionRoot = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .filter { $0.starts(with: "/private/var/tmp/_bazel") }
            .first.map(String.init) ?? ""
        if !executionRoot.isEmpty {
            cachedExecutionRoot = executionRoot
            return executionRoot
        }
        
        log("⚠️ Bazel execution root query returned empty result")
        return nil
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
                let sdkPath = String(command[range])
                
                // Handle Bazel placeholder __BAZEL_XCODE_SDKROOT__
                if sdkPath == "__BAZEL_XCODE_SDKROOT__" {
                    return resolveXcodeSDKRoot()
                }
                
                return sdkPath
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
    
    private func resolveXcodeSDKRoot() -> String? {
        // Get xcrun path with fallback logic
        guard let xcrunPath = BinaryResolver.shared.resolveXcrunExecutable() else {
            log("⚠️ xcrun not available - cannot resolve __BAZEL_XCODE_SDKROOT__")
            return nil
        }
        
        // Try different SDK types in order of preference (simulator first)
        let sdks = ["iphonesimulator", "iphoneos", "macosx"]
        
        for sdk in sdks {
            if let output = Popen.task(exec: xcrunPath, 
                                      arguments: ["--sdk", sdk, "--show-sdk-path"],
                                      cd: workspaceRoot) {
                let sdkPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sdkPath.isEmpty && !sdkPath.contains("error") {
                    return sdkPath
                }
            }
        }
        
        // Fallback to common SDK paths (simulator first)
        let fallbackPaths = [
            "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk",
            "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk",
            "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        ]
        
        for fallbackPath in fallbackPaths {
            if FileManager.default.fileExists(atPath: fallbackPath) {
                log("✅ Using fallback SDKROOT: \(fallbackPath)")
                return fallbackPath
            }
        }
        
        log("⚠️ Could not resolve __BAZEL_XCODE_SDKROOT__")
        return nil
    }
    
    // MARK: - Cache Management
    
    private func getCachedCommand(for key: String) -> String? {
        return BazelActionQueryHandler.commandCache.object(forKey: key as NSString) as String?
    }
    
    private func setCachedCommand(_ command: String, for key: String) {
        BazelActionQueryHandler.commandCache.setObject(command as NSString, forKey: key as NSString)
    }

    public func getCacheStats() -> (commands: Int, targets: Int) {
        // Note: NSCache doesn't provide exact count, returning approximate values
        return (0, 0) // NSCache manages its own statistics internally
    }
}
#endif
