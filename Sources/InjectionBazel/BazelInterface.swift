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

/// Shared utility for resolving development tool binaries with sandbox support
public class BinaryResolver {
    public static let shared = BinaryResolver()
    
    private init() {}
    
    /// Resolve bazel executable path with multi-level fallback
    public func resolveBazelExecutable(preferred: String = "bazel") -> String? {
        // Level 1: Try the preferred executable with PATH resolution
        if let result = Popen(cmd: "which \(preferred)") {
            let output = result.readAll().trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty && !output.contains("not found") {
                return output
            }
        }
        
        // Level 2: Check for injected environment variable
        if let injectedPath = getenv("INJECTION_BAZEL_PATH") {
            let pathString = String(cString: injectedPath)
            if FileManager.default.fileExists(atPath: pathString) {
                return pathString
            }
        }
        
        // Level 3: Try common Bazel installation paths
        let commonPaths = [
            "/opt/homebrew/bin/bazel",
            "/opt/homebrew/bin/bazelisk", 
            "/usr/local/bin/bazel",
            "/usr/local/bin/bazelisk"
        ]
        
        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    /// Resolve xcrun executable path with multi-level fallback
    public func resolveXcrunExecutable() -> String? {
        // Level 1: Try standard xcrun location
        let standardPath = "/usr/bin/xcrun"
        if FileManager.default.fileExists(atPath: standardPath) {
            return standardPath
        }
        
        // Level 2: Check for injected environment variable
        if let injectedPath = getenv("INJECTION_XCRUN_PATH") {
            let pathString = String(cString: injectedPath)
            if FileManager.default.fileExists(atPath: pathString) {
                return pathString
            }
        }
        
        // Level 3: Try PATH resolution
        if let result = Popen(cmd: "which xcrun") {
            let output = result.readAll().trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty && !output.contains("not found") {
                return output
            }
        }
        
        return nil
    }
    
    /// Check if basic development tools are accessible (to detect sandboxed environment)
    public func hasBasicToolAccess() -> Bool {
        // Try to access common development tools
        let basicTools = ["which", "ls", "echo"]
        
        for tool in basicTools {
            if let result = Popen(cmd: "\(tool) --version") {
                let output = result.readAll()
                if !output.contains("command not found") && !output.contains("No such file") {
                    return true
                }
            }
        }
        
        return false
    }
}

public enum BazelError: Error, CustomStringConvertible {
    case workspaceNotFound(String)
    case bazelNotFound
    
    public var description: String {
        switch self {
        case .workspaceNotFound(let path):
            return "Bazel workspace not found at path: \(path)"
        case .bazelNotFound:
            return "Bazel executable not found in PATH"
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
        
        // Validate bazel executable with helpful error message
        guard isBazelAvailable() else {
            // Check if we're in a sandboxed environment
            if let _ = getenv("INJECTION_BAZEL_PATH") {
                throw BazelError.bazelNotFound
            } else if !BinaryResolver.shared.hasBasicToolAccess() {
                // Provide helpful message for sandboxed environments
                print("⚠️ InjectionLite: Running in restricted environment (likely Bazel sandbox)")
                print("   Please set INJECTION_BAZEL_PATH environment variable to the bazel executable path")
                print("   Example: INJECTION_BAZEL_PATH=/opt/homebrew/bin/bazel")
            }
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

    // MARK: - Private Helpers
    
    private func isBazelAvailable() -> Bool {
        // Use shared binary resolver
        if let resolvedPath = BinaryResolver.shared.resolveBazelExecutable(preferred: bazelExecutable) {
            // Verify the resolved path actually works by running it from the workspace directory
            guard let output = Popen.task(exec: resolvedPath,
                                        arguments: ["version"],
                                        cd: workspaceRoot) else {
                return false  
            }
            return !output.contains("command not found") && !output.contains("No such file")
        }
        return false
    }
    
    // MARK: - Cache Management
    
    private func getCachedTarget(for sourcePath: String) -> String? {
        return BazelInterface.sourceToTargetCache.object(forKey: sourcePath as NSString) as String?
    }
    
    private func setCachedTarget(_ target: String, for sourcePath: String) {
        BazelInterface.sourceToTargetCache.setObject(target as NSString, forKey: sourcePath as NSString)
    }
}
#endif
