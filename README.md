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

For the sake of simplicity, this version of injection
is missing the "Unhiding" functionality from InjectionIII
sometimes required to be able to inject Swift code 
that uses default function arguments.
