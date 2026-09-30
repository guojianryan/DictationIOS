import AVFoundation
import Combine
import CoreMedia
import Foundation
import FoundationModels
import NaturalLanguage
import Speech
import Translation
import UIKit

struct SpeechLanguage: Identifiable, Hashable {
    let identifier: String
    let name: String

    var id: String { identifier }
}

struct TranscriptSentence: Identifiable {
    let id: Int
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let originalText: String
    let mergedFrom: [TranscriptSentence]?

    init(
        id: Int,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        originalText: String? = nil,
        mergedFrom: [TranscriptSentence]? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.originalText = originalText ?? text
        self.mergedFrom = mergedFrom
    }
}

struct SentenceReviewStatus {
    let changedWords: Int
    let allowedChanges: Int
    let originalWordCount: Int
    let isEmpty: Bool

    var isOverLimit: Bool { isEmpty || changedWords > allowedChanges }
}

enum PendingImportKind {
    case audio
    case text
}

private struct SavedPracticeSession: Codable {
    let formatVersion: Int
    let audioFileName: String
    let sourceLanguageIdentifier: String
    let sourceLanguageName: String
    let translationLanguage: String
    let sentences: [SavedSentence]
    let drafts: [Int: String]
    let answerDraft: String
    let currentSentenceIndex: Int
    let currentTime: TimeInterval
    let playbackRate: Float
    let sentenceOnly: Bool
    let createdFromText: Bool
    let reviewCompleted: Bool

    private enum CodingKeys: String, CodingKey {
        case formatVersion, audioFileName, sourceLanguageIdentifier, sourceLanguageName
        case translationLanguage, sentences, drafts, answerDraft, currentSentenceIndex
        case currentTime, playbackRate, sentenceOnly, createdFromText, reviewCompleted
    }

    init(
        formatVersion: Int,
        audioFileName: String,
        sourceLanguageIdentifier: String,
        sourceLanguageName: String,
        translationLanguage: String,
        sentences: [SavedSentence],
        drafts: [Int: String],
        answerDraft: String,
        currentSentenceIndex: Int,
        currentTime: TimeInterval,
        playbackRate: Float,
        sentenceOnly: Bool,
        createdFromText: Bool,
        reviewCompleted: Bool
    ) {
        self.formatVersion = formatVersion
        self.audioFileName = audioFileName
        self.sourceLanguageIdentifier = sourceLanguageIdentifier
        self.sourceLanguageName = sourceLanguageName
        self.translationLanguage = translationLanguage
        self.sentences = sentences
        self.drafts = drafts
        self.answerDraft = answerDraft
        self.currentSentenceIndex = currentSentenceIndex
        self.currentTime = currentTime
        self.playbackRate = playbackRate
        self.sentenceOnly = sentenceOnly
        self.createdFromText = createdFromText
        self.reviewCompleted = reviewCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        audioFileName = try container.decode(String.self, forKey: .audioFileName)
        sourceLanguageIdentifier = try container.decode(String.self, forKey: .sourceLanguageIdentifier)
        sourceLanguageName = try container.decode(String.self, forKey: .sourceLanguageName)
        translationLanguage = try container.decode(String.self, forKey: .translationLanguage)
        sentences = try container.decode([SavedSentence].self, forKey: .sentences)
        drafts = try container.decode([Int: String].self, forKey: .drafts)
        answerDraft = try container.decode(String.self, forKey: .answerDraft)
        currentSentenceIndex = try container.decode(Int.self, forKey: .currentSentenceIndex)
        currentTime = try container.decode(TimeInterval.self, forKey: .currentTime)
        playbackRate = try container.decode(Float.self, forKey: .playbackRate)
        sentenceOnly = try container.decode(Bool.self, forKey: .sentenceOnly)
        createdFromText = try container.decodeIfPresent(Bool.self, forKey: .createdFromText) ?? false
        reviewCompleted = try container.decodeIfPresent(Bool.self, forKey: .reviewCompleted) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(audioFileName, forKey: .audioFileName)
        try container.encode(sourceLanguageIdentifier, forKey: .sourceLanguageIdentifier)
        try container.encode(sourceLanguageName, forKey: .sourceLanguageName)
        try container.encode(translationLanguage, forKey: .translationLanguage)
        try container.encode(sentences, forKey: .sentences)
        try container.encode(drafts, forKey: .drafts)
        try container.encode(answerDraft, forKey: .answerDraft)
        try container.encode(currentSentenceIndex, forKey: .currentSentenceIndex)
        try container.encode(currentTime, forKey: .currentTime)
        try container.encode(playbackRate, forKey: .playbackRate)
        try container.encode(sentenceOnly, forKey: .sentenceOnly)
        try container.encode(createdFromText, forKey: .createdFromText)
        try container.encode(reviewCompleted, forKey: .reviewCompleted)
    }
}

private struct SavedSentence: Codable {
    let id: Int
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let translation: String
    let originalText: String?
    let mergedFrom: [SavedSentence]?
}

private struct ReviewSnapshot {
    let sentences: [TranscriptSentence]
    let translatedSentences: [String]
    let drafts: [Int: String]
    let answerDraft: String
    let currentSentenceIndex: Int
    let sentenceOnly: Bool
}

struct PracticeWordResult: Identifiable {
    let id: Int
    let text: String
    let isCorrect: Bool
    let expectedText: String?
}

@Generable
private struct PunctuationCorrection {
    @Guide(description: "Corrected punctuation and capitalization. Preserve every original word exactly, in the same order, and return exactly one item per input sentence.")
    var sentences: [String]
}

@Generable
private struct OCRTextReformat {
    @Guide(description: "The OCR text rejoined into normal, complete sentences with every original word preserved exactly and in the same order, formatted with exactly one sentence per line.")
    var text: String
}

private struct TimedTranscriptionChunk: Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

struct TranslationLanguage: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }

    static let supported = [
        TranslationLanguage(code: "en", name: "English"),
        TranslationLanguage(code: "de", name: "German"),
        TranslationLanguage(code: "es", name: "Spanish"),
        TranslationLanguage(code: "fr", name: "French"),
        TranslationLanguage(code: "it", name: "Italian"),
        TranslationLanguage(code: "ja", name: "Japanese"),
        TranslationLanguage(code: "zh", name: "Chinese")
    ]
}

@MainActor
final class DictationModel: ObservableObject {
    @Published private(set) var speechLanguages: [SpeechLanguage]
    @Published var defaultSpeechLocale: String {
        didSet {
            guard oldValue != defaultSpeechLocale else { return }
            UserDefaults.standard.set(defaultSpeechLocale, forKey: Self.originLanguageKey)
            if sentences.isEmpty, selectedSpeechLocale == oldValue {
                selectedSpeechLocale = defaultSpeechLocale
            }
        }
    }
    @Published var defaultTranslationLanguage: String {
        didSet {
            guard oldValue != defaultTranslationLanguage else { return }
            UserDefaults.standard.set(defaultTranslationLanguage, forKey: Self.translationLanguageKey)
            if sentences.isEmpty, selectedTranslationLanguage == oldValue {
                selectedTranslationLanguage = defaultTranslationLanguage
            }
        }
    }
    @Published var selectedSpeechLocale: String
    @Published private(set) var voicePreferences: [String: String] {
        didSet {
            guard oldValue != voicePreferences else { return }
            UserDefaults.standard.set(voicePreferences, forKey: Self.voicePreferencesKey)
        }
    }
    @Published var selectedTranslationLanguage: String {
        didSet {
            guard oldValue != selectedTranslationLanguage else { return }
            guard !sentences.isEmpty else { return }
            translateTranscript()
        }
    }
    @Published private(set) var sourceLanguageName = ""
    @Published private(set) var fileName = ""
    @Published private(set) var sentences: [TranscriptSentence] = []
    @Published private(set) var translatedSentences: [String] = []
    @Published private(set) var isTranscribing = false
    @Published private(set) var isReviewing = false
    @Published private(set) var reviewExternalEditRevision = 0
    @Published private(set) var isEditingSourceText = false
    @Published var sourceTextDraft = ""
    @Published private(set) var processingTitle: LocalizableText = ""
    @Published private(set) var transcriptionMode: LocalizableText = ""
    @Published private(set) var sessionDetail: LocalizableText = ""
    @Published private(set) var pendingImportKind = PendingImportKind.audio
    @Published private(set) var isPlaying = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var hasRecordingPreview = false
    @Published private(set) var isPlayingRecording = false
    @Published private(set) var recordingPreviewTime: TimeInterval = 0
    @Published private(set) var recordingPreviewDuration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentSentenceIndex = 0
    @Published private(set) var translationStatus: LocalizableText = ""
    @Published private(set) var punctuationStatus: LocalizableText = ""
    @Published private(set) var translationConfiguration: TranslationSession.Configuration?
    @Published private(set) var errorMessage: LocalizableText?
    @Published var isSavedSessionPromptPresented = false
    @Published private(set) var pendingAudioName = ""
    @Published var playbackRate: Float = 1 {
        didSet {
            player?.rate = playbackRate
            if isPlaying, sentenceOnly {
                scheduleSentenceStopDeadline()
            }
            savePracticeSession()
        }
    }
    @Published var sentenceOnly = true {
        didSet {
            if isPlaying {
                if sentenceOnly, sentences.indices.contains(currentSentenceIndex) {
                    player?.currentTime = playbackAnchorTime(for: currentSentenceIndex)
                    currentTime = player?.currentTime ?? currentTime
                    playbackSentenceIndex = currentSentenceIndex
                    scheduleSentenceStopDeadline()
                } else {
                    playbackSentenceIndex = nil
                    cancelSentenceStopDeadline()
                }
            }
            savePracticeSession()
        }
    }
    @Published var answerDraft = ""
    @Published private(set) var practiceFeedback: LocalizableText = ""
    @Published private(set) var answerIsRevealed = false
    @Published private(set) var practiceWordResults: [PracticeWordResult] = []
    @Published private(set) var missingPracticeWords: [String] = []
    @Published private(set) var practiceGradeTitle: LocalizableText = ""
    @Published private(set) var practiceGradeScore: Int?
    @Published private(set) var gradeCheckCount = 0

    private var player: AVAudioPlayer?
    private var playbackMonitor: Task<Void, Never>?
    private var playbackSentenceIndex: Int?
    private var sentenceStopWorkItem: DispatchWorkItem?
    private var drafts: [Int: String] = [:]
    private var translationCache: [String: String] = [:]
    private var scopedAudioURL: URL?
    private var activeTranslationRequest = 0
    private var translationSessionStartedRequestID: Int?
    private var translationWatchdog: Task<Void, Never>?
    private var translationRunner: Task<Void, Never>?
    private var reviewSnapshot: ReviewSnapshot?
    private var transcriptLocaleIdentifier = ""
    private var pendingAudioURL: URL?
    private var pendingTextURL: URL?
    private var activeAudioURL: URL?
    private var createdFromText = false
    private var pendingSaveTask: Task<Void, Never>?
    private var fileSpeaker: SentenceFileSpeaker?
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingMonitor: Task<Void, Never>?
    private var recordingPreviewURL: URL?
    private var previewPlayer: AVAudioPlayer?
    private var previewMonitor: Task<Void, Never>?
    private let hapticFeedback = UINotificationFeedbackGenerator()

