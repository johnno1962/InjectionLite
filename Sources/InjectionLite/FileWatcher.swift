//
//  FileWatcher.swift
//  InjectionIII
//
//  Created by John Holdsworth on 08/03/2015.
//  Copyright (c) 2015 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/FileWatcher.swift#39 $
//
//  Started out as an abstraction to watch files under a directory.
//  "Enhanced" to extract the last modified build log directory by
//  backdating the event stream to just before the app launched.
//  This class is "showing its age".
//
#if DEBUG || !SWIFT_PACKAGE
import Foundation

public class FileWatcher: NSObject {
    public typealias InjectionCallback = (_ filesChanged: [String]) -> Void
    static var INJECTABLE_PATTERN = try! NSRegularExpression(
        pattern: "[^~]\\.(mm?|cpp|swift|storyboard|xib)$")

    static let logsPref = "HotReloadingBuildLogsDir"
    static var derivedLog =
        UserDefaults.standard.string(forKey: logsPref) {
        didSet {
            UserDefaults.standard.set(derivedLog, forKey: logsPref)
        }
    }

    var initStream: ((FSEventStreamEventId) -> Void)!
    var eventsStart =
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    #if SWIFT_PACKAGE
    var eventsToBackdate: UInt64 = 10_000
    #else
    var eventsToBackdate: UInt64 = 50_000
    #endif

    var fileEvents: FSEventStreamRef! = nil
    var callback: InjectionCallback
    var context = FSEventStreamContext()

    @objc public init(roots: [String], callback: @escaping InjectionCallback,
                      runLoop: CFRunLoop? = nil) {
        self.callback = callback
        super.init()
        #if os(macOS)
        context.info = unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
        #else
        guard let FSEventStreamCreate = FSEventStreamCreate else {
            fatalError("Could not locate FSEventStreamCreate")
        }
        #endif
        initStream = { [weak self] since in
            guard let self = self else { return }
            let fileEvents = FSEventStreamCreate(kCFAllocatorDefault,
             { (streamRef: FSEventStreamRef,
                clientCallBackInfo: UnsafeMutableRawPointer?,
                numEvents: Int, eventPaths: UnsafeMutableRawPointer,
                eventFlags: UnsafePointer<FSEventStreamEventFlags>,
                eventIds: UnsafePointer<FSEventStreamEventId>) in
                 #if os(macOS)
                 let watcher = unsafeBitCast(clientCallBackInfo, to: FileWatcher.self)
                 #else
                 guard let watcher = watchers[streamRef] else { return }
                 #endif
                 // Check that the event flags include an item renamed flag, this helps avoid
                 // unnecessary injection, such as triggering injection when switching between
                 // files in Xcode.
                 for i in 0 ..< numEvents {
                     let flag = Int(eventFlags[i])
                     if (flag & (kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)) != 0 {
                        let changes = unsafeBitCast(eventPaths, to: NSArray.self)
                         if CFRunLoopGetCurrent() != CFRunLoopGetMain() {
                             return watcher.filesChanged(changes: changes)
                         }
                         DispatchQueue.main.async {
                             watcher.filesChanged(changes: changes)
                         }
                         return
                     }
                 }
             },
             &self.context, roots as CFArray, since, 0.1,
             FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents))!
        #if !os(macOS)
        watchers[fileEvents] = self
        #endif
        FSEventStreamScheduleWithRunLoop(fileEvents, runLoop ?? CFRunLoopGetMain(),
                                         "kCFRunLoopDefaultMode" as CFString)
        _ = FSEventStreamStart(fileEvents)
        self.fileEvents = fileEvents
        }
        initStream(eventsStart)
    }

    func restart() {
        eventsStart = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        FSEventStreamStop(fileEvents)
        initStream(eventsStart)
    }

    func filesChanged(changes: NSArray) {
        #if !INJECTION_III_APP
        let eventId = FSEventStreamGetLatestEventId(fileEvents)
        if eventId != kFSEventStreamEventIdSinceNow &&
            eventsStart == kFSEventStreamEventIdSinceNow {
            eventsStart = eventId
            FSEventStreamStop(fileEvents)
            initStream(max(0, eventsStart-eventsToBackdate))
            return
        }
        #endif

        var changed = Set<String>()
        for path in changes {
            guard let path = path as? String else { continue }
            #if !INJECTION_III_APP
            if path.hasSuffix(".xcactivitylog") &&
                path.contains("/Logs/Build/") {
                Self.derivedLog = path
            }
            if eventId <= eventsStart { continue }
            #endif

            if Self.INJECTABLE_PATTERN.firstMatch(in: path, range:
                        NSMakeRange(0, path.utf16.count)) != nil  &&
                path.range(of: "DerivedData/|InjectionProject/|.DocumentRevisions-|@__swiftmacro_|main.mm?$",
                            options: .regularExpression) == nil &&
                FileManager.default.fileExists(atPath: path as String) {
                changed.insert(path)
            }
        }

        if changed.count != 0 {
            callback(Array(changed))
        }
    }

    #if os(macOS)
    deinit {
        FSEventStreamStop(fileEvents)
        FSEventStreamInvalidate(fileEvents)
        FSEventStreamRelease(fileEvents)
    }
    #endif
}

