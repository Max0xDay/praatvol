import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import PraatvolCore

final class TrackWriter {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var firstSampleSeconds: Double?
    private var lastSampleSeconds: Double?
    private var failure: Error?
    private var level = AudioLevel.silence
    private var lastSignalSeconds = ProcessInfo.processInfo.systemUptime
    let format: AVAudioFormat

    init(url: URL, format: AVAudioFormat) throws {
        self.format = format
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                              commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    func write(_ buffer: AVAudioPCMBuffer, startSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil, let file else { return }
        do {
            try file.write(from: buffer)
            level = try AudioLevel.measure(buffer)
            if level.hasSignal { lastSignalSeconds = ProcessInfo.processInfo.systemUptime }
            if firstSampleSeconds == nil { firstSampleSeconds = startSeconds }
            lastSampleSeconds = ProcessInfo.processInfo.systemUptime
        } catch {
            failure = error
            AppLog.shared.event("capture-write-failed", code: (error as NSError).code)
        }
    }

    func snapshot() -> (start: Double?, last: Double?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (firstSampleSeconds, lastSampleSeconds, failure)
    }
    func meter() -> (level: AudioLevel, silenceSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        let uptime = ProcessInfo.processInfo.systemUptime
        // #COMPLETION_DRIVE: A 0.3-second callback gap means the displayed level is stale, not current signal.
        // #SUGGEST_VERIFY: Check low-rate hardware and idle playback during manual tests.
        let currentLevel = uptime - (lastSampleSeconds ?? 0) <= 0.3 ? level : AudioLevel.silence
        return (currentLevel, max(0, uptime - lastSignalSeconds))
    }
    func close() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
    }
}

final class SystemAudioRecorder {
    private var tapIdentifier = AudioObjectID(kAudioObjectUnknown)
    private var deviceIdentifier = AudioObjectID(kAudioObjectUnknown)
    private var inputOutputProcedure: AudioDeviceIOProcID?
    private var started = false
    private let writingQueue = DispatchQueue(label: "praatvol.system-audio.write")
    private(set) var writer: TrackWriter?

    func start(url: URL) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "praatvol system audio tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try checkStatus(AudioHardwareCreateProcessTap(description, &tapIdentifier), "Create system audio tap")
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "praatvol private capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                            kAudioSubTapDriftCompensationKey: true]]
        ]
        try checkStatus(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceIdentifier), "Create private audio device")
        var stream = AudioStreamBasicDescription()
        try AudioDevices.property(tapIdentifier, selector: kAudioTapPropertyFormat, value: &stream)
        guard let format = AVAudioFormat(streamDescription: &stream) else {
            throw PraatvolError("The system tap uses an unsupported format.")
        }
        let writer = try TrackWriter(url: url, format: format)
        self.writer = writer
        try checkStatus(AudioDeviceCreateIOProcIDWithBlock(&inputOutputProcedure, deviceIdentifier, writingQueue) {
            _, inputBuffers, inputTime, _, _ in
            guard inputBuffers.pointee.mNumberBuffers > 0,
                  inputBuffers.pointee.mBuffers.mDataByteSize > 0 else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputBuffers, deallocator: nil) else {
                AppLog.shared.event("invalid-system-buffer")
                return
            }
            let timestamp = inputTime.pointee
            let startSeconds: Double
            if timestamp.mFlags.contains(.hostTimeValid) {
                startSeconds = AVAudioTime.seconds(forHostTime: timestamp.mHostTime)
            } else {
                // #COMPLETION_DRIVE: A callback without host time arrives at the buffer's end, as in tap.swift.
                // #SUGGEST_VERIFY: Measure latency and alignment with a headset during the manual call test.
                startSeconds = ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / format.sampleRate
            }
            writer.write(buffer, startSeconds: startSeconds)
        }, "Create tap callback")
        try checkStatus(AudioDeviceStart(deviceIdentifier, inputOutputProcedure), "Start system audio")
        started = true
    }

    func stop() -> [String] {
        var warnings: [String] = []
        func cleanup(_ status: OSStatus, _ operation: String) {
            if status != noErr {
                AppLog.shared.event("tap-cleanup-failed", code: Int(status))
                warnings.append("\(operation) failed (\(status)). Relaunch the app before another call.")
            }
        }
        if started {
            cleanup(AudioDeviceStop(deviceIdentifier, inputOutputProcedure), "Stop system audio")
            started = false
        }
        if let inputOutputProcedure {
            cleanup(AudioDeviceDestroyIOProcID(deviceIdentifier, inputOutputProcedure), "Remove system callback")
            self.inputOutputProcedure = nil
        }
        writingQueue.sync { writer?.close() }
        if deviceIdentifier != kAudioObjectUnknown {
            cleanup(AudioHardwareDestroyAggregateDevice(deviceIdentifier), "Remove private audio device")
            deviceIdentifier = AudioObjectID(kAudioObjectUnknown)
        }
        if tapIdentifier != kAudioObjectUnknown {
            cleanup(AudioHardwareDestroyProcessTap(tapIdentifier), "Remove system tap")
            tapIdentifier = AudioObjectID(kAudioObjectUnknown)
        }
        return warnings
    }
}

struct CapturedItem {
    let folder: URL
    let date: Date
    let microphone: URL
    let system: URL?
    let offsetSeconds: Double
    let sources: String
    let warnings: [String]
}

