import AppKit
import ApplicationServices
import TatamiCore

let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    print("""
    usage: tatami start | stop | reload | state
           tatami run                 (like start, but stays in the foreground)
           tatami defaults            (print the built-in config your own file overrides)
           tatami focus|move <left|right|up|down>
           tatami desk <1-10|last> | send <1-10>
           tatami split|layout|float|fullscreen toggle
           tatami exec <shell command>
    """)
    exit(64)
}

if arguments == ["defaults"] {
    print(ConfigFile.builtinText)
    exit(0)
}

let running = CFMessagePortCreateRemote(nil, portName)

if arguments == ["start"] || arguments == ["run"] {
    if running != nil { log("already running"); exit(1) }
    if !NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty {
        log("AeroSpace is running; quit it first")
        exit(1)
    }
    guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
        log("not trusted for Accessibility: grant it in System Settings, then start again")
        exit(2)
    }
    do {
        if arguments == ["run"] { try Daemon().run() }
        _ = try Daemon.loadConfig()  // report a broken config here, not in the log
    } catch {
        log("config: \(error)")
        exit(1)
    }
    // start: run in the background, logging to a file.
    let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/tatami.log")
    if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
    let child = Process()
    child.executableURL = Bundle.main.executableURL
    child.arguments = ["run"]
    child.standardInput = FileHandle.nullDevice
    let logFile = try? FileHandle(forWritingTo: logURL)
    _ = try? logFile?.seekToEnd()  // append: earlier runs explain later surprises
    child.standardOutput = logFile
    child.standardError = child.standardOutput
    do { try child.run() } catch { log("could not start: \(error.localizedDescription)"); exit(1) }
    for _ in 0..<50 where child.isRunning {
        if CFMessagePortCreateRemote(nil, portName) != nil { exit(0) }
        usleep(100_000)
    }
    log("did not start; see \(logURL.path)")
    exit(1)
}

guard let running else { log("not running (tatami start)"); exit(1) }
var reply: Unmanaged<CFData>?
let request = Data(arguments.joined(separator: " ").utf8) as CFData
guard CFMessagePortSendRequest(running, 0, request, 2, 5, CFRunLoopMode.defaultMode.rawValue, &reply) == kCFMessagePortSuccess,
      let data = reply?.takeRetainedValue() as Data?, let text = String(data: data, encoding: .utf8)
else { log("no answer from tatami"); exit(1) }
guard text.hasPrefix("ok") else { log(text); exit(1) }
if text.count > 3 { print(text.dropFirst(3)) }
