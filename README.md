# InjectionLite

A cut down, standalone, Swift Package version of the
[InjectionIII](https://github.com/johnno1962/InjectionIII)
application for use in the simulator or unsandboxed macOS.

Simply add this package to your project and add "Other
Linker Flags" -Xlinker -interposable to the build settings of 
the targets of your project. When you launch your app and save a
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
an iOS app or even SwiftUI and how it works its magic.

For the sake of simplicy this version of injection is 
missing two functionalities of the InjectionIII app:
"Unhiding" which exposes symbols of "default argument
generators" so they can be referenced when they are
injected and the handling of `-filelist` arguments used
when a target has more than 128 Swift source files.
