//
//  BazelPathResolver.swift
//  InjectionLite
//
//  Resolves filesystem paths to Bazel labels for hot reloading
//

import Foundation
#if canImport(InjectionImpl)
import InjectionImpl
#endif

/// Wrapper class for Set<String> to use with NSCache
private final class StringSetWrapper {
    let stringSet: Set<String>
    init(stringSet: Set<String>) {
        self.stringSet = stringSet
    }
}

public enum BazelPathError: Error, CustomStringConvertible {
    case invalidPath(String)
    case packageNotFound(String)
    case workspaceNotFound
    case buildFileNotFound(String)
    case pathOutsideWorkspace(String)
    case labelGenerationFailed(String)
    
    public var description: String {
        switch self {
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .packageNotFound(let path):
            return "No Bazel package found for path: \(path)"
        case .workspaceNotFound:
            return "Bazel workspace not found"
        case .buildFileNotFound(let path):
            return "BUILD file not found for path: \(path)"
        case .pathOutsideWorkspace(let path):
            return "Path is outside workspace: \(path)"
        case .labelGenerationFailed(let path):
            return "Failed to generate Bazel label for path: \(path)"
        }
    }
}

public class BazelPathResolver {
    private let workspaceRoot: String
    private let bazelExecutable: String
    
    // Thread-safe caches using NSCache
    private static let packageCache = NSCache<NSString, NSString>()
    private static let buildFileCache = NSCache<NSString, StringSetWrapper>()
    
    public init(workspaceRoot: String, bazelExecutable: String = "bazel") {
        self.workspaceRoot = workspaceRoot
        self.bazelExecutable = bazelExecutable
    }
    
    // MARK: - Public Interface
    
    /// Convert a filesystem path to a Bazel label
    public func convertToLabel(_ path: String) throws -> String {
        log("🔍 Converting path to Bazel label: \(path)")
        
        // Ensure path is absolute
        let absolutePath = path.hasPrefix("/") ? path : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        
        // Validate path is within workspace
        guard absolutePath.hasPrefix(workspaceRoot) else {
            throw BazelPathError.pathOutsideWorkspace(absolutePath)
        }
        
        // Get relative path from workspace root
        let relativePath = String(absolutePath.dropFirst(workspaceRoot.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Find the package containing this path
        let packagePath = try findPackage(for: relativePath)
        
        // Generate the label
        let label: String
        if packagePath.isEmpty {
            // File is in the root package
            label = "//:\(relativePath)"
        } else {
            // File is in a sub-package
            let targetName = String(relativePath.dropFirst(packagePath.count + 1))
            label = "//\(packagePath):\(targetName)"
        }
        
        log("✅ Generated Bazel label: \(label)")
        return label
    }
    
    /// Find the Bazel package that contains the given relative path
    public func findPackage(for relativePath: String) throws -> String {
        log("📦 Finding package for: \(relativePath)")
        
        // Check cache first
        if let cachedPackage = getCachedPackage(for: relativePath) {
            log("💾 Using cached package: \(cachedPackage)")
            return cachedPackage
        }
        
        // Walk up the directory tree to find the nearest BUILD file
        var currentPath = relativePath
        var packagePath = ""
        
        while true {
            let buildFilePath = packagePath.isEmpty ? "BUILD" : "\(packagePath)/BUILD"
            let buildBazelPath = packagePath.isEmpty ? "BUILD.bazel" : "\(packagePath)/BUILD.bazel"
            
            let fullBuildPath = (workspaceRoot as NSString).appendingPathComponent(buildFilePath)
            let fullBuildBazelPath = (workspaceRoot as NSString).appendingPathComponent(buildBazelPath)
            
            if FileManager.default.fileExists(atPath: fullBuildPath) ||
               FileManager.default.fileExists(atPath: fullBuildBazelPath) {
                setCachedPackage(packagePath, for: relativePath)
                log("✅ Found package: \(packagePath.isEmpty ? "<root>" : packagePath)")
                return packagePath
            }
            
            // Move up one directory
            if packagePath.isEmpty {
                // We're at the root, check if we have a parent directory
                guard let lastSlash = currentPath.lastIndex(of: "/") else {
                    break
                }
                packagePath = String(currentPath[..<lastSlash])
                currentPath = packagePath
            } else {
                guard let lastSlash = packagePath.lastIndex(of: "/") else {
                    packagePath = ""
                    break
                }
                packagePath = String(packagePath[..<lastSlash])
            }
        }
        
        throw BazelPathError.packageNotFound(relativePath)
    }
    
    /// Discover all BUILD files in the workspace
    public func discoverBuildFiles() throws {
        log("🔍 Discovering BUILD files in workspace")
        
        let buildFiles = try findAllBuildFiles()
        setCachedBuildFiles(buildFiles)
        log("✅ Discovered \(buildFiles.count) BUILD files")
    }
    
    // MARK: - Cache Management
    
    private func getCachedPackage(for path: String) -> String? {
        return BazelPathResolver.packageCache.object(forKey: path as NSString) as String?
    }
    
    private func setCachedPackage(_ package: String, for path: String) {
        BazelPathResolver.packageCache.setObject(package as NSString, forKey: path as NSString)
    }
    
    private func setCachedBuildFiles(_ files: Set<String>) {
        let wrapper = StringSetWrapper(stringSet: files)
        BazelPathResolver.buildFileCache.setObject(wrapper, forKey: "buildFiles" as NSString)
    }
    
    public func invalidateCache(for path: String? = nil) {
        if let path = path {
            BazelPathResolver.packageCache.removeObject(forKey: path as NSString)
            log("🗑️ Invalidated cache for path: \(path)")
        } else {
            BazelPathResolver.packageCache.removeAllObjects()
            BazelPathResolver.buildFileCache.removeAllObjects()
            log("🗑️ Invalidated all path resolver caches")
        }
    }
    
    // MARK: - Private Helpers
    
    private func findAllBuildFiles() throws -> Set<String> {
        var buildFiles: Set<String> = []
        let fileManager = FileManager.default
        
        func searchDirectory(_ path: String, relativePath: String = "") throws {
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            
            for item in contents {
                let itemPath = (path as NSString).appendingPathComponent(item)
                let relativeItemPath = relativePath.isEmpty ? item : "\(relativePath)/\(item)"
                
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory) else {
                    continue
                }
                
                if isDirectory.boolValue {
                    // Skip common non-package directories
                    if item.hasPrefix(".") || item == "bazel-out" || item == "bazel-bin" || 
                       item == "bazel-genfiles" || item == "bazel-testlogs" {
                        continue
                    }
                    
                    try searchDirectory(itemPath, relativePath: relativeItemPath)
                } else if item == "BUILD" || item == "BUILD.bazel" {
                    buildFiles.insert(relativePath)
                }
            }
        }
        
        try searchDirectory(workspaceRoot)
        return buildFiles
    }
}