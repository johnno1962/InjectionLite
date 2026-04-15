//
//  BazelAQueryParser.swift
//  InjectionBazel
//
//  Bazel AQuery parser implementing LiteParser protocol for hot reloading
//

#if DEBUG || !SWIFT_PACKAGE
import Foundation
#if canImport(PopenD)
@_exported import PopenD
#else
@_exported import Popen
#endif

extension String {
    public var unescape: String {
        return self.replacingOccurrences(of: #"\\(.)"#, with: "$1",
                                         options: .regularExpression)
    }
}

public protocol LiteParser {
  func command(for source: String, platformFilter: String,
               found: inout (logDir: String, scanner: Popen?)?) -> String?
  func prepareFinalCommand(command: String, source: String, objectFile: String, tmpdir: String, injectionNumber: Int) -> String
}

#if os(macOS)
#if canImport(InjectionImpl)
import InjectionImpl
import DLKitD
#endif

public class BazelAQueryParser: LiteParser {
    private let workspaceRoot: String
    private let bazelInterface: BazelInterface
    private let actionQueryHandler: BazelActionQueryHandler
    
    // Cache for compilation commands using NSCache for thread-safety and memory management
    private static let commandCache = NSCache<NSString, NSString>()
    
    // App target detection for optimized queries
    private var detectedAppTarget: String?

    private lazy var developerDir = BinaryResolver.shared.resolveXcodeDeveloperDir()

    public init(workspaceRoot: String) throws {
        self.workspaceRoot = workspaceRoot
        
        // Initialize Bazel components
        self.bazelInterface = try BazelInterface(
            workspaceRoot: workspaceRoot
        )
        
        self.actionQueryHandler = try BazelActionQueryHandler(
            workspaceRoot: workspaceRoot
        )
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
        let fileName = URL(fileURLWithPath: source).lastPathComponent
        
        // One-time initialization logging on first use
        if detectedAppTarget == nil {
            log("🔍 Detected Bazel workspace at: \(workspaceRoot)")
        }
        
        // Ignore SPM Package.swift files - they can't be hot reloaded anyway
        if isSPMPackageManifest(source) {
            log("⏭️ Ignoring SPM Package.swift file: \(fileName)")
            return nil
        }
        
        // Check cache first - include app target in cache key for session-based caching
        let appTargetKey = detectedAppTarget ?? "no-target"
        let cacheKey = "\(source):\(platformFilter):\(appTargetKey)"
        if let cachedCommand = getCachedCommand(for: cacheKey) {
            return cachedCommand
        }
        
        // Use synchronous wrapper for async operations to conform to LiteParser protocol
        guard let rawCommand = findCompilationCommandSync(for: source, platformFilter: platformFilter) else {
            log("❌ No Bazel compilation command found for \(fileName)")
            return nil
        }
        
        // Apply frontend optimizations early (cacheable transformations)
        let optimizedCommand = applyFrontendOptimizations(to: rawCommand, primaryFile: source)
        
        // Cache the optimized result
        setCachedCommand(optimizedCommand, for: cacheKey)
        
        return optimizedCommand
    }
    
