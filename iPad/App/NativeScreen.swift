import SwiftUI
import UIKit

struct NativeScreen: UIViewRepresentable {
    let image: UIImage?
    let enabled: Bool
    let send: ([String: Any]) -> Void
    func makeUIView(context: Context) -> ScreenInputView { ScreenInputView() }
    func updateUIView(_ view: ScreenInputView, context: Context) {
        view.picture.image = image
        view.send = send; view.controlEnabled = enabled
    }
}

final class ScreenInputView: UIView {
    let picture = UIImageView()
    var send: (([String: Any]) -> Void)?
    var controlEnabled = false
    private var lastMove = Date.distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        picture.contentMode = .scaleAspectFit
        picture.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        picture.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
        picture.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picture)
        NSLayoutConstraint.activate([picture.leadingAnchor.constraint(equalTo: leadingAnchor), picture.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     picture.topAnchor.constraint(equalTo: topAnchor), picture.bottomAnchor.constraint(equalTo: bottomAnchor)])
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        scroll.minimumNumberOfTouches = 2; scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all
        tap.require(toFail: drag)
        addGestureRecognizer(tap); addGestureRecognizer(drag); addGestureRecognizer(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func position(_ point: CGPoint) -> [String: Any]? {
        guard controlEnabled, let image = picture.image, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        let origin = CGPoint(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2)
        return ["x": max(0, min(1, (point.x - origin.x) / width)), "y": max(0, min(1, (point.y - origin.y) / height))]
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard var body = position(gesture.location(in: self)) else { return }
        body["action"] = "click"; send?(body)
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard var body = position(gesture.location(in: self)) else { return }
        switch gesture.state {
        case .began:
            let point = gesture.location(in: self), translation = gesture.translation(in: self)
            guard let origin = position(CGPoint(x: point.x - translation.x, y: point.y - translation.y)) else { return }
            body = origin; body["action"] = "down"
        case .changed:
            guard Date().timeIntervalSince(lastMove) > 1.0 / 30 else { return }
            lastMove = Date(); body["action"] = "move"
        case .ended: body["action"] = "up"
        case .cancelled, .failed: body = ["action": "release"]
        default: return
        }
        send?(body)
    }
    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        guard controlEnabled, gesture.state == .changed else { return }
        let y = gesture.translation(in: self).y
        gesture.setTranslation(.zero, in: self)
        send?(["action": "scroll", "delta": max(-1000, min(1000, Int(y)))])
    }
}

struct RemoteKeyboard: UIViewRepresentable {
    let send: ([String: Any]) -> Void

    func makeUIView(context: Context) -> RemoteKeyField {
        let field = RemoteKeyField()
        field.placeholder = "Ketik di Mac"
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.delegate = field
        field.accessibilityIdentifier = "remote-keyboard-input"
        return field
    }

    func updateUIView(_ field: RemoteKeyField, context: Context) { field.send = send }

    static func dismantleUIView(_ field: RemoteKeyField, coordinator: ()) {
        field.send = nil
        field.resignFirstResponder()
    }
}

final class RemoteKeyField: UITextField, UITextFieldDelegate {
    var send: (([String: Any]) -> Void)?
    override var hasText: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.send != nil else { return }
            self.becomeFirstResponder()
        }
    }

    override func insertText(_ text: String) { forward(text) }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString text: String) -> Bool {
        if text.isEmpty { deleteBackward() }
        else { forward(text) }
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        forward("\n")
        return false
    }

    private func forward(_ text: String) {
        if text == "\n" { send?(["action": "key", "code": "Enter"]); return }
        // Keep paste chunks within the host's UTF-16 input limit.
        var chunk = ""
        for character in text {
            if chunk.utf16.count + String(character).utf16.count > 256 {
                if !chunk.isEmpty { send?(["action": "text", "text": chunk]) }
                chunk = ""
            }
            if String(character).utf16.count <= 256 { chunk.append(character) }
        }
        if !chunk.isEmpty { send?(["action": "text", "text": chunk]) }
    }
    override func deleteBackward() { send?(["action": "key", "code": "Backspace"]) }
    override var keyCommands: [UIKeyCommand]? {
        let keys = [(UIKeyCommand.inputLeftArrow, "ArrowLeft"), (UIKeyCommand.inputRightArrow, "ArrowRight"),
                    (UIKeyCommand.inputUpArrow, "ArrowUp"), (UIKeyCommand.inputDownArrow, "ArrowDown"),
                    (UIKeyCommand.inputEscape, "Escape"), ("\t", "Tab")]
        let commands = keys.map { UIKeyCommand(title: $0.1, action: #selector(specialKey(_:)), input: $0.0) }
            + [UIKeyCommand(title: "Salin di Mac", action: #selector(copyMac), input: "c", modifierFlags: .command),
               UIKeyCommand(title: "Tempel di Mac", action: #selector(pasteMac), input: "v", modifierFlags: .command)]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }
    @objc private func specialKey(_ command: UIKeyCommand) { send?(["action": "key", "code": command.title]) }
    @objc private func copyMac() { send?(["action": "key", "code": "KeyC", "command": true]) }
    @objc private func pasteMac() { send?(["action": "key", "code": "KeyV", "command": true]) }
}
