import AVFoundation
import CoreAudio
import Darwin
import Foundation

struct CaptureError: Error, CustomStringConvertible {
    let description: String
}

final class CaptureLog {
    private let file: FileHandle
    private let lock = NSLock()
    private(set) var failed = false

    init(path: String) throws {
        try Data().write(to: URL(fileURLWithPath: path))
        file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        print(message)
        fflush(stdout)
        do {
            try file.write(contentsOf: Data("\(Date()): \(message)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Error: Write log: \(error)\n".utf8))
            failed = true
        }
    }
}

var captureLog: CaptureLog?

func logError(_ message: String) {
    if let captureLog { captureLog.write("Error: \(message)") }
    else { FileHandle.standardError.write(Data("Error: \(message)\n".utf8)) }
}

func reportRecording(path: String) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard let sizeBytes = attributes[.size] as? NSNumber else {
        throw CaptureError(description: "Read WAV size: missing file size.")
    }
    captureLog?.write("Final file: \(path); size: \(sizeBytes) bytes")
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path),
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
          let channels = buffer.floatChannelData else {
        throw CaptureError(description: "Read WAV samples: unsupported PCM buffer.")
    }
    var peak: Float = 0
    while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else {
            throw CaptureError(description: "Read WAV samples: no progress.")
        }
        for channelIndex in 0..<Int(buffer.format.channelCount) {
            for sampleIndex in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channels[channelIndex][sampleIndex]))
            }
        }
    }
    // #COMPLETION_DRIVE: A normalized peak <= 0.00001 is considered near-zero silence.
    // #SUGGEST_VERIFY: Compare this threshold with quiet but audible playback recordings.
    let silent = peak <= 0.00001
    captureLog?.write("Silence check: frames=\(file.length), peak=\(peak), all-zero=\(peak == 0), silent=\(silent)")
}

func checkStatus(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else {
        let bytes = (0..<4).reversed().map { UInt8(truncatingIfNeeded: status >> ($0 * 8)) }
        let code = String(bytes: bytes, encoding: .ascii) ?? "unknown"
        throw CaptureError(description: "\(step) failed: OSStatus \(status) ('\(code)').")
    }
}

final class SystemAudioRecorder {
    private var tapIdentifier = AudioObjectID(kAudioObjectUnknown)
    private var deviceIdentifier = AudioObjectID(kAudioObjectUnknown)
    private var inputOutputProcedure: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var started = false
    private var finished = false
    private var writeFailed = false
    private let writingQueue = DispatchQueue(label: "praatvol.system-audio.write")
    private var interruptSource: DispatchSourceSignal?
    private var outputPath: String?
    private var firstSampleRecorded = false

