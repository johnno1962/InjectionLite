//
//  BazelInterface.swift
//  InjectionBazel
//
//  Bazel build system interface for hot reloading support
//

#if (DEBUG || !SWIFT_PACKAGE) && os(macOS)
import Foundation
#if canImport(InjectionImpl)
import InjectionImplC
import InjectionImpl
#endif

/// Shared utility for resolving development tool binaries with sandbox support
public class BinaryResolver {
    public static let shared = BinaryResolver()
    private var resolvedBazelPath: String?
    
    private init() {}
    
    /// Resolve bazel executable path with multi-level fallback
    public func resolveBazelExecutable() throws -> String {
        if let resolvedBazelPath {
            return resolvedBazelPath
        }
        let path = "/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin"
        let export = "export PATH='\(path)'; which "
        let bazelPath = (
            ProcessInfo.processInfo.environment[INJECTION_BAZEL_PATH] ??
            Popen.system(export+"bazelisk") ??
            Popen.system(export+"bazel")
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bazelPath {
            resolvedBazelPath = bazelPath
            return bazelPath
        } else {
            throw BazelError.bazelNotFound
        }
    }
    
    /// Resolve xcrun executable path with multi-level fallback
    public func resolveXcrunExecutable() -> String? {
        // Level 1: Try standard xcrun location
        let standardPath = "/usr/bin/xcrun"
        if FileManager.default.fileExists(atPath: standardPath) {
            return standardPath
        }
        
        // Level 2: Check for injected environment variable
        if let injectedPath = getenv(INJECTION_XCRUN_PATH) {
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

    /// Resolve Xcode Developer directory with multi-level fallback
    /// This ensures consistent Xcode version usage across compilation and linking
    public func resolveXcodeDeveloperDir() -> String {
        // Level 1: Check DEVELOPER_DIR environment variable
        if let developerDir = getenv("DEVELOPER_DIR") {
            let pathString = String(cString: developerDir)
            if FileManager.default.fileExists(atPath: pathString) {
                return pathString
            }
        }

        // Level 2: Use xcode-select -p
        if let result = Popen(cmd: "xcode-select -p") {
            let output = result.readAll().trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty && !output.contains("not found") && !output.contains("error") {
                if FileManager.default.fileExists(atPath: output) {
                    return output
                }
            }
        }

        // Level 3: Fall back to default Xcode location
        return "/Applications/Xcode.app/Contents/Developer"
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

    /// Global kill-switch. When the user forces a non-Bazel build system
    /// (e.g. `Build: Xcode` override in Settings), all Bazel detection and
    /// parsing is skipped — `findWorkspaceRoot(containing:)` returns nil,
    /// so `Recompiler.findParser` falls through to the log/Xcode path.
    public static var isDisabled: Bool = false
    
    public init(workspaceRoot: String) throws {
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
        self.bazelExecutable = try BinaryResolver.shared.resolveBazelExecutable()
    }
    
    // MARK: - Workspace Detection
    
    public static func findWorkspaceRoot(containing path: String) -> String? {
        if isDisabled { return nil }
        let fm = FileManager.default
        // If we're handed the bundle itself (`Foo.xcodeproj` /
        // `Foo.xcworkspace`) start the walk at its parent so the
        // internal `project.xcworkspace` doesn't trip the bail-out below.
        var currentPath = path
        if currentPath.hasSuffix(".xcodeproj") || currentPath.hasSuffix(".xcworkspace") {
            currentPath = (currentPath as NSString).deletingLastPathComponent
        }
        // A file is only a Bazel target if it lives inside a Bazel package —
        // i.e. a BUILD/BUILD.bazel exists in an ancestor *strictly below* the
        // workspace root (BUILD at workspace root alone doesn't count: many
        // monorepos place a BUILD next to MODULE.bazel but keep unrelated
        // xcodeproj-based apps under their own subdirs).
        //
        // If we encounter an .xcodeproj / .xcworkspace on the way up *before*
        // finding any BUILD file AND without a BUILD co-located with it, the
        // file is owned by that Xcode project — bail out. A BUILD next to the
        // xcodeproj means it's a rules_xcodeproj-generated project, i.e. still
        // Bazel-built.
        var sawBuildFile = false

        while currentPath != "/" && !currentPath.isEmpty {
            let moduleFile = (currentPath as NSString).appendingPathComponent("MODULE.bazel")
            let modulePlainFile = (currentPath as NSString).appendingPathComponent("MODULE")
            let workspaceFile = (currentPath as NSString).appendingPathComponent("WORKSPACE")
            let workspaceBazelFile = (currentPath as NSString).appendingPathComponent("WORKSPACE.bazel")
            let atWorkspaceRoot =
                fm.fileExists(atPath: moduleFile) ||
                fm.fileExists(atPath: modulePlainFile) ||
                fm.fileExists(atPath: workspaceFile) ||
                fm.fileExists(atPath: workspaceBazelFile)

            if atWorkspaceRoot {
                // BUILD at the workspace root itself doesn't qualify — we
                // require evidence of a Bazel package *below* it.
                return sawBuildFile ? currentPath : nil
            }

            let entries = (try? fm.contentsOfDirectory(atPath: currentPath)) ?? []
            let hasBuildFile = entries.contains("BUILD") || entries.contains("BUILD.bazel")
            let hasXcodeProject = entries.contains(where: {
                $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace")
            })

            // Xcode project closer than the workspace root wins, UNLESS a
            // BUILD file is co-located (rules_xcodeproj-generated project).
            if hasXcodeProject && !hasBuildFile && !sawBuildFile {
                return nil
            }

            if hasBuildFile {
                sawBuildFile = true
            }

            currentPath = (currentPath as NSString).deletingLastPathComponent
        }

        return nil
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