final class Recorder {
    private lazy var engine = AVAudioEngine()
    private let systemRecorder = SystemAudioRecorder()
    private var microphoneWriter: TrackWriter?
    private var systemWriter: TrackWriter?
    private var installedTap = false
    private(set) var folder: URL?
    private var date = Date()
    private var isCall = false
    private var microphoneName = ""
    private let cancellationLock = NSLock()
    private var cancelled = false
    private let meterLock = NSLock()

    func cancelStart() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
    }

    private func checkCancellation() throws {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        guard !cancelled else { throw PraatvolError("Capture setup was cancelled. Check capture permissions before another attempt.") }
    }

    func meters() -> (microphone: (AudioLevel, Double), system: (AudioLevel, Double)?) {
        meterLock.lock()
        defer { meterLock.unlock() }
        let microphone = microphoneWriter?.meter() ?? (.silence, 0)
        return (microphone, systemWriter?.meter())
    }

    func start(call: Bool, preferences: Preferences) throws {
        date = Date()
        isCall = call
        let folder = try Storage.createFolder(root: AppIdentity.root, date: date, kind: call ? "Call" : "Room")
        self.folder = folder
        try Library.save(ItemMetadata(date: date, kind: call ? "Call" : "Room", sources: "Capture setup"), folder: folder)
        do {
            try checkCancellation()
            let device = try AudioDevices.selected(preferences.microphoneIdentifier)
            microphoneName = device.name
            let input = engine.inputNode
            guard let audioUnit = input.audioUnit else { throw PraatvolError("The microphone audio unit is unavailable.") }
            var identifier = device.identifier
            try checkStatus(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &identifier, UInt32(MemoryLayout<AudioDeviceID>.size)), "Select microphone")
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw PraatvolError(Self.microphoneHelp) }
            let writer = try TrackWriter(url: folder.appendingPathComponent("mic.caf"), format: format)
            meterLock.lock()
            microphoneWriter = writer
            meterLock.unlock()
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                // #COMPLETION_DRIVE: Without host time, the microphone callback arrives at the buffer's end.
                // #SUGGEST_VERIFY: Compare alignment with a known simultaneous sound in both tracks.
                let start = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) :
                    ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / buffer.format.sampleRate
                writer.write(buffer, startSeconds: start)
            }
            installedTap = true
            engine.prepare()
            try checkCancellation()
            try engine.start()
            try checkCancellation()
            if call {
                try systemRecorder.start(url: folder.appendingPathComponent("system.caf"))
                meterLock.lock()
                systemWriter = systemRecorder.writer
                meterLock.unlock()
            }
            try checkCancellation()
            AppLog.shared.event(call ? "call-started" : "room-started")
        } catch {
            _ = stop()
            throw error
        }
    }

    static let microphoneHelp = "No microphone audio arrived. Allow access in System Settings > Privacy & Security > Microphone. Check Sound > Input, then relaunch the app. The raw audio stays saved."
    static let systemHelp = "The system track is silent or empty. Start playback and allow access in System Settings > Privacy & Security > Screen & System Audio Recording (or System Audio Recording), then relaunch the app. The microphone track stays saved."

    func microphoneProblem() -> Bool {
        guard let snapshot = microphoneWriter?.snapshot() else { return true }
        if snapshot.error != nil { return true }
        guard let last = snapshot.last else { return true }
        return ProcessInfo.processInfo.systemUptime - last > 5
    }

    func stop() -> CapturedItem? {
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        microphoneWriter?.close()
        var warnings = systemRecorder.stop()
        guard let folder, let microphoneWriter else { return nil }
        let microphone = microphoneWriter.snapshot()
        let system = systemRecorder.writer?.snapshot()
        if microphone.error != nil { warnings.append("The microphone file write failed. The partial audio stays saved.") }
        if system?.error != nil { warnings.append("The system file write failed. The partial audio stays saved.") }
        if let microphoneLast = microphone.last, let systemLast = system?.last {
            // #COMPLETION_DRIVE: A five-second callback gap suggests idle playback or an output change.
            // #SUGGEST_VERIFY: Inspect both raw tracks before another call after a device change.
            if microphoneLast - systemLast > 5 {
                warnings.append("System audio ended early. Playback may be idle, or the output device changed. The raw tracks stay saved.")
            }
        }
        let offset: Double
        if let microphoneStart = microphone.start, let systemStart = system?.start {
            offset = systemStart - microphoneStart
        } else {
            // #COMPLETION_DRIVE: Empty tracks have no timestamp; zero offset preserves the available track.
            // #SUGGEST_VERIFY: The pipeline reports silent tracks before upload.
            offset = 0
        }
        var sources = "mic: \(microphoneName) (\(microphoneWriter.format.sampleRate) Hz, \(microphoneWriter.format.channelCount) channels)"
        if let writer = systemRecorder.writer {
            sources += "; system: global playback (\(writer.format.sampleRate) Hz, \(writer.format.channelCount) channels)"
        }
        do {
            var metadata = try Library.load(folder: folder)
            metadata.sources = sources
            metadata.offsetSeconds = offset
            try Library.save(metadata, folder: folder)
        } catch {
            AppLog.shared.event("capture-metadata-failed", code: (error as NSError).code)
            warnings.append("The app could not save capture metadata. Inspect the raw tracks before retry.")
        }
        return CapturedItem(folder: folder, date: date, microphone: folder.appendingPathComponent("mic.caf"),
                            system: isCall ? folder.appendingPathComponent("system.caf") : nil,
                            offsetSeconds: offset, sources: sources, warnings: warnings)
    }
}