    var currentSentence: TranscriptSentence? {
        guard sentences.indices.contains(currentSentenceIndex) else { return nil }
        return sentences[currentSentenceIndex]
    }

    private static let sentenceLeadInCap: TimeInterval = 1.0

    private func playbackAnchorTime(for index: Int) -> TimeInterval {
        guard sentences.indices.contains(index) else { return 0 }
        let cappedLookback = max(sentences[index].startTime - Self.sentenceLeadInCap, 0)
        guard index > 0, sentences.indices.contains(index - 1) else { return cappedLookback }
        return min(max(sentences[index - 1].endTime, cappedLookback), sentences[index].startTime)
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    init() {
        let languages = Self.limitedSpeechLanguages(from: Array(SFSpeechRecognizer.supportedLocales()))
        speechLanguages = languages
        let storedOrigin = UserDefaults.standard.string(forKey: Self.originLanguageKey)
        let origin = Self.resolvedSpeechLocale(storedOrigin, in: languages)
        let storedTranslation = UserDefaults.standard.string(forKey: Self.translationLanguageKey)
        let translation = storedTranslation.flatMap { code in
            TranslationLanguage.supported.contains(where: { $0.code == code }) ? code : nil
        } ?? "en"
        defaultSpeechLocale = origin
        defaultTranslationLanguage = translation
        selectedSpeechLocale = origin
        selectedTranslationLanguage = translation
        voicePreferences = UserDefaults.standard.dictionary(forKey: Self.voicePreferencesKey) as? [String: String] ?? [:]
    }

    private static let originLanguageKey = "originLanguageIdentifier"
    private static let translationLanguageKey = "translationLanguageCode"
    private static let voicePreferencesKey = "voicePreferenceByLanguage"

    /// The preferred voice identifier for a language, if the user chose one in Settings.
    func preferredVoiceIdentifier(forLanguage code: String) -> String? {
        voicePreferences[code]
    }

    /// Sets (or clears, when `identifier` is `nil`) the preferred voice for a language.
    func setPreferredVoice(_ identifier: String?, forLanguage code: String) {
        voicePreferences[code] = identifier
    }

    /// The voices iOS offers for a given spoken locale, best matches first, for use in a picker.
    static func availableVoices(forLanguage localeIdentifier: String) -> [AVSpeechSynthesisVoice] {
        matchingVoices(for: localeIdentifier).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func loadSpeechLanguages() async {
        let locales = await DictationTranscriber.supportedLocales
        let languages = Self.limitedSpeechLanguages(from: Array(locales))
        guard !languages.isEmpty else { return }
        speechLanguages = languages
        let resolvedDefault = Self.resolvedSpeechLocale(defaultSpeechLocale, in: languages)
        if resolvedDefault != defaultSpeechLocale {
            defaultSpeechLocale = resolvedDefault
        }
        let resolved = Self.resolvedSpeechLocale(selectedSpeechLocale, in: languages)
        if resolved != selectedSpeechLocale {
            selectedSpeechLocale = resolved
        }
    }

    private static let preferredSpeechLocales = [
        "en": "en-US",
        "de": "de-DE",
        "es": "es-ES",
        "fr": "fr-FR",
        "it": "it-IT",
        "ja": "ja-JP",
        "zh": "zh-CN"
    ]

    private static func limitedSpeechLanguages(from locales: [Locale]) -> [SpeechLanguage] {
        TranslationLanguage.supported.map { language in
            let matches = locales.filter { languageCode(for: $0.identifier) == language.code }
            let preferred = preferredSpeechLocales[language.code] ?? language.code
            let chosen = matches.first { normalizedLocale($0.identifier) == normalizedLocale(preferred) }
                ?? matches.first { languageCode(for: $0.identifier) == language.code }
            return SpeechLanguage(identifier: chosen?.identifier ?? preferred, name: language.name)
        }
    }

    private static func resolvedSpeechLocale(_ identifier: String?, in languages: [SpeechLanguage]) -> String {
        if let identifier, languages.contains(where: { $0.identifier == identifier }) {
            return identifier
        }
        if let identifier, let match = languages.first(where: { languageCode(for: $0.identifier) == languageCode(for: identifier) }) {
            return match.identifier
        }
        return languages.first { languageCode(for: $0.identifier) == "de" }?.identifier
            ?? languages.first?.identifier
            ?? "de-DE"
    }

    private static func normalizedLocale(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    static func languageCode(for identifier: String) -> String {
        let normalized = normalizedLocale(identifier)
        return String(normalized.split(separator: "-").first ?? Substring(normalized))
    }

    // MARK: - Import

    func importAudio(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            resetPlayerAndAudioAccess()
            errorMessage = nil
            pendingImportKind = .audio
            pendingTextURL = nil
            pendingAudioURL = url
            pendingAudioName = url.lastPathComponent
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            if hasScopedAccess {
                scopedAudioURL = url
            }

            if FileManager.default.fileExists(atPath: savedSessionURL(for: url).path) {
                isSavedSessionPromptPresented = true
            } else {
                transcribePendingAudio()
            }
        case .failure(let error):
            errorMessage = .format("Could not open the selected audio file: %@", error.localizedDescription)
        }
    }

    func importText(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importTextFile(at: url)
        case .failure(let error):
            errorMessage = .format("Could not open the selected text file: %@", error.localizedDescription)
        }
    }

    func importTextFile(at url: URL) {
        resetPlayerAndAudioAccess()
        errorMessage = nil
        pendingImportKind = .text
        pendingTextURL = url
        pendingAudioURL = Self.speechAudioURL(for: url)
        pendingAudioName = url.lastPathComponent
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        if hasScopedAccess {
            scopedAudioURL = url
        }

        if let audioURL = pendingAudioURL,
           FileManager.default.fileExists(atPath: savedSessionURL(for: audioURL).path) {
            isSavedSessionPromptPresented = true
        } else {
            synthesizePendingText()
        }
    }

    /// Synthesizes speech from typed text already saved to a file.
    func importTypedText(_ text: String, suggestedName: String) {
        let speechDir = Self.speechDirectory()
        do {
            try FileManager.default.createDirectory(at: speechDir, withIntermediateDirectories: true)
        } catch {
            errorMessage = .format("Could not prepare speech folder: %@", error.localizedDescription)
            return
        }
        let textURL = speechDir.appendingPathComponent(suggestedName).appendingPathExtension("txt")
        do {
            try text.write(to: textURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = .format("Could not save the text: %@", error.localizedDescription)
            return
        }
        importTextFile(at: textURL)
    }

    func showError(_ message: LocalizableText) {
        errorMessage = message
    }

    func useSavedSession() {
        guard let url = pendingAudioURL else { return }
        isSavedSessionPromptPresented = false
        if scopedAudioURL != url, url.startAccessingSecurityScopedResource() {
            scopedAudioURL?.stopAccessingSecurityScopedResource()
            scopedAudioURL = url
        }
        do {
            let data = try Data(contentsOf: savedSessionURL(for: url))
            let saved = try JSONDecoder().decode(SavedPracticeSession.self, from: data)
            guard saved.formatVersion == 1 else {
                throw DictationError.unsupportedSavedSessionVersion
            }
            guard saved.audioFileName == url.lastPathComponent else {
                throw DictationError.savedSessionAudioMismatch
            }

            resetPracticeState()
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.enableRate = true
            audioPlayer.prepareToPlay()
            player = audioPlayer
            duration = audioPlayer.duration
            fileName = url.lastPathComponent
            activeAudioURL = url
            createdFromText = saved.createdFromText
            sessionDetail = saved.createdFromText ? "On-device text to speech" : "On-device transcription"
            selectedSpeechLocale = Self.resolvedSpeechLocale(saved.sourceLanguageIdentifier, in: speechLanguages)
            transcriptLocaleIdentifier = saved.sourceLanguageIdentifier
            sourceLanguageName = saved.sourceLanguageName
            selectedTranslationLanguage = saved.translationLanguage
            let validSavedSentences = saved.sentences.enumerated().filter { _, sentence in
                !saved.reviewCompleted
                    || sentence.text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) })
            }
            guard !validSavedSentences.isEmpty else {
                throw DictationError.noSpeechDetected
            }
            sentences = validSavedSentences.enumerated().map { newID, item in
                let sentence = item.element
                return TranscriptSentence(
                    id: newID,
                    text: sentence.text,
                    startTime: sentence.startTime,
                    endTime: sentence.endTime,
                    originalText: sentence.originalText,
                    mergedFrom: Self.restoredMergeHistory(sentence.mergedFrom)
                )
            }
            if !saved.createdFromText {
                sentences = Self.clampingEndTimes(sentences, duration: duration)
            }
            translatedSentences = validSavedSentences.map { $0.element.translation }
            drafts = Dictionary(uniqueKeysWithValues: validSavedSentences.enumerated().compactMap { newID, item in
                saved.drafts[item.offset].map { (newID, $0) }
            })
            let restoredSentenceIndex = validSavedSentences.firstIndex {
                $0.offset >= saved.currentSentenceIndex
            } ?? (validSavedSentences.count - 1)
            currentSentenceIndex = restoredSentenceIndex
            answerDraft = drafts[currentSentenceIndex] ?? saved.answerDraft
            playbackRate = saved.playbackRate
            sentenceOnly = saved.sentenceOnly
            audioPlayer.rate = playbackRate
            currentTime = min(max(saved.currentTime, 0), duration)
            audioPlayer.currentTime = currentTime
            if saved.reviewCompleted {
                translationStatus = "Loaded saved translations"
            } else {
                translatedSentences = []
                translationStatus = ""
                isReviewing = true
                sentenceOnly = true
            }
            transcriptionMode = ""
            processingTitle = ""
            punctuationStatus = saved.createdFromText ? "Spoken on this device from your text file." : ""
            translationConfiguration = nil
            errorMessage = nil
            pendingAudioURL = nil
            pendingTextURL = nil
            pendingAudioName = ""
            isTranscribing = false
            savePracticeSession()
        } catch {
            errorMessage = (error as? DictationError)?.localizable
                ?? .format("Could not load the saved practice data: %@", error.localizedDescription)
            releasePendingAudioAccess()
        }
    }

    func transcribePendingAudio() {
        guard let url = pendingAudioURL else { return }
        isSavedSessionPromptPresented = false
        pendingAudioURL = nil
        pendingTextURL = nil
        pendingAudioName = ""
        Task { await transcribeAudio(at: url) }
    }

    func continuePendingImport() {
        switch pendingImportKind {
        case .audio:
            transcribePendingAudio()
        case .text:
            synthesizePendingText()
        }
    }

    func synthesizePendingText() {
        guard let textURL = pendingTextURL else { return }
        let audioURL = pendingAudioURL ?? Self.speechAudioURL(for: textURL)
        isSavedSessionPromptPresented = false
        pendingAudioURL = nil
        pendingTextURL = nil
        pendingAudioName = ""
        Task { await synthesizeSpeech(from: textURL, audioURL: audioURL) }
    }

    func cancelPendingAudioSelection() {
        isSavedSessionPromptPresented = false
        pendingImportKind = .audio
        pendingAudioURL = nil
        pendingTextURL = nil
        pendingAudioName = ""
        releasePendingAudioAccess()
    }

    private func releasePendingAudioAccess() {
        resetPlayerAndAudioAccess()
        activeAudioURL = nil
    }

    private func resetPracticeState() {
        isReviewing = false
        reviewSnapshot = nil
        isEditingSourceText = false
        sourceTextDraft = ""
        sentences = []
        translatedSentences = []
        currentSentenceIndex = 0
        currentTime = 0
        translationStatus = ""
        punctuationStatus = ""
        drafts = [:]
        answerDraft = ""
        practiceFeedback = ""
        answerIsRevealed = false
        practiceGradeTitle = ""
        practiceGradeScore = nil
        practiceWordResults = []
        missingPracticeWords = []
    }

    // MARK: - Transcription

    func transcribeAudio(at url: URL) async {
        resetPlayerAndAudioAccess()
        errorMessage = nil
        isTranscribing = true
        createdFromText = false
        sessionDetail = "On-device transcription"
        processingTitle = .format("Transcribing %@", url.lastPathComponent)
        transcriptionMode = "Opening the audio file…"
        isReviewing = false
        reviewSnapshot = nil
        isEditingSourceText = false
        sourceTextDraft = ""
        activeTranslationRequest += 1
        translationWatchdog?.cancel()
        translationRunner?.cancel()
        translationConfiguration = nil
        fileName = url.lastPathComponent
        activeAudioURL = url
        sourceLanguageName = speechLanguages.first(where: { $0.identifier == selectedSpeechLocale })?.name
            ?? selectedSpeechLocale
        transcriptLocaleIdentifier = selectedSpeechLocale
        sentences = []
        translatedSentences = []
        translationStatus = ""
        drafts = [:]
        answerDraft = ""
        practiceFeedback = ""
        answerIsRevealed = false
        practiceGradeTitle = ""
        practiceGradeScore = nil
        practiceWordResults = []
        missingPracticeWords = []

        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        if hasScopedAccess {
            scopedAudioURL = url
        }

        do {
            activatePlaybackSession()
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.enableRate = true
            audioPlayer.rate = playbackRate
            audioPlayer.prepareToPlay()
            player = audioPlayer
            duration = audioPlayer.duration

            transcriptionMode = .language("Preparing Apple's long-audio speech model for %@…", selectedSpeechLocale)
            punctuationStatus = ""

            try await requestSpeechPermission()
            let transcriptChunks = try await recognizeWithDictationTranscriber(url: url)
            let result = Self.makeSentences(from: transcriptChunks, duration: duration, localeIdentifier: transcriptLocaleIdentifier)
            guard !result.isEmpty else { throw DictationError.noSpeechDetected }

            sentences = result
            await refinePunctuation()
            currentSentenceIndex = 0
            currentTime = 0
            translatedSentences = []
            isReviewing = true
            sentenceOnly = true
            isTranscribing = false
            savePracticeSession()
        } catch {
            isTranscribing = false
            processingTitle = ""
            transcriptionMode = ""
            errorMessage = LocalizableText.capture(error)
            resetPlayerAndAudioAccess()
        }
    }

    func synthesizeSpeech(from textURL: URL, audioURL: URL) async {
        resetPlayerAndAudioAccess()
        errorMessage = nil
        isTranscribing = true
        createdFromText = true
        sessionDetail = "On-device text to speech"
        processingTitle = .format("Creating speech for %@", textURL.lastPathComponent)
        transcriptionMode = "Reading the text file…"
        isReviewing = false
        reviewSnapshot = nil
        isEditingSourceText = false
        sourceTextDraft = ""
        activeTranslationRequest += 1
        translationWatchdog?.cancel()
        translationRunner?.cancel()
        translationConfiguration = nil
        fileName = textURL.lastPathComponent
        sourceLanguageName = speechLanguages.first(where: { $0.identifier == selectedSpeechLocale })?.name
            ?? selectedSpeechLocale
        transcriptLocaleIdentifier = selectedSpeechLocale
        sentences = []
        translatedSentences = []
        translationStatus = ""
        punctuationStatus = ""
        drafts = [:]
        answerDraft = ""
        practiceFeedback = ""
        answerIsRevealed = false
        practiceGradeTitle = ""
        practiceGradeScore = nil
        practiceWordResults = []
        missingPracticeWords = []

        let hasScopedAccess = textURL.startAccessingSecurityScopedResource()
        if hasScopedAccess {
            scopedAudioURL = textURL
        }

        do {
            let sessionAlreadyExists = FileManager.default.fileExists(atPath: savedSessionURL(for: audioURL).path)
            if FileManager.default.fileExists(atPath: audioURL.path), !sessionAlreadyExists {
                throw DictationError.speechFileAlreadyExists(audioURL.lastPathComponent)
            }

            let text = try readText(at: textURL)
            if hasScopedAccess {
                textURL.stopAccessingSecurityScopedResource()
                scopedAudioURL = nil
            }
            let pieces = Self.practiceSentences(from: text, localeIdentifier: transcriptLocaleIdentifier)
            sentences = try await synthesizeAndLoad(pieces: pieces, audioURL: audioURL)
            guard !sentences.isEmpty else { throw DictationError.speechSynthesisFailed }

            currentSentenceIndex = 0
            currentTime = 0
            translatedSentences = Array(repeating: "", count: sentences.count)
            punctuationStatus = "Spoken on this device from your text file."
            isTranscribing = false
            processingTitle = ""
            transcriptionMode = ""
            savePracticeSession()
            translateTranscript()
        } catch {
            isTranscribing = false
            processingTitle = ""
            transcriptionMode = ""
            createdFromText = false
            errorMessage = LocalizableText.capture(error)
            resetPlayerAndAudioAccess()
        }
    }

    private func synthesizeAndLoad(pieces: [String], audioURL: URL) async throws -> [TranscriptSentence] {
        guard !pieces.isEmpty else { throw DictationError.emptyText }
        guard let voice = speechFileVoice(for: transcriptLocaleIdentifier) else {
            throw DictationError.speechVoiceUnavailable(selectedSpeechLocale)
        }
        transcriptionMode = .format("Preparing %@…", voice.displayName)

        let temporaryURL = Self.temporarySpeechURL(for: audioURL)
        defer {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        // Ensure the speech directory exists
        let parentDir = audioURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let spokenSentences = try await writeSpeech(pieces, voice: voice, to: temporaryURL)
        if FileManager.default.fileExists(atPath: audioURL.path) {
            _ = try FileManager.default.replaceItemAt(audioURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: audioURL)
        }

        activatePlaybackSession()
        let audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
        audioPlayer.enableRate = true
        audioPlayer.rate = playbackRate
        audioPlayer.prepareToPlay()
        player = audioPlayer
        duration = audioPlayer.duration
        activeAudioURL = audioURL
        fileName = audioURL.lastPathComponent

        let safeDuration = max(duration, 0.05)
        return spokenSentences.map { sentence in
            TranscriptSentence(
                id: sentence.id,
                text: sentence.text,
                startTime: min(sentence.startTime, safeDuration),
                endTime: min(max(sentence.endTime, sentence.startTime + 0.05), safeDuration)
            )
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        errorMessage = nil
        deleteRecordingPreview()
        Task { await beginRecording() }
    }

    func stopRecording() {
        let duration = audioRecorder?.currentTime ?? recordingDuration
        let url = stopRecorder()
        guard let url else { return }
        guard duration >= 0.4, FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: url)
            errorMessage = "That recording is too short. Record a little longer, then save it."
            return
        }
        loadRecordingPreview(at: url)
    }

    func toggleRecordingPlayback() {
        guard hasRecordingPreview else { return }
        if previewPlayer == nil {
            reloadRecordingPreview()
        }
        guard let previewPlayer else { return }
        if isPlayingRecording {
            previewPlayer.pause()
            isPlayingRecording = false
            previewMonitor?.cancel()
            previewMonitor = nil
            recordingPreviewTime = previewPlayer.currentTime
            return
        }
        if previewPlayer.currentTime >= max(previewPlayer.duration - 0.05, 0) {
            previewPlayer.currentTime = 0
        }
        activatePlaybackSession()
        guard previewPlayer.play() else {
            errorMessage = "The recording could not be played."
            return
        }
        isPlayingRecording = true
        previewMonitor?.cancel()
        previewMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let player = self.previewPlayer else { return }
                self.recordingPreviewTime = player.currentTime
                if !player.isPlaying {
                    self.isPlayingRecording = false
                    self.previewMonitor?.cancel()
                    self.previewMonitor = nil
                    return
                }
            }
        }
    }

    func seekRecordingPreview(to time: TimeInterval) {
        guard let previewPlayer else { return }
        let safeTime = min(max(time, 0), recordingPreviewDuration)
        previewPlayer.currentTime = safeTime
        recordingPreviewTime = safeTime
    }

    func prepareRecordingForSave() -> URL? {
        stopRecordingPlayback()
        previewPlayer = nil
        return recordingPreviewURL
    }

    func reloadRecordingPreview() {
        guard let recordingPreviewURL else { return }
        loadRecordingPreview(at: recordingPreviewURL)
    }

    func clearSavedRecording() {
        stopRecordingPlayback()
        previewPlayer = nil
        recordingPreviewURL = nil
        hasRecordingPreview = false
        recordingPreviewTime = 0
        recordingPreviewDuration = 0
        recordingDuration = 0
    }

    func discardRecording() {
        let recordedURL = stopRecorder()
        if let recordedURL {
            try? FileManager.default.removeItem(at: recordedURL)
        }
        deleteRecordingPreview()
    }

    private func beginRecording() async {
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else {
            errorMessage = "Microphone access was denied. Allow it in Settings > Privacy & Security > Microphone, then try again."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            errorMessage = .format("Could not activate audio session: %@", error.localizedDescription)
            return
        }

        let recordingsDir = Self.recordingsDirectory()
        do {
            try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        } catch {
            errorMessage = .format("Recording could not be started: %@", error.localizedDescription)
            return
        }

        let url = recordingsDir
            .appendingPathComponent("dictation-recording-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else {
                recorder.stop()
                try? FileManager.default.removeItem(at: url)
                errorMessage = "Recording could not be started. Check that a microphone is available, then try again."
                return
            }
            audioRecorder = recorder
            recordingURL = url
            recordingDuration = 0
            isRecording = true
            recordingMonitor?.cancel()
            recordingMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, self.isRecording else { return }
                    self.recordingDuration = self.audioRecorder?.currentTime ?? self.recordingDuration
                }
            }
        } catch {
            errorMessage = .format("Recording could not be started: %@", error.localizedDescription)
        }
    }

    private func stopRecorder() -> URL? {
        recordingMonitor?.cancel()
        recordingMonitor = nil
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        let url = recordingURL
        recordingURL = nil
        // Deactivate recording session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }

    private func loadRecordingPreview(at url: URL) {
        stopRecordingPlayback()
        activatePlaybackSession()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            previewPlayer = player
            recordingPreviewURL = url
            recordingPreviewDuration = player.duration
            recordingPreviewTime = 0
            recordingDuration = player.duration
            hasRecordingPreview = true
        } catch {
            try? FileManager.default.removeItem(at: url)
            recordingPreviewURL = nil
            hasRecordingPreview = false
            errorMessage = .format("The recording could not be played: %@", error.localizedDescription)
        }
    }

    private func stopRecordingPlayback() {
        previewPlayer?.stop()
        isPlayingRecording = false
        previewMonitor?.cancel()
        previewMonitor = nil
    }

    private func deleteRecordingPreview() {
        stopRecordingPlayback()
        previewPlayer = nil
        if let recordingPreviewURL {
            try? FileManager.default.removeItem(at: recordingPreviewURL)
        }
        recordingPreviewURL = nil
        hasRecordingPreview = false
        recordingPreviewTime = 0
        recordingPreviewDuration = 0
        recordingDuration = 0
    }

    // MARK: - Reset

    func reset() {
        discardRecording()
        stopPlayback()
        isReviewing = false
        reviewSnapshot = nil
        isEditingSourceText = false
        sourceTextDraft = ""
        activeTranslationRequest += 1
        translationWatchdog?.cancel()
        translationRunner?.cancel()
        translationConfiguration = nil
        resetPlayerAndAudioAccess()
        fileName = ""
        sourceLanguageName = ""
        sentences = []
        translatedSentences = []
        currentSentenceIndex = 0
        currentTime = 0
        duration = 0
        translationStatus = ""
        punctuationStatus = ""
        transcriptLocaleIdentifier = ""
        processingTitle = ""
        transcriptionMode = ""
        sessionDetail = ""
        createdFromText = false
        errorMessage = nil
        drafts = [:]
        answerDraft = ""
        practiceFeedback = ""
        answerIsRevealed = false
        practiceGradeTitle = ""
        practiceGradeScore = nil
        practiceWordResults = []
        missingPracticeWords = []
        pendingAudioURL = nil
        pendingTextURL = nil
        pendingAudioName = ""
        pendingImportKind = .audio
        isSavedSessionPromptPresented = false
        activeAudioURL = nil
        if selectedSpeechLocale != defaultSpeechLocale {
            selectedSpeechLocale = defaultSpeechLocale
        }
        if selectedTranslationLanguage != defaultTranslationLanguage {
            selectedTranslationLanguage = defaultTranslationLanguage
        }
    }

    // MARK: - Playback

    func togglePlayback() {
        guard let player, !sentences.isEmpty else { return }
        if isPlaying {
            stopPlayback()
            return
        }

        if player.currentTime >= duration {
            player.currentTime = playbackAnchorTime(for: currentSentenceIndex)
        }
        if sentenceOnly {
            player.currentTime = playbackAnchorTime(for: currentSentenceIndex)
            playbackSentenceIndex = currentSentenceIndex
        } else {
            playbackSentenceIndex = nil
        }
        player.rate = playbackRate
        activatePlaybackSession()
        guard player.play() else {
            errorMessage = "Audio playback could not be started."
            return
        }
        isPlaying = true
        startPlaybackMonitor()
        scheduleSentenceStopDeadline()
    }

    func selectSentence(_ index: Int, play: Bool = false) {
        guard sentences.indices.contains(index), let player else { return }
        setCurrentSentence(index)
        player.currentTime = playbackAnchorTime(for: index)
        currentTime = player.currentTime
        savePracticeSession()
        if isPlaying && sentenceOnly {
            playbackSentenceIndex = index
            scheduleSentenceStopDeadline()
        }
        if play && !isPlaying {
            togglePlayback()
        }
    }

    func moveSentence(by offset: Int) {
        selectSentence(currentSentenceIndex + offset)
    }

    // MARK: - Review

    func toggleReviewPlayback(at index: Int) {
        guard isReviewing, sentences.indices.contains(index) else { return }
        if isPlaying, currentSentenceIndex == index {
            togglePlayback()
        } else {
            selectSentence(index, play: true)
        }
    }

    var canEditText: Bool {
        !createdFromText && !isReviewing && !isTranscribing && !sentences.isEmpty
    }

    var canCancelReview: Bool {
        isReviewing && reviewSnapshot != nil
    }

    var canEditSourceText: Bool {
        createdFromText && !isReviewing && !isEditingSourceText && !isTranscribing && !sentences.isEmpty
    }

    func beginEditingSourceText() {
        guard canEditSourceText else { return }
        stopPlayback()
        sourceTextDraft = sentences.map(\.text).joined(separator: "\n\n")
        isEditingSourceText = true
    }

    func cancelEditingSourceText() {
        guard isEditingSourceText else { return }
        isEditingSourceText = false
        sourceTextDraft = ""
    }

    func confirmSourceTextEdit() async {
        guard isEditingSourceText, let audioURL = activeAudioURL else { return }
        let text = sourceTextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "The text can't be empty."
            return
        }
        stopPlayback()
        errorMessage = nil
        isTranscribing = true
        processingTitle = .format("Creating speech for %@", fileName)
        transcriptionMode = "Regenerating speech from your edited text…"
        activeTranslationRequest += 1
        translationWatchdog?.cancel()
        translationRunner?.cancel()
        translationConfiguration = nil

        do {
            let pieces = Self.practiceSentences(from: text, localeIdentifier: transcriptLocaleIdentifier)
            let result = try await synthesizeAndLoad(pieces: pieces, audioURL: audioURL)
            guard !result.isEmpty else { throw DictationError.speechSynthesisFailed }

            sentences = result
            currentSentenceIndex = 0
            currentTime = 0
            drafts = [:]
            answerDraft = ""
            practiceFeedback = ""
            answerIsRevealed = false
            practiceGradeTitle = ""
            practiceGradeScore = nil
            practiceWordResults = []
            missingPracticeWords = []
            translatedSentences = Array(repeating: "", count: sentences.count)
            punctuationStatus = "Spoken on this device from your text file."
            isEditingSourceText = false
            sourceTextDraft = ""
            isTranscribing = false
            processingTitle = ""
            transcriptionMode = ""
            savePracticeSession()
            translateTranscript()
        } catch {
            isTranscribing = false
            processingTitle = ""
            transcriptionMode = ""
            errorMessage = LocalizableText.capture(error)
        }
    }

    func beginEditingText() {
        guard canEditText else { return }
        stopPlayback()
        reviewSnapshot = ReviewSnapshot(
            sentences: sentences,
            translatedSentences: translatedSentences,
            drafts: drafts,
            answerDraft: answerDraft,
            currentSentenceIndex: currentSentenceIndex,
            sentenceOnly: sentenceOnly
        )
        activeTranslationRequest += 1
        translationWatchdog?.cancel()
        translationRunner?.cancel()
        translationConfiguration = nil
        isReviewing = true
        sentenceOnly = true
    }

    func cancelReview() {
        guard isReviewing, let snapshot = reviewSnapshot else { return }
        stopPlayback()
        sentences = snapshot.sentences
        translatedSentences = snapshot.translatedSentences
        drafts = snapshot.drafts
        answerDraft = snapshot.answerDraft
        currentSentenceIndex = snapshot.currentSentenceIndex
        sentenceOnly = snapshot.sentenceOnly
        reviewSnapshot = nil
        isReviewing = false
        player?.currentTime = playbackAnchorTime(for: currentSentenceIndex)
        currentTime = player?.currentTime ?? currentTime
        savePracticeSession()
        if translatedSentences.contains(where: \.isEmpty) {
            translateTranscript()
        }
    }

    func updateReviewText(_ text: String, at index: Int) {
        guard isReviewing, sentences.indices.contains(index), sentences[index].text != text else { return }
        let old = sentences[index]
        sentences[index] = TranscriptSentence(
            id: old.id,
            text: text,
            startTime: old.startTime,
            endTime: old.endTime,
            originalText: old.originalText,
            mergedFrom: old.mergedFrom
        )
        schedulePracticeSessionSave()
    }

    func revertReviewSentence(at index: Int) {
        guard sentences.indices.contains(index) else { return }
        updateReviewText(sentences[index].originalText, at: index)
        reviewExternalEditRevision += 1
    }

    func mergeReviewSentence(at index: Int) {
        guard isReviewing, sentences.indices.contains(index), sentences.indices.contains(index + 1) else { return }
        stopPlayback()
        let first = sentences[index]
        let second = sentences[index + 1]
        let merged = TranscriptSentence(
            id: first.id,
            text: joinedSentenceText(first.text, second.text),
            startTime: first.startTime,
            endTime: max(first.endTime, second.endTime),
            originalText: joinedSentenceText(first.originalText, second.originalText),
            mergedFrom: [first, second]
        )
        replaceReviewSentences(index...(index + 1), with: [merged], currentIndex: index)
    }

    func canUnmergeReviewSentence(at index: Int) -> Bool {
        sentences.indices.contains(index) && sentences[index].mergedFrom != nil
    }

    func unmergeReviewSentence(at index: Int) {
        guard isReviewing, sentences.indices.contains(index), let pieces = sentences[index].mergedFrom else { return }
        stopPlayback()
        replaceReviewSentences(index...index, with: pieces, currentIndex: index)
    }

    private func replaceReviewSentences(
        _ range: ClosedRange<Int>,
        with replacement: [TranscriptSentence],
        currentIndex: Int
    ) {
        var updated = sentences
        updated.replaceSubrange(range, with: replacement)
        sentences = updated.enumerated().map { newID, sentence in
            TranscriptSentence(
                id: newID,
                text: sentence.text,
                startTime: sentence.startTime,
                endTime: sentence.endTime,
                originalText: sentence.originalText,
                mergedFrom: sentence.mergedFrom
            )
        }
        currentSentenceIndex = currentIndex
        reviewExternalEditRevision += 1
        savePracticeSession()
    }

    func reviewStatus(at index: Int) -> SentenceReviewStatus {
        guard sentences.indices.contains(index) else {
            return SentenceReviewStatus(changedWords: 0, allowedChanges: 0, originalWordCount: 0, isEmpty: false)
        }
        let sentence = sentences[index]
        let original = Self.reviewWords(sentence.originalText, localeIdentifier: transcriptLocaleIdentifier)
        let edited = Self.reviewWords(sentence.text, localeIdentifier: transcriptLocaleIdentifier)
        return SentenceReviewStatus(
            changedWords: Self.wordEditDistance(original, edited),
            allowedChanges: Self.allowedWordChanges(forWordCount: original.count),
            originalWordCount: original.count,
            isEmpty: edited.isEmpty
        )
    }

    var reviewBlockedCount: Int {
        guard isReviewing else { return 0 }
        return sentences.indices.filter {
            sentences[$0].text != sentences[$0].originalText && reviewStatus(at: $0).isOverLimit
        }.count
    }

    func confirmReview() {
        guard isReviewing, reviewBlockedCount == 0 else { return }
        stopPlayback()

        let snapshot = reviewSnapshot
        reviewSnapshot = nil
        isReviewing = false
        if let snapshot {
            sentenceOnly = snapshot.sentenceOnly
        }
        if let snapshot, snapshot.sentences.count == sentences.count {
            drafts = snapshot.drafts
            currentSentenceIndex = min(snapshot.currentSentenceIndex, sentences.count - 1)
            answerDraft = drafts[currentSentenceIndex] ?? ""
        } else {
            drafts = [:]
            answerDraft = ""
            currentSentenceIndex = min(snapshot?.currentSentenceIndex ?? 0, sentences.count - 1)
        }
        practiceFeedback = ""
        answerIsRevealed = false
        practiceGradeTitle = ""
        practiceGradeScore = nil
        practiceWordResults = []
        missingPracticeWords = []
        let resumeTime = snapshot == nil ? 0 : playbackAnchorTime(for: currentSentenceIndex)
        player?.currentTime = resumeTime
        currentTime = resumeTime
        translatedSentences = Array(repeating: "", count: sentences.count)
        savePracticeSession()
        translateTranscript()
    }

    private func joinedSentenceText(_ first: String, _ second: String) -> String {
        let head = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        let spaceless = transcriptLocaleIdentifier.hasPrefix("ja") || transcriptLocaleIdentifier.hasPrefix("zh")
        return spaceless ? head + tail : head + " " + tail
    }

    static func allowedWordChanges(forWordCount count: Int) -> Int {
        let proportional = Int(Double(count) * 0.4)
        let shortSentenceAllowance = count <= 2 ? 1 : (count <= 5 ? 2 : 0)
        return max(proportional, shortSentenceAllowance)
    }

    static func reviewWords(_ text: String, localeIdentifier: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let language = languageCode(for: localeIdentifier)
        if !language.isEmpty {
            tokenizer.setLanguage(NLLanguage(rawValue: language))
        }
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).precomposedStringWithCanonicalMapping.lowercased()
            if word.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                words.append(word)
            }
            return true
        }
        return words
    }

    static func wordEditDistance(_ original: [String], _ edited: [String]) -> Int {
        if original.isEmpty { return edited.count }
        if edited.isEmpty { return original.count }
        var previous = Array(0...edited.count)
        for (row, originalWord) in original.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: edited.count)
            for (column, editedWord) in edited.enumerated() {
                let substitution = previous[column] + (originalWord == editedWord ? 0 : 1)
                current[column + 1] = min(substitution, previous[column + 1] + 1, current[column] + 1)
            }
            previous = current
        }
        return previous[edited.count]
    }

    // MARK: - Seek & Answer

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let safeTime = min(max(time, 0), duration)
        player.currentTime = safeTime
        currentTime = safeTime
        let matchingIndex = Self.sentenceIndex(at: safeTime, in: sentences)
        setCurrentSentence(matchingIndex)
        schedulePracticeSessionSave()
        if isPlaying && sentenceOnly {
            playbackSentenceIndex = currentSentenceIndex
            scheduleSentenceStopDeadline()
        }
    }

    func updateAnswerDraft(_ value: String) {
        answerDraft = value
        if sentences.indices.contains(currentSentenceIndex) {
            drafts[currentSentenceIndex] = value
            schedulePracticeSessionSave()
        }
        practiceFeedback = ""
        answerIsRevealed = false
        practiceGradeTitle = ""
        practiceGradeScore = nil
        practiceWordResults = []
        missingPracticeWords = []
    }

    func checkAnswer() {
        guard let currentSentence else { return }
        let typedWords = answerDraft.split(whereSeparator: \.isWhitespace).map(String.init)
        let expectedWords = currentSentence.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let typedKeys = typedWords.map(Self.normalizedAnswer)
        let expectedKeys = expectedWords.map(Self.normalizedAnswer)
        let alignment = Self.alignWords(typedKeys, expectedKeys)
        practiceWordResults = alignment.typedMatches.enumerated().map { index, isCorrect in
            let expectedIndex = alignment.typedExpectedIndices[index]
            let expectedText = expectedIndex.map { expectedWords[$0] }
            return PracticeWordResult(
                id: index,
                text: typedWords[index],
                isCorrect: isCorrect,
                expectedText: isCorrect ? nil : expectedText
            )
        }
        missingPracticeWords = alignment.missingExpectedIndices.map { expectedWords[$0] }

        if alignment.typedMatches.allSatisfy({ $0 }) && missingPracticeWords.isEmpty {
            practiceGradeTitle = "Perfect!"
            practiceGradeScore = 100
            hapticFeedback.notificationOccurred(.success)
        } else {
            let mistakes = alignment.typedMatches.filter { !$0 }.count + missingPracticeWords.count
            let score = max(0, Int((1 - Double(mistakes) / Double(max(expectedWords.count, typedWords.count, 1))) * 100))
            practiceGradeScore = score
            switch score {
            case 85...:
                practiceGradeTitle = "Almost there!"
            case 65..<85:
                practiceGradeTitle = "Great effort!"
            default:
                practiceGradeTitle = "Keep going!"
            }
            if mistakes == 1 {
                practiceFeedback = "1 difference to review. Red words are incorrect or missing."
            } else {
                practiceFeedback = .format(
                    "%@ differences to review. Red words are incorrect or missing.",
                    String(mistakes)
                )
            }
            hapticFeedback.notificationOccurred(.warning)
        }
        gradeCheckCount += 1
        schedulePracticeSessionSave()
    }

    func toggleAnswerVisibility() {
        if answerIsRevealed {
            answerIsRevealed = false
            practiceFeedback = ""
            return
        }
        guard let currentSentence else { return }
        answerIsRevealed = true
        practiceGradeTitle = ""
        practiceGradeScore = nil
        practiceWordResults = []
        missingPracticeWords = []
        practiceFeedback = .verbatim(currentSentence.text)
        savePracticeSession()
    }

    private func setCurrentSentence(_ index: Int) {
        guard sentences.indices.contains(index), index != currentSentenceIndex else { return }
        drafts[currentSentenceIndex] = answerDraft
        currentSentenceIndex = index
        answerDraft = drafts[index] ?? ""
        practiceFeedback = ""
        answerIsRevealed = false
        practiceGradeTitle = ""
        practiceGradeScore = nil
        practiceWordResults = []
        missingPracticeWords = []
        schedulePracticeSessionSave()
    }

    private func stopPlayback() {
        player?.pause()
        isPlaying = false
        playbackSentenceIndex = nil
        cancelSentenceStopDeadline()
        playbackMonitor?.cancel()
        playbackMonitor = nil
        currentTime = player?.currentTime ?? currentTime
        savePracticeSession()
    }

    private func startPlaybackMonitor() {
        playbackMonitor?.cancel()
        playbackMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshPlaybackState()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func cancelSentenceStopDeadline() {
        sentenceStopWorkItem?.cancel()
        sentenceStopWorkItem = nil
    }

    private func scheduleSentenceStopDeadline() {
        cancelSentenceStopDeadline()
        guard isPlaying,
              sentenceOnly,
              let player,
              let index = playbackSentenceIndex,
              sentences.indices.contains(index) else { return }

        let endTime = sentences[index].endTime
        let rate = max(Double(playbackRate), 0.01)
        let remaining = max(0, (endTime - player.currentTime) / rate)
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleSentenceStopDeadline(expectedIndex: index)
        }
        sentenceStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: workItem)
    }

    private func handleSentenceStopDeadline(expectedIndex: Int) {
        guard isPlaying,
              sentenceOnly,
              playbackSentenceIndex == expectedIndex,
              let player,
              sentences.indices.contains(expectedIndex) else { return }

        let endTime = sentences[expectedIndex].endTime
        guard player.currentTime >= endTime - 0.02 else {
            scheduleSentenceStopDeadline()
            return
        }
        player.currentTime = min(endTime, duration)
        stopPlayback()
    }

    private func refreshPlaybackState() {
        guard let player else { return }
        currentTime = player.currentTime

        if let playbackSentenceIndex,
           sentences.indices.contains(playbackSentenceIndex),
           currentTime >= sentences[playbackSentenceIndex].endTime {
            player.currentTime = min(sentences[playbackSentenceIndex].endTime, duration)
            stopPlayback()
            return
        }

        if !sentenceOnly {
            let index = Self.sentenceIndex(at: currentTime, in: sentences)
            setCurrentSentence(index)
        }

        if !player.isPlaying {
            stopPlayback()
        }
    }

    private func resetPlayerAndAudioAccess() {
        stopPlayback()
        player = nil
        duration = 0
        currentTime = 0
        if let scopedAudioURL {
            scopedAudioURL.stopAccessingSecurityScopedResource()
            self.scopedAudioURL = nil
        }
        activeAudioURL = nil
    }

    // MARK: - Session Persistence (Documents-based on iOS)

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func speechDirectory() -> URL {
        documentsDirectory().appendingPathComponent("speech")
    }

    private static func recordingsDirectory() -> URL {
        documentsDirectory().appendingPathComponent("recordings")
    }

    private func savedSessionURL(for audioURL: URL) -> URL {
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        let folderName = baseName.isEmpty ? audioURL.lastPathComponent : baseName
        return Self.documentsDirectory()
            .appendingPathComponent("sessions")
            .appendingPathComponent(folderName)
            .appendingPathComponent("practice-session.json")
    }

    private static func speechAudioURL(for textURL: URL) -> URL {
        let baseName = textURL.deletingPathExtension().lastPathComponent
        let fileName = baseName.isEmpty ? "speech" : baseName
        return speechDirectory()
            .appendingPathComponent(fileName)
            .appendingPathExtension("wav")
    }

    private static func temporarySpeechURL(for audioURL: URL) -> URL {
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        return audioURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(baseName)-speech-tmp")
            .appendingPathExtension("wav")
    }

    private func schedulePracticeSessionSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.savePracticeSession()
        }
    }

    private func savePracticeSession() {
        guard let activeAudioURL, !sentences.isEmpty, reviewSnapshot == nil else { return }

        let savedSentences = sentences.enumerated().map { index, sentence in
            SavedSentence(
                id: sentence.id,
                text: sentence.text,
                startTime: sentence.startTime,
                endTime: sentence.endTime,
                translation: translatedSentences.indices.contains(index) ? translatedSentences[index] : "",
                originalText: sentence.originalText,
                mergedFrom: Self.savedMergeHistory(sentence.mergedFrom)
            )
        }
        let saved = SavedPracticeSession(
            formatVersion: 1,
            audioFileName: activeAudioURL.lastPathComponent,
            sourceLanguageIdentifier: transcriptLocaleIdentifier,
            sourceLanguageName: sourceLanguageName,
            translationLanguage: selectedTranslationLanguage,
            sentences: savedSentences,
            drafts: drafts,
            answerDraft: answerDraft,
            currentSentenceIndex: currentSentenceIndex,
            currentTime: currentTime,
            playbackRate: playbackRate,
            sentenceOnly: sentenceOnly,
            createdFromText: createdFromText,
            reviewCompleted: !isReviewing
        )

        do {
            let directory = savedSessionURL(for: activeAudioURL).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(saved)
            try data.write(to: savedSessionURL(for: activeAudioURL), options: .atomic)
            if errorMessage?.key == "Could not save practice data: %@" {
                errorMessage = nil
            }
        } catch {
            errorMessage = .format("Could not save practice data: %@", error.localizedDescription)
        }
    }

    // MARK: - Speech Permission

    private func requestSpeechPermission() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            throw DictationError.speechPermissionDenied
        }
    }

    // MARK: - Transcription

    /// If `url` points to a compressed audio file (e.g. MP3), decodes it to a
    /// temporary PCM WAV and returns `(tempURL, true)`.  For files already in
    /// linear PCM the original URL is returned as `(url, false)`.
    private static func decompressAudioIfNeeded(url: URL) throws -> (URL, Bool) {
        let source = try AVAudioFile(forReading: url)
        // kAudioFormatLinearPCM = 'lpcm'
        guard source.fileFormat.streamDescription.pointee.mFormatID != kAudioFormatLinearPCM else {
            return (url, false)
        }
        let processingFormat = source.processingFormat
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let dest = try AVAudioFile(forWriting: tempURL, settings: processingFormat.settings)
        let chunkSize: AVAudioFrameCount = 65536
        let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkSize)!
        while source.framePosition < source.length {
            let toRead = min(chunkSize, AVAudioFrameCount(source.length - source.framePosition))
            try source.read(into: buffer, frameCount: toRead)
            guard buffer.frameLength > 0 else { break }
            try dest.write(from: buffer)
        }
        return (tempURL, true)
    }

    private func recognizeWithDictationTranscriber(url: URL) async throws -> [TimedTranscriptionChunk] {
        guard let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: selectedSpeechLocale)
        ) else {
            throw DictationError.advancedSpeechLocaleUnavailable(selectedSpeechLocale)
        }

        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.frequentFinalization],
            attributeOptions: [.audioTimeRange]
        )
        let modules: [any SpeechModule] = [transcriber]
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            break
        case .supported:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                throw DictationError.speechAssetsNeedManualDownload(selectedSpeechLocale)
            }
            transcriptionMode = .language("Downloading Apple's %@ speech model…", selectedSpeechLocale)
            try await request.downloadAndInstall()
        case .downloading:
            transcriptionMode = .language("Waiting for Apple's %@ speech model to finish downloading…", selectedSpeechLocale)
            while await AssetInventory.status(forModules: modules) == .downloading {
                try await Task.sleep(for: .seconds(1))
            }
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw DictationError.speechAssetsUnavailable(selectedSpeechLocale)
            }
        case .unsupported:
            throw DictationError.speechAssetsUnavailable(selectedSpeechLocale)
        @unknown default:
            throw DictationError.speechAssetsUnavailable(selectedSpeechLocale)
        }

        let (pcmURL, isTemp) = try Self.decompressAudioIfNeeded(url: url)
        defer { if isTemp { try? FileManager.default.removeItem(at: pcmURL) } }
        let audioFile = try AVAudioFile(forReading: pcmURL)
        let analyzer = SpeechAnalyzer(modules: modules)
        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: audioFile.processingFormat
        ) else {
            throw DictationError.incompatibleAudioFormat
        }
        try await analyzer.prepareToAnalyze(in: analysisFormat)
        transcriptionMode = "Transcribing with Apple's long-audio model on this device…"

        let resultCollection = Task {
            var chunks: [TimedTranscriptionChunk] = []
            for try await result in transcriber.results {
                let fallbackStart = result.range.start.seconds
                let fallbackEnd = CMTimeRangeGetEnd(result.range).seconds
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                    let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] ?? result.range
                    let start = timeRange.start.seconds
                    let end = CMTimeRangeGetEnd(timeRange).seconds
                    let safeStart = start.isFinite ? start : fallbackStart
                    let safeEnd = end.isFinite && end > safeStart ? end : fallbackEnd
                    guard safeStart.isFinite, safeEnd.isFinite, safeEnd > safeStart else { continue }
                    chunks.append(TimedTranscriptionChunk(
                        text: text,
                        startTime: safeStart,
                        endTime: safeEnd
                    ))
                }
            }
            return chunks
        }

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch {
            resultCollection.cancel()
            throw error
        }
        return try await resultCollection.value
    }

    // MARK: - Translation

    private func translateTranscript() {
        activeTranslationRequest += 1
        translationWatchdog?.cancel()
        let requestID = activeTranslationRequest
        guard !sentences.isEmpty else {
            translationConfiguration = nil
            return
        }
        let targetLanguage = selectedTranslationLanguage
        let sourceLanguage = String(transcriptLocaleIdentifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "en")
        translatedSentences = Array(repeating: "", count: sentences.count)
        translationStatus = "Preparing Apple's on-device translation…"
        savePracticeSession()

        if sourceLanguage == targetLanguage {
            translatedSentences = sentences.map(\.text)
            translationStatus = "Source and translation languages match"
            translationConfiguration = nil
            savePracticeSession()
            return
        }

        let source = Locale.Language(identifier: sourceLanguage)
        let target = Locale.Language(identifier: targetLanguage)
        translationRunner?.cancel()
        translationConfiguration = nil
        translationRunner = Task { [weak self] in
            guard let self else { return }
            let availability = await LanguageAvailability().status(from: source, to: target)
            guard !Task.isCancelled, requestID == self.activeTranslationRequest else { return }
            switch availability {
            case .installed:
                let session = TranslationSession(installedSource: source, target: target)
                await self.runTranslation(with: session, requestID: requestID)
            case .supported:
                self.startTranslationSession(source: source, target: target, requestID: requestID)
            case .unsupported:
                self.translationStatus = .format("Local translation unavailable: %@", "this language pair isn't supported")
                self.savePracticeSession()
            @unknown default:
                self.startTranslationSession(source: source, target: target, requestID: requestID)
            }
        }
    }

    private func startTranslationSession(
        source: Locale.Language,
        target: Locale.Language,
        requestID: Int,
        isRetry: Bool = false
    ) {
        var configuration = TranslationSession.Configuration(source: source, target: target)
        configuration.invalidate()
        translationConfiguration = configuration

        guard !isRetry else { return }
        translationWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            guard self.activeTranslationRequest == requestID else { return }
            guard self.translationSessionStartedRequestID != requestID else { return }
            self.translationConfiguration = nil
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, self.activeTranslationRequest == requestID else { return }
            self.startTranslationSession(source: source, target: target, requestID: requestID, isRetry: true)
        }
    }

    // MARK: - Punctuation Refinement

    private func refinePunctuation() async {
        guard !sentences.isEmpty else { return }
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            punctuationStatus = "Punctuation unchanged — Apple Intelligence is not available on this device."
            return
        }
        guard model.supportsLocale(Locale(identifier: transcriptLocaleIdentifier)) else {
            punctuationStatus = .language("Punctuation unchanged — Apple Intelligence does not support %@ on this device.", transcriptLocaleIdentifier)
            return
        }

        let originalSentences = sentences
        transcriptionMode = "Refining punctuation locally with Apple Intelligence…"
        let session = LanguageModelSession(
            model: model,
            instructions: """
            You correct punctuation and capitalization in speech-recognition transcripts.
            Preserve every word exactly as written and in the same order. Do not add, remove, \
            replace, translate, or rearrange words. Do not split or combine sentences. \
            Only fix obvious punctuation and capitalization. If uncertain, keep the input unchanged.
            """
        )

        do {
            var correctedSentences = originalSentences
            let batchSize = 12
            for start in stride(from: 0, to: originalSentences.count, by: batchSize) {
                try Task.checkCancellation()
                let end = min(start + batchSize, originalSentences.count)
                let batch = Array(originalSentences[start..<end])
                let contextStart = max(0, start - 2)
                let contextEnd = min(originalSentences.count, end + 2)
                let context = originalSentences[contextStart..<contextEnd]
                let numberedSentences = context.enumerated()
                    .map { index, sentence in
                        let absoluteIndex = contextStart + index
                        let label = absoluteIndex >= start && absoluteIndex < end ? "FIX" : "context"
                        return "\(label) \(absoluteIndex + 1): \(sentence.text)"
                    }
                    .joined(separator: "\n")
                let prompt = """
                Source language: \(sourceLanguageName)

                Check each FIX sentence for obvious punctuation or capitalization errors and correct them when appropriate. Use the surrounding context to interpret the sentence. Preserve every word exactly and keep each FIX sentence as one item. If a change is uncertain, leave that sentence unchanged. Do not output the context sentences.
                \(numberedSentences)
                """
                let response = try await session.respond(
                    to: prompt,
                    generating: PunctuationCorrection.self
                )
                try Task.checkCancellation()

                guard response.content.sentences.count == batch.count else { continue }
                for (offset, suggestion) in response.content.sentences.enumerated() {
                    let original = batch[offset]
                    guard Self.lexicalWords(suggestion) == Self.lexicalWords(original.text) else { continue }
                    correctedSentences[start + offset] = TranscriptSentence(
                        id: original.id,
                        text: Self.formatPunctuationSpacing(suggestion),
                        startTime: original.startTime,
                        endTime: original.endTime
                    )
                }
            }
            sentences = correctedSentences
            punctuationStatus = "Punctuation checked locally with Apple Intelligence. Suggestions that changed words were discarded."
        } catch {
            guard !Task.isCancelled else { return }
            punctuationStatus = .format("Punctuation unchanged — local correction failed: %@", error.localizedDescription)
        }
    }

    // MARK: - OCR Reformatting

    /// Rejoins raw OCR text (which Vision returns split at line breaks, cutting sentences in the
    /// middle) into normal sentences, using on-device Apple Intelligence when it's available, then
    /// formats the result with one sentence per line. Falls back to a simple line-joining heuristic
    /// if Apple Intelligence is unavailable, or if the model's output doesn't preserve the original
    /// words.
    func reformatOCRText(_ rawText: String) async -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            return Self.oneSentencePerLine(Self.heuristicallyJoinedOCRLines(trimmed), localeIdentifier: selectedSpeechLocale)
        }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You clean up raw text extracted by OCR (optical character recognition) from a photo. \
            The OCR breaks sentences across lines wherever the original text wrapped. Rejoin those \
            lines into normal, complete sentences, and fix obvious OCR line-break artifacts such as \
            words split with a hyphen at the end of a line. Preserve every original word exactly, in \
            the same order — do not add, remove, translate, summarize, or rephrase anything. Format \
            the result with exactly one complete sentence per line.
            """
        )

        do {
            let prompt = """
            Reformat this OCR text so sentences are not cut in the middle, with one sentence per line:

            \(trimmed)
            """
            let response = try await session.respond(to: prompt, generating: OCRTextReformat.self)
            let reformatted = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reformatted.isEmpty, Self.lexicalWords(reformatted) == Self.lexicalWords(trimmed) else {
                return Self.oneSentencePerLine(Self.heuristicallyJoinedOCRLines(trimmed), localeIdentifier: selectedSpeechLocale)
            }
            return Self.oneSentencePerLine(reformatted, localeIdentifier: selectedSpeechLocale)
        } catch {
            return Self.oneSentencePerLine(Self.heuristicallyJoinedOCRLines(trimmed), localeIdentifier: selectedSpeechLocale)
        }
    }

    private static func heuristicallyJoinedOCRLines(_ text: String) -> String {
        var paragraphs: [String] = []
        var currentParagraph = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !currentParagraph.isEmpty {
                    paragraphs.append(currentParagraph)
                    currentParagraph = ""
                }
                continue
            }
            if currentParagraph.isEmpty {
                currentParagraph = line
            } else if currentParagraph.hasSuffix("-") {
                currentParagraph.removeLast()
                currentParagraph += line
            } else {
                currentParagraph += " " + line
            }
        }
        if !currentParagraph.isEmpty {
            paragraphs.append(currentParagraph)
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Splits text into sentences with `NLTokenizer` and puts each sentence on its own line.
    private static func oneSentencePerLine(_ text: String, localeIdentifier: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        let language = String(localeIdentifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        if !language.isEmpty {
            tokenizer.setLanguage(NLLanguage(rawValue: language))
        }

        var lines: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let sentence = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                lines.append(sentence)
            }
            return true
        }
        guard !lines.isEmpty else { return trimmed }
        return lines.joined(separator: "\n")
    }

    private static func lexicalWords(_ text: String) -> [String] {
        var words: [String] = []
        var currentWord = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                currentWord.unicodeScalars.append(scalar)
            } else if !currentWord.isEmpty {
                words.append(currentWord.lowercased())
                currentWord = ""
            }
        }
        if !currentWord.isEmpty {
            words.append(currentWord.lowercased())
        }
        return words
    }

    func translate(using session: TranslationSession) async {
        await runTranslation(with: session, requestID: activeTranslationRequest)
    }

    private func runTranslation(with session: TranslationSession, requestID: Int) async {
        translationSessionStartedRequestID = requestID
        let sourceLanguage = String(transcriptLocaleIdentifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "en")
        let targetLanguage = selectedTranslationLanguage
        let sentenceSnapshot = sentences
        translationStatus = "Translating locally with Apple Translation…"

        do {
            for (index, sentence) in sentenceSnapshot.enumerated() {
                try Task.checkCancellation()
                let cacheKey = "\(sourceLanguage):\(targetLanguage):\(sentence.text.lowercased())"
                let translation: String
                if let cached = translationCache[cacheKey] {
                    translation = cached
                } else {
                    translation = try await session.translate(sentence.text).targetText
                    try Task.checkCancellation()
                    translationCache[cacheKey] = translation
                }
                guard requestID == activeTranslationRequest else { return }
                translatedSentences[index] = translation
                translationStatus = .format("Translated %@ of %@", String(index + 1), String(sentenceSnapshot.count))
                savePracticeSession()
            }
            guard requestID == activeTranslationRequest else { return }
            translationStatus = "Translation complete — processed on this device"
            savePracticeSession()
        } catch {
            guard requestID == activeTranslationRequest, !Task.isCancelled else { return }
            translationStatus = .format("Local translation unavailable: %@", error.localizedDescription)
            savePracticeSession()
        }
    }

    // MARK: - Audio Session

    private func activatePlaybackSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            // Non-fatal; playback may still work
        }
    }

    // MARK: - Merge History

    private static func savedMergeHistory(_ pieces: [TranscriptSentence]?) -> [SavedSentence]? {
        pieces?.map { piece in
            SavedSentence(
                id: piece.id,
                text: piece.text,
                startTime: piece.startTime,
                endTime: piece.endTime,
                translation: "",
                originalText: piece.originalText,
                mergedFrom: savedMergeHistory(piece.mergedFrom)
            )
        }
    }

    private static func restoredMergeHistory(_ pieces: [SavedSentence]?) -> [TranscriptSentence]? {
        pieces?.map { piece in
            TranscriptSentence(
                id: piece.id,
                text: piece.text,
                startTime: piece.startTime,
                endTime: piece.endTime,
                originalText: piece.originalText,
                mergedFrom: restoredMergeHistory(piece.mergedFrom)
            )
        }
    }

    static func clampingEndTimes(_ sentences: [TranscriptSentence], duration: TimeInterval) -> [TranscriptSentence] {
        let stopMargin: TimeInterval = 0.15
        return sentences.enumerated().map { index, sentence in
            let cap = index + 1 < sentences.count
                ? sentences[index + 1].startTime - stopMargin
                : duration
            let clampedEnd = max(sentence.startTime + 0.05, min(sentence.endTime, cap))
            guard clampedEnd != sentence.endTime else { return sentence }
            return TranscriptSentence(
                id: sentence.id,
                text: sentence.text,
                startTime: sentence.startTime,
                endTime: clampedEnd,
                originalText: sentence.originalText,
                mergedFrom: sentence.mergedFrom
            )
        }
    }

    private static func sentenceIndex(at time: TimeInterval, in sentences: [TranscriptSentence]) -> Int {
        sentences.lastIndex(where: { time >= $0.startTime }) ?? 0
    }

    // MARK: - Sentence Building

    private static func makeSentences(
        from chunks: [TimedTranscriptionChunk],
        duration: TimeInterval,
        localeIdentifier: String
    ) -> [TranscriptSentence] {
        let sentenceEndings = terminalPunctuationMarks
        let defaultTerminalMark: Unicode.Scalar = (localeIdentifier.hasPrefix("ja") || localeIdentifier.hasPrefix("zh")) ? "。" : "."
        let pauseThreshold: TimeInterval = 0.65
        let maximumSentenceDuration: TimeInterval = 12
        let maximumSentenceWords = 24
        var currentText = ""
        var sentenceStart: TimeInterval?
        var sentenceEnd: TimeInterval = 0
        var wordCount = 0
        var results: [TranscriptSentence] = []

        let closingMarks = CharacterSet(charactersIn: "\"\u{2019}\u{201C}\u{201D}\u{00BB})]}'")
        func endsSentence(_ token: String) -> Bool {
            var scalars = token.unicodeScalars[...]
            while let last = scalars.last, closingMarks.contains(last) {
                scalars = scalars.dropLast()
            }
            guard let last = scalars.last else { return false }
            return sentenceEndings.contains(last)
        }

        func attachOrphanPunctuation(_ token: String, endTime: TimeInterval) {
            guard let lastIndex = results.indices.last else { return }
            let previous = results[lastIndex]
            results[lastIndex] = TranscriptSentence(
                id: previous.id,
                text: formatPunctuationSpacing(previous.text + token),
                startTime: previous.startTime,
                endTime: min(max(previous.endTime, endTime), duration)
            )
        }

        func finishSentence() {
            defer {
                currentText = ""
                sentenceStart = nil
                sentenceEnd = 0
                wordCount = 0
            }
            var text = formatPunctuationSpacing(currentText)
            guard !text.isEmpty, let start = sentenceStart else { return }

            let hasWordContent = text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            guard hasWordContent else {
                attachOrphanPunctuation(text, endTime: sentenceEnd + 0.15)
                return
            }

            if !endsSentence(text) {
                text.unicodeScalars.append(defaultTerminalMark)
            }

            let boundedStart = min(max(start, 0), duration)
            let boundedEnd = min(max(sentenceEnd + 0.15, boundedStart + 0.15), duration)
            results.append(TranscriptSentence(
                id: results.count,
                text: text,
                startTime: boundedStart,
                endTime: boundedEnd
            ))
        }

        for chunk in chunks.sorted(by: { $0.startTime < $1.startTime }) {
            let token = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            let tokenWordCount = token.split(whereSeparator: \.isWhitespace).count
            let punctuationOnly = !token.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) })

            let gap = sentenceStart == nil ? 0 : chunk.startTime - sentenceEnd
            let reachedSentenceLimit = sentenceStart.map {
                chunk.startTime - $0 >= maximumSentenceDuration || wordCount >= maximumSentenceWords
            } ?? false

            if (gap >= pauseThreshold && wordCount >= 3) || reachedSentenceLimit {
                finishSentence()
            }

            if punctuationOnly, currentText.isEmpty {
                attachOrphanPunctuation(token, endTime: chunk.endTime)
                continue
            }

            if sentenceStart == nil {
                sentenceStart = chunk.startTime
            }

            if punctuationOnly {
                currentText += token
            } else {
                if !currentText.isEmpty,
                   !localeIdentifier.hasPrefix("ja"),
                   !localeIdentifier.hasPrefix("zh") {
                    currentText.append(" ")
                }
                currentText += token
            }

            sentenceEnd = max(sentenceEnd, chunk.endTime)
            wordCount += punctuationOnly ? 0 : tokenWordCount

            if endsSentence(token) {
                finishSentence()
            }
        }

        finishSentence()
        return clampingEndTimes(results, duration: duration)
    }

    private static let terminalPunctuationMarks = CharacterSet(charactersIn: ".?!。！？")

    static func formatPunctuationSpacing(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var formatted: [Unicode.Scalar] = []
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                var nextIndex = index + 1
                while nextIndex < scalars.count,
                      CharacterSet.whitespacesAndNewlines.contains(scalars[nextIndex]) {
                    nextIndex += 1
                }
                if nextIndex < scalars.count,
                   CharacterSet.punctuationCharacters.contains(scalars[nextIndex]) {
                    index = nextIndex
                    continue
                }
            }
            if terminalPunctuationMarks.contains(scalar), let last = formatted.last, terminalPunctuationMarks.contains(last) {
                formatted.removeLast()
                formatted.append(scalar)
                index += 1
                continue
            }
            formatted.append(scalar)
            index += 1
        }

        var view = String.UnicodeScalarView()
        view.append(contentsOf: formatted)
        return String(view).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedAnswer(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func alignWords(
        _ typed: [String],
        _ expected: [String]
    ) -> (typedMatches: [Bool], typedExpectedIndices: [Int?], missingExpectedIndices: [Int]) {
        let typedCount = typed.count
        let expectedCount = expected.count
        var distances = Array(
            repeating: Array(repeating: 0, count: expectedCount + 1),
            count: typedCount + 1
        )

        for typedIndex in 0...typedCount {
            distances[typedIndex][0] = typedIndex
        }
        for expectedIndex in 0...expectedCount {
            distances[0][expectedIndex] = expectedIndex
        }

        if typedCount > 0 && expectedCount > 0 {
            for typedIndex in 1...typedCount {
                for expectedIndex in 1...expectedCount {
                    let substitutionCost = typed[typedIndex - 1] == expected[expectedIndex - 1] ? 0 : 1
                    let deletion = distances[typedIndex - 1][expectedIndex] + 1
                    let insertion = distances[typedIndex][expectedIndex - 1] + 1
                    let substitution = distances[typedIndex - 1][expectedIndex - 1] + substitutionCost
                    distances[typedIndex][expectedIndex] = min(deletion, min(insertion, substitution))
                }
            }
        }

        var typedMatches = Array(repeating: false, count: typedCount)
        var typedExpectedIndices = Array<Int?>(repeating: nil, count: typedCount)
        var missingExpectedIndices: [Int] = []
        var typedIndex = typedCount
        var expectedIndex = expectedCount

        while typedIndex > 0 || expectedIndex > 0 {
            if typedIndex > 0,
               expectedIndex > 0,
               typed[typedIndex - 1] == expected[expectedIndex - 1],
               distances[typedIndex][expectedIndex] == distances[typedIndex - 1][expectedIndex - 1] {
                typedMatches[typedIndex - 1] = true
                typedExpectedIndices[typedIndex - 1] = expectedIndex - 1
                typedIndex -= 1
                expectedIndex -= 1
            } else if typedIndex > 0,
                      expectedIndex > 0,
                      distances[typedIndex][expectedIndex] == distances[typedIndex - 1][expectedIndex - 1] + 1 {
                typedExpectedIndices[typedIndex - 1] = expectedIndex - 1
                typedIndex -= 1
                expectedIndex -= 1
            } else if expectedIndex > 0,
                      distances[typedIndex][expectedIndex] == distances[typedIndex][expectedIndex - 1] + 1 {
                missingExpectedIndices.append(expectedIndex - 1)
                expectedIndex -= 1
            } else {
                typedIndex -= 1
            }
        }

        return (typedMatches, typedExpectedIndices, missingExpectedIndices.reversed())
    }

    // MARK: - Speech Synthesis Helpers

    private func readText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = Self.decodeText(data) else {
            throw DictationError.unreadableTextFile
        }
        return text
    }

    private static func decodeText(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .windowsCP1252, .isoLatin1]
        for encoding in encodings {
            guard var text = String(data: data, encoding: encoding) else { continue }
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return text
        }
        return nil
    }

    private func writeSpeech(
        _ pieces: [String],
        voice: SpeechFileVoice,
        to url: URL
    ) async throws -> [TranscriptSentence] {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let speaker = SentenceFileSpeaker()
        fileSpeaker = speaker
        defer { fileSpeaker = nil }

        var audioFile: AVAudioFile?
        var timeline: TimeInterval = 0
        var results: [TranscriptSentence] = []
        let pause: TimeInterval = 0.35

        for (index, piece) in pieces.enumerated() {
            transcriptionMode = .format(
                "Speaking sentence %@ of %@ with %@…",
                String(index + 1),
                String(pieces.count),
                voice.displayName
            )
            let sentenceURL = url
                .deletingLastPathComponent()
                .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-sentence-\(index)")
                .appendingPathExtension("aiff")
            defer {
                if FileManager.default.fileExists(atPath: sentenceURL.path) {
                    try? FileManager.default.removeItem(at: sentenceURL)
                }
            }
            if FileManager.default.fileExists(atPath: sentenceURL.path) {
                try FileManager.default.removeItem(at: sentenceURL)
            }

            try await speaker.speak(piece, voice: voice.voice, to: sentenceURL)
            let spoken = try Self.readAudioFile(at: sentenceURL)
            guard spoken.frameLength > 0, spoken.format.sampleRate > 0 else {
                throw DictationError.speechSynthesisFailed
            }

            if audioFile == nil {
                audioFile = try Self.makeSpeechFile(
                    at: url,
                    sampleRate: spoken.format.sampleRate,
                    channels: spoken.format.channelCount
                )
            }
            guard let audioFile else { throw DictationError.speechSynthesisFailed }

            let start = timeline
            let converted = try Self.convertedBuffer(spoken, to: audioFile.processingFormat)
            guard let writable = Self.preparedBuffer(converted) else {
                throw DictationError.speechSynthesisFailed
            }
            try audioFile.write(from: writable)
            timeline += Double(writable.frameLength) / audioFile.processingFormat.sampleRate

            let silence = try Self.silenceBuffer(duration: pause, format: audioFile.processingFormat)
            try audioFile.write(from: silence)
            timeline += pause
            results.append(TranscriptSentence(
                id: index,
                text: piece,
                startTime: start,
                endTime: timeline
            ))
        }

        guard audioFile != nil, !results.isEmpty else {
            throw DictationError.speechSynthesisFailed
        }
        audioFile = nil
        return results
    }

    private static func readAudioFile(at url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw DictationError.speechSynthesisFailed
        }
        try file.read(into: buffer)
        return buffer
    }

    private static func makeSpeechFile(
        at url: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) throws -> AVAudioFile {
        guard sampleRate > 0, channels > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: true
              ) else {
            throw DictationError.speechSynthesisFailed
        }
        var settings = format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsBigEndianKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
        return try AVAudioFile(forWriting: url, settings: settings)
    }

    private static func silenceBuffer(duration: TimeInterval, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(max(1, (duration * format.sampleRate).rounded(.up)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw DictationError.speechSynthesisFailed
        }
        buffer.frameLength = frames
        guard let prepared = preparedBuffer(buffer) else {
            throw DictationError.speechSynthesisFailed
        }
        let list = UnsafeMutableAudioBufferListPointer(prepared.mutableAudioBufferList)
        for index in 0..<list.count {
            guard let data = list[index].mData, list[index].mDataByteSize > 0 else { continue }
            memset(data, 0, Int(list[index].mDataByteSize))
        }
        return prepared
    }

    private static func preparedBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let bytesPerFrame = max(Int(buffer.format.streamDescription.pointee.mBytesPerFrame), 1)
        let byteCount = Int(buffer.frameLength) * bytesPerFrame
        guard byteCount > 0 else { return nil }
        var hasData = false
        for index in 0..<list.count {
            guard list[index].mData != nil else { continue }
            if list[index].mDataByteSize == 0 {
                list[index].mDataByteSize = UInt32(byteCount)
            }
            if list[index].mDataByteSize > 0 {
                hasData = true
            }
        }
        return hasData ? buffer : nil
    }

    private static func convertedBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw DictationError.speechSynthesisFailed
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw DictationError.speechSynthesisFailed
        }

        let input = PCMConversionInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if input.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            input.consumed = true
            outStatus.pointee = .haveData
            return input.buffer
        }
        if let conversionError {
            throw conversionError
        }
        guard status != .error, output.frameLength > 0 else {
            throw DictationError.speechSynthesisFailed
        }
        return output
    }

    private func speechFileVoice(for localeIdentifier: String) -> SpeechFileVoice? {
        let matches = Self.matchingVoices(for: localeIdentifier)
        guard !matches.isEmpty else { return nil }
        let language = Self.languageCode(for: localeIdentifier)
        if let preferredIdentifier = voicePreferences[language],
           let preferred = matches.first(where: { $0.identifier == preferredIdentifier }) {
            return SpeechFileVoice(voice: preferred, displayName: preferred.name)
        }
        guard let voice = matches.first else { return nil }
        return SpeechFileVoice(voice: voice, displayName: voice.name)
    }

    private static func matchingVoices(for localeIdentifier: String) -> [AVSpeechSynthesisVoice] {
        let normalized = normalizedLocale(localeIdentifier)
        let language = languageCode(for: localeIdentifier)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let exact = voices.filter { $0.language.caseInsensitiveCompare(normalized) == .orderedSame }
        return exact.isEmpty ? voices.filter { $0.language.lowercased().hasPrefix(language) } : exact
    }

    private static func practiceSentences(from text: String, localeIdentifier: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        let language = String(localeIdentifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        if !language.isEmpty {
            tokenizer.setLanguage(NLLanguage(rawValue: language))
        }

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let sentence = formatPunctuationSpacing(String(trimmed[range]))
            guard sentence.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
                return true
            }
            sentences.append(contentsOf: chunksForPractice(sentence, localeIdentifier: localeIdentifier))
            return true
        }

        if sentences.isEmpty {
            let fallback = formatPunctuationSpacing(trimmed)
            guard fallback.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
                return []
            }
            return chunksForPractice(fallback, localeIdentifier: localeIdentifier)
        }
        return sentences
    }

    private static func chunksForPractice(_ sentence: String, localeIdentifier: String) -> [String] {
        let isSpaceless = localeIdentifier.hasPrefix("ja")
            || localeIdentifier.hasPrefix("zh")
            || localeIdentifier.hasPrefix("th")
        if isSpaceless {
            return splitLongText(sentence, limit: 70)
        }

        let words = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 36 else { return [sentence] }

        var chunks: [String] = []
        var current: [String] = []
        for word in words {
            current.append(word)
            let endsClause = word.contains(",") || word.contains(";") || word.contains(":")
            if current.count >= 36 || (current.count >= 24 && endsClause) {
                chunks.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
        }
        return chunks
    }

    private static func splitLongText(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        let separators = CharacterSet(charactersIn: "。！？、，,;； ")
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            let isSeparator = character.unicodeScalars.allSatisfy { separators.contains($0) }
            if current.count >= limit && (isSeparator || current.count >= limit + 20) {
                let chunk = formatPunctuationSpacing(current)
                if !chunk.isEmpty { chunks.append(chunk) }
                current = ""
            }
        }
        let remainder = formatPunctuationSpacing(current)
        if !remainder.isEmpty { chunks.append(remainder) }
        return chunks.isEmpty ? [text] : chunks
    }
}

// MARK: - Private Helpers

private final class PCMConversionInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private struct SpeechFileVoice: @unchecked Sendable {
    let voice: AVSpeechSynthesisVoice
    let displayName: String
}

private final class SpeechBufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFrameCount = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var isFinished = false

    init(url: URL) {
        self.url = url
    }

    func begin(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func receive(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        guard let pcm = buffer as? AVAudioPCMBuffer else {
            finish(failure: DictationError.speechSynthesisFailed)
            return
        }
        guard pcm.frameLength > 0 else {
            finish(failure: framesWritten > 0 ? nil : DictationError.speechSynthesisFailed)
            return
        }
        do {
            if file == nil {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: pcm.format.settings,
                    commonFormat: pcm.format.commonFormat,
                    interleaved: pcm.format.isInterleaved
                )
            }
            try file?.write(from: pcm)
            framesWritten += pcm.frameLength
        } catch {
            finish(failure: error)
        }
    }

    private func finish(failure: Error?) {
        isFinished = true
        file = nil
        let continuation = continuation
        self.continuation = nil
        if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}

@MainActor
private final class SentenceFileSpeaker {
    private var synthesizer: AVSpeechSynthesizer?

    func speak(_ text: String, voice: AVSpeechSynthesisVoice, to url: URL) async throws {
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        defer { self.synthesizer = nil }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let sink = SpeechBufferSink(url: url)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sink.begin(continuation)
            synthesizer.write(utterance) { buffer in
                sink.receive(buffer)
            }
        }
    }
}

// MARK: - Errors

private enum DictationError: LocalizedError {
    case advancedSpeechLocaleUnavailable(String)
    case speechAssetsUnavailable(String)
    case speechAssetsNeedManualDownload(String)
    case incompatibleAudioFormat
    case noSpeechDetected
    case speechPermissionDenied
    case unsupportedSavedSessionVersion
    case savedSessionAudioMismatch
    case emptyText
    case unreadableTextFile
    case speechVoiceUnavailable(String)
    case speechSynthesisFailed
    case speechFileAlreadyExists(String)

    var localizable: LocalizableText {
        switch self {
        case .advancedSpeechLocaleUnavailable(let language):
            return .language("Apple's long-audio transcription model does not support %@ on this device yet.", language)
        case .speechAssetsUnavailable(let language):
            return .language("Apple's speech model for %@ is not installed and the system could not start its download.", language)
        case .speechAssetsNeedManualDownload(let language):
            return .language("Apple's speech model for %@ is not yet downloaded. To install it, go to Settings > General > Dictation, enable Dictation, and add it as a dictation language. Then return here and try again.", language)
        case .incompatibleAudioFormat:
            return "Apple's speech analyzer does not support the audio format in this file."
        case .noSpeechDetected:
            return "No speech was recognized in this audio file."
        case .speechPermissionDenied:
            return "Speech Recognition permission was denied. Allow it in Settings > Privacy & Security > Speech Recognition, then try again."
        case .unsupportedSavedSessionVersion:
            return "This saved practice file was created by an incompatible version of the app."
        case .savedSessionAudioMismatch:
            return "The saved practice file does not match the selected audio file."
        case .emptyText:
            return "This text file has no words to read aloud."
        case .unreadableTextFile:
            return "This text file could not be read. Use a plain text file in UTF-8 or UTF-16."
        case .speechVoiceUnavailable(let language):
            return .language("No text-to-speech voice is available for %@. Add one in Settings > Accessibility > Spoken Content, then try again.", language)
        case .speechSynthesisFailed:
            return "Text to speech did not produce audio for this file."
        case .speechFileAlreadyExists(let fileName):
            return .format("A file named %@ is already in this folder. Move or rename it, then try again.", fileName)
        }
    }

    var errorDescription: String? {
        LocalizationTable.string(localizable, languageCode: "en")
    }
}

extension LocalizableText {
    static func capture(_ error: Error) -> LocalizableText {
        if let dictationError = error as? DictationError {
            return dictationError.localizable
        }
        return .verbatim(error.localizedDescription)
    }
}
