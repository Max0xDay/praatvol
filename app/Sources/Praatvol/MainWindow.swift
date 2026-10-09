import AppKit
import PraatvolCore
import SwiftUI

final class JobViewModel: ObservableObject {
    @Published var state = JobState()
    @Published var message = "Choose Record call, Record room, or Transcribe file from the menu."
    @Published var title = "No active item"
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
    @Published var library: [PraatvolCore.LibraryItem] = []
    @Published var libraryError: String?
    @Published var summary: ItemMetadata?
    var identifier = UUID()
    var folder: URL?
    var stop: () -> Void = {}
    var retry: (PraatvolCore.LibraryItem) -> Void = { _ in }
    var open: (URL) -> Void = { _ in }
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
    func advance(_ step: JobStep) {
        guard state.step != step else { return }
        do { try state.advance(to: step) } catch {
            AppLog.shared.event("job-transition-failed")
            message = error.localizedDescription
        }
    }
    func reset(title: String, call: Bool = false) {
        identifier = UUID()
        self.title = title
        isCall = call
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
    }
}

final class MainWindow {
    private let window: NSWindow
    init(model: JobViewModel) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppIdentity.name
        window.minSize = NSSize(width: 720, height: 600)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Dashboard(model: model))
        window.center()
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

private struct Dashboard: View {
    @ObservedObject var model: JobViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "waveform.path").font(.system(size: 34)).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(AppIdentity.name).font(.largeTitle.bold())
                        Text("Audio, voices, and transcripts").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.busy ? "ACTIVE" : "READY").font(.caption.bold()).padding(8).background(
                        .thinMaterial, in: Capsule())
                }
                nowPanel
                libraryPanel
            }.padding(28)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var nowPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Now", systemImage: "waveform.circle.fill").font(.title2.bold())
            Text(model.title).font(.headline)
            HStack(spacing: 8) {
                ForEach([JobStep.starting, .recording, .preparing, .uploading, .transcribing, .saved], id: \.self) {
                    step in
                    Text(step.rawValue).font(.caption).padding(7)
                        .background(
                            model.state.step == step ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08),
                            in: Capsule())
                }
            }.accessibilityLabel("Current step: \(model.state.step.rawValue)")
            currentProgress
            if !model.message.isEmpty {
                Text(model.message).foregroundStyle(model.state.step == .failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            currentActions
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
    @ViewBuilder private var currentProgress: some View {
        switch model.state.step {
        case .starting:
            ProgressView("Request permissions and start capture…")
        case .recording:
            Text(Transcript.timestamp(model.elapsedSeconds)).font(
                .system(size: 52, weight: .medium, design: .monospaced))
            meter("Microphone", level: model.microphoneLevel, silence: model.microphoneSilenceSeconds)
            if model.isCall { meter("System audio", level: model.systemLevel, silence: model.systemSilenceSeconds) }
            Text(String(format: "%.2f MB on disk", Double(model.diskBytes) / 1_000_000)).foregroundStyle(.secondary)
            Text(JobProgress.tierHint(durationSeconds: model.elapsedSeconds)).font(.callout)
        case .preparing:
            ProgressView(value: model.fraction)
            Text("Current operation: \(Int(model.fraction * 100))%").font(.caption.monospacedDigit())
        case .uploading:
            ProgressView(value: model.fraction)
            Text(
                String(
                    format: "%.2f / %.2f MB · %.0f%%", Double(model.sentBytes) / 1_000_000,
                    Double(model.totalBytes) / 1_000_000, model.fraction * 100)
            ).monospacedDigit()
        case .transcribing:
            ProgressView("The provider transcribes the audio…")
            Text(
                String(
                    format: "%.0f s elapsed · about %.0f s total", model.elapsedSeconds,
                    JobProgress.estimateSeconds(durationSeconds: model.durationSeconds))
            ).monospacedDigit()
            Text("The estimate uses earlier trials. Actual time varies.").font(.caption).foregroundStyle(.secondary)
        case .saved:
            if let summary = model.summary { summaryView(summary) }
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title2)
        case .idle: EmptyView()
        }
    }
    private func meter(_ title: String, level: AudioLevel, silence: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle().fill(level.hasSignal ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(title)
                Spacer()
                Text(String(format: "RMS %.3f · peak %.3f · %.1f dBFS", level.rms, level.peak, level.decibelsFullScale))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, max(0, (level.decibelsFullScale + 60) / 60))).tint(
                level.hasSignal ? .green : .orange)
            if silence >= 3 { Text("No signal for \(Int(silence)) s").font(.caption).foregroundStyle(.orange) }
        }
    }
    private func summaryView(_ metadata: ItemMetadata) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Transcript saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text(
                "\(Transcript.duration(metadata.durationSeconds)) · \(metadata.speakerCount) speakers · \(metadata.wordCount) words"
            )
            Text("\(cost(metadata.costUsd)) · \(metadata.model ?? "Model not reported")").foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var currentActions: some View {
        if model.canStop {
            Button(model.state.step == .starting ? "Cancel setup" : "Stop recording", action: model.stop).buttonStyle(
                .borderedProminent)
        }
        if let folder = model.folder {
            HStack {
                if model.state.step == .saved {
                    Button("Open transcript") { model.open(folder.appendingPathComponent("transcript.md")) }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                if model.state.step == .failed, let item = model.library.first(where: { $0.folder == folder }),
                    item.canRetry
                {
                    Button("Retry…") { model.retry(item) }
                }
            }
        }
    }
    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Library", systemImage: "books.vertical").font(.title2.bold())
            if let error = model.libraryError { Text(error).foregroundStyle(.red) }
            if model.library.isEmpty { Text("No saved items yet.").foregroundStyle(.secondary) }
            ForEach(model.library) { item in libraryRow(item) }
        }
    }
    private func libraryRow(_ item: PraatvolCore.LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: item.metadata.kind == "Call" ? "phone" : item.metadata.kind == "Room" ? "mic" : "doc")
                    .font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(item.metadata.kind).font(.headline)
                    Text(item.metadata.date, format: .dateTime.year().month().day().hour().minute().second())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.status.rawValue).font(.caption.bold()).padding(7).background(.thinMaterial, in: Capsule())
            }
            Text(
                "\(Transcript.duration(item.metadata.durationSeconds)) · \(item.metadata.speakerCount) speakers · \(cost(item.metadata.costUsd))"
            )
            .font(.callout).foregroundStyle(.secondary)
            if let message = item.metadata.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Open transcript") { model.open(item.transcript) }.disabled(item.status != .transcribed)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
                if item.canRetry { Button("Transcribe again…") { model.retry(item) }.disabled(model.busy) }
            }
        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    private func cost(_ value: Double?) -> String {
        value.map { String(format: "$%.6f USD", $0) } ?? "Cost not reported"
    }
}
