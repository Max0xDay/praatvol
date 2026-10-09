import AppKit
import PraatvolCore
import SwiftUI

final class JobViewModel: ObservableObject {
    /// The sidebar selection id for the live job row.
    static let liveSelection = "praatvol.live"

    @Published var state = JobState()
    @Published var message = ""
    @Published var title = ""
    @Published var fraction = 0.0
    @Published var elapsedSeconds = 0.0
    @Published var durationSeconds = 0.0
    @Published var sentBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var diskBytes: Int64 = 0
    @Published var microphoneLevel = AudioLevel.silence
    @Published var systemLevel = AudioLevel.silence
    @Published var microphoneSilenceSeconds = 0.0
    @Published var systemSilenceSeconds = 0.0
    @Published var isCall = false
    @Published var includesRecording = false
    @Published private(set) var lastActiveStep = JobStep.idle
    @Published var library: [PraatvolCore.LibraryItem] = []
    @Published var libraryError: String?
    @Published var summary: ItemMetadata?
    @Published var selection: String?
    /// The sidebar row being renamed inline.
    @Published var renaming: String?
    var identifier = UUID()
    var folder: URL?
    var stop: () -> Void = {}
    var retry: (PraatvolCore.LibraryItem) -> Void = { _ in }
    var open: (URL) -> Void = { _ in }
    var recordCall: () -> Void = {}
    var recordRoom: () -> Void = {}
    var transcribeFile: () -> Void = {}
    var openSettings: () -> Void = {}
    var openLibraryFolder: () -> Void = {}
    var rename: (PraatvolCore.LibraryItem, String) -> Void = { _, _ in }
    var trash: (PraatvolCore.LibraryItem) -> Void = { _ in }
    var canStop: Bool {
        switch state.step {
        case .starting, .recording: return true
        default: return false
        }
    }
    var busy: Bool {
        switch state.step {
        case .idle, .saved, .failed: return false
        default: return true
        }
    }
    /// The steps shown in the step bar. File imports and retries skip the recording step.
    var steps: [JobStep] {
        includesRecording
            ? [.recording, .preparing, .uploading, .transcribing, .saved]
            : [.preparing, .uploading, .transcribing, .saved]
    }
    var selectedItem: PraatvolCore.LibraryItem? { library.first { $0.id == selection } }
    /// The running job's folder can't be trashed until the job ends.
    func canTrash(_ item: PraatvolCore.LibraryItem) -> Bool { !(busy && folder == item.folder) }
    func copyTranscript(_ item: PraatvolCore.LibraryItem) {
        guard let text = try? String(contentsOf: item.transcript, encoding: .utf8) else {
            AppLog.shared.event("copy-transcript-failed")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func advance(_ step: JobStep) {
        guard state.step != step else { return }
        do {
            try state.advance(to: step)
            if step != .failed && step != .idle { lastActiveStep = step }
        } catch {
            AppLog.shared.event("job-transition-failed")
            message = error.localizedDescription
        }
    }
    func reset(title: String, call: Bool = false, recording: Bool = false) {
        identifier = UUID()
        self.title = title
        isCall = call
        includesRecording = recording
        lastActiveStep = .idle
        message = ""
        fraction = 0
        elapsedSeconds = 0
        durationSeconds = 0
        sentBytes = 0
        totalBytes = 0
        diskBytes = 0
        microphoneLevel = .silence
        systemLevel = .silence
        microphoneSilenceSeconds = 0
        systemSilenceSeconds = 0
        summary = nil
        folder = nil
        selection = Self.liveSelection
    }
}

final class MainWindow {
    private let window: NSWindow
    init(model: JobViewModel) {
        let controller = NSHostingController(rootView: Dashboard(model: model))
        // Let SwiftUI's .toolbar and .navigationTitle drive the AppKit window.
        controller.sceneBridgingOptions = [.toolbars, .title]
        window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 900, height: 600))
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("praatvol.main")
    }
    func show(activate: Bool) {
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
    }
}

// MARK: - Style

private enum Style {
    /// The brand colour of the sine-wave app icon.
    static let brand = Color(red: 0.37, green: 0.36, blue: 0.90)
    static let hairline = Color.primary.opacity(0.08)
    static let fill = Color.primary.opacity(0.045)
    static let speakerColors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .indigo]

    static func speakerColor(_ label: String) -> Color {
        guard let scalar = label.unicodeScalars.first, label != "?" else { return .secondary }
        let index = Int(scalar.value) - 65
        return speakerColors[((index % speakerColors.count) + speakerColors.count) % speakerColors.count]
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

// MARK: - Dashboard

private struct Dashboard: View {
    @ObservedObject var model: JobViewModel
    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            Detail(model: model)
        }
        .navigationTitle(AppIdentity.name)
        .toolbar { Toolbar(model: model) }
        .frame(minWidth: 720, minHeight: 460)
    }
}

