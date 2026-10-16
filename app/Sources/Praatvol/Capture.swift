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
    private var lastFrameEndSeconds: Double?
    private var resuming = false
    private var failure: Error?
    private var level = AudioLevel.silence
    private var lastSignalSeconds = ProcessInfo.processInfo.systemUptime
    let format: AVAudioFormat

    init(url: URL, format: AVAudioFormat) throws {
        self.format = format
        file = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    func write(_ buffer: AVAudioPCMBuffer, startSeconds: Double, converter: AVAudioConverter? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil, let file else { return }
        guard buffer.frameLength > 0 else { return }
        do {
            if resuming {
                try writeGap(until: startSeconds, file: file)
                resuming = false
            }
            if let converter {
                try writeConverted(buffer, converter: converter, file: file)
            } else {
                try file.write(from: buffer)
            }
            level = try AudioLevel.measure(buffer)
            if level.hasSignal { lastSignalSeconds = ProcessInfo.processInfo.systemUptime }
            if firstSampleSeconds == nil { firstSampleSeconds = startSeconds }
            lastSampleSeconds = ProcessInfo.processInfo.systemUptime
            lastFrameEndSeconds = startSeconds + Double(buffer.frameLength) / buffer.format.sampleRate
        } catch {
            failure = error
            AppLog.shared.event("capture-write-failed", code: (error as NSError).code)
        }
    }

    func resume() {
        lock.lock()
        resuming = true
        lock.unlock()
    }

    private func writeGap(until startSeconds: Double, file: AVAudioFile) throws {
        guard let lastFrameEndSeconds else { return }
        var remaining = Int64(max(0, startSeconds - lastFrameEndSeconds) * format.sampleRate)
        guard remaining > 0 else { return }
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw PraatvolError("Cannot preserve the microphone change gap.")
        }
        silence.frameLength = silence.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            buffer.mData?.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize))
        }
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, 8192))
            try file.write(from: silence)
            remaining -= Int64(silence.frameLength)
        }
    }

    private func writeConverted(
        _ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, file: AVAudioFile
    ) throws {
        let capacity =
            AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate))
            + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw PraatvolError("Cannot allocate a replacement microphone buffer.")
        }
        var supplied = false
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            var conversionError: NSError?
            status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if let conversionError { throw conversionError }
            guard status != .error else { throw PraatvolError("Replacement microphone conversion failed.") }
            if converted.frameLength > 0 { try file.write(from: converted) }
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
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        try checkStatus(
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceIdentifier),
            "Create private audio device")
        var stream = AudioStreamBasicDescription()
        try AudioDevices.property(tapIdentifier, selector: kAudioTapPropertyFormat, value: &stream)
        guard let format = AVAudioFormat(streamDescription: &stream) else {
            throw PraatvolError("The system tap uses an unsupported format.")
        }
        let writer = try TrackWriter(url: url, format: format)
        self.writer = writer
        try checkStatus(
            AudioDeviceCreateIOProcIDWithBlock(&inputOutputProcedure, deviceIdentifier, writingQueue) {
                _, inputBuffers, inputTime, _, _ in
                guard inputBuffers.pointee.mNumberBuffers > 0,
                    inputBuffers.pointee.mBuffers.mDataByteSize > 0
                else { return }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputBuffers, deallocator: nil)
                else {
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
    private var chosenMicrophoneIdentifier: String?
    private var resolvedMicrophoneName = ""
    private var activeMicrophone: MicrophoneDevice?
    private var deviceListChanged = false
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private let deviceListenerQueue = DispatchQueue(label: "praatvol.microphone-devices")
    private var captureWarnings: [String] = []

    var warnings: [String] {
        meterLock.lock()
        defer { meterLock.unlock() }
        return captureWarnings
    }
    private var systemCaptureActive = false
    var microphoneName: String {
        meterLock.lock()
        defer { meterLock.unlock() }
        return resolvedMicrophoneName
    }
    var capturingSystem: Bool {
        meterLock.lock()
        defer { meterLock.unlock() }
        return systemCaptureActive
    }
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
        guard !cancelled else {
            throw PraatvolError("Capture setup was cancelled. Check capture permissions before another attempt.")
        }
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
        chosenMicrophoneIdentifier = preferences.microphoneIdentifier
        let folder = try Storage.createFolder(root: AppIdentity.root, date: date, kind: call ? "Call" : "Room")
        self.folder = folder
        try Library.save(
            ItemMetadata(date: date, kind: call ? "Call" : "Room", sources: "Capture setup"), folder: folder)
        do {
            try checkCancellation()
            let device: MicrophoneDevice
            if call {
                guard
                    let callMicrophone = try AudioDevices.candidates(
                        call: true, chosenIdentifier: chosenMicrophoneIdentifier
                    ).first
                else {
                    throw PraatvolError("No call microphone is available. Connect a microphone and try again.")
                }
                device = callMicrophone
            } else {
                guard let builtInOrWired = try AudioDevices.candidates(call: false).first else {
                    throw PraatvolError(
                        "No suitable room microphone is available. Connect a wired microphone or use the built-in microphone."
                    )
                }
                device = builtInOrWired
            }
            try startMicrophone(device, folder: folder)
            try listenForDeviceChanges()
            try checkCancellation()
            if call {
                try systemRecorder.start(url: folder.appendingPathComponent("system.caf"))
                meterLock.lock()
                systemWriter = systemRecorder.writer
                systemCaptureActive = true
                meterLock.unlock()
            }
            try checkCancellation()
            AppLog.shared.event(call ? "call-started" : "room-started")
        } catch {
            _ = stop()
            throw error
        }
    }

    private func startMicrophone(_ device: MicrophoneDevice, folder: URL) throws {
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            throw PraatvolError("The microphone audio unit is unavailable.")
        }
        var identifier = device.identifier
        try checkStatus(
            AudioUnitSetProperty(
                audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &identifier, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "Select microphone")
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw PraatvolError(Self.microphoneHelp) }
        let writer = try microphoneWriter ?? TrackWriter(url: folder.appendingPathComponent("mic.caf"), format: format)
        let converter: AVAudioConverter?
        if format == writer.format {
            converter = nil
        } else {
            guard let replacementConverter = AVAudioConverter(from: format, to: writer.format) else {
                throw PraatvolError("The replacement microphone format cannot be converted.")
            }
            converter = replacementConverter
        }
        if microphoneWriter != nil { writer.resume() }
        meterLock.lock()
        microphoneWriter = writer
        resolvedMicrophoneName = device.name
        activeMicrophone = device
        meterLock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            // #COMPLETION_DRIVE: Without host time, the microphone callback arrives at the buffer's end.
            // #SUGGEST_VERIFY: Compare alignment with a known simultaneous sound in both tracks.
            let start =
                time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / buffer.format.sampleRate
            writer.write(buffer, startSeconds: start, converter: converter)
        }
        installedTap = true
        engine.prepare()
        try checkCancellation()
        try engine.start()
        AppLog.shared.event("microphone-selected name=\(device.name)")
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func listenForDeviceChanges() throws {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.meterLock.lock()
            self.deviceListChanged = true
            self.meterLock.unlock()
        }
        var address = Self.devicesAddress
        try checkStatus(
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, deviceListenerQueue, listener),
            "Watch microphone devices")
        deviceListener = listener
    }

    private func stopMicrophoneEngine() {
        engine.stop()
        if installedTap {
            engine.inputNode.removeTap(onBus: 0)
            installedTap = false
        }
    }

    func recoverMicrophoneIfNeeded() -> Bool {
        meterLock.lock()
        let listChanged = deviceListChanged
        deviceListChanged = false
        let previous = activeMicrophone
        meterLock.unlock()
        do {
            let devices = try AudioDevices.microphones()
            let present = devices.contains { $0.uniqueIdentifier == previous?.uniqueIdentifier }
            if present, !microphoneProblem() { return true }
            guard let previous, let folder else { return false }
            AppLog.shared.event(listChanged ? "microphone-disconnected" : "microphone-stalled")
            let candidates = try AudioDevices.candidates(
                call: isCall, chosenIdentifier: chosenMicrophoneIdentifier, excluding: previous.uniqueIdentifier)
            stopMicrophoneEngine()
            for candidate in candidates {
                try checkCancellation()
                engine = AVAudioEngine()
                do {
                    let attemptStarted = ProcessInfo.processInfo.systemUptime
                    try startMicrophone(candidate, folder: folder)
                    if try waitForMicrophone(since: attemptStarted) {
                        recordSwap(from: previous.name, to: candidate.name)
                        return true
                    }
                    AppLog.shared.event("microphone-replacement-stalled")
                } catch {
                    AppLog.shared.event("microphone-replacement-failed", code: (error as NSError).code)
                }
                stopMicrophoneEngine()
            }
        } catch {
            AppLog.shared.event("microphone-recovery-failed", code: (error as NSError).code)
        }
        meterLock.lock()
        captureWarnings.append("No replacement microphone was available. The partial audio stays saved.")
        meterLock.unlock()
        return false
    }

    private func waitForMicrophone(since attemptStarted: Double) throws -> Bool {
        // #COMPLETION_DRIVE: A first callback within three seconds establishes a working replacement input.
        // #SUGGEST_VERIFY: Disconnect wired and Bluetooth inputs on hardware; Apple start calls cannot be interrupted.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            try checkCancellation()
            let snapshot = microphoneWriter?.snapshot()
            if snapshot?.error != nil { return false }
            if let last = snapshot?.last, last > attemptStarted { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func recordSwap(from previous: String, to replacement: String) {
        let elapsed = Transcript.timestamp(Date().timeIntervalSince(date))
        let warning = "Microphone changed from \(previous) to \(replacement) at \(elapsed)"
        meterLock.lock()
        captureWarnings.append(warning)
        meterLock.unlock()
        AppLog.shared.event("microphone-swapped from=\(previous) to=\(replacement)")
        guard let folder else { return }
        do {
            var metadata = try Library.load(folder: folder)
            metadata.warnings = warnings
            try Library.save(metadata, folder: folder)
        } catch {
            AppLog.shared.event("microphone-warning-save-failed", code: (error as NSError).code)
        }
    }

    static let microphoneHelp =
        "No microphone audio arrived. Allow access in System Settings > Privacy & Security > Microphone. Check Sound > Input, then relaunch the app. The raw audio stays saved."
    static let systemHelp =
        "The system track is silent or empty. Start playback and allow access in System Settings > Privacy & Security > Screen & System Audio Recording (or System Audio Recording), then relaunch the app. The microphone track stays saved."

    func microphoneProblem() -> Bool {
        meterLock.lock()
        defer { meterLock.unlock() }
        if deviceListChanged { return true }
        guard let snapshot = microphoneWriter?.snapshot() else { return true }
        if snapshot.error != nil { return true }
        guard let last = snapshot.last else { return true }
        return ProcessInfo.processInfo.systemUptime - last > 5
    }

    private func removeDeviceListener() {
        if let deviceListener {
            var address = Self.devicesAddress
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, deviceListenerQueue, deviceListener)
            if status != noErr { AppLog.shared.event("microphone-listener-removal-failed", code: Int(status)) }
            self.deviceListener = nil
        }
    }

    func stop() -> CapturedItem? {
        removeDeviceListener()
        stopMicrophoneEngine()
        microphoneWriter?.close()
        var warnings = self.warnings + systemRecorder.stop()
        meterLock.lock()
        systemCaptureActive = false
        meterLock.unlock()
        guard let folder, let microphoneWriter else { return nil }
        let microphone = microphoneWriter.snapshot()
        let system = systemRecorder.writer?.snapshot()
        if microphone.error != nil {
            warnings.append("The microphone file write failed. The partial audio stays saved.")
        }
        if system?.error != nil { warnings.append("The system file write failed. The partial audio stays saved.") }
        if let microphoneLast = microphone.last, let systemLast = system?.last {
            // #COMPLETION_DRIVE: A five-second callback gap suggests idle playback or an output change.
            // #SUGGEST_VERIFY: Inspect both raw tracks before another call after a device change.
            if microphoneLast - systemLast > 5 {
                warnings.append(
                    "System audio ended early. Playback may be idle, or the output device changed. The raw tracks stay saved."
                )
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
        var sources =
            "mic: \(microphoneName) (\(microphoneWriter.format.sampleRate) Hz, \(microphoneWriter.format.channelCount) channels)"
        if let writer = systemRecorder.writer {
            sources +=
                "; system: global playback (\(writer.format.sampleRate) Hz, \(writer.format.channelCount) channels)"
        }
        do {
            var metadata = try Library.load(folder: folder)
            metadata.sources = sources
            metadata.offsetSeconds = offset
            metadata.warnings = warnings
            try Library.save(metadata, folder: folder)
        } catch {
            AppLog.shared.event("capture-metadata-failed", code: (error as NSError).code)
            warnings.append("The app could not save capture metadata. Inspect the raw tracks before retry.")
        }
        return CapturedItem(
            folder: folder, date: date, microphone: folder.appendingPathComponent("mic.caf"),
            system: isCall ? folder.appendingPathComponent("system.caf") : nil,
            offsetSeconds: offset, sources: sources, warnings: warnings)
    }
}
