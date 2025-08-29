# InjectionLite

A cut down, standalone, Swift Package "reference" version of
the [InjectionIII](https://github.com/johnno1962/InjectionIII)
application for use in the simulator or un-sandboxed macOS.
Since Xcode 16.3, Xcode no longer logs compilation commands 
by default so the build setting EMIT_FRONTEND_COMMAND_LINES
with a value of YES is required in your project.

Add this package to your project and add "Other Linker Flags" 
-Xlinker -interposable (on separate lines) to the `Debug` build 
settings of all targets of your project. 

![Icon](https://github.com/johnno1962/InjectionIII/blob/main/interposable.png)

When you launch your app and save a source file (somewhere in 
your home directory), this package attempts to find how to 
recompile the file from the most recent build log, creates 
a dynamic library and loads it, then "swizzles" the new function 
implementations into the app without having to restart it.

It should be functionally equivalent to using the InjectionIII.app
in the simulator but it's rather new and there may be problems 
to iron out. If you encounter one, please file an issue. Consult 
the [InjectionIII](https://github.com/johnno1962/InjectionIII)
README for more details on how it can be used to inject an iOS 
app or SwiftUI interfaces and how it works its magic.

For the sake of simplicity, this version of injection is
missing the "Unhiding" functionality from InjectionIII
sometimes required to be able to inject Swift code 
that uses default function arguments.

## Bazel Support

This version includes enhanced Bazel build system support with automatic target discovery and optimized compilation queries. When InjectionLite detects a Bazel workspace (via `MODULE.bazel` or `WORKSPACE` files), it automatically:

1. **Auto-discovers iOS application targets** from your Bazel build graph, prioritizing targets closer to the workspace root
2. **Generates optimized aquery commands** that only query dependencies of your app targets, reducing overhead
3. **Handles Bazel-specific placeholders** like `__BAZEL_XCODE_SDKROOT__` and `__BAZEL_XCODE_DEVELOPER_DIR__`
4. **Processes output-file-map configurations** for better compatibility with Bazel's compilation strategy
5. **Automatically overrides whole-module-optimization** settings that interfere with hot reloading

The system uses a two-tier approach: first attempting optimized queries using discovered app targets, then falling back to legacy broad queries if needed. This ensures compatibility while providing performance benefits for typical iOS development workflows.

Bazel integration requires either `bazel` or `/opt/homebrew/bin/bazelisk` to be available in your system PATH.

### ⚠️ rules_xcodeproj Limitation

**Important**: Currently, Bazel queries and commands cannot be executed from within the rules_xcodeproj-generated Xcode project environment. This means:

- If you run your app from Xcode using a rules_xcodeproj-generated project and modify a file, **hot reloading will not work** because the app runs through a different execution route that doesn't provide access to Bazel tooling
- **Workaround**: Run your app directly from the terminal using `bazel run` instead of launching from Xcode to enable hot reloading functionality
- This limitation only affects rules_xcodeproj workflows - standard Bazel development workflows are fully supported

We're working on addressing this limitation in future releases.
