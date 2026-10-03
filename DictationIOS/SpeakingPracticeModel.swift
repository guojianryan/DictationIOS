import AVFoundation
import Combine
import Foundation
import NaturalLanguage
import Speech
import UIKit

struct SpokenWordResult: Identifiable {
    let id: Int
    let text: String
    let isRecognized: Bool
}

/// Records the learner speaking the current sentence, transcribes it live with
/// on-device speech recognition when available, and scores how much of the
/// expected sentence was recognized.
@MainActor
final class SpeakingPracticeModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var recognizedText = ""
    @Published private(set) var wordResults: [SpokenWordResult] = []
    @Published private(set) var score: Int?
    @Published private(set) var attemptCount = 0
    @Published private(set) var errorMessage: LocalizableText?
    @Published private(set) var hasRecording = false
    @Published private(set) var isPlaying = false

    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var expectedText = ""
    private var localeIdentifier = "en-US"
    private var silenceTimeout: Task<Void, Never>?
    private var activeAttempt = 0
    private let hapticFeedback = UINotificationFeedbackGenerator()
    private var recordingFile: RecordingFileWriter?
    private var player: AVAudioPlayer?
    private var playbackEnd: Task<Void, Never>?
    private let recordingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("speaking-attempt")
        .appendingPathExtension("caf")

    func reset() {
        cancelRecognition()
        stopPlaying()
        deleteRecording()
        recognizedText = ""
        wordResults = []
        score = nil
        attemptCount = 0
        errorMessage = nil
    }

    func toggleRecording(expectedText: String, localeIdentifier: String) {
        if isRecording {
            finishRecording()
        } else {
            Task { await startRecording(expectedText: expectedText, localeIdentifier: localeIdentifier) }
        }
    }

    private func startRecording(expectedText: String, localeIdentifier: String) async {
        errorMessage = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access was denied. Allow it in Settings > Privacy & Security > Microphone, then try again."
            return
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            errorMessage = "Speech recognition permission was denied. Allow it in Settings, then try again."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            errorMessage = "Speech recognition is not available for this language right now."
            return
        }

        cancelRecognition()
        stopPlaying()
        deleteRecording()
        self.expectedText = expectedText
        self.localeIdentifier = localeIdentifier
        recognizedText = ""
        wordResults = []
        score = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = [expectedText]

        let engine = AVAudioEngine()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let file = try RecordingFileWriter(url: recordingURL, format: format)
            recordingFile = file
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(appendingTo: request, file: file))
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            recordingFile = nil
            deleteRecording()
            errorMessage = .format("Recording could not be started: %@", error.localizedDescription)
            return
        }

        self.audioEngine = engine
        self.request = request
        isRecording = true
        activeAttempt += 1
        let attempt = activeAttempt

        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] text, isFinal, failed in
            guard let self, self.activeAttempt == attempt else { return }
            if let text {
                self.recognizedText = text
                self.restartSilenceTimeout()
            }
            if isFinal || (failed && self.isRecording) {
                self.completeAttempt()
            }
        })
        restartSilenceTimeout()
    }

    /// Stops listening; the recognizer then delivers its final result.
    func finishRecording() {
        guard isRecording else { return }
        stopAudio()
        request?.endAudio()
        // Fall back to the latest partial result if no final result arrives.
        let attempt = activeAttempt
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.activeAttempt == attempt, self.task != nil else { return }
            self.completeAttempt()
        }
    }

    private func completeAttempt() {
        guard task != nil else { return }
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        grade()
    }

    private func grade() {
        let expected = Self.words(in: expectedText, localeIdentifier: localeIdentifier)
        let spoken = Self.words(in: recognizedText, localeIdentifier: localeIdentifier)
        guard !expected.isEmpty else { return }

        let alignment = DictationModel.alignWords(spoken.map(\.key), expected.map(\.key))
        var recognizedIndices = Set<Int>()
        for (index, matched) in alignment.typedMatches.enumerated() where matched {
            if let expectedIndex = alignment.typedExpectedIndices[index] {
                recognizedIndices.insert(expectedIndex)
            }
        }
        wordResults = expected.enumerated().map { index, word in
            SpokenWordResult(id: index, text: word.display, isRecognized: recognizedIndices.contains(index))
        }

        // Extra words that were not in the sentence lower the score too.
        let extraWords = alignment.typedMatches.filter { !$0 }.count
        let missed = expected.count - recognizedIndices.count
        let mistakes = max(missed, extraWords)
        let rating = max(0, Int((1 - Double(mistakes) / Double(expected.count)) * 100))
        score = recognizedText.isEmpty ? 0 : rating
        attemptCount += 1
        hapticFeedback.notificationOccurred(rating == 100 ? .success : .warning)
    }

    /// Stops automatically after a pause in speech, or if nothing is heard at all.
    private func restartSilenceTimeout() {
        silenceTimeout?.cancel()
        let delay: Duration = recognizedText.isEmpty ? .seconds(8) : .milliseconds(2500)
        silenceTimeout = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.finishRecording()
        }
    }

    private func stopAudio() {
        silenceTimeout?.cancel()
        silenceTimeout = nil
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        if recordingFile != nil {
            // Releasing the writer closes the file so it can be played back.
            recordingFile = nil
            hasRecording = FileManager.default.fileExists(atPath: recordingURL.path)
        }
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func cancelRecognition() {
        activeAttempt += 1
        stopAudio()
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            stopPlaying()
            return
        }
        guard hasRecording, !isRecording else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: recordingURL)
            guard player.play() else { return }
            self.player = player
            isPlaying = true
            let duration = player.duration
            playbackEnd = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration + 0.1))
                guard !Task.isCancelled else { return }
                self?.stopPlaying()
            }
        } catch {
            errorMessage = "Audio playback could not be started."
        }
    }

    private func stopPlaying() {
        playbackEnd?.cancel()
        playbackEnd = nil
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func deleteRecording() {
        try? FileManager.default.removeItem(at: recordingURL)
        hasRecording = false
    }

    // Audio and recognition callbacks arrive on background threads, so they are
    // built outside the main actor and hop back to it explicitly.
    private nonisolated static func tapBlock(
        appendingTo request: SFSpeechAudioBufferRecognitionRequest,
        file: RecordingFileWriter
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            file.write(buffer)
        }
    }

    private nonisolated static func resultHandler(
        _ handler: @escaping @MainActor (String?, Bool, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in handler(text, isFinal, failed) }
        }
    }

    private static func words(in text: String, localeIdentifier: String) -> [(display: String, key: String)] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let language = DictationModel.languageCode(for: localeIdentifier)
        if !language.isEmpty {
            tokenizer.setLanguage(NLLanguage(rawValue: language))
        }
        var words: [(display: String, key: String)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            let key = String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            if !key.isEmpty {
                words.append((word, key))
            }
            return true
        }
        return words
    }
}

/// Writes microphone buffers to disk from the audio thread.
private nonisolated final class RecordingFileWriter: @unchecked Sendable {
    private let file: AVAudioFile

    init(url: URL, format: AVAudioFormat) throws {
        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        try? file.write(from: buffer)
    }
}
