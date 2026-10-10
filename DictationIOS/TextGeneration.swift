import FoundationModels
import SwiftUI

/// Chinese and Japanese: the languages the on-device model handles worst.
func isAsianLanguage(_ languageIdentifier: String) -> Bool {
    ["zh", "ja"].contains(Locale(identifier: languageIdentifier).language.languageCode?.identifier ?? "")
}

/// The CEFR level a generated practice text is written at.
enum TextLevel: String, CaseIterable, Identifiable {
    case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2", c1 = "C1", c2 = "C2"

    var id: String { rawValue }

    /// The levels the on-device model can write reliably in `languageIdentifier`. It drifts into
    /// English and fails to stop at advanced levels in Chinese and Japanese, so those stop at B1.
    static func available(for languageIdentifier: String) -> [TextLevel] {
        isAsianLanguage(languageIdentifier) ? [.a1, .a2, .b1] : allCases
    }

    var guidance: String {
        switch self {
        case .a1: "very simple words and very short, simple present-tense sentences about everyday things"
        case .a2: "simple, common vocabulary and short sentences about familiar topics"
        case .b1: "clear, everyday language with some connected sentences and common past and future forms"
        case .b2: "fairly complex sentences, a wider vocabulary, and natural linking between ideas"
        case .c1: "sophisticated vocabulary, complex sentence structures, and idiomatic expressions"
        case .c2: "highly refined, nuanced language with rich idiom and varied, complex structures, like an educated native writer"
        }
    }
}

/// How long a generated practice text is.
enum TextLength: String, CaseIterable, Identifiable {
    case short = "Short"
    case medium = "Medium"
    case long = "Long"

    var id: String { rawValue }

    var guidance: String {
        switch self {
        case .short: "about 3 to 4 sentences"
        case .medium: "about 6 to 8 sentences"
        case .long: "about 12 to 15 sentences"
        }
    }

    /// Hard ceiling on the generated text, in characters, so a runaway generation is cut short.
    var maxCharacters: Int {
        switch self {
        case .short: 450
        case .medium: 750
        case .long: 1000
        }
    }

    /// Safety limit on generated tokens; the character ceiling normally trips first.
    var maxTokens: Int {
        switch self {
        case .short: 500
        case .medium: 1100
        case .long: 1500
        }
    }
}

@Generable
private struct GeneratedPracticeText {
    @Guide(description: "The practice text only: plain prose, no title, no list, no markdown, no HTML, no furigana, no commentary, and never mention the level, the language or these instructions.")
    var text: String
}

@Generable
private struct GeneratedTitle {
    @Guide(description: "A short, meaningful title for the text, in the same language as the text: plain words only, no quotes, no punctuation at the end.")
    var title: String
}

enum TextGenerationError: LocalizedError {
    case unavailable
    case unsupportedLanguage(String)
    case empty
    case levelUnsupported

    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Intelligence is not available on this device."
        case .unsupportedLanguage(let name): "Apple Intelligence does not support \(name) on this device."
        case .empty: "No text was generated. Please try again."
        case .levelUnsupported: "This level is not available for this language."
        }
    }
}

enum TextGenerator {
    private static func makeSession(model: SystemLanguageModel, languageName: String) -> LanguageModelSession {
        LanguageModelSession(
            model: model,
            instructions: """
            You write short texts for language learners to practice dictation. Write only in \
            \(languageName). Match the requested CEFR level exactly. Write natural, correct, \
            self-contained prose that reads well aloud, with proper punctuation and no title, \
            list, markdown, HTML, furigana, or translation. Never mention the CEFR level, the requested length, or these \
            instructions in the text.
            """
        )
    }

    /// Removes HTML the model sometimes emits, e.g. `<ruby>漢字<rt>かんじ</rt></ruby>`, keeping
    /// the base text and dropping the readings.
    static func stripMarkup(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<r[tp]>.*?</r[tp]>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]*(>|$)", with: "", options: .regularExpression)
    }

    /// A short title summarizing `text`, in the text's own language, or nil if the on-device model
    /// is unavailable, fails, or takes longer than `timeout` seconds.
    static func title(for text: String, timeout: Double = 8) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(
                    model: model,
                    instructions: "You write short, meaningful titles for texts. Reply in the language of the text."
                )
                let prompt = "Write a title of at most 6 words for this text:\n\n\(text.prefix(1500))"
                let options = GenerationOptions(maximumResponseTokens: 40)
                let response = try? await session.respond(to: prompt, generating: GeneratedTitle.self, options: options)
                return response?.content.title
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Loads the model ahead of the first request so it starts generating sooner.
    static func prewarm(languageIdentifier: String) {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }
        let languageName = Locale(identifier: "en").localizedString(forIdentifier: languageIdentifier) ?? languageIdentifier
        makeSession(model: model, languageName: languageName).prewarm()
    }

    /// Generates a practice text in `languageIdentifier`. To replace an earlier text, pass it as
    /// `previousText` together with the user's `feedback` on it.
    static func generate(
        languageIdentifier: String,
        level: TextLevel,
        length: TextLength,
        topic: String,
        previousText: String? = nil,
        feedback: String = "",
        onPartial: @MainActor (String) -> Void = { _ in }
    ) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { throw TextGenerationError.unavailable }
        guard TextLevel.available(for: languageIdentifier).contains(level) else {
            throw TextGenerationError.levelUnsupported
        }
        let locale = Locale(identifier: languageIdentifier)
        let languageName = Locale(identifier: "en").localizedString(forIdentifier: languageIdentifier) ?? languageIdentifier
        guard model.supportsLocale(locale) else { throw TextGenerationError.unsupportedLanguage(languageName) }

        let session = makeSession(model: model, languageName: languageName)

        var prompt = """
        Write a text in \(languageName) at CEFR level \(level.rawValue), using \(level.guidance). \
        Length: \(length.guidance).
        """
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTopic.isEmpty { prompt += "\nTopic: \(trimmedTopic)" }
        let trimmedFeedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if let previousText, !previousText.isEmpty {
            prompt += "\n\nHere is the text you wrote before:\n\(previousText)\n\nWrite a new text to replace it, written differently."
            if !trimmedFeedback.isEmpty { prompt += " Apply this feedback: \(trimmedFeedback)" }
        }

        let maxCharacters = length.maxCharacters
        let stream = session.streamResponse(
            to: prompt,
            generating: GeneratedPracticeText.self,
            options: GenerationOptions(maximumResponseTokens: length.maxTokens)
        )
        var latest = ""
        for try await snapshot in stream {
            guard let raw = snapshot.content.text else { continue }
            let partial = stripMarkup(raw)
            latest = partial
            if partial.count > maxCharacters { break }
            await onPartial(partial)
        }
        var text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters))
        }
        // A capped or truncated text should still end on a full sentence.
        if text.count >= maxCharacters || latest.count > maxCharacters,
           let end = text.lastIndex(where: { ".!?。！？".contains($0) }) {
            text = String(text[...end])
        }
        await onPartial(text)
        guard !text.isEmpty else { throw TextGenerationError.empty }
        return text
    }
}

