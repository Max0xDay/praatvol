import AVFoundation
import AppKit
import PraatvolCore

private enum AppState {
    case idle, starting, recording, stopping, transcribing
    var canStop: Bool {
        switch self {
        case .starting, .recording: return true
        default: return false
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var state: AppState = .idle
    private let settings = SettingsWindow()
    private let notifications = Notifications()
    private let captureQueue = DispatchQueue(label: "praatvol.capture")
    private let libraryQueue = DispatchQueue(label: "praatvol.library", qos: .utility)
    private var recorder: Recorder?
    private var recordingDate: Date?
    private var recordingPreferences = Preferences.read()
    private var timer: Timer?
    private var job: Task<Void, Never>?
    private var authorizedTermination = false
    private let viewModel = JobViewModel()
    private var mainWindow: MainWindow!
    private var startIdentifier: UUID?
    private var startWatchdog: DispatchWorkItem?
    private var stepDate = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        notifications.configure()
        mainWindow = MainWindow(model: viewModel)
        viewModel.stop = { [weak self] in self?.stopRecording() }
        viewModel.retry = { [weak self] item in self?.retry(item) }
        viewModel.open = { [weak self] file in self?.openFile(file) }
        viewModel.recordCall = { [weak self] in self?.recordCall() }
        viewModel.recordRoom = { [weak self] in self?.recordRoom() }
        viewModel.transcribeFile = { [weak self] in self?.transcribeFile() }
        viewModel.openSettings = { [weak self] in self?.openSettings() }
        viewModel.openLibraryFolder = { [weak self] in self?.openTranscripts() }
        viewModel.rename = { [weak self] item, name in self?.rename(item, to: name) }
        viewModel.trash = { [weak self] item in self?.trash(item) }
        reloadLibrary()
        refreshMenu()
        AppLog.shared.event("app-launched")
    }

    // An accessory app has no main menu, so Cmd+X/C/V/A need an Edit menu to reach text fields.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func refreshMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: menuStatus(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add("Record call (mic + system audio)", action: #selector(recordCall), to: menu, enabled: state == .idle)
        add("Record room (mic only)", action: #selector(recordRoom), to: menu, enabled: state == .idle)
        if state.canStop {
            add(
                state == .starting ? "Stop / Cancel setup" : "Stop recording", action: #selector(stopRecording),
                to: menu)
        }
        menu.addItem(.separator())
        add("Transcribe file…", action: #selector(transcribeFile), to: menu, enabled: state == .idle)
        add("Open praatvol…", action: #selector(openMainWindow), to: menu)
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        for item in viewModel.library.filter({ $0.status == .transcribed }).prefix(5) {
            let entry = NSMenuItem(
                title:
                    "\(ItemPresentation.title(of: item.metadata)) · \(item.metadata.date.formatted(date: .abbreviated, time: .omitted))",
                action: #selector(openRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.transcript
            recentMenu.addItem(entry)
        }
        recent.submenu = recentMenu
        menu.addItem(recent)
        add("Open transcripts in Finder", action: #selector(openTranscripts), to: menu)
        add("Settings…", action: #selector(openSettings), to: menu)
        menu.addItem(.separator())
        add("Quit", action: #selector(quit), to: menu)
        statusItem.menu = menu
        refreshStatus()
    }

    private func menuStatus() -> String {
        if state == .recording {
            let microphone = viewModel.microphoneLevel.hasSignal ? "●" : "○"
            let system = viewModel.isCall ? " · system \(viewModel.systemLevel.hasSignal ? "●" : "○")" : ""
            return "Recording \(Transcript.timestamp(viewModel.elapsedSeconds)) · mic \(microphone)\(system)"
        }
        if viewModel.state.step == .uploading { return "Uploading \(Int(viewModel.fraction * 100))%" }
        return state == .idle ? "Idle" : viewModel.state.step.rawValue + "…"
    }

    private func refreshStatus() {
        statusItem.button?.image = sineImage()
        statusItem.button?.imagePosition = .imageLeading
        // The icon carries the state; text appears only where a number helps: the timer and the upload percentage.
        switch state {
        case .recording:
            statusItem.button?.title = " " + Transcript.timestamp(Date().timeIntervalSince(recordingDate ?? Date()))
        case .transcribing where viewModel.state.step == .uploading:
            statusItem.button?.title = " \(Int(viewModel.fraction * 100))%"
        default: statusItem.button?.title = ""
        }
        statusItem.button?.toolTip = "\(AppIdentity.name): \(menuStatus())"
        statusItem.menu?.items.first?.title = menuStatus()
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.autoenablesItems = false
        menu.addItem(item)
    }

    private func sineImage() -> NSImage {
        let recording = state == .recording
        let transcribing = state == .transcribing
        let image = NSImage(size: NSSize(width: AppIdentity.isDevelopment ? 30 : 23, height: 18), flipped: false) { _ in
            (recording ? NSColor.systemRed : NSColor.black).setStroke()
            let path = NSBezierPath()
            path.lineWidth = transcribing ? 3 : 2
            path.lineCapStyle = .round
            for index in 0...80 {
                let fraction = Double(index) / 80
                let point = NSPoint(x: 2 + 18 * fraction, y: 9 + 5 * sin(2 * .pi * fraction))
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.stroke()
            if recording {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 18, y: 13, width: 4, height: 4)).fill()
            }
            if AppIdentity.isDevelopment {
                ("D" as NSString).draw(
                    at: NSPoint(x: 23, y: 3),
                    withAttributes: [
                        .font: NSFont.boldSystemFont(ofSize: 9),
                        .foregroundColor: recording ? NSColor.systemRed : NSColor.black,
                    ])
            }
            return true
        }
        image.isTemplate = !recording
        return image
    }

    @objc private func recordCall() { beginRecording(call: true) }
    @objc private func recordRoom() { beginRecording(call: false) }

    private func beginRecording(call: Bool) {
        guard state == .idle else { return }
        state = .starting
        viewModel.reset(title: call ? "Call" : "Room", call: call, recording: true)
        viewModel.advance(.starting)
        recordingPreferences = Preferences.read()
        let identifier = viewModel.identifier
        startIdentifier = identifier
        let recorder = Recorder()
        self.recorder = recorder
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.startIdentifier == identifier else { return }
            self.cancelSetup(
                message: "Capture setup exceeded 8 seconds. Check Microphone permission"
                    + (call ? " and Screen & System Audio Recording permission" : "")
                    + " in System Settings > Privacy & Security. Approve the prompt, then retry.")
        }
        startWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: watchdog)
        mainWindow.show(activate: false)
        refreshMenu()
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            DispatchQueue.main.async {
                guard self.startIdentifier == identifier else { return }
                guard allowed else {
                    AppLog.shared.event("microphone-permission-denied")
                    self.cancelSetup(message: Recorder.microphoneHelp)
                    return
                }
                self.startCapture(call: call, recorder: recorder, identifier: identifier)
            }
        }
    }

    private func startCapture(call: Bool, recorder: Recorder, identifier: UUID) {
        let preferences = recordingPreferences
        captureQueue.async {
            do {
                try recorder.start(call: call, preferences: preferences)
                DispatchQueue.main.async {
                    guard self.startIdentifier == identifier else {
                        recorder.cancelStart()
                        self.captureQueue.async {
                            _ = recorder.stop()
                            if let folder = recorder.folder {
                                self.saveFailure(folder: folder, message: "Capture setup was cancelled.")
                            }
                            DispatchQueue.main.async {
                                self.reloadLibrary()
                                if self.viewModel.identifier == identifier { self.viewModel.folder = recorder.folder }
                            }
                        }
                        return
                    }
                    self.startWatchdog?.cancel()
                    self.startIdentifier = nil
                    self.state = .recording
                    self.viewModel.advance(.recording)
                    self.viewModel.folder = recorder.folder
                    self.recordingDate = Date()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                        self?.tick()
                    }
                    self.refreshMenu()
                }
            } catch {
                AppLog.shared.event("capture-start-failed", code: (error as NSError).code)
                if let folder = recorder.folder {
                    self.saveFailure(folder: folder, message: error.localizedDescription)
                }
                DispatchQueue.main.async {
                    self.reloadLibrary()
                    guard self.startIdentifier == identifier else {
                        if self.viewModel.identifier == identifier { self.viewModel.folder = recorder.folder }
                        return
                    }
                    self.viewModel.folder = recorder.folder
                    self.cancelSetup(
                        message: error.localizedDescription + "\n"
                            + (call ? Recorder.systemHelp : Recorder.microphoneHelp))
                }
            }
        }
    }

    private func cancelSetup(message: String) {
        startWatchdog?.cancel()
        startIdentifier = nil
        recorder?.cancelStart()
        // #COMPLETION_DRIVE: Apple provides no cancellation API for a blocked AVAudioEngine.start or Core Audio call.
        // #SUGGEST_VERIFY: Confirm cleanup after prompt dismissal; relaunch if the operating-system call never returns.
        // Cleanup runs on the capture queue after the blocked call returns, never concurrently with setup.
        state = .idle
        viewModel.advance(.failed)
        viewModel.message = message
        refreshMenu()
        AppLog.shared.event("capture-setup-cancelled")
    }

    private func tick() {
        if let recorder, state == .recording {
            let meters = recorder.meters()
            viewModel.microphoneLevel = meters.microphone.0
            viewModel.microphoneSilenceSeconds = meters.microphone.1
            viewModel.systemLevel = meters.system?.0 ?? .silence
            viewModel.systemSilenceSeconds = meters.system?.1 ?? Date().timeIntervalSince(recordingDate ?? Date())
            viewModel.elapsedSeconds = Date().timeIntervalSince(recordingDate ?? Date())
            if let folder = viewModel.folder { updateDiskSize(folder) }
        }
        refreshStatus()
        guard state == .recording, let recordingDate else { return }
        if Date().timeIntervalSince(recordingDate) > 5 {
            if recorder?.microphoneProblem() == true {
                AppLog.shared.event("microphone-stalled")
                stopRecording()
                showAlert(Recorder.microphoneHelp)
            }
        }
    }

    @objc private func stopRecording() {
        if state == .starting {
            cancelSetup(message: "Capture setup was cancelled. No paid request was sent.")
            return
        }
        finishCapture(quitAfterSave: false)
    }

    private func finishCapture(quitAfterSave: Bool) {
        guard state == .recording, let recorder else { return }
        timer?.invalidate()
        timer = nil
        state = .stopping
        viewModel.advance(.preparing)
        refreshMenu()
        let preferences = recordingPreferences
        captureQueue.async {
            let capture = recorder.stop()
            DispatchQueue.main.async {
                guard let capture else {
                    self.state = .idle
                    self.viewModel.advance(.failed)
                    self.viewModel.message = "The recorder saved no track. Check capture permissions."
                    self.refreshMenu()
                    if quitAfterSave { self.terminate() }
                    return
                }
                if quitAfterSave {
                    self.saveBeforeQuit(capture)
                } else {
                    self.process(capture: capture, file: nil, preferences: preferences)
                }
            }
        }
    }

    private func saveBeforeQuit(_ capture: CapturedItem) {
        let report = reporter()
        job = Task { @MainActor in
            do {
                _ = try await Task.detached { try TranscriptionJob.prepare(capture: capture, report: report) }.value
            } catch {
                AppLog.shared.event("quit-archive-failed", code: (error as NSError).code)
                showAlert("The raw audio stays saved in \(capture.folder.path).\n\n\(error.localizedDescription)")
            }
            terminate()
        }
    }

    @objc private func transcribeFile() {
        guard state == .idle else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file that AVFoundation can read."
        if panel.runModal() == .OK, let file = panel.url {
            mainWindow.show(activate: true)
            process(capture: nil, file: file, preferences: Preferences.read())
        }
    }

    private func process(
        capture: CapturedItem?, file: URL?, preferences: Preferences, retryItem: PraatvolCore.LibraryItem? = nil
    ) {
        state = .transcribing
        if let file { viewModel.reset(title: "File: \(file.lastPathComponent)") }
        if let retryItem { viewModel.reset(title: retryItem.metadata.kind) }
        viewModel.advance(.preparing)
        refreshMenu()
        let report = reporter()
        job = Task { @MainActor in
            var folder = capture?.folder ?? retryItem?.folder
            do {
                if let file {
                    let date = Date()
                    let created = try Storage.createFolder(
                        root: AppIdentity.root, date: date, kind: "File: \(file.lastPathComponent)")
                    folder = created
                    try Library.save(
                        ItemMetadata(
                            date: date, kind: "File: \(file.lastPathComponent)", sources: file.lastPathComponent),
                        folder: created)
                }
                guard let itemFolder = folder else { throw PraatvolError("No source audio exists.") }
                viewModel.folder = itemFolder
                if let retryItem {
                    var metadata = retryItem.metadata
                    metadata.status = .notTranscribed
                    metadata.errorMessage = nil
                    try Library.save(metadata, folder: itemFolder)
                }
                let prepared = try await Task.detached {
                    if let capture { return try TranscriptionJob.prepare(capture: capture, report: report) }
                    if let retryItem { return try TranscriptionJob.prepareRetry(item: retryItem, report: report) }
                    guard let file else { throw PraatvolError("No source audio exists.") }
                    return try TranscriptionJob.prepare(file: file, folder: itemFolder, report: report)
                }.value
                viewModel.durationSeconds = prepared.durationSeconds
                guard approveUpload(prepared) else {
                    viewModel.advance(.idle)
                    viewModel.message = "The audio stays saved. Choose Transcribe again for a paid request."
                    finishJob()
                    return
                }
                let key = try Keychain.read()
                let completion = try await Task.detached {
                    try await TranscriptionJob.transcribe(
                        item: prepared, preferences: preferences, apiKey: key, report: report)
                }.value
                if viewModel.state.step == .uploading { viewModel.advance(.transcribing) }
                viewModel.advance(.saved)
                viewModel.summary = completion.metadata
                viewModel.message =
                    completion.hasSpeakerLabels ? "The transcript is ready." : "The transcript has no speaker labels."
                notifications.post(title: "Transcript ready", message: viewModel.message, file: completion.transcript)
            } catch {
                AppLog.shared.event("transcription-failed", code: (error as NSError).code)
                if let folder { saveFailure(folder: folder, message: error.localizedDescription) }
                viewModel.advance(.failed)
                viewModel.message = error.localizedDescription
                notifications.post(
                    title: "Transcription failed",
                    message: error.localizedDescription + "\nThe audio stays saved. No paid request was retried.",
                    file: folder, failure: true)
            }
            finishJob()
        }
    }

    private func approveUpload(_ item: PreparedItem) -> Bool {
        var warnings = item.warnings
        if UploadRules.isBeyondTestedLength(item.durationSeconds) {
            warnings.append(
                "Beyond tested length; may time out; recording saved locally. The AAC duration rule follows Opus trials, not AAC trials."
            )
        }
        if warnings.isEmpty { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Review the saved audio"
        alert.informativeText = warnings.joined(separator: "\n\n")
        alert.addButton(withTitle: "Transcribe")
        alert.addButton(withTitle: "Keep audio only")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func finishJob() {
        state = .idle
        job = nil
        recorder = nil
        timer?.invalidate()
        timer = nil
        let finished = viewModel.state.step
        let folder = viewModel.folder
        reloadLibrary { [weak self] in
            // Hand the finished job over to its library item, so the sidebar's "Now" row disappears.
            guard let self, finished == .saved || finished == .failed, let folder,
                self.viewModel.state.step == finished, self.viewModel.folder == folder,
                self.viewModel.library.contains(where: { $0.folder == folder })
            else { return }
            self.viewModel.advance(.idle)
            self.viewModel.selection = folder.path
        }
        refreshMenu()
    }

    private func acceptsProgress(_ identifier: UUID) -> Bool {
        guard viewModel.identifier == identifier else { return false }
        switch state {
        case .transcribing, .stopping: return true
        default: return false
        }
    }

    private func reporter() -> JobReporter {
        let identifier = viewModel.identifier
        return { [weak self] update in
            DispatchQueue.main.async {
                guard let self, self.acceptsProgress(identifier) else { return }
                if update.step == .transcribing, self.viewModel.state.step != .transcribing {
                    self.stepDate = Date()
                    self.timer?.invalidate()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        guard let self else { return }
                        self.viewModel.elapsedSeconds = Date().timeIntervalSince(self.stepDate)
                    }
                }
                self.viewModel.advance(update.step)
                self.viewModel.message = update.message
                self.viewModel.fraction = update.fraction
                self.viewModel.sentBytes = update.sentBytes
                self.viewModel.totalBytes = update.totalBytes
                self.refreshStatus()
            }
        }
    }

    private func saveFailure(folder: URL, message: String) {
        do {
            var metadata = try Library.load(folder: folder)
            metadata.status = .failed
            metadata.errorMessage = message
            try Library.save(metadata, folder: folder)
        } catch { AppLog.shared.event("failure-metadata-save-failed", code: (error as NSError).code) }
    }

    private func reloadLibrary(then completion: (() -> Void)? = nil) {
        libraryQueue.async {
            do {
                let items = try Library.scan(root: AppIdentity.root)
                DispatchQueue.main.async {
                    self.viewModel.library = items
                    self.viewModel.libraryError = nil
                    self.refreshMenu()
                    completion?()
                }
            } catch {
                AppLog.shared.event("library-scan-failed", code: (error as NSError).code)
                DispatchQueue.main.async {
                    self.viewModel.libraryError = "Cannot scan the library: \(error.localizedDescription)"
                }
            }
        }
    }

    private func updateDiskSize(_ folder: URL) {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey])
            viewModel.diskBytes = try files.reduce(0) { count, file in
                count + Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
        } catch { AppLog.shared.event("capture-size-read-failed", code: (error as NSError).code) }
    }

    private func retry(_ item: PraatvolCore.LibraryItem) {
        guard state == .idle, item.canRetry else { return }
        let alert = NSAlert()
        alert.messageText = "Transcribe again?"
        alert.informativeText =
            "OpenRouter charges for a new request. A failed or timed-out request may already have a charge. Check your account first."
        alert.addButton(withTitle: "Transcribe again")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        mainWindow.show(activate: true)
        process(capture: nil, file: nil, preferences: Preferences.read(), retryItem: item)
    }

    private func rename(_ item: PraatvolCore.LibraryItem, to name: String) {
        do {
            try Library.rename(item, to: name)
        } catch {
            AppLog.shared.event("rename-failed", code: (error as NSError).code)
            showAlert("Cannot rename the item: \(error.localizedDescription)")
        }
        reloadLibrary()
    }

    private func trash(_ item: PraatvolCore.LibraryItem) {
        guard item.folder != viewModel.folder || !viewModel.busy else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(ItemPresentation.title(of: item.metadata))” to the Trash?"
        alert.informativeText = "The audio and transcript move to the Trash. You can restore them from there."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: item.folder, resultingItemURL: nil)
            if viewModel.selection == item.id { viewModel.selection = nil }
        } catch {
            AppLog.shared.event("trash-failed", code: (error as NSError).code)
            showAlert("Cannot move the item to the Trash: \(error.localizedDescription)")
        }
        reloadLibrary()
    }

    private func openFile(_ file: URL) {
        if !NSWorkspace.shared.open(file) {
            AppLog.shared.event("open-transcript-failed")
            showAlert("No app can open the transcript. Choose an editor in Finder.")
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let file = sender.representedObject as? URL { openFile(file) }
    }
    @objc private func openMainWindow() {
        reloadLibrary()
        mainWindow.show(activate: true)
    }

    @objc private func openTranscripts() {
        do {
            try FileManager.default.createDirectory(at: AppIdentity.root, withIntermediateDirectories: true)
            if !NSWorkspace.shared.open(AppIdentity.root) {
                throw PraatvolError("Finder could not open the transcript folder.")
            }
        } catch {
            AppLog.shared.event("open-folder-failed", code: (error as NSError).code)
            showAlert(error.localizedDescription)
        }
    }
    @objc private func openSettings() { settings.show() }

    @objc private func quit() {
        switch state {
        case .recording:
            if confirm(
                "Stop capture and quit?",
                message: "The app saves the audio before quit. The app does not send a transcription request.")
            {
                finishCapture(quitAfterSave: true)
            }
        case .starting:
            cancelSetup(message: "Capture setup was cancelled.")
        case .stopping:
            showAlert("Wait for the app to save the audio, then choose Quit.")
        case .transcribing:
            showAlert("Wait for transcription to finish before quit. The audio stays saved if transcription fails.")
        case .idle: terminate()
        }
    }

    private func confirm(_ title: String, message: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save and quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func terminate() {
        authorizedTermination = true
        NSApp.terminate(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if authorizedTermination { return .terminateNow }
        quit()
        return .terminateCancel
    }
}
