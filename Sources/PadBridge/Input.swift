import AppKit
import ApplicationServices

struct RemoteInput: Decodable {
    let action: String
    var x: Double?
    var y: Double?
    var delta: Int?
    var text: String?
    var code: String?
    var command: Bool?
    var control: Bool?
    var option: Bool?
    var shift: Bool?

    static let keyCodes: [String: CGKeyCode] = [
        "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5,
        "KeyZ": 6, "KeyX": 7, "KeyC": 8, "KeyV": 9, "KeyB": 11, "KeyQ": 12,
        "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16, "KeyT": 17,
        "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit6": 22,
        "Digit5": 23, "Equal": 24, "Digit9": 25, "Digit7": 26, "Minus": 27,
        "Digit8": 28, "Digit0": 29, "BracketRight": 30, "KeyO": 31, "KeyU": 32,
        "BracketLeft": 33, "KeyI": 34, "KeyP": 35, "Enter": 36, "KeyL": 37,
        "KeyJ": 38, "Quote": 39, "KeyK": 40, "Semicolon": 41, "Backslash": 42,
        "Comma": 43, "Slash": 44, "KeyN": 45, "KeyM": 46, "Period": 47,
        "Tab": 48, "Space": 49, "Backquote": 50, "Backspace": 51, "Escape": 53,
        "Home": 115, "PageUp": 116, "Delete": 117, "End": 119, "PageDown": 121,
        "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126
    ]

    var valid: Bool {
        switch action {
        case "down", "up", "move", "click", "rightClick":
            return [x, y].allSatisfy { value in
                guard let value else { return false }
                return value.isFinite && (0...1).contains(value)
            }
        case "scroll": return delta.map { (-1000...1000).contains($0) } ?? false
        case "text": return text.map { !$0.isEmpty && $0.utf16.count <= 256 } ?? false
        case "key": return code.flatMap { Self.keyCodes[$0] } != nil
        case "release": return true
        default: return false
        }
    }
}

final class InputController {
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var dragging = false
    private var position = CGPoint.zero
    private var releaseTimer: Timer?
    private var lastClick = Date.distantPast
    private var lastClickPosition = CGPoint.zero
    private var clickCount: Int64 = 1

    func release() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        if dragging { postMouse(.leftMouseUp, position, .left) }
        dragging = false
    }

    func send(_ input: RemoteInput) -> Bool {
        guard AXIsProcessTrusted(), input.valid else { return false }
        if input.action == "release" { release(); return true }
        if let x = input.x, let y = input.y {
            let bounds = CGDisplayBounds(displayID)
            guard !bounds.isEmpty else { release(); return false }
            position = CGPoint(x: bounds.minX + x * max(0, bounds.width - 1),
                               y: bounds.minY + y * max(0, bounds.height - 1))
        }
        switch input.action {
        case "down":
            release()
            postMouse(.leftMouseDown, position, .left)
            dragging = true
        case "up": release()
        case "move": postMouse(dragging ? .leftMouseDragged : .mouseMoved, position, .left)
        case "click", "rightClick":
            release()
            let right = input.action == "rightClick"
            postMouse(right ? .rightMouseDown : .leftMouseDown, position, right ? .right : .left)
            postMouse(right ? .rightMouseUp : .leftMouseUp, position, right ? .right : .left)
        case "scroll":
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                    wheel1: Int32(input.delta!), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        case "text":
            let units = Array(input.text!.utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                units.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!) }
                event?.post(tap: .cghidEventTap)
            }
        case "key":
            var flags: CGEventFlags = []
            if input.command == true { flags.insert(.maskCommand) }
            if input.control == true { flags.insert(.maskControl) }
            if input.option == true { flags.insert(.maskAlternate) }
            if input.shift == true { flags.insert(.maskShift) }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: RemoteInput.keyCodes[input.code!]!, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
        default: return false
        }
        if dragging {
            // shortcut: release an idle drag after 3 seconds; add a heartbeat for longer stationary drags.
            releaseTimer?.invalidate()
            releaseTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.release() }
        }
        return true
    }

    private func postMouse(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton) {
        if type == .leftMouseDown {
            let now = Date()
            clickCount = now.timeIntervalSince(lastClick) <= NSEvent.doubleClickInterval
                && hypot(point.x - lastClickPosition.x, point.y - lastClickPosition.y) < 4 ? min(clickCount + 1, 3) : 1
            lastClick = now
            lastClickPosition = point
        }
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event?.post(tap: .cghidEventTap)
    }
}
