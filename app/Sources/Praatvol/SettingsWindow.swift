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
    private let askBeforeTranscribing = NSButton(
        checkboxWithTitle: "Ask before transcribing", target: nil, action: nil)
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let loginExplanation = NSTextField(labelWithString: "")
    var notifyLoginStatus: (String) -> Void = { _ in }
    private let controlSocket = NSButton(
        checkboxWithTitle: "Enable control socket (lets the Touch Bar and praatvolctl control this app)", target: nil,
        action: nil)
    private var devices: [MicrophoneDevice] = []
    var saved: () -> Void = {}

    func show() {
        do {
            devices = try AudioDevices.microphones()
            apiKey.stringValue = try KeyStore.read()
            let preferences = Preferences.read()
            model.removeAllItems()
            // The inspected public models API exposes audio chat inputs, not transcription models.
            // An editable field avoids incorrectly treating audio chat models as STT models.
            model.addItems(withObjectValues: ["elevenlabs/scribe-v2"])
            model.isEditable = true
            model.stringValue = preferences.model
            microphone.removeAllItems()
            microphone.addItem(withTitle: "Automatic (Bluetooth first)")
            for device in devices { microphone.addItem(withTitle: device.name) }
            let selected = devices.firstIndex { $0.uniqueIdentifier == preferences.microphoneIdentifier }
            microphone.selectItem(at: selected.map { $0 + 1 } ?? 0)
            lossless.state = preferences.lossless ? .on : .off
            askBeforeTranscribing.state = preferences.askBeforeTranscribing ? .on : .off
            controlSocket.state = preferences.controlSocketEnabled ? .on : .off
            refreshLoginState()
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(AppIdentity.name) Settings"
        window.isReleasedWhenClosed = false
        window.center()
        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        let note = NSTextField(
            wrappingLabelWithString:
                "The key is stored in a private file in the app's Application Support folder. The model field accepts a transcription model identifier. The public models API does not reliably list transcription models. Settings affect the next item. Turning off the control socket stops praatvolctl and Touch Bar control."
        )
        let stack = NSStackView(views: [
            row("OpenRouter API key", apiKey), row("Model", model),
            row("Microphone for calls", microphone),
            NSTextField(
                wrappingLabelWithString:
                    "Calls prefer Bluetooth headsets unless you choose a microphone. Room always uses the built-in microphone, or a wired input if unavailable."
            ),
            lossless, askBeforeTranscribing, launchAtLogin, loginExplanation, controlSocket, note, save,
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

    private func refreshLoginState() {
        let state = LoginItems.state()
        launchAtLogin.state = state == .enabled ? .on : .off
        launchAtLogin.isEnabled = LoginItems.isInstalled
        switch state {
        case .notInstalled:
            loginExplanation.stringValue = "Move praatvol to Applications to launch at login."
        case .needsApproval:
            loginExplanation.stringValue = "Approve praatvol in System Settings > General > Login Items."
        case .failed(let message): loginExplanation.stringValue = message
        default: loginExplanation.stringValue = ""
        }
    }

    private func saveLoginSetting() {
        guard LoginItems.isInstalled else {
            refreshLoginState()
            return
        }
        let requested = launchAtLogin.state == .on
        UserDefaults.standard.set(requested, forKey: "launchAtLoginRequested")
        let service = SMAppService.mainApp
        var errorMessage: String?
        do {
            if requested {
                if service.status != .enabled { try service.register() }
            } else if [.enabled, .requiresApproval].contains(service.status) {
                // Unregister throws EPERM for .notFound (e.g. an app outside /Applications), so only undo a real registration.
                try service.unregister()
            }
        } catch {
            AppLog.shared.event("login-item-update-failed", code: (error as NSError).code)
            errorMessage = error.localizedDescription
        }
        let state = LoginItems.state(errorMessage: errorMessage)
        switch state {
        case .needsApproval:
            notifyLoginStatus("Approve praatvol in System Settings > General > Login Items.")
        case .failed(let message):
            AppLog.shared.event("login-item-unavailable")
            notifyLoginStatus(message)
        case .disabled where requested:
            AppLog.shared.event("login-item-registration-not-enabled")
            notifyLoginStatus("Launch at login was not enabled. Check System Settings > General > Login Items.")
        default: break
        }
        refreshLoginState()
    }

    @objc private func saveSettings() {
        do {
            let modelIdentifier = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelIdentifier.isEmpty else { throw PraatvolError("Enter a transcription model identifier.") }
            try KeyStore.save(apiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            let defaults = UserDefaults.standard
            defaults.set(modelIdentifier, forKey: "model")
            let selected = microphone.indexOfSelectedItem
            defaults.set(selected > 0 ? devices[selected - 1].uniqueIdentifier : "", forKey: "microphone")
            defaults.set(lossless.state == .on, forKey: "lossless")
            defaults.set(askBeforeTranscribing.state == .on, forKey: "askBeforeTranscribing")
            defaults.set(controlSocket.state == .on, forKey: "controlSocketEnabled")
            saveLoginSetting()
            apiKey.stringValue = ""
            window?.close()
            saved()
        } catch {
            AppLog.shared.event("settings-save-failed", code: (error as NSError).code)
            showAlert(error.localizedDescription)
        }
    }
}
