//
//  BazelActionQueryHandler.swift
//  InjectionBazel
//
//  Handles Bazel AQuery operations for extracting Swift compilation commands
//

#if DEBUG || !SWIFT_PACKAGE
import Foundation
#if canImport(InjectionImpl)
import InjectionImpl
#endif
#if canImport(PopenD)
import PopenD
#else
import Popen
#endif

/// Wrapper class for target arrays to use with NSCache
private final class TargetArrayWrapper {
    let targets: [String]
    init(targets: [String]) {
        self.targets = targets
    }
}

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


public class BazelActionQueryHandler {
    private let workspaceRoot: String
    private let bazelExecutable: String
    private static let commandCache = NSCache<NSString, NSString>()
    private static let targetCache = NSCache<NSString, TargetArrayWrapper>()
    
    public init(workspaceRoot: String, bazelExecutable: String = "bazel") {
        self.workspaceRoot = workspaceRoot
        self.bazelExecutable = bazelExecutable
    }
    
    // MARK: - Public Interface
    
    /// Find compilation command for a given source file
    public func findCompilationCommand(for sourcePath: String) throws -> String {
        log("🔍 Finding compilation command for: \(sourcePath)")
        
        // Check cache first
        if let cachedCommand = getCachedCommand(for: sourcePath) {
            log("💾 Using cached compilation command")
            return cachedCommand
        }
        
        // Find all targets that contain this source file
        let targets = try findTargets(for: sourcePath)
        guard !targets.isEmpty else {
            throw BazelActionQueryError.noTargetsFound(sourcePath)
        }
        
        // Sort targets by specificity (longest path first)
        let sortedTargets = targets.sorted { $0.count > $1.count }
        
        // Try each target until we find one that actually includes our source file in its inputs
        var lastError: BazelActionQueryError?
        for target in sortedTargets {
            do {
                log("🎯 Trying target: \(target)")
                let command = try getCompilationCommand(for: target, sourcePath: sourcePath)
                
                // Cache the successful result
                setCachedCommand(command, for: sourcePath)
                
                log("✅ Found compilation command for \(sourcePath) in target: \(target)")
                return command
            } catch let error as BazelActionQueryError {
                log("⚠️ Target \(target) doesn't include \(sourcePath) in inputs, trying next...")
                lastError = error
                continue
            }
        }
        
        // If we get here, no target actually included our source file in its inputs
        throw lastError ?? BazelActionQueryError.noCompilationCommandFound(sourcePath)
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
        
        // Find all possible Bazel label representations for this file
        let possibleLabels = try generatePossibleBazelLabels(for: relativePath)
        
        var allTargets: [String] = []
        
        // Try each possible label representation until we find targets
        for label in possibleLabels {
            log("🔍 Trying Bazel query for label: \(label)")
            let query = "attr(srcs, \(label), //...)"
            
            do {
                let targets = try executeBazelQuery(query)
                if !targets.isEmpty {
                    log("✅ Found \(targets.count) targets for label: \(label)")
                    allTargets.append(contentsOf: targets)
                }
            } catch {
                log("⚠️ Query failed for label \(label): \(error)")
                continue
            }
        }
        
        // Remove duplicates while preserving order
        let uniqueTargets = Array(NSOrderedSet(array: allTargets)) as! [String]
        
        // Cache the results
        setCachedTargets(uniqueTargets, for: sourcePath)
        
        log("✅ Found \(uniqueTargets.count) total unique targets for \(sourcePath)")
        return uniqueTargets
    }
    