    private func readProperty<Value>(
        _ objectIdentifier: AudioObjectID, _ selector: AudioObjectPropertySelector,
        into value: inout Value, step: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectIdentifier, &address, 0, nil, &size, $0)
        }
        try checkStatus(status, step)
    }

    func start(path: String) throws {
        outputPath = path
        try String(getpid()).write(toFile: path + ".pid", atomically: true, encoding: .utf8)
        captureLog?.write("Start: output \(path)")
        // 1. Privately mix all process outputs to stereo; leave playback unmuted.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "praatvol system audio tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try checkStatus(AudioHardwareCreateProcessTap(description, &tapIdentifier),
                        "AudioHardwareCreateProcessTap")

        // 2. A tap-only private aggregate needs no physical input or output device.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "praatvol private capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try checkStatus(AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &deviceIdentifier
        ), "AudioHardwareCreateAggregateDevice")

        // 3. Write PCM WAV using the tap's actual stream format.
        var streamDescription = AudioStreamBasicDescription()
        try readProperty(tapIdentifier, kAudioTapPropertyFormat, into: &streamDescription,
                         step: "Read kAudioTapPropertyFormat")
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureError(description: "Read tap format: unsupported audio format.")
        }
        audioFile = try AVAudioFile(forWriting: URL(fileURLWithPath: path),
                                    settings: format.settings, commonFormat: format.commonFormat,
                                    interleaved: format.isInterleaved)

        // 4. Consume each input buffer on a serial queue before returning it to Core Audio.
        try checkStatus(AudioDeviceCreateIOProcIDWithBlock(
            &inputOutputProcedure, deviceIdentifier, writingQueue
        ) { [self] _, inputBuffers, _, _, _ in
            write(inputBuffers, format: format)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try checkStatus(AudioDeviceStart(deviceIdentifier, inputOutputProcedure), "AudioDeviceStart")
        started = true
    }

    private func write(_ inputBuffers: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard !writeFailed else { return }
        guard inputBuffers.pointee.mNumberBuffers > 0 else { return }
        guard inputBuffers.pointee.mBuffers.mDataByteSize > 0 else { return }
        do {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, bufferListNoCopy: inputBuffers, deallocator: nil
            ) else {
                throw CaptureError(description: "Wrap tap input: invalid PCM buffer.")
            }
            guard let audioFile else {
                throw CaptureError(description: "Write WAV: file is not open.")
            }
            if !firstSampleRecorded, let outputPath {
                // #COMPLETION_DRIVE: The callback arrives at the end of its captured buffer.
                // #SUGGEST_VERIFY: Measure device latency if tighter alignment is required.
                let startSeconds = Date().timeIntervalSince1970
                    - Double(buffer.frameLength) / format.sampleRate
                try String(startSeconds).write(toFile: outputPath + ".start",
                                               atomically: true, encoding: .utf8)
                firstSampleRecorded = true
            }
            try audioFile.write(from: buffer)
        } catch {
            logError("Write WAV: \(error)")
            writeFailed = true
            DispatchQueue.main.async { self.finish(exitCode: 1) }
        }
    }

    func waitForInterrupt(seconds: Double?) -> Never {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { self.finish(exitCode: 0) }
        interruptSource = source
        source.resume()
        if let seconds {
            captureLog?.write("Recording system audio for \(seconds) seconds; Ctrl+C also stops")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                self.finish(exitCode: 0)
            }
        } else {
            captureLog?.write("Recording system audio... press Ctrl+C to stop")
        }
        dispatchMain()
    }

    // 5. Stop callbacks before releasing the file, then remove every private object.
    func cleanup() -> Bool {
        var succeeded = true
        func cleanupStatus(_ status: OSStatus, _ step: String) {
            do { try checkStatus(status, step) }
            catch { logError(String(describing: error)); succeeded = false }
        }
        if started {
            cleanupStatus(AudioDeviceStop(deviceIdentifier, inputOutputProcedure), "AudioDeviceStop")
            started = false
        }
        if let inputOutputProcedure {
            cleanupStatus(AudioDeviceDestroyIOProcID(deviceIdentifier, inputOutputProcedure),
                          "AudioDeviceDestroyIOProcID")
            self.inputOutputProcedure = nil
        }
        writingQueue.sync { audioFile = nil }
        if deviceIdentifier != kAudioObjectUnknown {
            cleanupStatus(AudioHardwareDestroyAggregateDevice(deviceIdentifier),
                          "AudioHardwareDestroyAggregateDevice")
            deviceIdentifier = AudioObjectID(kAudioObjectUnknown)
        }
        if tapIdentifier != kAudioObjectUnknown {
            cleanupStatus(AudioHardwareDestroyProcessTap(tapIdentifier), "AudioHardwareDestroyProcessTap")
            tapIdentifier = AudioObjectID(kAudioObjectUnknown)
        }
        if let outputPath {
            let pidPath = outputPath + ".pid"
            if FileManager.default.fileExists(atPath: pidPath) {
                do { try FileManager.default.removeItem(atPath: pidPath) }
                catch { logError("Remove PID file: \(error)"); succeeded = false }
            }
        }
        return succeeded
    }

    private func finish(exitCode: Int32) {
        guard !finished else { return }
        finished = true
        interruptSource?.cancel()
        captureLog?.write("Stop: finalizing WAV and removing private capture objects")
        let cleanedUp = cleanup()
        let recordingFailed = writingQueue.sync { writeFailed }
        do {
            if let outputPath { try reportRecording(path: outputPath) }
        } catch {
            logError("Inspect WAV: \(error)")
            exit(1)
        }
        if recordingFailed { exit(1) }
        if captureLog?.failed == true { exit(1) }
        exit(cleanedUp ? exitCode : 1)
    }
}

func isValidDuration(_ durationSeconds: Double) -> Bool {
    durationSeconds.isFinite && durationSeconds > 0
}

func parseArguments() throws -> (path: String, seconds: Double?) {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var seconds: Double?
    if arguments.first == "--seconds" {
        guard arguments.count == 3 else {
            throw CaptureError(description: "Usage: tap [--seconds N] /absolute/path/out.wav")
        }
        guard let durationSeconds = Double(arguments[1]), isValidDuration(durationSeconds) else {
            throw CaptureError(description: "--seconds must be a finite positive number.")
        }
        seconds = durationSeconds
        arguments.removeFirst(2)
    }
    guard arguments.count == 1 else {
        throw CaptureError(description: "Usage: tap [--seconds N] /absolute/path/out.wav")
    }
    let outputURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    guard outputURL.pathExtension.lowercased() == "wav" else {
        throw CaptureError(description: "Output must have a .wav extension.")
    }
    return (outputURL.path, seconds)
}

let recorder = SystemAudioRecorder()
do {
    let arguments = try parseArguments()
    captureLog = try CaptureLog(path: arguments.path + ".log")
    try recorder.start(path: arguments.path)
    recorder.waitForInterrupt(seconds: arguments.seconds)
} catch {
    logError(String(describing: error))
    logError("If access was denied, allow praatvol in System Settings > Privacy & Security > Screen & System Audio Recording (or System Audio Recording), then relaunch praatvol.app.")
    captureLog?.write("Stop: setup failed; removing private capture objects")
    _ = recorder.cleanup()
    exit(1)
}