let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
#if !os(macOS) // Yes, this api is available inside the simulator...
typealias FSEventStreamRef = OpaquePointer
typealias ConstFSEventStreamRef = OpaquePointer
struct FSEventStreamContext {
    var version: CFIndex = 0
    var info: UnsafeRawPointer?
    var retain: UnsafeRawPointer?
    var release: UnsafeRawPointer?
    var copyDescription: UnsafeRawPointer?
}
typealias FSEventStreamCreateFlags = UInt32
typealias FSEventStreamEventId = UInt64
typealias FSEventStreamEventFlags = UInt32

typealias FSEventStreamCallback = @convention(c) (ConstFSEventStreamRef, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer, UnsafePointer<FSEventStreamEventFlags>, UnsafePointer<FSEventStreamEventId>) -> Void

#if true // avoid linker flags -undefined dynamic_lookup
let FSEventStreamCreate = unsafeBitCast(dlsym(RTLD_DEFAULT, "FSEventStreamCreate"), to: (@convention(c) (_ allocator: CFAllocator?, _ callback: FSEventStreamCallback, _ context: UnsafeMutableRawPointer?, _ pathsToWatch: CFArray, _ sinceWhen: FSEventStreamEventId, _ latency: CFTimeInterval, _ flags: FSEventStreamCreateFlags) -> FSEventStreamRef?)?.self)
let FSEventStreamScheduleWithRunLoop = unsafeBitCast(dlsym(RTLD_DEFAULT, "FSEventStreamScheduleWithRunLoop"), to: (@convention(c) (_ streamRef: FSEventStreamRef, _ runLoop: CFRunLoop, _ runLoopMode: CFString) -> Void).self)
let FSEventStreamStart = unsafeBitCast(dlsym(RTLD_DEFAULT, "FSEventStreamStart"), to: (@convention(c) (_ streamRef: FSEventStreamRef) -> Bool).self)
let FSEventStreamGetLatestEventId = unsafeBitCast(dlsym(RTLD_DEFAULT, "FSEventStreamGetLatestEventId"), to: (@convention(c) (_ streamRef: FSEventStreamRef) -> FSEventStreamEventId).self)
let FSEventStreamStop = unsafeBitCast(dlsym(RTLD_DEFAULT, "FSEventStreamStop"), to: (@convention(c) (_ streamRef: FSEventStreamRef) -> Void).self)
#else
@_silgen_name("FSEventStreamCreate")
func FSEventStreamCreate(_ allocator: CFAllocator?, _ callback: FSEventStreamCallback, _ context: UnsafeMutablePointer<FSEventStreamContext>?, _ pathsToWatch: CFArray, _ sinceWhen: FSEventStreamEventId, _ latency: CFTimeInterval, _ flags: FSEventStreamCreateFlags) -> FSEventStreamRef?
@_silgen_name("FSEventStreamScheduleWithRunLoop")
func FSEventStreamScheduleWithRunLoop(_ streamRef: FSEventStreamRef, _ runLoop: CFRunLoop, _ runLoopMode: CFString)
@_silgen_name("FSEventStreamStart")
func FSEventStreamStart(_ streamRef: FSEventStreamRef) -> Bool
#endif

let kFSEventStreamEventIdSinceNow: UInt64 = 18446744073709551615
let kFSEventStreamCreateFlagUseCFTypes: FSEventStreamCreateFlags = 1
let kFSEventStreamCreateFlagFileEvents: FSEventStreamCreateFlags = 16
let kFSEventStreamEventFlagItemRenamed = 0x00000800
let kFSEventStreamEventFlagItemModified = 0x00001000
fileprivate var watchers = [FSEventStreamRef: FileWatcher]()
#endif
#endif
