import AppKit
import PraatvolCore
import ServiceManagement

final class SettingsWindow: NSObject {
    private var window: NSWindow?
    private let apiKey = NSSecureTextField()
    private let model = NSComboBox()
    private let microphone = NSPopUpButton()
    private let lossless = NSButton(
        checkboxWithTitle: "Send lossless (FLAC; WAV if FLAC is unavailable)", target: nil, action: nil)
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private var devices: [MicrophoneDevice] = []

    func show() {
        do {
            devices = try AudioDevices.microphones()
            apiKey.stringValue = try Keychain.read()
            let preferences = Preferences.read()
            model.removeAllItems()
            // The inspected public models API exposes audio chat inputs, not transcription models.
            // An editable field avoids incorrectly treating audio chat models as STT models.
            model.addItems(withObjectValues: ["elevenlabs/scribe-v2"])
            model.isEditable = true
            model.stringValue = preferences.model
            microphone.removeAllItems()
            microphone.addItem(withTitle: "System default")
            for device in devices { microphone.addItem(withTitle: device.name) }
            let selected = devices.firstIndex { $0.uniqueIdentifier == preferences.microphoneIdentifier }
            microphone.selectItem(at: selected.map { $0 + 1 } ?? 0)
            lossless.state = preferences.lossless ? .on : .off
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval: launchAtLogin.state = .on
            default: launchAtLogin.state = .off
            }
            if window == nil { createWindow() }
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            AppLog.shared.event("settings-load-failed", code: (error as NSError).code)
            showAlert(error.localizedDescription)
        }
    }

    private func createWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 365),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(AppIdentity.name) Settings"
        window.isReleasedWhenClosed = false
        window.center()
        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        let note = NSTextField(
            wrappingLabelWithString:
                "The key stays in Keychain. The model field accepts a transcription model identifier. The public models API does not reliably list transcription models. Launch at login requires an installed app. Settings affect the next item."
        )
        let stack = NSStackView(views: [
            row("OpenRouter API key", apiKey), row("Model", model),
            row("Microphone", microphone), lossless, launchAtLogin, note, save,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            ])
        }
        self.window = window
    }

    private func row(_ title: String, _ field: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let stack = NSStackView(views: [label, field])
        stack.orientation = .horizontal
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return stack
    }

    @objc private func saveSettings() {
        do {
            let modelIdentifier = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelIdentifier.isEmpty else { throw PraatvolError("Enter a transcription model identifier.") }
            let service = SMAppService.mainApp
            if launchAtLogin.state == .on {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                // Unregister throws EPERM for .notFound (e.g. an app outside /Applications), so only undo a real registration.
                try service.unregister()
            }
            try Keychain.save(apiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            let defaults = UserDefaults.standard
            defaults.set(modelIdentifier, forKey: "model")
            let selected = microphone.indexOfSelectedItem
            defaults.set(selected > 0 ? devices[selected - 1].uniqueIdentifier : "", forKey: "microphone")
            defaults.set(lossless.state == .on, forKey: "lossless")
            apiKey.stringValue = ""
            window?.close()
            if service.status == .requiresApproval {
                showAlert("Approve \(AppIdentity.name) in System Settings > General > Login Items.")
            }
        } catch {
            AppLog.shared.event("settings-save-failed", code: (error as NSError).code)
            showAlert(error.localizedDescription)
        }
    }
}
