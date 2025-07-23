//
//  BazelInterface.swift
//  InjectionBazel
//
//  Bazel build system interface for hot reloading support
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

public enum BazelError: Error, CustomStringConvertible {
    case workspaceNotFound(String)
    case bazelNotFound
    case queryFailed(String)
    case buildFailed(String)
    case targetNotFound(String)
    case invalidPath(String)
    case pathResolutionFailed(String)
    
    public var description: String {
        switch self {
        case .workspaceNotFound(let path):
            return "Bazel workspace not found at path: \(path)"
        case .bazelNotFound:
            return "Bazel executable not found in PATH"
        case .queryFailed(let error):
            return "Bazel query failed: \(error)"
        case .buildFailed(let error):
            return "Bazel build failed: \(error)"
        case .targetNotFound(let target):
            return "Target not found: \(target)"
        case .invalidPath(let path):
            return "Invalid path provided: \(path)"
        case .pathResolutionFailed(let path):
            return "Failed to resolve path: \(path)"
        }
    }
}

public class BazelInterface {
    private let workspaceRoot: String
    private let bazelExecutable: String
    private static let sourceToTargetCache = NSCache<NSString, NSString>()
    
    public init(workspaceRoot: String, bazelExecutable: String = "bazel") throws {
        // Validate workspace
        let moduleFile = (workspaceRoot as NSString).appendingPathComponent("MODULE.bazel")
        let modulePlainFile = (workspaceRoot as NSString).appendingPathComponent("MODULE")
        let workspaceFile = (workspaceRoot as NSString).appendingPathComponent("WORKSPACE")
        let workspaceBazelFile = (workspaceRoot as NSString).appendingPathComponent("WORKSPACE.bazel")
        
        guard FileManager.default.fileExists(atPath: moduleFile) ||
              FileManager.default.fileExists(atPath: modulePlainFile) ||
              FileManager.default.fileExists(atPath: workspaceFile) ||
              FileManager.default.fileExists(atPath: workspaceBazelFile) else {
            throw BazelError.workspaceNotFound(workspaceRoot)
        }
        
        self.workspaceRoot = workspaceRoot
        self.bazelExecutable = bazelExecutable
        
        // Validate bazel executable
        guard isBazelAvailable() else {
            throw BazelError.bazelNotFound
        }
    }
    
    // MARK: - Workspace Detection
    
    public static func findWorkspaceRoot(containing path: String) -> String? {
        var currentPath = path
        
        while currentPath != "/" && !currentPath.isEmpty {
            let moduleFile = (currentPath as NSString).appendingPathComponent("MODULE.bazel")
            let modulePlainFile = (currentPath as NSString).appendingPathComponent("MODULE")
            let workspaceFile = (currentPath as NSString).appendingPathComponent("WORKSPACE")
            let workspaceBazelFile = (currentPath as NSString).appendingPathComponent("WORKSPACE.bazel")
            
            if FileManager.default.fileExists(atPath: moduleFile) ||
               FileManager.default.fileExists(atPath: modulePlainFile) ||
               FileManager.default.fileExists(atPath: workspaceFile) ||
               FileManager.default.fileExists(atPath: workspaceBazelFile) {
                return currentPath
            }
            
            currentPath = (currentPath as NSString).deletingLastPathComponent
        }
        
        return nil
    }
    
    public static func isBazelWorkspace(containing path: String) -> Bool {
        return findWorkspaceRoot(containing: path) != nil
    }
    
    // MARK: - Target Discovery
    
