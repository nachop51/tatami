/// The one command vocabulary shared by the CLI and binds.
public enum Command: Equatable, Sendable {
    case focus(Direction)
    case move(Direction)
    case desk(Int)
    case deskLast
    case send(Int)
    case splitToggle
    case layoutToggle
    case floatToggle
    case fullscreenToggle
    case exec(String)
    case reload

    public static let deskNumbers = 1...10

    /// Parses e.g. "focus left", "desk 3", "desk last", "exec open -a Ghostty". Nil if not a command.
    public init?(_ text: String) {
        let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let verb = parts.first else { return nil }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        let arg = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let number = Int(arg).flatMap { Command.deskNumbers.contains($0) ? $0 : nil }

        switch (verb, arg) {
        case ("focus", _): guard let d = Direction(rawValue: arg) else { return nil }; self = .focus(d)
        case ("move", _): guard let d = Direction(rawValue: arg) else { return nil }; self = .move(d)
        case ("desk", "last"): self = .deskLast
        case ("desk", _): guard let number else { return nil }; self = .desk(number)
        case ("send", _): guard let number else { return nil }; self = .send(number)
        case ("split", "toggle"): self = .splitToggle
        case ("layout", "toggle"): self = .layoutToggle
        case ("float", "toggle"): self = .floatToggle
        case ("fullscreen", "toggle"): self = .fullscreenToggle
        case ("exec", _): guard !arg.isEmpty else { return nil }; self = .exec(rest)
        case ("reload", ""): self = .reload
        default: return nil
        }
    }
}
