import Foundation
import Speech
import AVFoundation

/// Native macOS voice dictation built on `SFSpeechRecognizer` + `AVAudioEngine`.
///
/// Captures the microphone, streams audio to Apple's speech recognizer and
/// reports partial transcriptions live. Recognition runs in short segments that
/// are stitched together so dictation continues uninterrupted across pauses.
/// On-device recognition is preferred when the language model is installed —
/// it's private and has no server time limit.
final class DictationManager: NSObject {

    enum DictationError: LocalizedError {
        case denied
        case recognizerUnavailable
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {
            case .denied: return "Allow microphone & speech in System Settings"
            case .recognizerUnavailable: return "Dictation isn't available for this language"
            case .microphoneUnavailable: return "Couldn't access the microphone"
            }
        }
    }

    // Callbacks are always delivered on the main thread.
    var onText: ((String) -> Void)?    // full spoken transcription so far
    var onLevel: ((Float) -> Void)?    // live audio level, 0…1
    var onError: ((Error) -> Void)?
    var onStop: (() -> Void)?

    private(set) var isRunning = false

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Finalized segments joined together; the active segment is appended live.
    private var committedText = ""
    private var segmentStart = Date()
    private var segmentProducedText = false
    private var didRetryStart = false

    // MARK: - Authorization

    /// Requests both Speech and Microphone access, calling back on the main thread.
    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                DispatchQueue.main.async { completion(true) }
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async { completion(granted) }
                }
            default:
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    // MARK: - Control

    /// Starts dictation for the given language code ("auto"/"system" → device language).
    func start(localeCode: String) {
        DebugLog.log("DictationManager.start(localeCode=\(localeCode))")
        guard !isRunning else { return }

        guard let recognizer = Self.makeRecognizer(localeCode: localeCode), recognizer.isAvailable else {
            DebugLog.log("recognizer unavailable")
            onError?(DictationError.recognizerUnavailable)
            return
        }
        DebugLog.log("recognizer ok onDevice=\(recognizer.supportsOnDeviceRecognition)")
        self.recognizer = recognizer
        committedText = ""
        isRunning = true

        // Use the input node's *hardware* format for the tap. Passing the node's
        // output format here can make AVAudioEngine raise an (uncatchable) NSException
        // — "required condition is false" — that aborts the whole app. A format with
        // a zero sample rate or zero channels (no/just-granted mic) would do the same,
        // so bail out gracefully instead.
        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        DebugLog.log("inputFormat sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            isRunning = false
            // The mic may have only just been authorized and the audio HAL hasn't
            // exposed it yet — give it a moment and retry once before giving up.
            if !didRetryStart {
                didRetryStart = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.start(localeCode: localeCode)
                }
                return
            }
            didRetryStart = false
            onError?(DictationError.microphoneUnavailable)
            return
        }
        didRetryStart = false

        // Tap installation and engine start can raise Objective-C NSExceptions
        // (bad format/state) that Swift can't catch — which would abort the whole
        // app. Run them through the ObjC catcher so a failure is just an error.
        var startError: Error?
        do {
            try ObjCExceptionCatcher.try {
                DebugLog.log("installing tap…")
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    self?.request?.append(buffer)
                    self?.emitLevel(from: buffer)
                }
                DebugLog.log("tap installed; preparing + starting engine…")
                self.audioEngine.prepare()
                do { try self.audioEngine.start() } catch { startError = error }
            }
        } catch {
            startError = error // NSException raised by AVAudioEngine
            DebugLog.log("‼️ ObjC exception during audio setup: \(error.localizedDescription)")
        }

        if let startError {
            DebugLog.log("start failed: \(startError.localizedDescription)")
            isRunning = false
            input.removeTap(onBus: 0)
            onError?(DictationError.microphoneUnavailable)
            return
        }

        DebugLog.log("engine started; starting recognition segment")
        startSegment()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        endSegment()
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        DispatchQueue.main.async {
            self.onLevel?(0)
            self.onStop?()
        }
    }

    // MARK: - Recognition segments

    private func startSegment() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        segmentStart = Date()
        segmentProducedText = false
        DebugLog.log("creating recognitionTask…")

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error { DebugLog.log("recognitionTask error: \(error.localizedDescription)") }

            if let result {
                let segment = result.bestTranscription.formattedString
                self.segmentProducedText = !segment.isEmpty
                let full = self.join(self.committedText, segment)
                DispatchQueue.main.async { self.onText?(full) }

                if result.isFinal {
                    self.committedText = full
                    if self.isRunning { self.restartSegment(after: nil) }
                }
                return
            }

            if let error { self.restartSegment(after: error) }
        }
    }

    private func endSegment() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    /// Recovers from a finalized/errored segment by starting a fresh one so the
    /// user can keep talking. Bails out if the recognizer keeps failing instantly.
    private func restartSegment(after error: Error?) {
        guard isRunning else { return }

        // A near-instant error with no transcription means a real failure
        // (no model, no audio) — stop instead of spinning in a restart loop.
        if error != nil, !segmentProducedText, Date().timeIntervalSince(segmentStart) < 0.6 {
            isRunning = false
            if audioEngine.isRunning {
                audioEngine.inputNode.removeTap(onBus: 0)
                audioEngine.stop()
            }
            endSegment()
            DispatchQueue.main.async {
                self.onLevel?(0)
                self.onError?(DictationError.recognizerUnavailable)
            }
            return
        }

        endSegment()
        startSegment()
    }

    // MARK: - Helpers

    private func join(_ base: String, _ next: String) -> String {
        if base.isEmpty { return next }
        if next.isEmpty { return base }
        return base + " " + next
    }

    private func emitLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(frames))

        // Map RMS to a perceptual 0…1 range via dB with a -50 dB noise floor.
        let db = 20 * log10f(max(rms, 1e-7))
        let floor: Float = -50
        let level = db < floor ? 0 : (db - floor) / (-floor)
        DispatchQueue.main.async { self.onLevel?(min(1, max(0, level))) }
    }

    private static func makeRecognizer(localeCode: String) -> SFSpeechRecognizer? {
        if localeCode == "auto" || localeCode == "system" {
            return SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer()
        }
        return SFSpeechRecognizer(locale: locale(for: localeCode)) ?? SFSpeechRecognizer()
    }

    private static func locale(for code: String) -> Locale {
        switch code {
        case "ru": return Locale(identifier: "ru-RU")
        case "en": return Locale(identifier: "en-US")
        case "sr": return Locale(identifier: "sr-RS")
        case "sl": return Locale(identifier: "sl-SI")
        default: return Locale(identifier: code)
        }
    }
}
