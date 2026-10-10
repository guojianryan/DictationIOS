import FoundationModels
import SwiftUI

/// The CEFR level a generated practice text is written at.
enum TextLevel: String, CaseIterable, Identifiable {
    case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2", c1 = "C1", c2 = "C2"

    var id: String { rawValue }

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
}

@Generable
private struct GeneratedPracticeText {
    @Guide(description: "The practice text only: plain prose, no title, no list, no markdown, no commentary.")
    var text: String
}

enum TextGenerationError: LocalizedError {
    case unavailable
    case unsupportedLanguage(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Intelligence is not available on this device."
        case .unsupportedLanguage(let name): "Apple Intelligence does not support \(name) on this device."
        case .empty: "No text was generated. Please try again."
        }
    }
}

enum TextGenerator {
    /// Generates a practice text in `languageIdentifier`. To replace an earlier text, pass it as
    /// `previousText` together with the user's `feedback` on it.
    static func generate(
        languageIdentifier: String,
        level: TextLevel,
        length: TextLength,
        topic: String,
        previousText: String? = nil,
        feedback: String = ""
    ) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { throw TextGenerationError.unavailable }
        let locale = Locale(identifier: languageIdentifier)
        let languageName = Locale(identifier: "en").localizedString(forIdentifier: languageIdentifier) ?? languageIdentifier
        guard model.supportsLocale(locale) else { throw TextGenerationError.unsupportedLanguage(languageName) }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You write short texts for language learners to practice dictation. Write only in \
            \(languageName). Match the requested CEFR level exactly. Write natural, correct, \
            self-contained prose that reads well aloud, with proper punctuation and no title, \
            list, markdown, or translation.
            """
        )

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

        let response = try await session.respond(to: prompt, generating: GeneratedPracticeText.self)
        let text = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    items: TextLevel.allCases.map { ClayTabItem(value: $0, title: $0.rawValue) },
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

            if generatedText.isEmpty {
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

                generateButton(title: tr("Regenerate"), systemImage: "arrow.clockwise", kind: .secondary)

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
        .onDisappear { task?.cancel() }
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
                    feedback: currentFeedback
                )
                guard !Task.isCancelled else { return }
                generatedText = text
                feedback = ""
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }
}
