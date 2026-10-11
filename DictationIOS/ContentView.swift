import AVFoundation
import PhotosUI
import SwiftUI
import Translation
import UniformTypeIdentifiers
import Vision

private enum SetupChoice {
    case text
    case audio
    case photo
}

private enum PhotoProcessingStage {
    case scanning
    case formatting
}

private enum TextSetupTab: String, CaseIterable, Identifiable {
    case type = "Type"
    case upload = "Upload file"
    case generate = "Generate"
    var id: String { rawValue }
}

private enum AudioSetupTab: String, CaseIterable, Identifiable {
    case upload = "Upload file"
    case record = "Record"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var model = DictationModel()
    @StateObject private var localization = AppLocalization()
    @StateObject private var speaking = SpeakingPracticeModel()
    @State private var setupChoice: SetupChoice?
    @State private var textTab: TextSetupTab = .type
    @State private var audioTab: AudioSetupTab = .upload
    @State private var typedText = ""
    @State private var isNamingText = false
    @State private var showsOriginalText = true
    @State private var showsTranslation = true
    @State private var showsSettings = !UserDefaults.standard.bool(forKey: "hasShownInitialSettings")
    @State private var showsGradePopup = false
    @State private var choicesHaveAppeared = false
    @State private var recentRowHeight: CGFloat = 86
    @State private var gradePopupTask: Task<Void, Never>?
    @State private var showsAudioImporter = false
    @State private var showsTextImporter = false
    @State private var selectedPhotoPickerItem: PhotosPickerItem?
    @State private var photoUIImage: UIImage?
    @State private var isRecognizingPhotoText = false
    @State private var photoProcessingStage: PhotoProcessingStage = .scanning
    @State private var photoRecognizedText = ""
    @State private var photoErrorMessage: LocalizableText?
    @State private var showsCameraCapture = false
    @State private var pendingCropImage: UIImage?
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .light
    @FocusState private var isAnswerFieldFocused: Bool
    /// Whether the playback bar floats above the keyboard while typing. Otherwise it stays in the
    /// page and the page scrolls to keep it visible.
    @AppStorage("floatsPlaybackWhileTyping") private var floatsPlayback = true

