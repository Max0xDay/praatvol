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

private enum RecordingOrigin {
    case menu, control
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var state: AppState = .idle
    private let settings = SettingsWindow()
    private let notifications = Notifications()
    private let captureQueue = DispatchQueue(label: "praatvol.capture")
    private var microphoneRecoveryInProgress = false
    private let libraryQueue = DispatchQueue(label: "praatvol.library", qos: .utility)
    private var recorder: Recorder?
    private var recordingDate: Date?
    private var recordingPreferences = Preferences.read()
    private var recordingOrigin: RecordingOrigin = .menu
    private var timer: Timer?
    private var job: Task<Void, Never>?
    private var authorizedTermination = false
    private let viewModel = JobViewModel()
    private var mainWindow: MainWindow!
    private var startIdentifier: UUID?
    private var startWatchdog: DispatchWorkItem?
    private var reviewContinuation: CheckedContinuation<Bool, Never>?
    private var quitAfterReview = false
    private var controlServer: ControlServer?
    private var modalDepth = 0
    private var lastControlTickSeconds = 0.0
    private var lastControlPublishSeconds = 0.0
    private var lastControlStatus: ControlStatus?
    private var pendingControlPublish: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        notifications.configure()
        LoginItems.verifyAtLaunch()
        settings.notifyLoginStatus = { [weak self] message in
            self?.notifications.post(
                title: "Launch at login", message: message, file: nil, alertOnFailure: false,
                allowAutomaticPresentation: false)
        }
        mainWindow = MainWindow(model: viewModel)
        viewModel.stop = { [weak self] in self?.stopRecording() }
        viewModel.transcribe = { [weak self] in self?.transcribeReviewedAudio() }
        viewModel.keep = { [weak self] in self?.keepReviewedAudio() }
        viewModel.retry = { [weak self] item in self?.retry(item) }
        viewModel.open = { [weak self] file in self?.openFile(file) }
        viewModel.recordCall = { [weak self] in self?.recordCall() }
        viewModel.recordRoom = { [weak self] in self?.recordRoom() }
        viewModel.transcribeFile = { [weak self] in self?.transcribeFile() }
        viewModel.openSettings = { [weak self] in self?.openSettings() }
        viewModel.openLibraryFolder = { [weak self] in self?.openTranscripts() }
        viewModel.rename = { [weak self] item, name in self?.rename(item, to: name) }
        viewModel.trash = { [weak self] item in self?.trash(item) }
        viewModel.stepChanged = { [weak self] in self?.publishStatus() }
        AppModal.attentionChanged = { [weak self] visible in
            guard let self else { return }
            self.modalDepth += visible ? 1 : -1
            self.publishStatus()
        }
        settings.saved = { [weak self] in self?.applyControlSocketSetting() }
        applyControlSocketSetting()
        reloadLibrary()
        refreshMenu()
        AppLog.shared.event("app-launched")
    }

    // Starts the server when enabled and stops it (closing clients, removing the socket) when disabled.
    @MainActor private func applyControlSocketSetting() {
        // #COMPLETION_DRIVE: Live start and stop after Settings save is verified by build and tests only, not by launching the app.
        // #SUGGEST_VERIFY: Toggle the box off and on, then check control.sock is removed and recreated with 0600 and the directory with 0700.
        guard Preferences.read().controlSocketEnabled else {
            controlServer?.stop()
            controlServer = nil
            return
        }
        guard controlServer == nil else { return }
        let server = ControlServer(socketURL: AppIdentity.controlSocket) { [weak self] command, completion in
            DispatchQueue.main.async {
                guard let self else { return }
                self.handleControl(command, completion: completion)
            }
        }
        controlServer = server
        server.start()
        publishStatus()
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
        if viewModel.state.step == .review {
            add("Transcribe", action: #selector(transcribeReviewedAudio), to: menu)
            add("Keep audio only", action: #selector(keepReviewedAudio), to: menu)
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
        publishStatus()
    }

    private func menuStatus() -> String {
        if state == .recording {
            let microphone = viewModel.microphoneLevel.hasSignal ? "●" : "○"
            let system = viewModel.isCall ? " · system \(viewModel.systemLevel.hasSignal ? "●" : "○")" : ""
            return "Recording \(Transcript.timestamp(viewModel.elapsedSeconds)) · mic \(microphone)\(system)"
        }
        if viewModel.state.step == .review { return "Ready to transcribe" }
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

    @objc private func recordCall() { beginRecording(call: true, origin: .menu) }
    @objc private func recordRoom() { beginRecording(call: false, origin: .menu) }

    private func beginRecording(call: Bool, origin: RecordingOrigin) {
        guard state == .idle else { return }
        recordingOrigin = origin
        state = .starting
        viewModel.reset(title: call ? "Call" : "Room", call: call, recording: true)
        recordingPreferences = Preferences.read()
        let identifier = viewModel.identifier
        startIdentifier = identifier
        let recorder = Recorder()
        self.recorder = recorder
        viewModel.advance(.starting)
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.startIdentifier == identifier else { return }
            self.cancelSetup(
                message: "Capture setup exceeded 8 seconds. Check Microphone permission"
                    + (call ? " and Screen & System Audio Recording permission" : "")
                    + " in System Settings > Privacy & Security. Approve the prompt, then retry.")
        }
        startWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: watchdog)
        if origin == .menu { mainWindow.show(activate: false) }
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
                    self.recordingDate = Date()
                    self.viewModel.advance(.recording)
                    self.viewModel.folder = recorder.folder
                    if recorder.hasMicrophoneFailed { self.notifyMicrophoneFailure(recorder) }
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
        viewModel.message = message
        viewModel.advance(.failed)
        refreshMenu()
        AppLog.shared.event("capture-setup-cancelled")
        if recordingOrigin == .control {
            notifications.post(
                title: "Recording failed", message: message, file: nil, failure: true,
                allowAutomaticPresentation: false)
        }
        recordingOrigin = .menu
    }

    private func tick() {
        if let recorder, state == .recording {
            let meters = recorder.meters()
            viewModel.warnings = recorder.warnings
            viewModel.microphoneLevel = meters.microphone.0
            viewModel.microphoneSilenceSeconds = meters.microphone.1
            viewModel.systemLevel = meters.system?.0 ?? .silence
            viewModel.systemSilenceSeconds = meters.system?.1 ?? Date().timeIntervalSince(recordingDate ?? Date())
            viewModel.elapsedSeconds = Date().timeIntervalSince(recordingDate ?? Date())
            if let folder = viewModel.folder { updateDiskSize(folder) }
        }
        if viewModel.state.step == .transcribing {
            viewModel.elapsedSeconds = Date().timeIntervalSince(viewModel.stepDate)
        }
        refreshStatus()
        let uptimeSeconds = ProcessInfo.processInfo.systemUptime
        if uptimeSeconds - lastControlTickSeconds >= 1 {
            lastControlTickSeconds = uptimeSeconds
            publishStatus(force: true)
        }
        guard state == .recording, let recordingDate else { return }
        if Date().timeIntervalSince(recordingDate) > 5 {
            if recorder?.microphoneProblem() == true { recoverMicrophone() }
        }
    }

    private func recoverMicrophone() {
        guard !microphoneRecoveryInProgress, let recorder else { return }
        microphoneRecoveryInProgress = true
        captureQueue.async {
            let recovered = recorder.recoverMicrophoneIfNeeded()
            DispatchQueue.main.async {
                self.microphoneRecoveryInProgress = false
                guard self.state == .recording, self.recorder === recorder else { return }
                self.viewModel.warnings = recorder.warnings
                if !recovered {
                    self.notifyMicrophoneFailure(recorder)
                    if !recorder.capturingSystem { self.stopRecording() }
                }
            }
        }
    }

    private func notifyMicrophoneFailure(_ recorder: Recorder) {
        notifications.post(
            title: "Microphone unavailable",
            message: recorder.capturingSystem
                ? "Recording continues with system audio only. Your microphone is not being recorded."
                : "The microphone could not restart. Available audio will be saved.",
            file: nil, failure: true, allowAutomaticPresentation: false)
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
        recorder.cancelStart()
        timer?.invalidate()
        timer = nil
        state = .stopping
        viewModel.durationSeconds = viewModel.elapsedSeconds
        viewModel.advance(.preparing)
        startJobTimer()
        refreshMenu()
        let preferences = recordingPreferences
        captureQueue.async {
            let capture = recorder.stop()
            DispatchQueue.main.async {
                guard let capture else {
                    self.state = .idle
                    self.viewModel.message = "The recorder saved no track. Check capture permissions."
                    self.viewModel.advance(.failed)
                    if self.recordingOrigin == .control {
                        self.notifications.post(
                            title: "Recording failed", message: self.viewModel.message, file: nil, failure: true,
                            allowAutomaticPresentation: false)
                    }
                    self.recordingOrigin = .menu
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
                let message = "The raw audio stays saved in \(capture.folder.path).\n\n\(error.localizedDescription)"
                if recordingOrigin == .menu {
                    showAlert(message)
                } else {
                    notifications.post(
                        title: "Recording failed", message: message, file: nil, failure: true,
                        allowAutomaticPresentation: false)
                }
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
        if AppModal.run({ panel.runModal() }) == .OK, let file = panel.url {
            mainWindow.show(activate: true)
            process(capture: nil, file: file, preferences: Preferences.read())
        }
    }

    private func process(
        capture: CapturedItem?, file: URL?, preferences: Preferences, retryItem: PraatvolCore.LibraryItem? = nil
    ) {
        state = .transcribing
        if capture == nil { recordingOrigin = .menu }
        if let file { viewModel.reset(title: "File: \(file.lastPathComponent)") }
        if let retryItem { viewModel.reset(title: retryItem.metadata.kind) }
        viewModel.includesReview = preferences.askBeforeTranscribing
        viewModel.advance(.preparing)
        startJobTimer()
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
                try await updatePreparationDuration(capture: capture, file: file, retryItem: retryItem)
                let prepared = try await Task.detached {
                    if let capture { return try TranscriptionJob.prepare(capture: capture, report: report) }
                    if let retryItem { return try TranscriptionJob.prepareRetry(item: retryItem, report: report) }
                    guard let file else { throw PraatvolError("No source audio exists.") }
                    return try TranscriptionJob.prepare(file: file, folder: itemFolder, report: report)
                }.value
                try await processPrepared(prepared, preferences: preferences, report: report)
            } catch {
                AppLog.shared.event("transcription-failed", code: (error as NSError).code)
                if let folder { saveFailure(folder: folder, message: error.localizedDescription) }
                viewModel.message = error.localizedDescription
                viewModel.advance(.failed)
                notifications.post(
                    title: "Transcription failed",
                    message: error.localizedDescription + "\nThe audio stays saved. No paid request was retried.",
                    file: folder, failure: true, allowAutomaticPresentation: recordingOrigin == .menu)
            }
            finishJob()
        }
    }

    @MainActor private func updatePreparationDuration(
        capture: CapturedItem?, file: URL?, retryItem: PraatvolCore.LibraryItem?
    ) async throws {
        let durationSource = capture?.microphone ?? file ?? retryItem?.retrySource
        guard let durationSource else { return }
        viewModel.durationSeconds = try await Task.detached {
            if let capture { try AudioFiles.validateRecordedMicrophone(capture.microphone) }
            if let retryItem, let reason = retryItem.retryUnavailableReason { throw PraatvolError(reason) }
            return try AudioFiles.duration(durationSource)
        }.value
        publishStatus()
    }

    private func startJobTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    @MainActor private func processPrepared(
        _ prepared: PreparedItem, preferences: Preferences, report: @escaping JobReporter
    ) async throws {
        viewModel.durationSeconds = prepared.durationSeconds
        let upload = preferences.lossless ? prepared.archive.url : prepared.upload
        let uploadBytes = try await Task.detached {
            let attributes = try FileManager.default.attributesOfItem(atPath: upload.path)
            guard let size = attributes[.size] as? NSNumber else { throw PraatvolError("Upload size is unavailable.") }
            return size.int64Value
        }.value
        viewModel.uploadBytes = uploadBytes
        if preferences.askBeforeTranscribing {
            viewModel.warnings = JobProgress.reviewWarnings(
                preparationWarnings: prepared.warnings, durationSeconds: prepared.durationSeconds)
            let shouldTranscribe = await withCheckedContinuation { continuation in
                reviewContinuation = continuation
                viewModel.message = "Audio is saved. Choose whether to transcribe."
                viewModel.advance(.review)
                refreshMenu()
                let details = String(
                    format: "%@ · %.1f MB", Transcript.duration(prepared.durationSeconds),
                    Double(uploadBytes) / 1_000_000)
                notifications.post(
                    title: "Ready to transcribe", message: ([details] + viewModel.warnings).joined(separator: "\n"),
                    file: nil, alertOnFailure: false, allowAutomaticPresentation: recordingOrigin == .menu)
            }
            guard shouldTranscribe else { return }
        } else {
            notifyUploadWarnings(prepared)
        }
        let key = try KeyStore.read()
        let completion = try await Task.detached {
            try await TranscriptionJob.transcribe(item: prepared, preferences: preferences, apiKey: key, report: report)
        }.value
        if viewModel.state.step == .uploading { viewModel.advance(.transcribing) }
        viewModel.summary = completion.metadata
        viewModel.message =
            completion.hasSpeakerLabels ? "The transcript is ready." : "The transcript has no speaker labels."
        viewModel.advance(.saved)
        notifications.post(
            title: "Transcript ready", message: viewModel.message, file: completion.transcript,
            allowAutomaticPresentation: recordingOrigin == .menu)
    }

    @objc private func transcribeReviewedAudio() { decideReview(transcribe: true) }
    @objc private func keepReviewedAudio() { decideReview(transcribe: false) }

    private func decideReview(transcribe: Bool) {
        guard viewModel.state.step == .review, let continuation = reviewContinuation else { return }
        reviewContinuation = nil
        viewModel.warnings = []
        viewModel.message = transcribe ? "Send audio to OpenRouter" : "Audio saved without transcription."
        viewModel.advance(transcribe ? .uploading : .saved)
        refreshMenu()
        continuation.resume(returning: transcribe)
    }

    private func notifyUploadWarnings(_ item: PreparedItem) {
        var warnings = item.warnings
        if UploadRules.isBeyondTestedLength(item.durationSeconds) {
            warnings.append(
                "Beyond tested length; may time out; recording saved locally. The AAC duration rule follows Opus trials, not AAC trials."
            )
        }
        if warnings.isEmpty { return }
        AppLog.shared.event("transcribing-with-warnings")
        notifications.post(
            title: "Transcribing with warnings", message: warnings.joined(separator: "\n\n"),
            file: nil, alertOnFailure: false, allowAutomaticPresentation: recordingOrigin == .menu)
    }

    private func finishJob() {
        recordingOrigin = .menu
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
        if quitAfterReview { terminate() }
    }

    private func acceptsProgress(_ identifier: UUID) -> Bool {
        guard viewModel.identifier == identifier else { return false }
        if viewModel.state.step == .review { return false }
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
                self.viewModel.message = update.message
                self.viewModel.sentBytes = update.sentBytes
                self.viewModel.totalBytes = update.totalBytes
                self.viewModel.advance(update.step)
                self.viewModel.fraction = update.fraction
                self.refreshStatus()
                self.publishStatus()
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
        guard AppModal.run({ alert.runModal() }) == .alertFirstButtonReturn else { return }
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
        guard AppModal.run({ alert.runModal() }) == .alertFirstButtonReturn else { return }
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
        case .transcribing where viewModel.state.step == .review:
            quitAfterReview = true
            keepReviewedAudio()
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
        return AppModal.run { alert.runModal() } == .alertFirstButtonReturn
    }

    private func controlStatus() -> ControlStatus {
        let step = viewModel.state.step
        let capturing = state.canStop
        let meters = capturing ? recorder?.meters() : nil
        let microphoneName = capturing ? recorder?.microphoneName : nil
        var microphone: ControlStatus.Microphone?
        if let microphoneName, !microphoneName.isEmpty, let meters {
            microphone = .init(
                name: microphoneName, hasSignal: meters.microphone.0.hasSignal,
                silenceSeconds: meters.microphone.1)
        }
        var system: ControlStatus.System?
        if capturing, viewModel.isCall {
            system = .init(
                active: recorder?.capturingSystem ?? false, hasSignal: meters?.system?.0.hasSignal ?? false,
                silenceSeconds: meters?.system?.1 ?? 0)
        }
        let kind = viewModel.includesRecording ? (viewModel.isCall ? "call" : "room") : nil
        let message: String?
        switch step {
        case .failed:
            // Use the existing safe summary, never provider text or localized errors that may contain private paths.
            message = ItemPresentation.problem(for: viewModel.message).summary
        case .starting, .recording, .preparing, .review, .uploading, .transcribing: message = step.rawValue
        case .idle, .saved: message = nil
        }
        let uploadBytes: Int64?
        switch step {
        case .idle, .starting, .recording, .preparing: uploadBytes = nil
        default: uploadBytes = viewModel.uploadBytes
        }
        return ControlStatus(
            step: step, kind: step == .idle ? nil : kind,
            startedAt: state == .recording ? recordingDate?.timeIntervalSince1970 : nil,
            elapsedSeconds: state == .recording ? viewModel.elapsedSeconds : 0,
            microphone: microphone, system: system,
            uploadFraction: step == .uploading ? min(1, max(0, viewModel.fraction)) : nil,
            needsAttention: modalDepth > 0, message: message,
            stepStartedAt: step == .idle ? nil : viewModel.stepDate.timeIntervalSince1970,
            estimatedSeconds: step == .transcribing
                ? JobProgress.estimateSeconds(durationSeconds: viewModel.durationSeconds) : nil,
            preparingFraction: step == .preparing ? min(1, max(0, viewModel.fraction)) : nil,
            durationSeconds: step == .idle ? nil : (viewModel.durationSeconds > 0 ? viewModel.durationSeconds : nil),
            uploadBytes: uploadBytes,
            warnings: viewModel.warnings.isEmpty ? nil : viewModel.warnings)
    }

    private func shouldThrottleControl(_ status: ControlStatus) -> Bool {
        guard [JobStep.preparing.controlKey, JobStep.uploading.controlKey].contains(status.step) else { return false }
        guard lastControlStatus?.step == status.step else { return false }
        guard lastControlStatus?.needsAttention == status.needsAttention else { return false }
        return ProcessInfo.processInfo.systemUptime - lastControlPublishSeconds < 0.25
    }

    private func publishStatus(force: Bool = false) {
        let status = controlStatus()
        controlServer?.update(status)
        if !force, status == lastControlStatus { return }
        if shouldThrottleControl(status) {
            guard pendingControlPublish == nil else { return }
            let pending = DispatchWorkItem { [weak self] in
                self?.pendingControlPublish = nil
                self?.publishStatus()
            }
            pendingControlPublish = pending
            let delay = max(0, 0.25 - (ProcessInfo.processInfo.systemUptime - lastControlPublishSeconds))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: pending)
            return
        }
        pendingControlPublish?.cancel()
        pendingControlPublish = nil
        lastControlStatus = status
        lastControlPublishSeconds = ProcessInfo.processInfo.systemUptime
        controlServer?.publish(status, force: force)
    }

    private func handleControl(_ command: ControlRequest.Command, completion: ControlServer.Completion) {
        if let rejection = ControlRequest.rejection(command, step: viewModel.state.step, canStart: state == .idle) {
            completion(.failure(rejection))
            return
        }
        switch command {
        case .recordRoom: beginRecording(call: false, origin: .control)
        case .recordCall: beginRecording(call: true, origin: .control)
        case .stop: stopRecording()
        case .transcribe: transcribeReviewedAudio()
        case .keep: keepReviewedAudio()
        case .status, .subscribe: break
        }
        publishStatus()
        completion(.success(controlStatus()))
    }

    private func terminate() {
        pendingControlPublish?.cancel()
        controlServer?.stop()
        authorizedTermination = true
        NSApp.terminate(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if authorizedTermination { return .terminateNow }
        quit()
        return .terminateCancel
    }
}
