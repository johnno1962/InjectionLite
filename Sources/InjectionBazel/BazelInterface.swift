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

    // MARK: - Private Helpers
    
    private func isBazelAvailable() -> Bool {
        guard let result = Popen(cmd: "which \(bazelExecutable)") else {
            return false
        }
        let output = result.readAll()
        return !output.isEmpty && !output.contains("not found")
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