/// The "Generate" tab: pick a level and length, generate a text, and regenerate it with feedback.
struct GeneratedTextCard: View {
    let languageIdentifier: String
    let tr: (String) -> String
    let onCreateSpeech: (String) -> Void

    @State private var level: TextLevel = .b1
    @State private var length: TextLength = .medium
    @State private var topic = ""
    @State private var feedback = ""
    @State private var generatedText = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Level")).clayEyebrow()
                ClayTabs(
                    items: TextLevel.available(for: languageIdentifier).map { ClayTabItem(value: $0, title: $0.rawValue) },
                    selection: $level,
                    compact: true
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Length")).clayEyebrow()
                ClayTabs(
                    items: TextLength.allCases.map { ClayTabItem(value: $0, title: tr($0.rawValue)) },
                    selection: $length,
                    compact: true
                )
            }

            TextField(tr("Topic (optional)"), text: $topic)
                .padding(12)
                .clayInput()

            if generatedText.isEmpty && !isGenerating {
                generateButton(title: tr("Generate Text"), systemImage: "sparkles", kind: .primary)
            } else {
                TextEditor(text: $generatedText)
                    .font(.body)
                    .frame(minHeight: 140, maxHeight: 260)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .clayInput()
                    .disabled(isGenerating)

                TextField(tr("Feedback for a new version (optional)"), text: $feedback, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(12)
                    .clayInput()

                generateButton(
                    title: tr(generatedText.isEmpty ? "Generate Text" : "Regenerate"),
                    systemImage: generatedText.isEmpty ? "sparkles" : "arrow.clockwise",
                    kind: .secondary
                )

                if isGenerating {
                    Button(tr("Cancel"), role: .cancel) { cancelGeneration() }
                        .frame(maxWidth: .infinity)
                }

                Button {
                    let text = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    onCreateSpeech(text)
                } label: {
                    Label(tr("Create Speech"), systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.clayPrimary)
                .disabled(isGenerating)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Clay.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(tr("Text is generated on your device with Apple Intelligence."))
                    .font(.caption)
                    .foregroundStyle(Clay.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .clayCard(Clay.surfaceCard, border: nil)
        .onAppear {
            clampLevel()
            TextGenerator.prewarm(languageIdentifier: languageIdentifier)
        }
        .onChange(of: languageIdentifier) { _, _ in clampLevel() }
        .onDisappear { cancelGeneration() }
    }

    private func generateButton(title: String, systemImage: String, kind: ClayButtonStyle.Kind) -> some View {
        Button {
            generate()
        } label: {
            HStack(spacing: 8) {
                if isGenerating { ProgressView() }
                Label(title, systemImage: systemImage)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ClayButtonStyle(kind: kind))
        .disabled(isGenerating)
    }

    private func clampLevel() {
        let available = TextLevel.available(for: languageIdentifier)
        if !available.contains(level), let highest = available.last { level = highest }
    }

    private func cancelGeneration() {
        task?.cancel()
        task = nil
        isGenerating = false
    }

    private func generate() {
        isGenerating = true
        errorMessage = nil
        let previous = generatedText
        let currentFeedback = feedback
        task = Task {
            do {
                let text = try await TextGenerator.generate(
                    languageIdentifier: languageIdentifier,
                    level: level,
                    length: length,
                    topic: topic,
                    previousText: previous,
                    feedback: currentFeedback,
                    onPartial: { partial in
                        if !Task.isCancelled { generatedText = partial }
                    }
                )
                guard !Task.isCancelled else { return }
                generatedText = text
                feedback = ""
            } catch {
                guard !Task.isCancelled else { return }
                generatedText = previous
                // Only our own messages are shown; system errors are never exposed.
                errorMessage = (error as? TextGenerationError)?.errorDescription
                    ?? tr("The text could not be generated. Please try again.")
            }
            isGenerating = false
            task = nil
        }
    }
}