    /// Generate all possible Bazel label representations for a relative file path
    private func generatePossibleBazelLabels(for relativePath: String) throws -> [String] {
        log("🏷️ Generating possible Bazel labels for: \(relativePath)")
        
        var possibleLabels: [String] = []
        let pathComponents = relativePath.components(separatedBy: "/")
        
        // Walk up the directory tree to find all possible package boundaries
        for i in 0..<pathComponents.count {
            let packagePath = pathComponents[0..<i].joined(separator: "/")
            let remainingPath = pathComponents[i...].joined(separator: "/")
            
            // Check if this directory has a BUILD file (making it a valid package)
            let isValidPackage = try hasValidBuildFile(packagePath: packagePath)
            
            if isValidPackage {
                // Generate the Bazel label for this package boundary
                let bazelLabel: String
                if packagePath.isEmpty {
                    // Root package
                    bazelLabel = remainingPath
                } else {
                    // Sub-package - use relative path from this package
                    bazelLabel = remainingPath
                }
                
                possibleLabels.append(bazelLabel)
                log("📦 Valid package found at '\(packagePath.isEmpty ? "<root>" : packagePath)' -> label: \(bazelLabel)")
            }
        }
        
        // If no valid packages found, fall back to the full relative path
        if possibleLabels.isEmpty {
            possibleLabels.append(relativePath)
            log("⚠️ No BUILD files found, using full relative path: \(relativePath)")
        }
        
        log("🏷️ Generated \(possibleLabels.count) possible labels: \(possibleLabels)")
        return possibleLabels
    }
    
    /// Check if a directory path has a valid BUILD file
    private func hasValidBuildFile(packagePath: String) throws -> Bool {
        let fullPackagePath = packagePath.isEmpty ? workspaceRoot : (workspaceRoot as NSString).appendingPathComponent(packagePath)
        
        let buildFilePath = (fullPackagePath as NSString).appendingPathComponent("BUILD")
        let buildBazelPath = (fullPackagePath as NSString).appendingPathComponent("BUILD.bazel")
        
        let hasBuildFile = FileManager.default.fileExists(atPath: buildFilePath) ||
                          FileManager.default.fileExists(atPath: buildBazelPath)
        
        if hasBuildFile {
            log("✅ Found BUILD file in: \(packagePath.isEmpty ? "<root>" : packagePath)")
        }
        
        return hasBuildFile
    }
    
    // MARK: - Private Implementation
    
    
    private func getCompilationCommand(for target: String, sourcePath: String) throws -> String {
        log("⚙️ Getting compilation command for target: \(target)")
        
        // Use aquery to get the compilation action for this target
        let query = "mnemonic('SwiftCompile', deps(\(target)))"
        
        let command = "\(bazelExecutable) aquery '\(query)' --output=textproto"
        
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
                    inputs = parseInputsList(inputsString)
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
        // Convert environment dictionary to export statements
        let envExports = environment.map { key, value in
            "export \(key)=\"\(value)\""
        }.joined(separator: " && ")
        
        // Combine environment and command
        if envExports.isEmpty {
            return command
        } else {
            return "\(envExports) && \(command)"
        }
    }
    
    private func executeBazelQuery(_ query: String) throws -> [String] {
        let command = "\(bazelExecutable) query '\(query)'"
        
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
        return BazelActionQueryHandler.commandCache.object(forKey: key as NSString) as String?
    }
    
    private func setCachedCommand(_ command: String, for key: String) {
        BazelActionQueryHandler.commandCache.setObject(command as NSString, forKey: key as NSString)
    }
    
    private func getCachedTargets(for sourcePath: String) -> [String]? {
        return BazelActionQueryHandler.targetCache.object(forKey: sourcePath as NSString)?.targets
    }
    
    private func setCachedTargets(_ targets: [String], for sourcePath: String) {
        let wrapper = TargetArrayWrapper(targets: targets)
        BazelActionQueryHandler.targetCache.setObject(wrapper, forKey: sourcePath as NSString)
    }
    
    public func clearCache() {
        BazelActionQueryHandler.commandCache.removeAllObjects()
        BazelActionQueryHandler.targetCache.removeAllObjects()
        log("🗑️ AQuery handler cache cleared")
    }
    
    public func getCacheStats() -> (commands: Int, targets: Int) {
        // Note: NSCache doesn't provide exact count, returning approximate values
        return (0, 0) // NSCache manages its own statistics internally
    }
}
#endif