private struct Toolbar: ToolbarContent {
    @ObservedObject var model: JobViewModel
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.canStop {
                Button(action: model.stop) {
                    Label(model.state.step == .starting ? "Cancel" : "Stop", systemImage: "stop.fill")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop the recording and transcribe it")
            } else {
                Button(action: model.recordCall) { Label("Record Call", systemImage: "phone.fill") }
                    .labelStyle(.titleAndIcon)
                    .help("Record your microphone and the sound your Mac plays")
                    .disabled(model.busy)
                Button(action: model.recordRoom) { Label("Record Room", systemImage: "mic.fill") }
                    .labelStyle(.titleAndIcon)
                    .help("Record your microphone only")
                    .disabled(model.busy)
                Button(action: model.transcribeFile) { Label("Import Audio", systemImage: "square.and.arrow.down") }
                    .labelStyle(.titleAndIcon)
                    .help("Transcribe an audio file, such as an iPhone voice memo")
                    .disabled(model.busy)
            }
        }
        ToolbarItem(placement: .automatic) {
            Button(action: model.openSettings) { Label("Settings", systemImage: "gearshape") }
                .help("Settings")
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: JobViewModel
    var body: some View {
        List(selection: $model.selection) {
            if model.state.step != .idle {
                Section("Now") {
                    LiveRow(model: model).tag(JobViewModel.liveSelection)
                }
            }
            ForEach(ItemPresentation.sections(ItemPresentation.listed(model.library)), id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        ItemRow(item: item, model: model)
                            .tag(item.id)
                            .contextMenu { ItemMenu(item: item, model: model) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) {
            guard model.renaming == nil, let item = model.selectedItem else { return .ignored }
            model.renaming = item.id
            return .handled
        }
        .onDeleteCommand {
            if let item = model.selectedItem, model.canTrash(item) { model.trash(item) }
        }
        .overlay {
            if ItemPresentation.listed(model.library).isEmpty && model.state.step == .idle {
                ContentUnavailableView(
                    "No Recordings", systemImage: "waveform",
                    description: Text("Record a call or a room, or import an audio file."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: model.openLibraryFolder) { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(.borderless)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if AppIdentity.isDevelopment { Text("DEV").font(.caption2.weight(.bold)).foregroundStyle(.orange) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

private struct LiveRow: View {
    @ObservedObject var model: JobViewModel
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(model.state.step == .failed ? Color.red : Color.red.opacity(0.9))
                Image(systemName: model.canStop ? "record.circle" : "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: model.busy)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title.hasPrefix("File: ") ? String(model.title.dropFirst(6)) : model.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
    private var status: String {
        switch model.state.step {
        case .recording: return "Recording · " + Transcript.timestamp(model.elapsedSeconds)
        case .uploading: return "Uploading · \(Int(model.fraction * 100))%"
        default: return model.state.step.rawValue
        }
    }
}

private struct ItemRow: View {
    let item: PraatvolCore.LibraryItem
    @ObservedObject var model: JobViewModel
    var body: some View {
        HStack(spacing: 10) {
            KindBadge(kind: ItemPresentation.kind(of: item.metadata.kind), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                if model.renaming == item.id {
                    RenameField(item: item, model: model)
                } else {
                    Text(ItemPresentation.title(of: item.metadata))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            switch item.status {
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).help("Transcription failed")
            case .notTranscribed:
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary).help("Not transcribed")
            case .transcribed: EmptyView()
            }
        }
        .padding(.vertical, 2)
    }
    private var subtitle: String {
        var parts: [String] = []
        if item.metadata.durationSeconds > 0 { parts.append(Transcript.duration(item.metadata.durationSeconds)) }
        if item.metadata.speakerCount > 0 {
            parts.append("\(item.metadata.speakerCount) speaker\(item.metadata.speakerCount == 1 ? "" : "s")")
        }
        if parts.isEmpty {
            switch item.status {
            case .failed: return "Failed"
            case .notTranscribed: return "Not transcribed"
            case .transcribed: return "Transcribed"
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Finder-style inline rename: Return saves, Escape cancels, clicking elsewhere saves.
private struct RenameField: View {
    let item: PraatvolCore.LibraryItem
    @ObservedObject var model: JobViewModel
    @State private var draft = ""
    @State private var cancelled = false
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { focused = false }
            .onExitCommand {
                cancelled = true
                model.renaming = nil
            }
            .onAppear {
                draft = ItemPresentation.title(of: item.metadata)
                focused = true
            }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused else { return }
                if !cancelled { commit(item: item, draft: draft, model: model) }
                model.renaming = nil
            }
    }
}

/// Saves a typed name. Typing the generated title back, or clearing the field, removes the custom name.
private func commit(item: PraatvolCore.LibraryItem, draft: String, model: JobViewModel) {
    let generated = ItemPresentation.title(kind: item.metadata.kind, date: item.metadata.date)
    let cleaned = ItemPresentation.cleanTitle(draft)
    let stored = cleaned == generated ? nil : cleaned
    if stored != item.metadata.title { model.rename(item, stored ?? "") }
}

private struct ItemMenu: View {
    let item: PraatvolCore.LibraryItem
    @ObservedObject var model: JobViewModel
    var body: some View {
        if item.status == .transcribed {
            Button("Open Transcript") { model.open(item.transcript) }
            Button("Copy Transcript") { model.copyTranscript(item) }
        }
        Button("Rename") {
            model.selection = item.id
            model.renaming = item.id
        }
        if item.canRetry { Button("Transcribe Again…") { model.retry(item) }.disabled(model.busy) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
        Divider()
        Button("Move to Trash…", role: .destructive) { model.trash(item) }.disabled(!model.canTrash(item))
    }
}

private struct KindBadge: View {
    let kind: ItemPresentation.Kind
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(color.gradient)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
    private var symbol: String {
        switch kind {
        case .call: return "phone.fill"
        case .room: return "mic.fill"
        case .file: return "waveform"
        }
    }
    private var color: Color {
        switch kind {
        case .call: return .blue
        case .room: return Style.brand
        case .file: return .orange
        }
    }
}

// MARK: - Detail

private struct Detail: View {
    @ObservedObject var model: JobViewModel
    var body: some View {
        if model.selection == JobViewModel.liveSelection, model.state.step != .idle {
            LiveView(model: model)
        } else if let item = model.library.first(where: { $0.id == model.selection }) {
            ItemDetail(item: item, model: model).id(item.id)
        } else {
            ContentUnavailableView(
                "Select a Recording", systemImage: "waveform",
                description: Text("Choose an item in the sidebar to see its transcript."))
        }
    }
}

private struct ItemDetail: View {
    let item: PraatvolCore.LibraryItem
    @ObservedObject var model: JobViewModel
    @State private var lines: [TranscriptPreview.Line] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if item.status == .failed { ProblemBanner(item: item, model: model) }
                if item.status == .transcribed { StatsRow(metadata: item.metadata) }
                transcript
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: item.id) { await loadPreview() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            KindBadge(kind: ItemPresentation.kind(of: item.metadata.kind), size: 44)
            VStack(alignment: .leading, spacing: 3) {
                TitleField(item: item, model: model)
                Text(item.metadata.date.formatted(date: .complete, time: .shortened))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if item.status == .transcribed {
                    Button {
                        model.open(item.transcript)
                    } label: {
                        Label("Open Transcript", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Style.brand)
                } else if item.canRetry && item.status == .notTranscribed {
                    Button {
                        model.retry(item)
                    } label: {
                        Label("Transcribe", systemImage: "text.bubble")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Style.brand)
                    .disabled(model.busy)
                }
                Menu {
                    ItemMenu(item: item, model: model)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .labelStyle(.iconOnly)
                .fixedSize()
                .help("More actions")
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.large)
        }
    }

    @ViewBuilder private var transcript: some View {
        if item.status == .transcribed {
            VStack(alignment: .leading, spacing: 10) {
                Text("Transcript").font(.headline)
                if lines.isEmpty && loaded {
                    Text("No speech was detected.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in TranscriptLine(line: line) }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Style.fill))
                    if lines.count >= previewLimit {
                        Button("Open Full Transcript") { model.open(item.transcript) }
                            .buttonStyle(.link)
                    }
                }
            }
        } else if item.status == .notTranscribed {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not transcribed yet").font(.headline)
                Text("The audio is saved. Transcribe it to get a transcript with speakers and timestamps.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private let previewLimit = 40

    private func loadPreview() async {
        guard item.status == .transcribed else {
            loaded = true
            return
        }
        let url = item.transcript
        let limit = previewLimit
        let parsed = await Task.detached(priority: .userInitiated) { () -> [TranscriptPreview.Line] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return TranscriptPreview.lines(markdown: text, limit: limit)
        }.value
        lines = parsed
        loaded = true
    }
}

/// The detail title doubles as a rename field, like a document title in Pages or Freeform.
private struct TitleField: View {
    let item: PraatvolCore.LibraryItem
    @ObservedObject var model: JobViewModel
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField(
            "Name", text: $draft,
            prompt: Text(ItemPresentation.title(kind: item.metadata.kind, date: item.metadata.date))
        )
        .textFieldStyle(.plain)
        .font(.title2.weight(.semibold))
        .lineLimit(1)
        .focused($focused)
        .help("Click to rename")
        .onSubmit { focused = false }
        .onExitCommand {
            draft = ItemPresentation.title(of: item.metadata)
            focused = false
        }
        .onAppear { draft = ItemPresentation.title(of: item.metadata) }
        .onChange(of: item.metadata.title) { _, _ in
            if !focused { draft = ItemPresentation.title(of: item.metadata) }
        }
        .onChange(of: focused) { _, isFocused in
            guard !isFocused else { return }
            commit(item: item, draft: draft, model: model)
            if ItemPresentation.cleanTitle(draft) == nil {
                draft = ItemPresentation.title(kind: item.metadata.kind, date: item.metadata.date)
            }
        }
    }
}

private struct TranscriptLine: View {
    let line: TranscriptPreview.Line
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .leading)
            Text(line.speaker == "?" ? "Unknown" : "Speaker \(line.speaker)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Style.speakerColor(line.speaker))
                .frame(width: 72, alignment: .leading)
            Text(line.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProblemBanner: View {
    let item: PraatvolCore.LibraryItem
    @ObservedObject var model: JobViewModel
    var body: some View {
        let problem = ItemPresentation.problem(for: item.metadata.errorMessage ?? "")
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(problem.summary).font(.body.weight(.semibold))
                Text(problem.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 8) {
                    if problem.action == .openSettings {
                        Button("Open Settings", action: model.openSettings)
                            .buttonStyle(.borderedProminent)
                            .tint(Style.brand)
                    }
                    if item.canRetry {
                        if problem.action == .retry {
                            Button("Transcribe Again…") { model.retry(item) }
                                .buttonStyle(.borderedProminent)
                                .tint(Style.brand)
                                .disabled(model.busy)
                        } else {
                            Button("Transcribe Again…") { model.retry(item) }
                                .disabled(model.busy)
                        }
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.25)))
    }
}

private struct StatsRow: View {
    let metadata: ItemMetadata
    var body: some View {
        HStack(spacing: 10) {
            Stat(label: "Duration", value: Transcript.duration(metadata.durationSeconds))
            Stat(label: "Speakers", value: "\(metadata.speakerCount)")
            Stat(label: "Words", value: metadata.wordCount.formatted())
            Stat(label: "Cost", value: ItemPresentation.cost(metadata.costUsd) ?? "–")
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Style.fill))
    }
}

// MARK: - Live job

private struct LiveView: View {
    @ObservedObject var model: JobViewModel
    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Text(headline)
                    .font(.system(size: model.state.step == .recording ? 56 : 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(subheadline).font(.title3).foregroundStyle(.secondary)
            }
            StepBar(steps: model.steps, current: model.state.step, lastActive: model.lastActiveStep)
                .frame(maxWidth: 460)
            detail.frame(maxWidth: 460)
            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: String {
        switch model.state.step {
        case .recording: return Transcript.timestamp(model.elapsedSeconds)
        case .uploading: return "\(Int(model.fraction * 100))%"
        case .saved: return "Transcript Ready"
        case .failed: return "Something Went Wrong"
        case .starting: return "Starting…"
        case .preparing: return "Preparing Audio"
        case .transcribing: return "Transcribing"
        case .idle: return ""
        }
    }

    private var subheadline: String {
        let name = model.title.hasPrefix("File: ") ? String(model.title.dropFirst(6)) : model.title
        switch model.state.step {
        case .recording: return model.isCall ? "Recording call · mic and system audio" : "Recording room · mic only"
        case .starting: return "Approve any macOS permission prompt"
        case .uploading: return "Uploading \(name)"
        default: return name
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.state.step {
        case .recording:
            VStack(spacing: 10) {
                LevelMeter(
                    title: "Microphone", symbol: "mic.fill", level: model.microphoneLevel,
                    silence: model.microphoneSilenceSeconds)
                if model.isCall {
                    LevelMeter(
                        title: "System", symbol: "speaker.wave.2.fill", level: model.systemLevel,
                        silence: model.systemSilenceSeconds)
                }
                Text(
                    "\(Style.megabytes(model.diskBytes)) · \(JobProgress.tierHint(durationSeconds: model.elapsedSeconds))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        case .starting:
            ProgressView().controlSize(.small)
        case .preparing:
            ProgressRow(fraction: model.fraction > 0 ? model.fraction : nil, caption: model.message)
        case .uploading:
            ProgressRow(
                fraction: model.fraction,
                caption: "\(Style.megabytes(model.sentBytes)) of \(Style.megabytes(model.totalBytes))")
        case .transcribing:
            let estimate = JobProgress.estimateSeconds(durationSeconds: model.durationSeconds)
            let remaining = JobProgress.remainingSeconds(
                durationSeconds: model.durationSeconds, elapsedSeconds: model.elapsedSeconds)
            ProgressRow(
                fraction: min(0.95, model.elapsedSeconds / max(1, estimate)),
                caption: remaining > 0 ? "About \(Int(remaining)) s left" : "Almost done")
        case .saved:
            VStack(spacing: 14) {
                if let summary = model.summary { StatsRow(metadata: summary) }
                if let folder = model.folder {
                    Button {
                        model.open(folder.appendingPathComponent("transcript.md"))
                    } label: {
                        Label("Open Transcript", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Style.brand)
                    .controlSize(.large)
                }
            }
        case .failed:
            let problem = ItemPresentation.problem(for: model.message)
            VStack(spacing: 12) {
                Text(problem.summary).font(.body.weight(.semibold))
                Text(problem.detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if problem.action == .openSettings {
                    Button("Open Settings", action: model.openSettings)
                        .buttonStyle(.borderedProminent)
                        .tint(Style.brand)
                }
            }
        case .idle: EmptyView()
        }
    }
}

private struct StepBar: View {
    let steps: [JobStep]
    let current: JobStep
    let lastActive: JobStep
    var body: some View {
        let active = activeIndex
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { offset, step in
                VStack(spacing: 6) {
                    Capsule().fill(color(offset: offset, active: active)).frame(height: 4)
                    Text(label(step))
                        .font(.caption2.weight(offset == active ? .semibold : .regular))
                        .foregroundStyle(offset <= active ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current step: \(current.rawValue)")
    }
    private var activeIndex: Int {
        let step: JobStep
        switch current {
        case .starting: step = .recording
        case .failed: step = lastActive
        default: step = current
        }
        return steps.firstIndex(of: step) ?? (current == .failed ? 0 : -1)
    }
    private func color(offset: Int, active: Int) -> Color {
        if current == .saved { return .green }
        if offset < active { return Style.brand }
        if offset == active { return current == .failed ? .red : Style.brand.opacity(0.55) }
        return Style.hairline
    }
    private func label(_ step: JobStep) -> String {
        switch step {
        case .recording: return "Record"
        case .preparing: return "Prepare"
        case .uploading: return "Upload"
        case .transcribing: return "Transcribe"
        case .saved: return "Done"
        default: return step.rawValue
        }
    }
}

private struct ProgressRow: View {
    let fraction: Double?
    let caption: String
    var body: some View {
        VStack(spacing: 6) {
            if let fraction {
                ProgressView(value: min(1, max(0, fraction))).tint(Style.brand)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Style.brand)
            }
            if !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

private struct LevelMeter: View {
    let title: String
    let symbol: String
    let level: AudioLevel
    let silence: Double
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.callout).frame(width: 82, alignment: .leading)
            SegmentBar(value: min(1, max(0, (level.decibelsFullScale + 60) / 60)))
            Group {
                if silence >= 3 {
                    Text("No signal").foregroundStyle(.orange)
                } else {
                    Text("\(Int(level.decibelsFullScale.rounded())) dB").foregroundStyle(.secondary)
                }
            }
            .font(.caption.monospacedDigit())
            .frame(width: 64, alignment: .trailing)
        }
    }
}

private struct SegmentBar: View {
    let value: Double
    private let count = 28
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                let threshold = Double(index) / Double(count)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(value > threshold ? color(threshold) : Style.hairline)
            }
        }
        .frame(height: 10)
        .animation(.linear(duration: 0.1), value: value)
    }
    private func color(_ threshold: Double) -> Color {
        if threshold < 0.7 { return .green }
        if threshold < 0.9 { return .yellow }
        return .red
    }
}