    /// Bazel output base, resolved lazily from the workspace `bazel-out` symlink.
    /// In Bazel 7+/Bzlmod the layout is:
    ///   <outputBase>/execroot/_main/bazel-out/...   (build artifacts)
    ///   <outputBase>/external/...                   (external repos)
    private lazy var bazelOutputBase: String = {
        let bazelOutLink = "\(workspaceRoot)/bazel-out"
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: bazelOutLink) {
            let url = URL(fileURLWithPath: resolved)
            return url.deletingLastPathComponent()
                       .deletingLastPathComponent()
                       .deletingLastPathComponent().path
        }
        return workspaceRoot
    }()

    private lazy var execRoot: String = {
        let bazelOutLink = "\(workspaceRoot)/bazel-out"
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: bazelOutLink) {
            let url = URL(fileURLWithPath: resolved)
            return url.deletingLastPathComponent().path
        }
        return workspaceRoot
    }()

    // MARK: - rules_xcodeproj Support

    /// Detects whether rules_xcodeproj is in use and resolves the alternative
    /// output base where Xcode-triggered builds actually place artifacts.
    private lazy var rulesXcodeprojExecRoot: String? = {
        let rxpOutputBase = bazelOutputBase + "/rules_xcodeproj.noindex/build_output_base"
        let rxpExecRoot = rxpOutputBase + "/execroot/_main"
        guard FileManager.default.fileExists(atPath: rxpExecRoot) else {
            return nil
        }
        log("📦 Detected rules_xcodeproj output base at: \(rxpOutputBase)")
        return rxpExecRoot
    }()

    private lazy var rulesXcodeprojOutputBase: String? = {
        guard rulesXcodeprojExecRoot != nil else { return nil }
        return bazelOutputBase + "/rules_xcodeproj.noindex/build_output_base"
    }()

    /// Cache of aquery config → rules_xcodeproj config directory mappings.
    /// e.g. "ios_sim_arm64-fastbuild-ST-abc123" → "ios_sim_arm64-dbg-ios-sim_arm64-min17.0-ST-xyz789"
    private var configMappingCache = [String: String]()

    /// Maps an aquery configuration directory name to the corresponding
    /// directory in the rules_xcodeproj output base.
    ///
    /// Config format: `<arch>-<mode>[-exec]-<suffix>-ST-<hash>`
    /// e.g. aquery target:  `ios_sim_arm64-fastbuild-ios-sim_arm64-min17.0-ST-538543d366db`
    ///      rxp target:     `ios_sim_arm64-dbg-ios-sim_arm64-min17.0-ST-37293c460a5a`
    ///      aquery exec:    `darwin_arm64-opt-exec-ST-d57f47055a04`
    ///      rxp exec:       `darwin_arm64-opt-exec-ST-d57f47055a04`  (often identical hash)
    private func resolveRxpConfig(for aqueryConfig: String) -> String? {
        if let cached = configMappingCache[aqueryConfig] {
            return cached
        }
        guard let rxpExecRoot = rulesXcodeprojExecRoot else { return nil }
        let rxpBazelOut = rxpExecRoot + "/bazel-out"

        guard let entries = try? FileManager.default
                .contentsOfDirectory(atPath: rxpBazelOut) else { return nil }

        // 1) Exact match (exec configs often share the same hash)
        if entries.contains(aqueryConfig) {
            log("🔗 Exact match for aquery config '\(aqueryConfig)' in rxp")
            configMappingCache[aqueryConfig] = aqueryConfig
            return aqueryConfig
        }

        let (archPrefix, modeQualifier) = extractArchAndMode(from: aqueryConfig)

        // 2) Match by arch + mode qualifier (e.g. darwin_arm64 + opt-exec)
        let candidates = entries
            .filter {
                let (entryArch, entryMode) = extractArchAndMode(from: $0)
                return entryArch == archPrefix && entryMode == modeQualifier
            }
            .sorted { $0 > $1 }

        if let match = candidates.first {
            log("🔗 Mapped aquery config '\(aqueryConfig)' → rxp config '\(match)' (mode: \(modeQualifier))")
            configMappingCache[aqueryConfig] = match
            return match
        }

        // 3) For target configs (fastbuild), fall back to dbg with same arch
        if modeQualifier == "fastbuild" {
            let dbgCandidates = entries
                .filter {
                    let (entryArch, entryMode) = extractArchAndMode(from: $0)
                    return entryArch == archPrefix && entryMode == "dbg"
                }
                .sorted { $0 > $1 }

            if let match = dbgCandidates.first {
                log("🔗 Mapped aquery config '\(aqueryConfig)' → rxp config '\(match)' (fastbuild→dbg)")
                configMappingCache[aqueryConfig] = match
                return match
            }
        }

        // 4) Last resort: any config with the same arch prefix
        let anyMatch = entries
            .filter { extractArchAndMode(from: $0).arch == archPrefix }
            .sorted { $0 > $1 }
            .first

        if let match = anyMatch {
            log("⚠️ Loose match for '\(aqueryConfig)' → rxp config '\(match)'")
            configMappingCache[aqueryConfig] = match
            return match
        }

        log("⚠️ No rules_xcodeproj config matching '\(aqueryConfig)' in \(rxpBazelOut)")
        return nil
    }

    /// Extracts the architecture prefix and mode qualifier from a Bazel config.
    /// e.g. `ios_sim_arm64-fastbuild-...` → (`ios_sim_arm64`, `fastbuild`)
    ///      `darwin_arm64-opt-exec-ST-...` → (`darwin_arm64`, `opt-exec`)
    ///      `darwin_arm64-dbg-ST-...` → (`darwin_arm64`, `dbg`)
    private func extractArchAndMode(from config: String) -> (arch: String, mode: String) {
        // Order matters: check compound modes first
        let modeTokens = ["-fastbuild-", "-opt-exec-", "-dbg-", "-opt-"]
        let modeNames  = ["fastbuild",   "opt-exec",   "dbg",   "opt"]
        for (token, mode) in zip(modeTokens, modeNames) {
            if let range = config.range(of: token) {
                return (String(config[config.startIndex..<range.lowerBound]), mode)
            }
        }
        return (config.components(separatedBy: "-").first ?? config, "unknown")
    }

    /// Distinct filesystem spellings of the main workspace execroot (`…/execroot/_main`),
    /// so absolute paths in aquery output match even with symlink / normalization drift.
    private func mainExecRootPathVariants() -> [String] {
        let outputBaseExec = bazelOutputBase + "/execroot/_main"
        var roots = Set<String>()
        roots.insert(execRoot)
        roots.insert(outputBaseExec)
        roots.insert((execRoot as NSString).standardizingPath)
        roots.insert((outputBaseExec as NSString).standardizingPath)
        roots.insert(URL(fileURLWithPath: execRoot).resolvingSymlinksInPath().path)
        roots.insert(URL(fileURLWithPath: outputBaseExec).resolvingSymlinksInPath().path)
        return roots.filter { !$0.isEmpty }
    }

    /// Rewrites all `bazel-out/<config>/` path segments in a command so they
    /// point to the rules_xcodeproj output base with the correct config hash.
    ///
    /// aquery lines use the default output base (`fastbuild`, etc.). Xcode-driven
    /// rules_xcodeproj builds use `…/rules_xcodeproj.noindex/build_output_base/`.
    /// When paths are **absolute** (`…/execroot/_main/bazel-out/<cfg>/…`), replacing
    /// only the `bazel-out/<cfg>/` fragment would splice the rxp execroot onto the
    /// main execroot and break module map resolution — so longer absolute prefixes
    /// are rewritten first, then relative `bazel-out/` segments.
    private func rewritePathsForRulesXcodeproj(_ command: String) -> String {
        guard let rxpExecRoot = rulesXcodeprojExecRoot else { return command }

        var result = command
        let pattern = #"bazel-out/([^/]+)/"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return command }

        let nsRange = NSRange(result.startIndex..., in: result)
        var configsSeen = Set<String>()
        for match in regex.matches(in: result, range: nsRange) {
            if let range = Range(match.range(at: 1), in: result) {
                configsSeen.insert(String(result[range]))
            }
        }

        for aqueryConfig in configsSeen {
            guard let rxpConfig = resolveRxpConfig(for: aqueryConfig) else { continue }
            let destination = "\(rxpExecRoot)/bazel-out/\(rxpConfig)/"

            // 1) Absolute: …/execroot/_main/bazel-out/<aquery>/  (several spellings)
            for execVariant in mainExecRootPathVariants() {
                let oldAbs = "\(execVariant)/bazel-out/\(aqueryConfig)/"
                result = result.replacingOccurrences(of: oldAbs, with: destination)
            }

            // 2) Relative to exec root (no directory prefix before bazel-out/)
            result = result.replacingOccurrences(
                of: "bazel-out/\(aqueryConfig)/",
                with: destination)
        }

        return result
    }

    public func prepareFinalCommand(command: String, source: String, objectFile: String, tmpdir: String, injectionNumber: Int) -> String {
        let effectiveRoot = rulesXcodeprojExecRoot ?? execRoot
        let cdPrefix = "cd '\(effectiveRoot)' && "

        // Strip any existing -o flag so we can set our own output path
        var cmd = command
        if let regex = try? NSRegularExpression(pattern: Reloader.compilerOutputFlagRegex, options: []) {
            let range = NSRange(cmd.startIndex..., in: cmd)
            cmd = regex.stringByReplacingMatches(in: cmd, options: [], range: range, withTemplate: "")
        }

        // Replace -emit-object with -c so -o controls output path
        cmd = cmd.replacingOccurrences(of: " -emit-object", with: " -c")

        // Check if this is a frontend command (already optimized)
        if cmd.contains("swiftc -frontend") {
            return cdPrefix + cmd + " -o \(objectFile)"
        }
        
        // For non-frontend commands, try output-file-map first
        let outputFileMapRegex = #" -output-file-map ([^\s\\]*(?:\\.[^\s\\]*)*)"#
        if let outputFileMapPath = (cmd[outputFileMapRegex] as String?)?.unescape {
            return createMinimalOutputFileMapCommand(command: cmd, source: source, objectFile: objectFile, outputFileMapPath: outputFileMapPath, tmpdir: tmpdir, injectionNumber: injectionNumber)
        } else {
            // Traditional -o flag fallback
            return cmd + " -o \(objectFile)"
        }
    }
    
    // MARK: - Frontend Optimization (Cacheable)
    
    /// Apply frontend optimizations that can be cached and reused
    /// This includes path normalization, frontend transformation, and command cleaning
    private func applyFrontendOptimizations(to command: String, primaryFile: String) -> String {
        // Step 1: Try to optimize with Swift frontend mode for single-file compilation
        let frontendCommand = transformToFrontendMode(command: command, primaryFile: primaryFile) ?? command
        
        // Step 2: Clean frontend command - remove -Xfrontend flags and output-file-map
        let cleanedFrontendCommand = cleanFrontendCommand(frontendCommand)
        
        return cleanedFrontendCommand
    }
    
    /// Clean frontend command by removing -Xfrontend flags and output-file-map
    /// Since we're already in frontend mode, -Xfrontend is redundant
    private func cleanFrontendCommand(_ command: String) -> String {
        var cleanedCommand = command
        
        // Remove -Xfrontend flags since we're already in frontend mode
        // Pattern: -Xfrontend <flag> -> <flag>
        let xfrontendPattern = #" -Xfrontend ([^-\s]\S*)"#
        if let regex = try? NSRegularExpression(pattern: xfrontendPattern, options: []) {
            let range = NSRange(cleanedCommand.startIndex..., in: cleanedCommand)
            cleanedCommand = regex.stringByReplacingMatches(in: cleanedCommand, options: [], range: range, withTemplate: " $1")
        }
        
        // Remove standalone -Xfrontend flags that might be left over
        cleanedCommand = cleanedCommand.replacingOccurrences(of: " -Xfrontend ", with: " ")

        // Remove output-file-map since frontend mode will use -o instead
        let outputFileMapRegex = #" -output-file-map ([^\s\\]*(?:\\.[^\s\\]*)*)"#
        if let regex = try? NSRegularExpression(pattern: outputFileMapRegex, options: []) {
            let range = NSRange(cleanedCommand.startIndex..., in: cleanedCommand)
            cleanedCommand = regex.stringByReplacingMatches(in: cleanedCommand, options: [], range: range, withTemplate: "")
        }

        // Remove existing -o flags so prepareFinalCommand can set the correct output path
        let existingOutputRegex = Reloader.compilerOutputFlagRegex
        if let regex = try? NSRegularExpression(pattern: existingOutputRegex, options: []) {
            let range = NSRange(cleanedCommand.startIndex..., in: cleanedCommand)
            cleanedCommand = regex.stringByReplacingMatches(in: cleanedCommand, options: [], range: range, withTemplate: "")
        }
        
        // Clean up extra whitespace
        cleanedCommand = cleanedCommand.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleanedCommand = cleanedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleanedCommand
    }

    // MARK: - Private Implementation
    
    private func findCompilationCommandSync(for sourcePath: String, platformFilter: String) -> String? {
        do {
            // Auto-discover app target on first use if not already cached
            if detectedAppTarget == nil {
                autoDiscoverAppTarget(for: sourcePath)
            }
            
            // Use the auto-discovery logic in findCompilationCommand
            // This will use cached app target if available, or auto-discover it
            let command = try actionQueryHandler.findCompilationCommand(for: sourcePath, appTarget: detectedAppTarget)
            
            // Update our cached app target if one was discovered
            if detectedAppTarget == nil, let cachedTarget = actionQueryHandler.currentAppTarget {
                detectedAppTarget = cachedTarget
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
        var cleanedCommand = command
        
        // Strip Bazel worker binary prefix: the aquery command starts with
        // something like "/path/to/worker swiftc ..." — the worker binary
        // uses a protobuf stdin protocol and can't be invoked directly.
        if let workerRange = cleanedCommand.range(of: #"[^\s]*worker\s+"#, options: .regularExpression) {
            cleanedCommand.removeSubrange(cleanedCommand.startIndex..<workerRange.upperBound)
        }
        
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
        
        // WMO prevents single-file recompilation — the compiler silently
        // skips -primary-file / -emit-object when WMO is active.
        let standaloneFlags = [
            "-whole-module-optimization",
            "-internalize-at-link",
            "-no-serialize-debugging-options",
        ]
        for flag in standaloneFlags {
            cleanedCommand = cleanedCommand.replacingOccurrences(
                of: flag, with: "")
        }
        
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
        
        // Strip -Xfrontend wrapper since we invoke swift-frontend directly.
        // The Bazel aquery command is already in frontend mode, so -Xfrontend
        // is redundant and causes "unknown argument" errors.
        while cleanedCommand.contains(" -Xfrontend ") {
            cleanedCommand = cleanedCommand.replacingOccurrences(of: " -Xfrontend ", with: " ")
        }
        
        // Strip the `cd "<execRoot>" &&` prefix that BazelActionQueryHandler
        // embeds — prepareFinalCommand will add the correct one.
        if let cdRange = cleanedCommand.range(
            of: #"^cd \"[^\"]+\" && "#, options: .regularExpression) {
            cleanedCommand.removeSubrange(cdRange)
        }

        // When rules_xcodeproj is in use, rewrite bazel-out/<config>/ paths
        // to the correct output base with the matching config hash FIRST,
        // before doing generic relative→absolute resolution.
        cleanedCommand = rewritePathsForRulesXcodeproj(cleanedCommand)

        // Choose the correct output base / execroot for external/ and bazel-out/
        // resolution. For rules_xcodeproj, artifacts live in a separate output base.
        let effectiveOutputBase = rulesXcodeprojOutputBase ?? bazelOutputBase
        let effectiveExecRoot = rulesXcodeprojExecRoot ?? execRoot

        // In Bazel 7+/Bzlmod, external repos live at <outputBase>/external/,
        // NOT at <execroot>/_main/external/. Replace relative external/ refs
        // with the absolute path so the compiler can find module maps and
        // headers for third-party dependencies.
        let absExternal = "\(effectiveOutputBase)/external/"
        cleanedCommand = cleanedCommand.replacingOccurrences(
            of: "=external/", with: "=\(absExternal)")
        cleanedCommand = cleanedCommand.replacingOccurrences(
            of: " external/", with: " \(absExternal)")
        cleanedCommand = cleanedCommand.replacingOccurrences(
            of: "'external/", with: "'\(absExternal)")

        // bazel-out/ relative paths must also be resolved to absolute.
        // After rewritePathsForRulesXcodeproj, any remaining bazel-out/ refs
        // are ones that didn't match a config (or rules_xcodeproj isn't in use).
        let absBazelOut = "\(effectiveExecRoot)/bazel-out/"
        cleanedCommand = cleanedCommand.replacingOccurrences(
            of: "=bazel-out/", with: "=\(absBazelOut)")
        cleanedCommand = cleanedCommand.replacingOccurrences(
            of: " bazel-out/", with: " \(absBazelOut)")
        cleanedCommand = cleanedCommand.replacingOccurrences(
            of: "'bazel-out/", with: "'\(absBazelOut)")

        // Flags that concatenate the path directly (no space before the relative path)
        for prefix in ["-F", "-I", "-iquote", "-isystem"] {
            cleanedCommand = cleanedCommand.replacingOccurrences(
                of: "\(prefix)external/", with: "\(prefix)\(absExternal)")
            cleanedCommand = cleanedCommand.replacingOccurrences(
                of: "\(prefix)bazel-out/", with: "\(prefix)\(absBazelOut)")
        }

        // Replace Bazel placeholders in the command with actual values
        let finalCommand = replaceBazelPlaceholders(in: cleanedCommand)
        
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
        
        return filteredCommand
    }
    
    /// Replace Bazel placeholders in the command with actual values
    private func replaceBazelPlaceholders(in command: String) -> String {
        var result = command
        
        // Replace __BAZEL_XCODE_SDKROOT__ with actual SDK path
        if result.contains("__BAZEL_XCODE_SDKROOT__") {
            // Get xcrun path with fallback logic
            if let xcrunPath = BinaryResolver.shared.resolveXcrunExecutable() {
                // Use xcrun to get the simulator SDK path (preferred for development)
                if let output = Popen.task(exec: xcrunPath, 
                                          arguments: ["--sdk", "iphonesimulator", "--show-sdk-path"],
                                          cd: workspaceRoot) {
                    let sdkPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sdkPath.isEmpty && !sdkPath.contains("error") {
                        result = result.replacingOccurrences(of: "__BAZEL_XCODE_SDKROOT__", with: sdkPath)
                    }
                }
            } else {
                log("⚠️ xcrun not available - cannot resolve __BAZEL_XCODE_SDKROOT__")
            }
        }
        
        // Replace __BAZEL_XCODE_DEVELOPER_DIR__ with actual developer directory
        if result.contains("__BAZEL_XCODE_DEVELOPER_DIR__") {
            result = result.replacingOccurrences(of: "__BAZEL_XCODE_DEVELOPER_DIR__", with: developerDir)
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
            var options: JSONSerialization.WritingOptions = [.prettyPrinted]
            if #available(macOS 15.0, iOS 13.0, *) {
                options.formUnion( [.sortedKeys, .withoutEscapingSlashes] )
            }
            let mapData = try JSONSerialization.data(withJSONObject: minimalMap, options: options)
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
    
    // MARK: - File Filtering
    
    /// Check if a file is an SPM Package.swift manifest that should be ignored
    private func isSPMPackageManifest(_ filePath: String) -> Bool {
        // Only check files named Package.swift
        guard filePath.hasSuffix("Package.swift") else {
            return false
        }
        
        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            
            // SPM Package.swift files must have both patterns
            return content.contains("let package = Package") && content.contains("import PackageDescription")
        } catch {
            // If we can't read the file, assume it's not an SPM manifest (don't block legitimate files)
            log("⚠️ Could not read Package.swift file to verify SPM manifest: \(error)")
            return false
        }
    }

    // MARK: - Cache Management
    
    private func getCachedCommand(for key: String) -> String? {
        return BazelAQueryParser.commandCache.object(forKey: key as NSString) as String?
    }
    
    private func setCachedCommand(_ command: String, for key: String) {
        BazelAQueryParser.commandCache.setObject(command as NSString, forKey: key as NSString)
    }
    
    // MARK: - Swift Frontend Optimization
    
    /// Extract Swift source files from a Bazel compilation command
    /// Returns tuple of (all swift files, swift files without the changed file)
    private func extractSwiftSourceFiles(from command: String, changedFile: String) -> (allFiles: [String], otherFiles: [String]) {
        var swiftFiles: [String] = []
        
        // Split command into components, handling quoted arguments
        let components = parseCommandComponents(command)
        
        let pathArgFlags: Set<String> = ["-F", "-I", "-iquote", "-isystem", "-Xcc"]
        var previousComponent = ""
        for component in components {
            let cleanPath = component.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let cleanPrev = previousComponent.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            if cleanPath.hasSuffix(".swift") && !cleanPath.hasPrefix("-")
                && !pathArgFlags.contains(cleanPrev) {
                swiftFiles.append(cleanPath)
            }
            previousComponent = component
        }
        
        // Filter out the changed file to create list of other files
        // Use multiple comparison strategies to ensure accurate filtering
        let otherFiles = swiftFiles.filter { file in
            // Strategy 1: Direct string comparison
            if file == changedFile {
                return false
            }
            
            // Strategy 2: Standardized path comparison
            let normalizedFile = URL(fileURLWithPath: file).standardized.path
            let normalizedChangedFile = URL(fileURLWithPath: changedFile).standardized.path
            if normalizedFile == normalizedChangedFile {
                return false
            }
            
            // Strategy 3: Last path component comparison (for different path formats)
            let fileComponent = URL(fileURLWithPath: file).lastPathComponent
            let changedComponent = URL(fileURLWithPath: changedFile).lastPathComponent
            if fileComponent == changedComponent && fileComponent.hasSuffix(".swift") {
                // Additional check: if both contain the same parent directory structure
                let fileParent = URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent
                let changedParent = URL(fileURLWithPath: changedFile).deletingLastPathComponent().lastPathComponent
                if fileParent == changedParent {
                    return false
                }
            }
            
            return true
        }
        
        return (allFiles: swiftFiles, otherFiles: otherFiles)
    }
    
    /// Parse command string into components, respecting quoted arguments
    private func parseCommandComponents(_ command: String) -> [String] {
        var components: [String] = []
        var currentComponent = ""
        var inQuotes = false
        var quoteChar: Character = "\""
        var i = command.startIndex
        
        while i < command.endIndex {
            let char = command[i]
            
            if !inQuotes {
                if char == "\"" || char == "'" {
                    inQuotes = true
                    quoteChar = char
                    currentComponent.append(char)
                } else if char.isWhitespace {
                    if !currentComponent.isEmpty {
                        components.append(currentComponent)
                        currentComponent = ""
                    }
                } else {
                    currentComponent.append(char)
                }
            } else {
                currentComponent.append(char)
                if char == quoteChar {
                    // Check if it's escaped
                    let prevIndex = command.index(before: i)
                    if prevIndex >= command.startIndex && command[prevIndex] != "\\" {
                        inQuotes = false
                    }
                }
            }
            
            i = command.index(after: i)
        }
        
        // Add the last component if not empty
        if !currentComponent.isEmpty {
            components.append(currentComponent)
        }
        
        return components
    }
    
    /// Transform Bazel command to use Swift frontend mode for single-file compilation
    /// Returns nil if transformation isn't beneficial or fails
    private func transformToFrontendMode(command: String, primaryFile: String) -> String? {
        // Check if command is already a Swift frontend command
        if command.contains("swiftc -frontend") || command.contains("swift-frontend") {
            log("⚡ Command is already in frontend mode, adjusting primary file")
            return adjustExistingFrontendCommand(command: command, newPrimaryFile: primaryFile)
        }
        
        let (allFiles, otherFiles) = extractSwiftSourceFiles(from: command, changedFile: primaryFile)
        
        // Validate that primary file is not in other files (double-check filtering)
        let primaryFileName = URL(fileURLWithPath: primaryFile).lastPathComponent
        let duplicateInOthers = otherFiles.filter { otherFile in
            let otherFileName = URL(fileURLWithPath: otherFile).lastPathComponent
            return otherFileName == primaryFileName
        }
        
        if !duplicateInOthers.isEmpty {
            log("⚠️ Found potential duplicates in other files, removing them:")
            for duplicate in duplicateInOthers {
                log("   - Removing: \(duplicate)")
            }
        }
        
        // Filter out any remaining duplicates based on filename
        let cleanOtherFiles = otherFiles.filter { otherFile in
            let otherFileName = URL(fileURLWithPath: otherFile).lastPathComponent
            return otherFileName != primaryFileName
        }
        
        var transformedCommand = command
        
        // Step 1: Replace 'swiftc' with 'swiftc -frontend'
        if let swiftcRange = transformedCommand.range(of: "swiftc") {
            transformedCommand.replaceSubrange(swiftcRange, with: "swiftc -frontend")
        }
        
        // Step 2: Remove all .swift files from the command
        for swiftFile in allFiles {
            let escaped = NSRegularExpression.escapedPattern(for: swiftFile)
            let doubleQuoted = NSRegularExpression.escapedPattern(for: "\"\(swiftFile)\"")
            let singleQuoted = NSRegularExpression.escapedPattern(for: "'\(swiftFile)'")
            let patterns = [
                "\\s+\(singleQuoted)(?=\\s|$)",
                "\\s+\(doubleQuoted)(?=\\s|$)",
                "\\s+\(escaped)(?=\\s|$)",
            ]
            
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let range = NSRange(transformedCommand.startIndex..., in: transformedCommand)
                    transformedCommand = regex.stringByReplacingMatches(in: transformedCommand, options: [], range: range, withTemplate: "")
                }
            }
        }
        
        // Step 3: Add -primary-file with the changed file
        let quotedPrimary = primaryFile.contains(" ") ? "'\(primaryFile)'" : primaryFile
        transformedCommand += " -primary-file \(quotedPrimary)"

        // Step 4: Add plugin paths for system macros

        let pluginServerPath = "\(developerDir)/Platforms/iPhoneOS.platform/Developer/usr/bin/swift-plugin-server"
        transformedCommand += """
         -external-plugin-path '\(developerDir)/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins#\(pluginServerPath)' \
        -external-plugin-path '\(developerDir)/Platforms/iPhoneOS.platform/Developer/usr/local/lib/swift/host/plugins#\(pluginServerPath)' \
        -in-process-plugin-server-path '\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/libSwiftInProcPluginServer.dylib' \
        -plugin-path '\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins' \
        -plugin-path '\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/local/lib/swift/host/plugins'
        """

        // Step 5: Add other Swift files as secondary sources (using cleaned list)
        for otherFile in cleanOtherFiles {
            let quoted = otherFile.contains(" ") ? "'\(otherFile)'" : otherFile
            transformedCommand += " \(quoted)"
        }
        
        return transformedCommand
    }
    
    /// Adjust existing frontend command to use the correct primary file
    /// This handles cases where Bazel already generates frontend commands but with different primary files
    private func adjustExistingFrontendCommand(command: String, newPrimaryFile: String) -> String? {
        log("🔄 Adjusting existing frontend command for primary file: \(URL(fileURLWithPath: newPrimaryFile).lastPathComponent)")
        
        var adjustedCommand = command
        
        // Find and replace existing -primary-file argument (handles unquoted, single-quoted, and double-quoted paths)
        let primaryFilePattern = Reloader.primaryFileFlagRegex
        if let regex = try? NSRegularExpression(pattern: primaryFilePattern, options: []) {
            let range = NSRange(adjustedCommand.startIndex..., in: adjustedCommand)
            let matches = regex.matches(in: adjustedCommand, options: [], range: range)
            
            if let match = matches.first, let matchRange = Range(match.range, in: adjustedCommand) {
                let oldPrimaryFile = String(adjustedCommand[matchRange])
                let quotedNew = newPrimaryFile.contains(" ") ? "'\(newPrimaryFile)'" : newPrimaryFile
                adjustedCommand = adjustedCommand.replacingOccurrences(of: oldPrimaryFile, with: " -primary-file \(quotedNew)")
                log("🔄 Replaced primary file in existing frontend command")
                log("   Old: \(oldPrimaryFile)")
                log("   New: -primary-file \(URL(fileURLWithPath: newPrimaryFile).lastPathComponent)")
            }
        } else {
            let quotedNew = newPrimaryFile.contains(" ") ? "'\(newPrimaryFile)'" : newPrimaryFile
            adjustedCommand += " -primary-file \(quotedNew)"
            log("➕ Added -primary-file to existing frontend command")
        }
        
        // Remove existing -o flag since prepareFinalCommand will add the correct one (handles quoted paths)
        let outputPattern = Reloader.compilerOutputFlagRegex
        if let regex = try? NSRegularExpression(pattern: outputPattern, options: []) {
            let range = NSRange(adjustedCommand.startIndex..., in: adjustedCommand)
            let matches = regex.matches(in: adjustedCommand, options: [], range: range)
            
            if let match = matches.first, let matchRange = Range(match.range, in: adjustedCommand) {
                let oldOutput = String(adjustedCommand[matchRange])
                adjustedCommand = adjustedCommand.replacingOccurrences(of: oldOutput, with: "")
                log("🗑️ Removed existing -o flag from frontend command: \(oldOutput)")
            }
        }
        
        // Clean up extra whitespace
        adjustedCommand = adjustedCommand.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        adjustedCommand = adjustedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return adjustedCommand
    }
    
    
}
#endif
#endif
