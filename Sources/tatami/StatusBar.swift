import AppKit

/// Menu bar item showing each Monitor's Active Desk, left to right: "1 | 4". The focused one is bold.
final class StatusBar: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let run: (String) -> Void

    /// `run` executes a tatami command line ("reload", "stop").
    init(run: @escaping (String) -> Void) {
        self.run = run
        super.init()
        let menu = NSMenu()
        for (title, action) in [("Reload config", #selector(reload)), ("Stop tatami", #selector(stop))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        item.menu = menu
    }

    func show(desks: [Int], focused: Int) {
        let title = NSMutableAttributedString()
        for (i, desk) in desks.enumerated() {
            if i > 0 {
                title.append(NSAttributedString(string: " | ", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            }
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: desk == focused ? .bold : .regular)
            title.append(NSAttributedString(string: String(desk), attributes: [.font: font]))
        }
        item.button?.attributedTitle = title
    }

    @objc private func reload() { run("reload") }
    @objc private func stop() { run("stop") }
}