    public func findTarget(for sourcePath: String) async throws -> String {
        // Check cache first
        if let cachedTarget = getCachedTarget(for: sourcePath) {
            log("🎯 Using cached target for \(sourcePath): \(cachedTarget)")
            return cachedTarget
        }
        
        log("🔍 Finding Bazel target for: \(sourcePath)")
        
        // Convert absolute path to relative from workspace root
        guard sourcePath.hasPrefix(workspaceRoot) else {
            throw BazelError.invalidPath(sourcePath)
        }
        
        let relativePath = String(sourcePath.dropFirst(workspaceRoot.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Query for targets that include this source file
        let queryCommand = "\(bazelExecutable) query 'attr(srcs, \(relativePath), //...)'"
        
        guard let result = Popen(cmd: queryCommand)?.readAll() else {
            throw BazelError.queryFailed("Failed to execute query for \(relativePath)")
        }
        
        let targets = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.newlines)
            .filter { !$0.isEmpty }
        
        guard let target = targets.first else {
            throw BazelError.targetNotFound(relativePath)
        }
        
        log("✅ Found target for \(sourcePath): \(target)")
        setCachedTarget(target, for: sourcePath)
        return target
    }
    
    // MARK: - Build Operations
    
    public func buildForHotReload(target: String, bepOutput: String? = nil) async throws {
        log("🔨 Building target for hot reload: \(target)")
        
        var buildCommand = "\(bazelExecutable) build \(target)"
        
        // Add build event protocol output if specified
        if let bepOutput = bepOutput {
            buildCommand += " --build_event_json_file=\(bepOutput)"
        }
        
        // Add flags for hot reloading compatibility
        buildCommand += " --linkopt=-Wl,interposable"
        buildCommand += " --swiftcopt=-enable-library-evolution"
        buildCommand += " --compilation_mode=dbg"
        
        guard let result = Popen(cmd: buildCommand) else {
            throw BazelError.buildFailed("Failed to execute build command")
        }
        
        let output = result.readAll()
        if output.contains("ERROR:") || output.contains("FAILED:") {
            throw BazelError.buildFailed(output)
        }
        
        log("✅ Successfully built target: \(target)")
    }
    
    
    // MARK: - Path Resolution
    
    public func resolveBuildPath(_ buildPath: String) -> String? {
        // Handle bazel-out paths
        if buildPath.hasPrefix("bazel-out/") {
            let symlinkPath = (workspaceRoot as NSString).appendingPathComponent(buildPath)
            
            // Try to resolve through bazel info
            if let execRoot = getBazelInfo("execution_root") {
                let fullPath = (execRoot as NSString).appendingPathComponent(buildPath)
                if FileManager.default.fileExists(atPath: fullPath) {
                    return fullPath
                }
            }
            
            // Fallback to symlink resolution
            if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath) {
                return resolved
            }
        }
        
        return nil
    }
    
    // MARK: - Validation
    
    public func validateWorkspace() throws {
        // Check if workspace root exists and is a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspaceRoot, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BazelError.workspaceNotFound(workspaceRoot)
        }
        
        // Validate bazel executable
        guard isBazelAvailable() else {
            throw BazelError.bazelNotFound
        }
        
        log("✅ Bazel workspace validated: \(workspaceRoot)")
    }
    
    // MARK: - Private Helpers
    
    private func isBazelAvailable() -> Bool {
        guard let result = Popen(cmd: "which \(bazelExecutable)") else {
            return false
        }
        let output = result.readAll()
        return !output.isEmpty && !output.contains("not found")
    }
    
    private func getBazelInfo(_ key: String) -> String? {
        let command = "\(bazelExecutable) info \(key)"
        guard let result = Popen(cmd: command) else {
            return nil
        }
        
        let output = result.readAll().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return output.contains("ERROR:") ? nil : output
    }
    
    // MARK: - Cache Management
    
    private func getCachedTarget(for sourcePath: String) -> String? {
        return BazelInterface.sourceToTargetCache.object(forKey: sourcePath as NSString) as String?
    }
    
    private func setCachedTarget(_ target: String, for sourcePath: String) {
        BazelInterface.sourceToTargetCache.setObject(target as NSString, forKey: sourcePath as NSString)
    }
    
    public func clearCache() {
        BazelInterface.sourceToTargetCache.removeAllObjects()
        log("🗑️ Bazel target cache cleared")
    }
}
#endif