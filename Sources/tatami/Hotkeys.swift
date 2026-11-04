import Carbon.HIToolbox

private var onPress: ((Int) -> Void)?

/// Global hotkeys through the public Carbon API.
enum Hotkeys {
    private static var registered: [EventHotKeyRef] = []
    private static var installed = false
    /// Letters and digits as the current keyboard layout places them; refreshed on every `register`.
    private static var layout: [String: Int] = [:]

    /// "alt+shift+h" → key code and modifier mask. Nil if any part is unknown.
    static func parse(_ keys: String) -> (code: UInt32, modifiers: UInt32)? {
        var modifiers = 0, code: Int?
        for part in keys.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            switch part {
            case "alt", "opt", "option": modifiers |= optionKey
            case "shift": modifiers |= shiftKey
            case "ctrl", "control": modifiers |= controlKey
            case "cmd", "super": modifiers |= cmdKey
            default:
                guard code == nil, let c = layout[String(part)] ?? keyCodes[String(part)] else { return nil }
                code = c
            }
        }
        return code.map { (UInt32($0), UInt32(modifiers)) }
    }

    /// Replaces every hotkey. `press` gets the index into `keys`. Returns the combinations macOS refused.
    static func register(_ keys: [String], press: @escaping (Int) -> Void) -> [String] {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                onPress?(Int(id.id))
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        layout = layoutCodes()
        registered.forEach { UnregisterEventHotKey($0) }
        registered = []
        onPress = press
        var refused: [String] = []
        for (i, combo) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x7461_746d /* "tatm" */, id: UInt32(i))
            if let (code, modifiers) = parse(combo),
               RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                registered.append(ref)
            } else {
                refused.append(combo)
            }
        }
        return refused
    }

    /// Which key types each letter and digit on the current layout, so "alt+z" is the key labelled Z on
    /// AZERTY or Dvorak too. Punctuation stays physical: on many layouts it needs shift and would never fire.
    /// A layout without a letter (Cyrillic) is swapped for its ASCII-capable pair; missing digits (AZERTY's
    /// shifted top row) fall back to `keyCodes`.
    private static func layoutCodes() -> [String: Int] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var map: [String: Int] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for code in 0..<65 {  // below the keypad, whose digits would shadow AZERTY's missing ones
                var dead: UInt32 = 0, length = 0, chars = [UniChar](repeating: 0, count: 4)
                guard UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                     OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &length, &chars) == noErr,
                      length == 1, let c = Character(UnicodeScalar(chars[0]) ?? " ").lowercased().first,
                      c.isASCII, c.isLetter || c.isNumber, map[String(c)] == nil else { continue }
                map[String(c)] = code
            }
        }
        return map
    }

    /// Physical US positions: named keys, punctuation, and the fallback for anything the layout lacks.
    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "enter": kVK_Return, "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "escape": kVK_Escape,
        "backspace": kVK_Delete, "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period,
        "slash": kVK_ANSI_Slash, "backslash": kVK_ANSI_Backslash, "semicolon": kVK_ANSI_Semicolon,
        "quote": kVK_ANSI_Quote, "grave": kVK_ANSI_Grave, "leftbracket": kVK_ANSI_LeftBracket,
        "rightbracket": kVK_ANSI_RightBracket,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]
}
