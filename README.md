# InjectionLite

A cut down, standalone, Swift Package version of the
[InjectionIII](https://github.com/johnno1962/InjectionIII)
application for use in the simulator or unsandboxed macOS.
This version will only recompile and inject Swift source files.

Simply add this package to your project and when you save a
source file (somewhere in your home directory), this package
attempts to find how to recompile the file from the most
recent build log, creates a dynamic library and loads it,
then "swizzles" the new function implementations into the 
app without having to restart it.

It should be fuctionally equivalent to using the app but 
it's rather new and there are likely to be some problems
to iron out. If you encounter one, please file an issue.
Consult the [InjectionIII](https://github.com/johnno1962/InjectionIII)
README for more details on how it can be used to inject
an iOS app or even SwiftUI.
