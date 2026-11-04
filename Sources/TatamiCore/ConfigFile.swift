import Foundation

/// `~/.config/tatami/config`: one `key = value` per line, `#` comment lines.
/// The built-in defaults always apply first; the user's file only says what differs.
public struct ConfigFile: Equatable, Sendable {
    public struct Bind: Equatable, Sendable {
        public var keys: String
        public var command: Command
        public var line: Int
    }

    public enum RuleAction: Equatable, Sendable { case desk(Int), float }

    public struct Rule: Equatable, Sendable {
        public var app: String  // app name or bundle id
        public var action: RuleAction
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public init(line: Int, message: String) { self.line = line; self.message = message }
        public var description: String { "line \(line): \(message)" }
    }

    public var layout = Config()
    public var borderWidth = 4.0
    public var borderActive: UInt32 = 0xff2d_78ff  // RGBA
    public var borderInactive: UInt32 = 0x4145_50ff
    public var focusFollowsMouse = true
    public var pins: [Int: Int] = [:]
    public var layouts: [Int: LayoutKind] = [:]
    public var binds: [Bind] = []
    public var rules: [Rule] = []

    /// What applies before, and without, the user's config file. `tatami defaults` prints it.
    public static let builtin = try! ConfigFile(parsing: builtinText)

    /// The built-in defaults with the user's file applied on top.
    public static func user(_ text: String) throws -> ConfigFile {
        var file = builtin
        try file.apply(text)
        return file
    }

    public init() {}
    public static let builtinText: String = {
        var lines = ["gap.inner = 8", "gap.outer = 8", "border.width = 4", "border.active = #ff2d78",
                     "border.inactive = #414550", "focus.follows_mouse = true", "",
                     "bind alt+tab = desk last", "bind alt+f = fullscreen toggle", "bind alt+t = float toggle",
                     "bind alt+e = split toggle", "bind alt+comma = layout toggle"]
        for (key, dir) in [("h", "left"), ("j", "down"), ("k", "up"), ("l", "right")] {
            lines += ["bind alt+\(key) = focus \(dir)", "bind alt+shift+\(key) = move \(dir)"]
        }
        for n in Command.deskNumbers {
            lines += ["bind alt+\(n % 10) = desk \(n)", "bind alt+cmd+\(n % 10) = send \(n)"]
        }
        // It resizes, but never wider than about 740 px: tiled, it would be found out and floated a moment later.
        lines += ["", "rule com.apple.systempreferences = float"]
        return lines.joined(separator: "\n")
    }()

    public init(parsing text: String) throws { try apply(text) }

    /// Applies config text on top of what is already set. A `bind` replaces an earlier bind of the same keys;
    /// `unbind <keys>` removes one.
    public mutating func apply(_ text: String) throws {
        func same(_ a: String, _ b: String) -> Bool { Set(a.lowercased().split(separator: "+")) == Set(b.lowercased().split(separator: "+")) }
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            func fail(_ message: String) -> ParseError { ParseError(line: i + 1, message: message) }
            if line.hasPrefix("unbind ") {
                let keys = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                guard binds.contains(where: { same($0.keys, keys) }) else { throw fail("nothing is bound to `\(keys)`") }
                binds.removeAll { same($0.keys, keys) }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { throw fail("expected `key = value`") }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            func number() throws -> Double {
                guard let n = Double(value), n >= 0 else { throw fail("expected a number, got `\(value)`") }
                return n
            }
            func colour() throws -> UInt32 {
                let hex = value.dropFirst()
                guard value.hasPrefix("#"), hex.count == 6 || hex.count == 8, let n = UInt32(hex, radix: 16) else {
                    throw fail("expected a colour like #ff2d78, got `\(value)`")
                }
                return hex.count == 6 ? n << 8 | 0xff : n
            }

            switch key {
            case "gap.inner": layout.gapInner = try number()
            case "gap.outer": layout.gapOuter = try number()
            case "border.width": borderWidth = try number()
            case "border.active": borderActive = try colour()
            case "border.inactive": borderInactive = try colour()
            case "focus.follows_mouse":
                guard let b = Bool(value) else { throw fail("expected true or false, got `\(value)`") }
                focusFollowsMouse = b
            default:
                let parts = key.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                let subject = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                switch parts.first {
                case "pin":
                    // One Desk or several: `pin 2 = monitor 2`, `pin 1,3,5 = monitor 1`.
                    let target = value.split(whereSeparator: \.isWhitespace)
                    let desks = subject.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                    guard !desks.isEmpty, desks.allSatisfy({ $0.map(Command.deskNumbers.contains) == true }), target.count == 2,
                          target[0] == "monitor", let monitor = Int(target[1]), monitor >= 1
                    else { throw fail("expected `pin <desks 1-10, comma separated> = monitor <number>`") }
                    for desk in desks { pins[desk!] = monitor }
                case "bind":
                    guard !subject.isEmpty else { throw fail("expected `bind <keys> = <command>`") }
                    guard let command = Command(value) else { throw fail("unknown command `\(value)`") }
                    binds.removeAll { same($0.keys, subject) }
                    binds.append(Bind(keys: subject, command: command, line: i + 1))
                case "layout":
                    let desks = subject.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                    guard !desks.isEmpty, desks.allSatisfy({ $0.map(Command.deskNumbers.contains) == true }),
                          let kind = LayoutKind(rawValue: value)
                    else { throw fail("expected `layout <desks 1-10, comma separated> = dwindle | accordion`") }
                    for desk in desks { layouts[desk!] = kind }
                case "rule":
                    let app = subject.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    guard !app.isEmpty else { throw fail("expected `rule <app> = <desk N | float>`") }
                    if value == "float" {
                        rules.append(Rule(app: app, action: .float))
                    } else if case .desk(let n)? = Command(value) {
                        rules.append(Rule(app: app, action: .desk(n)))
                    } else {
                        throw fail("a rule's action is `desk <1-10>` or `float`, got `\(value)`")
                    }
                default:
                    throw fail("unknown key `\(key)`")
                }
            }
        }
    }
}