    private var typedTextIsEmpty: Bool {
        typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var photoRecognizedTextIsEmpty: Bool {
        photoRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }


    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            Clay.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if model.isTranscribing {
                    transcriptionProgress
                } else if model.isReviewing {
                    reviewView
                } else if model.isEditingSourceText {
                    sourceTextEditView
                } else if model.sentences.isEmpty {
                    setupView
                } else {
                    practiceView
                }
            }
        }
        .foregroundStyle(Clay.ink)
        .tint(Clay.ink)
        // Rebuild the screen on a theme change so every color is resolved again.
        .id(appearance)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: setupChoice)
        .sensoryFeedback(trigger: model.gradeCheckCount) { _, _ in
            model.practiceGradeScore == 100 ? .success : .impact
        }
        .task { await model.loadSpeechLanguages() }
        .translationTask(model.translationConfiguration) { session in
            await model.translate(using: session)
        }
        .sheet(isPresented: $showsSettings, onDismiss: {
            UserDefaults.standard.set(true, forKey: "hasShownInitialSettings")
        }) {
            SettingsSheet(model: model, localization: localization)
        }
        .alert(tr("Saved practice found"), isPresented: $model.isSavedSessionPromptPresented) {
            Button(tr("Resume")) { model.useSavedSession() }
            Button(
                model.pendingImportKind == .text ? tr("New Speech") : tr("New Transcript"),
                role: .destructive
            ) { model.continuePendingImport() }
            Button(tr("Cancel"), role: .cancel) { model.cancelPendingAudioSelection() }
        } message: {
            Text(
                model.pendingImportKind == .text
                    ? tr("Saved speech, translation, and practice progress were found for \u{201C}%@\u{201D}. Use them, or create new speech and replace the saved practice data.", model.pendingAudioName)
                    : tr("Saved transcript, translation, and practice progress were found for \u{201C}%@\u{201D}. Use them, or create a new transcription and replace the saved practice data.", model.pendingAudioName)
            )
        }
        .fileImporter(
            isPresented: $showsAudioImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls): model.importAudio(.success(urls))
            case .failure(let error): model.importAudio(.failure(error))
            }
        }
        .fileImporter(
            isPresented: $showsTextImporter,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls): model.importText(.success(urls))
            case .failure(let error): model.importText(.failure(error))
            }
        }
        .onChange(of: audioTab) { _, tab in
            guard tab != .record, model.isRecording else { return }
            model.stopRecording()
        }
        .onChange(of: selectedPhotoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                defer { selectedPhotoPickerItem = nil }
                do {
                    guard let data = try await newItem.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        photoErrorMessage = "Could not open the selected photo."
                        return
                    }
                    handlePickedPhoto(image)
                } catch {
                    photoErrorMessage = "Could not read the photo."
                }
            }
        }
        .sheet(isPresented: $showsCameraCapture) {
            CameraCaptureView(
                onCapture: { image in
                    showsCameraCapture = false
                    handlePickedPhoto(image)
                },
                onCancel: {
                    showsCameraCapture = false
                }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: Binding(
            get: { pendingCropImage != nil },
            set: { isPresented in if !isPresented { pendingCropImage = nil } }
        )) {
            if let pendingCropImage {
                PhotoCropView(
                    image: pendingCropImage,
                    localization: localization,
                    onCrop: { cropped in
                        self.pendingCropImage = nil
                        photoUIImage = cropped
                        recognizeText(in: cropped)
                    },
                    onCancel: {
                        self.pendingCropImage = nil
                    }
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: model.isPlaying)
                .frame(width: 40, height: 40)
                .background(Clay.pink, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "EchoLingo")
                    .font(.clayTitle)
                    .tracking(-0.4)
                Text(tr("Listen \u{2022} learn \u{2022} level up"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Clay.muted)
            }

            Spacer()

            if !model.sentences.isEmpty {
                Button {
                    returnToSetup()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.clayIcon)
                .accessibilityLabel(tr("Start over"))
            }

            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.clayIcon)
            .accessibilityLabel(tr("Settings"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Setup

    private var setupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if setupChoice == nil {
                    choiceScreen
                } else {
                    detailScreen
                }
                errorBanner
            }
            .padding(16)
        }
    }

    private var choiceScreen: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                EqualizerBars(height: 72)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                    .background(Clay.surfaceSoft, in: RoundedRectangle(cornerRadius: Clay.Radius.xl, style: .continuous))

                Text(tr("What do you want to practice?"))
                    .font(.clayDisplay)
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr("Start from text or from audio. Speech, transcription, and translations stay on your device."))
                    .font(.body)
                    .lineSpacing(3)
                    .foregroundStyle(Clay.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                choiceButton(
                    title: tr("Text"),
                    subtitle: tr("Type words or upload a text file"),
                    systemImage: "text.alignleft",
                    accent: .pink,
                    order: 0
                ) { setupChoice = .text }

                choiceButton(
                    title: tr("Audio"),
                    subtitle: tr("Upload a file or record your own"),
                    systemImage: "waveform",
                    accent: .lavender,
                    order: 1
                ) { setupChoice = .audio }

                choiceButton(
                    title: tr("Photo"),
                    subtitle: tr("Take or upload a photo, then edit the recognized text"),
                    systemImage: "text.viewfinder",
                    accent: .peach,
                    order: 2
                ) { setupChoice = .photo }
            }

            if !model.recentPractices.isEmpty {
                recentPracticesSection
            }
        }
        .onAppear { choicesHaveAppeared = true }
    }

    // MARK: - Recent Practices

    private static let recentAccents: [ClayAccent] = [.ochre, .mint, .lavender, .peach, .pink]

    private var recentPracticesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Recent practices"))
                .clayEyebrow()

            if model.recentPractices.count > Self.visibleRecentRows {
                // Taller lists scroll inside a window that fits exactly three rows.
                ScrollView {
                    recentPracticeRows
                        .padding(.trailing, 12)
                }
                .scrollIndicators(.visible)
                .scrollIndicatorsFlash(onAppear: true)
                .frame(
                    height: recentRowHeight * CGFloat(Self.visibleRecentRows)
                        + Self.recentRowSpacing * CGFloat(Self.visibleRecentRows - 1)
                )
            } else {
                recentPracticeRows
            }
        }
    }

    private static let visibleRecentRows = 3
    private static let recentRowSpacing: CGFloat = 12

    private var recentPracticeRows: some View {
        VStack(spacing: Self.recentRowSpacing) {
            ForEach(Array(model.recentPractices.enumerated()), id: \.element.id) { index, practice in
                recentPracticeRow(practice, accent: Self.recentAccents[index % Self.recentAccents.count])
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        recentRowHeight = height
                    }
            }
        }
    }

    private func recentPracticeRow(_ practice: RecentPractice, accent: ClayAccent) -> some View {
        let sentenceNumber = min(practice.currentSentenceIndex + 1, max(practice.sentenceCount, 1))
        return HStack(spacing: 4) {
            Button {
                model.openRecentPractice(practice)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: sourceIcon(practice.source))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accent.on)
                        .frame(width: 44, height: 44)
                        .background(accent.fill, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(practice.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Clay.ink)
                            .lineLimit(1)
                        Text(recentPracticeDetail(practice))
                            .font(.caption)
                            .foregroundStyle(Clay.muted)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            ProgressView(value: Double(sentenceNumber), total: Double(max(practice.sentenceCount, 1)))
                                .tint(Clay.ink)
                            Text("\(sentenceNumber)/\(practice.sentenceCount)")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Clay.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.clayPressable)

            Menu {
                recentPracticeActions(practice)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Clay.ink)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(tr("More"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 12)
        .clayCard(Clay.surfaceCard, border: nil)
        .contextMenu { recentPracticeActions(practice) }
    }

    @ViewBuilder
    private func recentPracticeActions(_ practice: RecentPractice) -> some View {
        Button {
            model.openRecentPractice(practice)
        } label: {
            Label(tr("Continue"), systemImage: "play.fill")
        }
        Button {
            model.openRecentPractice(practice, fromBeginning: true)
        } label: {
            Label(tr("Start from the beginning"), systemImage: "arrow.counterclockwise")
        }
        Divider()
        Button(role: .destructive) {
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                model.removeRecentPractice(practice)
            }
        } label: {
            Label(tr("Remove from list"), systemImage: "trash")
        }
    }

    private func sourceIcon(_ source: PracticeSource) -> String {
        switch source {
        case .typedText: "keyboard"
        case .textFile: "doc.text"
        case .photo: "text.viewfinder"
        case .audioFile: "waveform"
        case .recording: "mic.fill"
        }
    }

    private func sourceTitle(_ source: PracticeSource) -> String {
        switch source {
        case .typedText: tr("Typed text")
        case .textFile: tr("Text file")
        case .photo: tr("Photo")
        case .audioFile: tr("Audio file")
        case .recording: tr("Recording")
        }
    }

    private func recentPracticeDetail(_ practice: RecentPractice) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: localization.resolvedCode)
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return [
            sourceTitle(practice.source),
            localization.languageName(for: practice.languageIdentifier),
            formatter.localizedString(for: practice.lastPracticed, relativeTo: Date())
        ].joined(separator: " \u{00B7} ")
    }

    // MARK: - Setup Details

    private var detailScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                leaveDetailScreen()
            } label: {
                Label(tr("Back"), systemImage: "arrow.left")
            }
            .buttonStyle(.claySecondary)
            .controlSize(.small)

            languageCard

            if setupChoice == .text {
                ClayTabs(
                    items: TextSetupTab.allCases.map { ClayTabItem(value: $0, title: tr($0.rawValue)) },
                    selection: $textTab
                )

                if textTab == .type {
                    typedTextCard
                } else if textTab == .generate {
                    GeneratedTextCard(
                        languageIdentifier: model.selectedSpeechLocale,
                        tr: { tr($0) }
                    ) { text in
                        importText(text)
                    }
                } else {
                    uploadCard(
                        systemImage: "doc.text",
                        title: tr("Upload a text file"),
                        message: tr("The text is read aloud, and the spoken audio is saved in your folder."),
                        buttonTitle: tr("Choose Text"),
                        accent: .pink
                    ) { showsTextImporter = true }
                }
            } else if setupChoice == .audio {
                ClayTabs(
                    items: AudioSetupTab.allCases.map { ClayTabItem(value: $0, title: tr($0.rawValue)) },
                    selection: $audioTab
                )

                if audioTab == .upload {
                    uploadCard(
                        systemImage: "waveform",
                        title: tr("Upload an audio file"),
                        message: tr("MP3, WAV, M4A, and other audio formats are transcribed on your device."),
                        buttonTitle: tr("Choose Audio"),
                        accent: .lavender
                    ) { showsAudioImporter = true }
                } else {
                    recordingCard
                }
            } else {
                if photoUIImage != nil && !isRecognizingPhotoText {
                    photoReviewCard
                } else {
                    photoCaptureCard
                }
                if let message = photoErrorMessage {
                    errorBanner(message)
                }
            }
        }
    }

    private var languageCard: some View {
        HStack(spacing: 10) {
            Picker(tr("Spoken language"), selection: $model.selectedSpeechLocale) {
                ForEach(model.speechLanguages) { language in
                    Text(localization.languageName(for: language.identifier)).tag(language.identifier)
                }
            }
            .frame(maxWidth: .infinity)

            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Clay.muted)

            Picker(tr("Translation"), selection: $model.selectedTranslationLanguage) {
                ForEach(TranslationLanguage.supported) { language in
                    Text(localization.languageName(for: language.code)).tag(language.code)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .clayCard(Clay.surfaceCard, border: nil)
    }

    private var typedTextCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $typedText)
                    .font(.body)
                    .frame(minHeight: 140, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if typedText.isEmpty {
                    Text(tr("Type or paste the text you want to hear\u{2026}"))
                        .font(.body)
                        .foregroundStyle(Clay.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .clayInput()

            Text(tr("Speech is generated on your device and saved in your folder."))
                .font(.caption)
                .foregroundStyle(Clay.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                saveTypedTextAndCreateSpeech()
            } label: {
                Label(tr("Create Speech"), systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.clayPrimary)
            .disabled(typedTextIsEmpty)
        }
        .padding(16)
        .clayCard(Clay.surfaceCard, border: nil)
    }

    private var recordingCard: some View {
        VStack(spacing: 16) {
            if model.hasRecordingPreview && !model.isRecording {
                recordingReview
            } else {
                EqualizerBars(height: 44, isAnimating: model.isRecording)
                    .frame(width: 160)
                    .opacity(model.isRecording ? 1 : 0.35)

                Text(Self.timeString(model.recordingDuration))
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(model.isRecording ? Clay.errorText : Clay.ink)

                Button {
                    if model.isRecording { model.stopRecording() }
                    else { model.startRecording() }
                } label: {
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 80, height: 80)
                        .background(model.isRecording ? Clay.error : Clay.pink, in: Circle())
                }
                .buttonStyle(.clayPressable)
                .accessibilityLabel(model.isRecording ? tr("Stop") : tr("Record"))

                Text(model.isRecording
                     ? tr("Recording. Press stop when you are finished, then listen back.")
                     : tr("Record with your microphone. You can play it back before saving."))
                    .font(.subheadline)
                    .foregroundStyle(Clay.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .clayCard(Clay.surfaceCard, radius: Clay.Radius.xl, border: model.isRecording ? Clay.error : nil)
    }

    private var recordingReview: some View {
        VStack(spacing: 14) {
            Text(tr("Listen to your recording"))
                .font(.clayTitle)

            HStack(spacing: 8) {
                Text(Self.timeString(model.recordingPreviewTime))
                    .monospacedDigit()
                    .foregroundStyle(Clay.muted)
                Slider(value: Binding(
                    get: { model.recordingPreviewTime },
                    set: { model.seekRecordingPreview(to: $0) }
                ), in: 0...max(model.recordingPreviewDuration, 0.1))
                .tint(Clay.pink)
                Text(Self.timeString(model.recordingPreviewDuration))
                    .monospacedDigit()
                    .foregroundStyle(Clay.muted)
            }
            .font(.caption)

            HStack(spacing: 12) {
                Button {
                    model.toggleRecordingPlayback()
                } label: {
                    Label(model.isPlayingRecording ? tr("Pause") : tr("Play"),
                          systemImage: model.isPlayingRecording ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.claySecondary)

                Button {
                    model.startRecording()
                } label: {
                    Label(tr("Record again"), systemImage: "mic.fill")
                }
                .buttonStyle(.claySecondary)
            }

            Button {
                saveRecordingAndStartDictation()
            } label: {
                Label(tr("Start Dictation"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.clayPrimary)

            Text(tr("Play the recording first. When it sounds right, save it and dictation will begin."))
                .font(.caption)
                .foregroundStyle(Clay.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var photoCaptureCard: some View {
        VStack(spacing: 16) {
            if isRecognizingPhotoText {
                EqualizerBars(height: 44)
                    .frame(width: 160)
                Text(photoProcessingStage == .formatting
                     ? tr("Formatting the recognized text\u{2026}")
                     : tr("Reading the text in your photo\u{2026}"))
                    .font(.subheadline)
                    .foregroundStyle(Clay.muted)
            } else {
                accentIcon("text.viewfinder", accent: .peach)
                Text(tr("Scan a photo of text"))
                    .font(.clayTitle)
                Text(tr("Take a photo or choose one from your library. The text is recognized on your device."))
                    .font(.subheadline)
                    .foregroundStyle(Clay.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    if Self.cameraIsAvailable {
                        Button {
                            showsCameraCapture = true
                        } label: {
                            Label(tr("Take Photo"), systemImage: "camera.fill")
                                .frame(width: 60)
                        }
                        .buttonStyle(.clayPrimary)
                    }

                    PhotosPicker(selection: $selectedPhotoPickerItem, matching: .images) {
                        Label(tr("Choose Photo"), systemImage: "photo.on.rectangle")
                            .frame(width: 60)
                    }
                    .buttonStyle(.claySecondary)
                }
                .labelStyle(.iconOnly)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .clayCard(Clay.surfaceCard, radius: Clay.Radius.xl, border: nil)
    }

    private var photoReviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $photoRecognizedText)
                    .font(.body)
                    .frame(minHeight: 140, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if photoRecognizedText.isEmpty {
                    Text(tr("No text was recognized. You can type it in manually."))
                        .font(.body)
                        .foregroundStyle(Clay.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .clayInput()

            Text(tr("Check the recognized text, fix any mistakes, then create the speech."))
                .font(.caption)
                .foregroundStyle(Clay.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    resetPhotoCapture()
                } label: {
                    Label(tr("Retake"), systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.claySecondary)

                Spacer()

                Button {
                    savePhotoTextAndCreateSpeech()
                } label: {
                    Label(tr("Create Speech"), systemImage: "waveform")
                }
                .buttonStyle(.clayPrimary)
                .disabled(photoRecognizedTextIsEmpty)
            }
        }
        .padding(16)
        .clayCard(Clay.surfaceCard, border: nil)
    }

    // MARK: - Transcription Progress

    private var transcriptionProgress: some View {
        VStack(spacing: 16) {
            Spacer()
            EqualizerBars(height: 72)
                .frame(width: 200)
            Text(model.processingTitle.isEmpty ? tr("Working on %@", model.fileName) : localized(model.processingTitle))
                .font(.clayTitle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(model.transcriptionMode.isEmpty ? tr("Preparing\u{2026}") : localized(model.transcriptionMode))
                .font(.subheadline)
                .foregroundStyle(Clay.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Source Text Edit

    private var sourceTextEditView: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Edit the text"))
                    .font(.clayTitle)
                Text(tr("This text is the source, so any change regenerates the speech for it."))
                    .font(.subheadline)
                    .foregroundStyle(Clay.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TextEditor(text: Binding(
                get: { model.sourceTextDraft },
                set: { model.sourceTextDraft = $0 }
            ))
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clayInput()

            HStack(spacing: 12) {
                Button(tr("Cancel")) {
                    model.cancelEditingSourceText()
                }
                .buttonStyle(.claySecondary)
                Spacer()
                Button {
                    Task { await model.confirmSourceTextEdit() }
                } label: {
                    Label(tr("Regenerate Speech"), systemImage: "waveform")
                }
                .buttonStyle(.clayPrimary)
                .disabled(model.sourceTextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                errorBanner(message).padding(.horizontal, 16).padding(.top, 4)
            }
        }
    }

    // MARK: - Review

    private var reviewView: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("Review the transcription"))
                    .font(.clayTitle)
                Text(tr("Listen to each sentence and fix any mistakes. Punctuation and capitalization changes don't count."))
                    .font(.subheadline)
                    .foregroundStyle(Clay.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(model.sentences.enumerated()), id: \.element.id) { index, sentence in
                        ReviewRow(
                            model: model,
                            localization: localization,
                            index: index,
                            sentence: sentence
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            reviewFooter
        }
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                errorBanner(message).padding(.horizontal, 16).padding(.top, 4)
            }
        }
    }

    private var reviewFooter: some View {
        let blockedCount = model.reviewBlockedCount
        return VStack(spacing: 8) {
            if blockedCount > 0 {
                Label(tr("Fix the highlighted sentences to continue."), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Clay.errorText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                if model.canCancelReview {
                    Button(tr("Cancel")) { model.cancelReview() }
                        .buttonStyle(.claySecondary)
                }
                Spacer()
                Button {
                    model.confirmReview()
                } label: {
                    Label(
                        model.canCancelReview ? tr("Save") : tr("Confirm"),
                        systemImage: "checkmark.circle.fill"
                    )
                }
                .buttonStyle(.clayPrimary)
                .disabled(blockedCount > 0)
            }
        }
        .padding(14)
        .clayCard(Clay.surfaceCard, border: nil)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Practice

    private var practiceView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    sessionCard

                    textPanels

                    if model.sentenceOnly {
                        practiceCard
                            .id("answerField")
                            .overlay(alignment: .top) {
                                if showsGradePopup, !model.practiceGradeTitle.isEmpty {
                                    gradePopup
                                        .offset(y: -30)
                                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                                }
                            }
                            .onChange(of: model.gradeCheckCount) { _, _ in flashGradePopup() }

                        if model.practiceGradeScore == 100 {
                            speakingCard
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }

                    if !playbackFloats {
                        playbackControls()
                            .id("playbackControls")
                    }
                }
                .padding(16)
            }
            // While typing, keep play within reach just above the keyboard.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if playbackFloats {
                    playbackControls(compact: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
            .onChange(of: isAnswerFieldFocused) { _, focused in
                guard focused else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation(.easeOut(duration: 0.25)) {
                        // Floating: show the answer field. Docked: show the playback bar under it.
                        proxy.scrollTo(floatsPlayback ? "answerField" : "playbackControls", anchor: .bottom)
                    }
                }
            }
            .onChange(of: floatsPlayback) { _, _ in
                guard isAnswerFieldFocused else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(floatsPlayback ? "answerField" : "playbackControls", anchor: .bottom)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                errorBanner(message).padding(.horizontal, 16).padding(.top, 4)
            }
        }
    }

    private var textPanels: some View {
        Group {
            if showsOriginalText || showsTranslation {
                VStack(spacing: 12) {
                    if showsOriginalText {
                        transcriptCard
                    }
                    if showsTranslation {
                        translationCard
                    }
                }
            } else {
                Label(tr("Turn on Original text or Translation to show a panel."), systemImage: "eye.slash")
                    .font(.subheadline)
                    .foregroundStyle(Clay.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
    }

    private var sessionCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: model.isPlaying)
                    .frame(width: 40, height: 40)
                    .background(Clay.pink, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(localized(model.sessionDetail))
                        .font(.caption)
                        .foregroundStyle(Clay.muted)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(model.currentSentenceIndex + 1)/\(model.sentences.count)")
                    .font(.callout.monospacedDigit().weight(.bold))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.currentSentenceIndex)
                    .foregroundStyle(Clay.onColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Clay.ochre, in: Capsule())
            }

            HStack(spacing: 8) {
                Toggle(isOn: $showsOriginalText) {
                    Label(tr("Original"), systemImage: "text.quote")
                }
                .toggleStyle(ClayChipToggleStyle(accent: .lavender))

                Toggle(isOn: $showsTranslation) {
                    Label(tr("Translation"), systemImage: "character.bubble")
                }
                .toggleStyle(ClayChipToggleStyle(accent: .mint))

                if model.canEditText {
                    Button {
                        model.beginEditingText()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.clayIcon)
                    .accessibilityLabel(tr("Edit text"))
                } else if model.canEditSourceText {
                    Button {
                        model.beginEditingSourceText()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.clayIcon)
                    .accessibilityLabel(tr("Edit text"))
                }

                Spacer()

                modeSwitcher
            }
        }
        .padding(14)
        .clayCard(Clay.surfaceCard, border: nil)
    }

    private var modeSwitcher: some View {
        ClayTabs(
            items: [
                ClayTabItem(value: false, title: tr("Listen"), systemImage: "ear"),
                ClayTabItem(value: true, title: tr("Dictate"), systemImage: "pencil.and.outline")
            ],
            selection: $model.sentenceOnly,
            iconOnly: true
        )
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(localization.languageName(for: model.selectedSpeechLocale), systemImage: "text.quote")
                .clayBadge(.lavender)

            sentencePanel(model.sentences.map(\.text), accent: .lavender, height: 118)

            if !model.punctuationStatus.isEmpty {
                Text(localized(model.punctuationStatus))
                    .font(.caption)
                    .foregroundStyle(Clay.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clayCard()
    }

    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tr("Translation"), systemImage: "character.bubble")
                    .clayBadge(.mint)
                Spacer()
                Picker(tr("Translation language"), selection: $model.selectedTranslationLanguage) {
                    ForEach(TranslationLanguage.supported) { language in
                        Text(localization.languageName(for: language.code)).tag(language.code)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 130)
            }

            sentencePanel(
                model.sentences.indices.map { index in
                    model.translatedSentences.indices.contains(index) ? model.translatedSentences[index] : ""
                },
                accent: .mint,
                height: 118
            )

            Text(translationCaption)
                .font(.caption)
                .foregroundStyle(Clay.muted)
        }
        .padding(14)
        .clayCard()
    }

    private func sentencePanel(_ texts: [String], accent: ClayAccent, height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                sentenceRows(texts, accent: accent)
            }
            .frame(height: height)
            .onAppear {
                proxy.scrollTo(model.currentSentenceIndex, anchor: .center)
            }
            .onChange(of: model.currentSentenceIndex) { _, newIndex in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func sentenceRows(_ texts: [String], accent: ClayAccent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
                let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanText.isEmpty {
                    let isCurrent = index == model.currentSentenceIndex
                    Button {
                        model.selectSentence(index, play: true)
                    } label: {
                        Text(cleanText)
                            .font(.body)
                            .lineSpacing(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(isCurrent ? accent.on : Clay.body)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                isCurrent ? accent.fill : Color.clear,
                                in: RoundedRectangle(cornerRadius: Clay.Radius.sm, style: .continuous)
                            )
                            .animation(.spring(duration: 0.3, bounce: 0.2), value: isCurrent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var practiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(tr("Write what you hear"), systemImage: "pencil.and.outline")
                        .clayBadge(.ochre)
                    Text(tr("Listen closely, then write the sentence from memory."))
                        .font(.caption)
                        .foregroundStyle(Clay.muted)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button {
                        model.toggleAnswerVisibility()
                    } label: {
                        Image(systemName: model.answerIsRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.clayIcon)
                    Button {
                        model.checkAnswer()
                    } label: {
                        Label(tr("Check"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Clay.onInk)
                            .frame(width: 40, height: 40)
                            .background(Clay.ink, in: Circle())
                    }
                    .buttonStyle(.clayPressable)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: Binding(
                        get: { model.answerDraft },
                        set: { model.updateAnswerDraft($0) }
                    ))
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .focused($isAnswerFieldFocused)
                    .clayInput(
                        border: isAnswerFieldFocused ? Clay.ink : Clay.hairline,
                        lineWidth: isAnswerFieldFocused ? 1.5 : 1
                    )

                    if !model.practiceFeedback.isEmpty {
                        Text(localized(model.practiceFeedback))
                            .font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Clay.surfaceCard, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
                    }

                    if !model.practiceWordResults.isEmpty {
                        Text(practiceDiff)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if !model.missingPracticeWords.isEmpty {
                            Text(tr("Missing: %@", model.missingPracticeWords.joined(separator: " ")))
                                .font(.callout)
                                .foregroundStyle(Clay.errorText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 10) {
                            Label(tr("Correct"), systemImage: "checkmark").foregroundStyle(Clay.successText)
                            Label(tr("Review"), systemImage: "xmark").foregroundStyle(Clay.errorText)
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(14)
        .clayCard()
    }

    private var gradePopup: some View {
        let accent = scoreAccent(model.practiceGradeScore ?? 0)
        return HStack(spacing: 12) {
            Image(systemName: model.practiceGradeScore == 100 ? "star.fill" : "sparkles")
                .font(.title3.weight(.bold))
                .symbolEffect(.bounce, value: model.gradeCheckCount)
                .frame(width: 42, height: 42)
                .background(accent.on.opacity(0.12), in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(model.practiceGradeTitle))
                    .font(.clayTitle)
                Text("\(model.practiceGradeScore ?? 0)%")
                    .font(.subheadline.weight(.bold).monospacedDigit())
            }
        }
        .foregroundStyle(accent.on)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(accent.fill, in: RoundedRectangle(cornerRadius: Clay.Radius.lg, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .allowsHitTesting(false)
    }

    private func flashGradePopup() {
        gradePopupTask?.cancel()
        withAnimation(.spring(duration: 0.4, bounce: 0.45)) { showsGradePopup = true }
        gradePopupTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { showsGradePopup = false }
        }
    }

    private var practiceDiff: AttributedString {
        var result = AttributedString()
        for word in model.practiceWordResults {
            if !result.characters.isEmpty { result.append(AttributedString(" ")) }
            var typedWord = AttributedString(word.text)
            typedWord.foregroundColor = word.isCorrect ? Clay.successText : Clay.errorText
            result.append(typedWord)
            if let expectedText = word.expectedText {
                var correction = AttributedString(" → \(expectedText)")
                correction.foregroundColor = Clay.successText
                result.append(correction)
            }
        }
        return result
    }

    private func scoreAccent(_ score: Int) -> ClayAccent {
        switch score {
        case 100: .mint
        case 85...: .lavender
        case 65..<85: .ochre
        default: .peach
        }
    }

    // MARK: - Speaking Practice

    private var speakingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label(tr("Say it out loud"), systemImage: "waveform.and.mic")
                    .clayBadge(.pink)
                Text(tr("Record yourself reading the sentence. Try as many times as you like."))
                    .font(.caption)
                    .foregroundStyle(Clay.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button {
                    guard let sentence = model.currentSentence else { return }
                    model.pausePlayback()
                    isAnswerFieldFocused = false
                    speaking.toggleRecording(expectedText: sentence.text, localeIdentifier: model.selectedSpeechLocale)
                } label: {
                    Image(systemName: speaking.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 56, height: 56)
                        .background(speaking.isRecording ? Clay.error : Clay.pink, in: Circle())
                }
                .buttonStyle(.clayPressable)
                .accessibilityLabel(speaking.isRecording ? tr("Stop") : tr("Record"))

                if speaking.hasRecording && !speaking.isRecording {
                    Button {
                        model.pausePlayback()
                        speaking.togglePlayback()
                    } label: {
                        Image(systemName: speaking.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Clay.ink)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 56, height: 56)
                            .background(Clay.surfaceCard, in: Circle())
                    }
                    .buttonStyle(.clayPressable)
                    .accessibilityLabel(speaking.isPlaying ? tr("Stop") : tr("Play my recording"))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(speaking.isRecording
                         ? tr("Listening\u{2026}")
                         : (speaking.attemptCount > 0 ? tr("Record again") : tr("Tap to record")))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(speaking.isRecording ? Clay.errorText : Clay.ink)
                    if speaking.attemptCount > 0 && !speaking.isRecording {
                        Text(tr("Attempts: %@", String(speaking.attemptCount)))
                            .font(.caption)
                            .foregroundStyle(Clay.muted)
                    }
                }

                Spacer(minLength: 8)

                if let score = speaking.score, !speaking.isRecording {
                    let accent = scoreAccent(score)
                    VStack(spacing: 0) {
                        Text("\(score)%")
                            .font(.title3.weight(.heavy).monospacedDigit())
                        Text(tr(speakingRatingTitle(score)))
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(accent.on)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(accent.fill, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
                }
            }

            if speaking.isRecording || speaking.score != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Recognized"))
                        .clayEyebrow()
                    Text(speaking.recognizedText.isEmpty
                         ? (speaking.isRecording ? tr("Start speaking\u{2026}") : tr("Nothing was recognized. Try again."))
                         : speaking.recognizedText)
                        .font(.callout)
                        .foregroundStyle(speaking.recognizedText.isEmpty ? Clay.muted : Clay.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Clay.surfaceCard, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
            }

            if !speaking.wordResults.isEmpty && !speaking.isRecording {
                Text(spokenDiff)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label(tr("Heard"), systemImage: "checkmark").foregroundStyle(Clay.successText)
                    Label(tr("Not heard"), systemImage: "xmark").foregroundStyle(Clay.errorText)
                }
                .font(.caption)
            }

            if let message = speaking.errorMessage {
                Text(localized(message))
                    .font(.caption)
                    .foregroundStyle(Clay.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clayCard(border: speaking.isRecording ? Clay.error : Clay.hairline)
        .onDisappear { speaking.reset() }
    }

    private var spokenDiff: AttributedString {
        var result = AttributedString()
        for word in speaking.wordResults {
            if !result.characters.isEmpty { result.append(AttributedString(" ")) }
            var spokenWord = AttributedString(word.text)
            spokenWord.foregroundColor = word.isRecognized ? Clay.successText : Clay.errorText
            result.append(spokenWord)
        }
        return result
    }

    private func speakingRatingTitle(_ score: Int) -> String {
        switch score {
        case 100: "Perfect!"
        case 85...: "Almost there!"
        case 65..<85: "Great effort!"
        default: "Keep going!"
        }
    }

    // MARK: - Playback Controls

    private var playbackFloats: Bool { isAnswerFieldFocused && floatsPlayback }

    private func playbackControls(compact: Bool = false) -> some View {
        VStack(spacing: 12) {
            if !compact {
                HStack(spacing: 8) {
                    Text(Self.timeString(model.currentTime))
                        .monospacedDigit()
                    Slider(value: Binding(
                        get: { model.currentTime },
                        set: { model.seek(to: $0) }
                    ), in: 0...max(model.duration, 1))
                    .tint(Clay.ochre)
                    Text(Self.timeString(model.duration))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
            }

            HStack(spacing: 8) {
                Button {
                    model.moveSentence(by: -1)
                } label: {
                    playbackStepIcon("backward.end.fill")
                }
                .buttonStyle(.clayPressable)
                .accessibilityLabel(tr("Previous sentence"))

                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Clay.onColor)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 60, height: 60)
                        .background(Clay.cream, in: Circle())
                }
                .buttonStyle(.clayPressable)
                .accessibilityLabel(model.isPlaying ? tr("Pause") : tr("Play"))

                Button {
                    model.moveSentence(by: 1)
                } label: {
                    playbackStepIcon("forward.end.fill")
                }
                .buttonStyle(.clayPressable)
                .accessibilityLabel(tr("Next sentence"))

                Spacer()

                Picker(tr("Playback speed"), selection: $model.playbackRate) {
                    Text("0.5×").tag(Float(0.5))
                    Text("0.75×").tag(Float(0.75))
                    Text("1×").tag(Float(1))
                    Text("1.25×").tag(Float(1.25))
                    Text("1.5×").tag(Float(1.5))
                }
                .labelsHidden()
                .tint(.white)
                .frame(width: 90)

                Button {
                    withAnimation(.easeOut(duration: 0.2)) { floatsPlayback.toggle() }
                } label: {
                    Image(systemName: floatsPlayback ? "pin.slash.fill" : "pin.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 28, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(floatsPlayback ? tr("Keep controls in the page while typing") : tr("Float controls above the keyboard while typing"))
            }
        }
        .padding(compact ? 10 : 16)
        .background(Clay.teal, in: RoundedRectangle(cornerRadius: Clay.Radius.xl, style: .continuous))
    }

    private func playbackStepIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.body.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.14), in: Circle())
    }

    // MARK: - Helpers

    private func choiceButton(
        title: String,
        subtitle: String,
        systemImage: String,
        accent: ClayAccent,
        order: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(accent.on.opacity(0.14), in: RoundedRectangle(cornerRadius: Clay.Radius.lg, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.clayTitle)
                    Text(subtitle)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(accent.fill)
                    .frame(width: 36, height: 36)
                    .background(accent.on, in: Circle())
            }
            .foregroundStyle(accent.on)
            .padding(20)
            .background(accent.fill, in: RoundedRectangle(cornerRadius: Clay.Radius.xl, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Clay.Radius.xl, style: .continuous))
        }
        .buttonStyle(.clayPressable)
        .opacity(choicesHaveAppeared ? 1 : 0)
        .offset(y: choicesHaveAppeared ? 0 : 18)
        .animation(.spring(duration: 0.55, bounce: 0.3).delay(Double(order) * 0.07), value: choicesHaveAppeared)
    }

    private func accentIcon(_ systemImage: String, accent: ClayAccent) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(accent.on)
            .frame(width: 72, height: 72)
            .background(accent.fill, in: Circle())
    }

    private func uploadCard(
        systemImage: String,
        title: String,
        message: String,
        buttonTitle: String,
        accent: ClayAccent,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 14) {
            accentIcon(systemImage, accent: accent)
            Text(title)
                .font(.clayTitle)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Clay.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle, action: action)
                .buttonStyle(.clayPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .clayCard(Clay.surfaceCard, radius: Clay.Radius.xl, border: nil)
    }

    private func leaveDetailScreen() {
        model.discardRecording()
        setupChoice = nil
    }

    private func returnToSetup() {
        setupChoice = nil
        textTab = .type
        audioTab = .upload
        typedText = ""
        model.reset()
    }

    private func saveTypedTextAndCreateSpeech() {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        importText(text)
    }

    private static var cameraIsAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    private func handlePickedPhoto(_ image: UIImage) {
        photoRecognizedText = ""
        photoErrorMessage = nil
        pendingCropImage = Self.normalizedOrientation(image)
    }

    private static func normalizedOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func resetPhotoCapture() {
        photoUIImage = nil
        photoRecognizedText = ""
        photoErrorMessage = nil
        isRecognizingPhotoText = false
        pendingCropImage = nil
    }

    private func recognizeText(in image: UIImage) {
        guard let cgImage = image.cgImage else {
            photoErrorMessage = "Could not open the selected photo."
            return
        }
        isRecognizingPhotoText = true
        photoProcessingStage = .scanning
        photoErrorMessage = nil
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        Task {
            let rawText: String
            do {
                rawText = try await Self.performOCR(cgImage: cgImage, orientation: orientation)
            } catch {
                isRecognizingPhotoText = false
                photoErrorMessage = "Could not read the photo."
                return
            }
            let trimmedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRaw.isEmpty else {
                isRecognizingPhotoText = false
                photoRecognizedText = ""
                photoErrorMessage = "No text was found in the photo. Try another photo or a clearer image."
                return
            }
            photoProcessingStage = .formatting
            let formattedText = await model.reformatOCRText(trimmedRaw)
            isRecognizingPhotoText = false
            photoRecognizedText = formattedText
        }
    }

    private static func performOCR(cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try handler.perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }

    private func savePhotoTextAndCreateSpeech() {
        let text = photoRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        importText(text, source: .photo)
    }

    private func saveRecordingAndStartDictation() {
        guard let tempURL = model.prepareRecordingForSave() else { return }
        let recordingsDir = StorageFolder.shared.subfolder("recordings")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        do {
            try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
            let dest = recordingsDir
                .appendingPathComponent("Recording \(formatter.string(from: Date()))")
                .appendingPathExtension("wav")
            // The recording is in the temporary folder, which may be on a different volume
            // than the chosen folder, so it is moved (copied) rather than swapped in place.
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            model.clearSavedRecording()
            model.importAudio(.success([dest]), source: .recording)
        } catch {
            model.reloadRecordingPreview()
            model.showError("Could not save the recording.")
        }
    }

    private var translationCaption: String {
        let status = localized(model.translationStatus)
        if status.isEmpty {
            return tr("Translation is processed on this device with Apple Translation.")
        }
        return tr("Translation is processed on this device with Apple Translation. %@", status)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.errorMessage {
            errorBanner(message)
        }
    }

    private func errorBanner(_ message: LocalizableText) -> some View {
        Label(localized(message), systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(Clay.errorText)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Clay.error.opacity(0.12), in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
    }

    private func tr(_ key: String, _ arguments: String...) -> String {
        localization.string(LocalizableText(key: key, arguments: arguments.map(LocalizableArgument.text)))
    }

    private func localized(_ text: LocalizableText) -> String {
        localization.string(text)
    }

    /// A meaningful title for `text` from the on-device model, falling back to its first line.
    private func suggestedFilename(for text: String) async -> String {
        if let title = await TextGenerator.title(for: text) {
            let cleaned = sanitizedFilename(title)
            if !cleaned.isEmpty { return cleaned }
        }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let cleaned = sanitizedFilename(firstLine)
        return cleaned.isEmpty ? tr("Practice") : cleaned
    }

    private func sanitizedFilename(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-"))
        let cleaned = String(text.unicodeScalars.filter { allowed.contains($0) })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(cleaned.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Names `text` with an automatic title, then creates speech from it.
    private func importText(_ text: String, source: PracticeSource = .typedText) {
        guard !isNamingText else { return }
        isNamingText = true
        Task {
            let name = await suggestedFilename(for: text)
            isNamingText = false
            model.importTypedText(text, suggestedName: name, source: source)
        }
    }

    private static func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let totalSeconds = max(0, Int(time))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

// MARK: - Camera Capture

private struct CameraCaptureView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onCancel()
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - Photo Crop

private enum CropCorner: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

private struct PhotoCropView: View {
    let image: UIImage
    @ObservedObject var localization: AppLocalization
    var onCrop: (UIImage) -> Void
    var onCancel: () -> Void

    /// Normalized to the image's own bounds: (0,0) is the image's top-left corner, (1,1) its bottom-right.
    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var dragBaseRect: CGRect?

    private let minCropFraction: CGFloat = 0.15
    private let handleDiameter: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            Text(tr("Drag the corners to crop the photo, then continue."))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)

            GeometryReader { geo in
                let imageFrame = Self.aspectFitFrame(for: image.size, in: geo.size)
                let box = CGRect(
                    x: imageFrame.minX + cropRect.minX * imageFrame.width,
                    y: imageFrame.minY + cropRect.minY * imageFrame.height,
                    width: cropRect.width * imageFrame.width,
                    height: cropRect.height * imageFrame.height
                )

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)

                    dimOverlay(fullSize: geo.size, box: box)

                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .contentShape(Rectangle())
                        .gesture(moveGesture(imageFrame: imageFrame))

                    ForEach(CropCorner.allCases, id: \.self) { corner in
                        handleView(corner: corner, box: box, imageFrame: imageFrame)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .clipped()

            controls
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func dimOverlay(fullSize: CGSize, box: CGRect) -> some View {
        ZStack {
            Color.black.opacity(0.6)
                .frame(width: fullSize.width, height: max(0, box.minY))
                .position(x: fullSize.width / 2, y: box.minY / 2)
            Color.black.opacity(0.6)
                .frame(width: fullSize.width, height: max(0, fullSize.height - box.maxY))
                .position(x: fullSize.width / 2, y: box.maxY + (fullSize.height - box.maxY) / 2)
            Color.black.opacity(0.6)
                .frame(width: max(0, box.minX), height: box.height)
                .position(x: box.minX / 2, y: box.midY)
            Color.black.opacity(0.6)
                .frame(width: max(0, fullSize.width - box.maxX), height: box.height)
                .position(x: box.maxX + (fullSize.width - box.maxX) / 2, y: box.midY)
        }
        .allowsHitTesting(false)
    }

    private func moveGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let base = dragBaseRect ?? cropRect
                dragBaseRect = base
                let dx = value.translation.width / max(imageFrame.width, 1)
                let dy = value.translation.height / max(imageFrame.height, 1)
                var newRect = base
                newRect.origin.x = min(max(0, base.minX + dx), 1 - base.width)
                newRect.origin.y = min(max(0, base.minY + dy), 1 - base.height)
                cropRect = newRect
            }
            .onEnded { _ in dragBaseRect = nil }
    }

    private func handleView(corner: CropCorner, box: CGRect, imageFrame: CGRect) -> some View {
        Circle()
            .fill(Color.white)
            .overlay { Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1) }
            .frame(width: handleDiameter, height: handleDiameter)
            .shadow(radius: 2)
            .position(corner.point(in: box))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let base = dragBaseRect ?? cropRect
                        dragBaseRect = base
                        let dx = value.translation.width / max(imageFrame.width, 1)
                        let dy = value.translation.height / max(imageFrame.height, 1)
                        cropRect = Self.resizedRect(base: base, corner: corner, dx: dx, dy: dy, minSize: minCropFraction)
                    }
                    .onEnded { _ in dragBaseRect = nil }
            )
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(tr("Cancel"), action: onCancel)
                .buttonStyle(.bordered)
                .tint(.white)

            Button {
                cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button {
                performCrop()
            } label: {
                Label(tr("Use Photo"), systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(16)
    }

    private func performCrop() {
        guard let cgImage = image.cgImage else {
            onCrop(image)
            return
        }
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let cropInPixels = CGRect(
            x: (cropRect.minX * pixelWidth).rounded(),
            y: (cropRect.minY * pixelHeight).rounded(),
            width: (cropRect.width * pixelWidth).rounded(),
            height: (cropRect.height * pixelHeight).rounded()
        ).intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard cropInPixels.width > 0, cropInPixels.height > 0,
              let cropped = cgImage.cropping(to: cropInPixels) else {
            onCrop(image)
            return
        }
        onCrop(UIImage(cgImage: cropped, scale: image.scale, orientation: .up))
    }

    private static func aspectFitFrame(for size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    private static func resizedRect(base: CGRect, corner: CropCorner, dx: CGFloat, dy: CGFloat, minSize: CGFloat) -> CGRect {
        var x0 = base.minX
        var y0 = base.minY
        var x1 = base.maxX
        var y1 = base.maxY
        switch corner {
        case .topLeft:
            x0 += dx; y0 += dy
        case .topRight:
            x1 += dx; y0 += dy
        case .bottomLeft:
            x0 += dx; y1 += dy
        case .bottomRight:
            x1 += dx; y1 += dy
        }
        x0 = max(0, min(x0, x1 - minSize))
        y0 = max(0, min(y0, y1 - minSize))
        x1 = min(1, max(x1, x0 + minSize))
        y1 = min(1, max(y1, y0 + minSize))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func tr(_ key: String, _ arguments: String...) -> String {
        localization.string(LocalizableText(key: key, arguments: arguments.map(LocalizableArgument.text)))
    }
}

// MARK: - Review Row

private struct ReviewRow: View {
    @ObservedObject var model: DictationModel
    @ObservedObject var localization: AppLocalization
    let index: Int
    let sentence: TranscriptSentence

    @State private var editedText = ""
    @FocusState private var isFocused: Bool

    private func tr(_ key: String, _ arguments: String...) -> String {
        localization.string(LocalizableText(key: key, arguments: arguments.map(LocalizableArgument.text)))
    }

    var body: some View {
        let status = model.reviewStatus(at: index)
        let isPlayingThis = model.isPlaying && model.currentSentenceIndex == index
        let isEdited = sentence.text != sentence.originalText

        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(Clay.muted)
                Button {
                    model.toggleReviewPlayback(at: index)
                } label: {
                    Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Clay.onInk)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                        .background(Clay.ink, in: Circle())
                }
                .buttonStyle(.clayPressable)
            }

            VStack(alignment: .leading, spacing: 7) {
                TextField("", text: $editedText, axis: .vertical)
                    .focused($isFocused)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(10)
                    .clayInput(
                        border: status.isOverLimit ? Clay.error : (isFocused ? Clay.ink : Clay.hairline),
                        lineWidth: status.isOverLimit ? 2 : 1
                    )
                    .onAppear { editedText = sentence.text }
                    .onChange(of: editedText) { _, newValue in
                        model.updateReviewText(newValue, at: index)
                    }
                    .onChange(of: model.reviewExternalEditRevision) { _, _ in
                        guard model.sentences.indices.contains(index) else { return }
                        isFocused = false
                        editedText = model.sentences[index].text
                    }

                VStack(alignment: .leading, spacing: 3) {
                    if status.changedWords > 0 {
                        Text(tr("%@ of %@ words changed (limit %@)",
                             String(status.changedWords),
                             String(status.originalWordCount),
                             String(status.allowedChanges)))
                            .foregroundStyle(status.isOverLimit ? Clay.errorText : Clay.muted)
                    }
                    if status.isEmpty {
                        Text(tr("A sentence can't be empty.")).foregroundStyle(Clay.errorText)
                    } else if status.isOverLimit {
                        Text(tr("Too many words changed. Revert or reduce the changes to continue.")).foregroundStyle(Clay.errorText)
                    }
                }
                .font(.caption)

                HStack(spacing: 8) {
                    Button {
                        model.revertReviewSentence(at: index)
                    } label: {
                        Label(tr("Revert"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!isEdited)

                    if model.canUnmergeReviewSentence(at: index) {
                        Button {
                            model.unmergeReviewSentence(at: index)
                        } label: {
                            Label(tr("Unmerge"), systemImage: "arrow.triangle.branch")
                        }
                    }

                    if index < model.sentences.count - 1 {
                        Button {
                            model.mergeReviewSentence(at: index)
                        } label: {
                            Label(tr("Merge"), systemImage: "arrow.triangle.merge")
                        }
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .tint(Clay.ink)

                if isEdited {
                    Text(tr("Recognized: %@", sentence.originalText))
                        .font(.caption)
                        .foregroundStyle(Clay.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .clayCard(
            status.isOverLimit ? Clay.error.opacity(0.1) : Clay.surfaceCard,
            border: status.isOverLimit ? Clay.error : nil
        )
    }
}

// MARK: - Settings Sheet

private struct SettingsSheet: View {
    @ObservedObject var model: DictationModel
    @ObservedObject var localization: AppLocalization
    @ObservedObject private var storageFolder = StorageFolder.shared
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .light
    @Environment(\.dismiss) private var dismiss
    @State private var showsFolderPicker = false
    @State private var folderErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(localization.string("Theme")) {
                    Group {
                        Picker(localization.string("Theme"), selection: Binding(
                            get: { appearance },
                            set: { newValue in
                                appearance = newValue
                                newValue.apply()
                            }
                        )) {
                            ForEach(AppAppearance.allCases) { option in
                                Text(localization.string(LocalizableText(key: option.title))).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .listRowBackground(Clay.surfaceCard)
                }
                Section {
                    Group {
                        Picker(localization.string("App language"), selection: $localization.appLanguage) {
                            Text(localization.string("System")).tag("system")
                            ForEach(AppLocalization.choices, id: \.id) { choice in
                                Text(choice.title).tag(choice.id)
                            }
                        }
                    }
                    .listRowBackground(Clay.surfaceCard)
                }
                Section {
                    Group {
                        Picker(localization.string("Default spoken language"), selection: $model.defaultSpeechLocale) {
                            ForEach(model.speechLanguages) { language in
                                Text(localization.languageName(for: language.identifier)).tag(language.identifier)
                            }
                        }
                        Picker(localization.string("Default translation language"), selection: $model.defaultTranslationLanguage) {
                            ForEach(TranslationLanguage.supported) { language in
                                Text(localization.languageName(for: language.code)).tag(language.code)
                            }
                        }
                    }
                    .listRowBackground(Clay.surfaceCard)
                } footer: {
                    Text(localization.string("Defaults are used when you start. A language you pick while adding text or audio applies only to that session."))
                }
                Section {
                    Group {
                        Picker(localization.string("Voice"), selection: voiceSelection) {
                            Text(localization.string("Automatic")).tag(String?.none)
                            ForEach(availableVoices, id: \.identifier) { voice in
                                Text(voiceLabel(voice)).tag(String?.some(voice.identifier))
                            }
                        }
                    }
                    .listRowBackground(Clay.surfaceCard)
                } footer: {
                    Text(localization.string(.format(
                        "The voice used to read %@. Change the spoken language above to choose a voice for a different language.",
                        localization.languageName(for: model.defaultSpeechLocale)
                    )))
                }
                Section {
                    Group {
                        LabeledContent(localization.string("Folder")) {
                            Text(storageFolder.displayName ?? localization.string("Documents (default)"))
                        }
                        Button(localization.string("Choose Folder")) {
                            showsFolderPicker = true
                        }
                        if storageFolder.chosenURL != nil {
                            Button(localization.string("Use Documents Folder")) {
                                storageFolder.useDocumentsFolder()
                                folderErrorMessage = nil
                            }
                        }
                    }
                    .listRowBackground(Clay.surfaceCard)
                } header: {
                    Text(localization.string("Saved files"))
                } footer: {
                    if let folderErrorMessage {
                        Text(folderErrorMessage).foregroundStyle(.red)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(localization.string("Speech, recordings, and practice progress are saved in this folder. Choose a folder in iCloud Drive to use the same files in the Mac app."))
                            Text(localization.string("If you choose a folder in iCloud Drive, you can continue your practice on your other Apple devices."))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Clay.canvas)
            .tint(Clay.ink)
            .fileImporter(
                isPresented: $showsFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    try storageFolder.choose(url)
                    folderErrorMessage = nil
                } catch {
                    folderErrorMessage = localization.string("Could not use this folder.")
                }
            }
            .onChange(of: appearance) { _, newValue in newValue.apply() }
            .navigationTitle(localization.string("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localization.string("Done")) { dismiss() }
                }
            }
        }
    }

    private var availableVoices: [AVSpeechSynthesisVoice] {
        DictationModel.availableVoices(forLanguage: model.defaultSpeechLocale)
    }

    private var voiceSelection: Binding<String?> {
        let language = DictationModel.languageCode(for: model.defaultSpeechLocale)
        return Binding(
            get: { model.preferredVoiceIdentifier(forLanguage: language) },
            set: { model.setPreferredVoice($0, forLanguage: language) }
        )
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .enhanced: "\(voice.name) (\(localization.string("Enhanced")))"
        case .premium: "\(voice.name) (\(localization.string("Premium")))"
        default: voice.name
        }
    }
}
