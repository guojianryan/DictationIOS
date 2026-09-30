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
    @Environment(\.colorScheme) private var colorScheme
    @State private var setupChoice: SetupChoice?
    @State private var textTab: TextSetupTab = .type
    @State private var audioTab: AudioSetupTab = .upload
    @State private var typedText = ""
    @State private var showsOriginalText = true
    @State private var showsTranslation = true
    @State private var showsSettings = false
    @State private var showsGradePopup = false
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
    @FocusState private var isAnswerFieldFocused: Bool

    private var typedTextIsEmpty: Bool {
        typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var photoRecognizedTextIsEmpty: Bool {
        photoRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Colors

    private let studentBlue = Color(red: 0.27, green: 0.40, blue: 0.92)
    private let studentPurple = Color(red: 0.52, green: 0.35, blue: 0.88)
    private let studentMint = Color(red: 0.08, green: 0.44, blue: 0.37)
    private let studentAmber = Color(red: 0.82, green: 0.47, blue: 0.10)
    private let studentCanvas = Color(red: 0.95, green: 0.96, blue: 0.99)
    private let studentInk = Color(red: 0.15, green: 0.17, blue: 0.25)

    private var ink: Color {
        colorScheme == .dark ? Color(red: 0.93, green: 0.94, blue: 0.97) : studentInk
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color(red: 0.16, green: 0.17, blue: 0.22) : Color.white.opacity(0.96)
    }

    private var canvasFill: Color {
        colorScheme == .dark ? Color(red: 0.12, green: 0.13, blue: 0.17) : studentCanvas
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider()
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
        .foregroundStyle(ink)
        .task { await model.loadSpeechLanguages() }
        .translationTask(model.translationConfiguration) { session in
            await model.translate(using: session)
        }
        .sheet(isPresented: $showsSettings) {
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
                    photoErrorMessage = .format("Could not read the photo: %@", error.localizedDescription)
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

    private var backgroundGradient: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.11, green: 0.12, blue: 0.16), Color(red: 0.08, green: 0.09, blue: 0.12)]
                : [studentCanvas, Color(red: 0.94, green: 0.95, blue: 1.0)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    LinearGradient(colors: [studentBlue, studentPurple], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .shadow(color: studentPurple.opacity(0.22), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Language Dictation"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(ink)
                Text(tr("Listen \u{2022} learn \u{2022} level up"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.sentences.isEmpty {
                Button {
                    returnToSetup()
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
            }

            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(backgroundGradient)
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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("What do you want to practice?"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(ink)
                Text(tr("Start from text or from audio. Speech, transcription, and translations stay on your device."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                choiceButton(
                    title: tr("Text"),
                    subtitle: tr("Type words or upload a text file"),
                    systemImage: "text.alignleft",
                    tint: studentMint
                ) { setupChoice = .text }

                choiceButton(
                    title: tr("Audio"),
                    subtitle: tr("Upload a file or record your own"),
                    systemImage: "waveform",
                    tint: studentBlue
                ) { setupChoice = .audio }

                choiceButton(
                    title: tr("Photo"),
                    subtitle: tr("Take or upload a photo, then edit the recognized text"),
                    systemImage: "text.viewfinder",
                    tint: studentAmber
                ) { setupChoice = .photo }
            }
        }
    }

    private var detailScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                leaveDetailScreen()
            } label: {
                Label(tr("Back"), systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(studentPurple)

            languageCard

            if setupChoice == .text {
                Picker(tr("Text source"), selection: $textTab) {
                    ForEach(TextSetupTab.allCases) { tab in
                        Text(tr(tab.rawValue)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if textTab == .type {
                    typedTextCard
                } else {
                    uploadCard(
                        systemImage: "doc.text",
                        title: tr("Upload a text file"),
                        message: tr("The text is read aloud, and the spoken audio is saved in the app."),
                        buttonTitle: tr("Choose Text"),
                        tint: studentMint
                    ) { showsTextImporter = true }
                }
            } else if setupChoice == .audio {
                Picker(tr("Audio source"), selection: $audioTab) {
                    ForEach(AudioSetupTab.allCases) { tab in
                        Text(tr(tab.rawValue)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if audioTab == .upload {
                    uploadCard(
                        systemImage: "waveform",
                        title: tr("Upload an audio file"),
                        message: tr("MP3, WAV, M4A, and other audio formats are transcribed on your device."),
                        buttonTitle: tr("Choose Audio"),
                        tint: studentBlue
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

            Picker(tr("Translation"), selection: $model.selectedTranslationLanguage) {
                ForEach(TranslationLanguage.supported) { language in
                    Text(localization.languageName(for: language.code)).tag(language.code)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(studentBlue.opacity(0.16)) }
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
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .background(canvasFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(studentMint.opacity(0.2)) }

            Text(tr("Speech is generated on your device and saved in the app."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                saveTypedTextAndCreateSpeech()
            } label: {
                Label(tr("Create Speech"), systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(studentMint)
            .disabled(typedTextIsEmpty)
        }
        .padding(16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(studentMint.opacity(0.18)) }
    }

    private var recordingCard: some View {
        VStack(spacing: 16) {
            if model.hasRecordingPreview && !model.isRecording {
                recordingReview
            } else {
                Text(Self.timeString(model.recordingDuration))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(model.isRecording ? .red : ink)

                Button {
                    if model.isRecording { model.stopRecording() }
                    else { model.startRecording() }
                } label: {
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 80, height: 80)
                        .background(model.isRecording ? Color.red : studentBlue, in: Circle())
                }
                .buttonStyle(.plain)

                Text(model.isRecording
                     ? tr("Recording. Press stop when you are finished, then listen back.")
                     : tr("Record with your microphone. You can play it back before saving."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder((model.isRecording ? Color.red : studentBlue).opacity(0.2)) }
    }

    private var recordingReview: some View {
        VStack(spacing: 14) {
            Text(tr("Listen to your recording"))
                .font(.headline)
                .foregroundStyle(ink)

            HStack(spacing: 8) {
                Text(Self.timeString(model.recordingPreviewTime))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { model.recordingPreviewTime },
                    set: { model.seekRecordingPreview(to: $0) }
                ), in: 0...max(model.recordingPreviewDuration, 0.1))
                .tint(studentBlue)
                Text(Self.timeString(model.recordingPreviewDuration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            HStack(spacing: 12) {
                Button {
                    model.toggleRecordingPlayback()
                } label: {
                    Label(model.isPlayingRecording ? tr("Pause") : tr("Play"),
                          systemImage: model.isPlayingRecording ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(studentBlue)

                Button {
                    model.startRecording()
                } label: {
                    Label(tr("Record again"), systemImage: "mic.fill")
                }
                .buttonStyle(.bordered)
            }

            Button {
                saveRecordingAndStartDictation()
            } label: {
                Label(tr("Start Dictation"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(studentPurple)

            Text(tr("Play the recording first. When it sounds right, save it and dictation will begin."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var photoCaptureCard: some View {
        VStack(spacing: 16) {
            if isRecognizingPhotoText {
                ProgressView()
                    .controlSize(.large)
                Text(photoProcessingStage == .formatting
                     ? tr("Formatting the recognized text\u{2026}")
                     : tr("Reading the text in your photo\u{2026}"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(studentAmber)
                Text(tr("Scan a photo of text"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(ink)
                Text(tr("Take a photo or choose one from your library. The text is recognized on your device."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                        .buttonStyle(.borderedProminent)
                        .tint(studentAmber)
                    }

                    PhotosPicker(selection: $selectedPhotoPickerItem, matching: .images) {
                        Label(tr("Choose Photo"), systemImage: "photo.on.rectangle")
                            .frame(width: 60)
                    }
                    .buttonStyle(.bordered)
                    .tint(studentAmber)
                }
                .labelStyle(.iconOnly)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(studentAmber.opacity(0.2)) }
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
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .background(canvasFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(studentAmber.opacity(0.2)) }

            Text(tr("Check the recognized text, fix any mistakes, then create the speech."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    resetPhotoCapture()
                } label: {
                    Label(tr("Retake"), systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    savePhotoTextAndCreateSpeech()
                } label: {
                    Label(tr("Create Speech"), systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
                .tint(studentAmber)
                .disabled(photoRecognizedTextIsEmpty)
            }
        }
        .padding(16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(studentAmber.opacity(0.18)) }
    }

    // MARK: - Transcription Progress

    private var transcriptionProgress: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(model.processingTitle.isEmpty ? tr("Working on %@", model.fileName) : localized(model.processingTitle))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(model.transcriptionMode.isEmpty ? tr("Preparing\u{2026}") : localized(model.transcriptionMode))
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ink)
                Text(tr("This text is the source, so any change regenerates the speech for it."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
            .background(canvasFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(studentMint.opacity(0.2)) }

            HStack(spacing: 12) {
                Button(tr("Cancel")) {
                    model.cancelEditingSourceText()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Spacer()
                Button {
                    Task { await model.confirmSourceTextEdit() }
                } label: {
                    Label(tr("Regenerate Speech"), systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
                .tint(studentMint)
                .controlSize(.large)
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
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ink)
                Text(tr("Listen to each sentence and fix any mistakes. Punctuation and capitalization changes don't count."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                            sentence: sentence,
                            studentPurple: studentPurple,
                            cardFill: cardFill,
                            canvasFill: canvasFill
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
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                if model.canCancelReview {
                    Button(tr("Cancel")) { model.cancelReview() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
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
                .buttonStyle(.borderedProminent)
                .tint(studentPurple)
                .controlSize(.large)
                .disabled(blockedCount > 0)
            }
        }
        .padding(14)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(studentPurple.opacity(0.16)) }
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
                                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                                }
                            }
                            .onChange(of: model.gradeCheckCount) { _, _ in flashGradePopup() }
                    }

                    playbackControls
                }
                .padding(16)
            }
            .onChange(of: isAnswerFieldFocused) { _, focused in
                guard focused else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("answerField", anchor: .bottom)
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
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
    }

    private var sessionCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(studentBlue)
                    .padding(8)
                    .background(studentBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(localized(model.sessionDetail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(model.currentSentenceIndex + 1)/\(model.sentences.count)")
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(studentPurple)
            }

            Divider()

            HStack(spacing: 8) {
                Toggle(isOn: $showsOriginalText) {
                    Label(tr("Original"), systemImage: "text.quote")
                }
                .tint(studentBlue)

                Toggle(isOn: $showsTranslation) {
                    Label(tr("Translation"), systemImage: "character.bubble")
                }
                .tint(studentMint)

                if model.canEditText {
                    Button {
                        model.beginEditingText()
                    } label: {
                        Label(tr("Edit text"), systemImage: "pencil")
                    }
                    .tint(studentPurple)
                } else if model.canEditSourceText {
                    Button {
                        model.beginEditingSourceText()
                    } label: {
                        Label(tr("Edit text"), systemImage: "pencil")
                    }
                    .tint(studentMint)
                }

                Spacer()

                modeSwitcher
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(studentPurple.opacity(0.13)) }
    }

    private var modeSwitcher: some View {
        Picker(tr("Mode"), selection: $model.sentenceOnly) {
            Label(tr("Listen"), systemImage: "ear").tag(false)
            Label(tr("Dictate"), systemImage: "pencil.and.outline").tag(true)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .frame(width: 92)
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(localization.languageName(for: model.selectedSpeechLocale), systemImage: "text.quote")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(studentBlue)

            sentencePanel(model.sentences.map(\.text), highlightColor: studentBlue, height: 118)

            if !model.punctuationStatus.isEmpty {
                Text(localized(model.punctuationStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(studentBlue.opacity(0.16)) }
    }

    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(tr("Translation"), systemImage: "character.bubble")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(studentMint)
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
                highlightColor: studentMint,
                height: 118
            )

            Text(translationCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(studentMint.opacity(0.18)) }
    }

    private func sentencePanel(_ texts: [String], highlightColor: Color, height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                sentenceRows(texts, highlightColor: highlightColor)
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

    private func sentenceRows(_ texts: [String], highlightColor: Color) -> some View {
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
                            .foregroundStyle(isCurrent ? .white : ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                isCurrent ? highlightColor : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var practiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(tr("Write what you hear"), systemImage: "pencil.and.outline")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(studentPurple)
                    Text(tr("Listen closely, then write the sentence from memory."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button {
                        model.checkAnswer()
                    } label: {
                        Label(tr("Check"), systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(studentPurple)
                    .controlSize(.small)
                    Button {
                        model.toggleAnswerVisibility()
                    } label: {
                        Image(systemName: model.answerIsRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.bordered)
                    .tint(studentBlue)
                    .controlSize(.small)
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
                    .background(canvasFill, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(studentPurple.opacity(0.16)) }

                    if !model.practiceFeedback.isEmpty {
                        Text(localized(model.practiceFeedback))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(canvasFill, in: RoundedRectangle(cornerRadius: 10))
                    }

                    if !model.practiceWordResults.isEmpty {
                        Text(practiceDiff)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if !model.missingPracticeWords.isEmpty {
                            Text(tr("Missing: %@", model.missingPracticeWords.joined(separator: " ")))
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 10) {
                            Label(tr("Correct"), systemImage: "checkmark").foregroundStyle(.green)
                            Label(tr("Review"), systemImage: "xmark").foregroundStyle(.red)
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(14)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(studentPurple.opacity(0.16)) }
    }

    private var gradePopup: some View {
        HStack(spacing: 12) {
            Image(systemName: model.practiceGradeScore == 100 ? "star.fill" : "sparkles")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(gradeColor, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(model.practiceGradeTitle))
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(gradeColor)
                Text("\(model.practiceGradeScore ?? 0)%")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(ink)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        .background(gradeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(gradeColor.opacity(0.45), lineWidth: 1.5) }
        .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
        .allowsHitTesting(false)
    }

    private func flashGradePopup() {
        gradePopupTask?.cancel()
        withAnimation(.spring(duration: 0.3)) { showsGradePopup = true }
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
            typedWord.foregroundColor = word.isCorrect ? .green : .red
            result.append(typedWord)
            if let expectedText = word.expectedText {
                var correction = AttributedString(" → \(expectedText)")
                correction.foregroundColor = .green
                result.append(correction)
            }
        }
        return result
    }

    private var gradeColor: Color {
        switch model.practiceGradeScore ?? 0 {
        case 100: studentMint
        case 85...: studentBlue
        case 65..<85: studentPurple
        default: Color(red: 0.72, green: 0.36, blue: 0.12)
        }
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(Self.timeString(model.currentTime))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { model.currentTime },
                    set: { model.seek(to: $0) }
                ), in: 0...max(model.duration, 1))
                .tint(studentPurple)
                Text(Self.timeString(model.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            HStack(spacing: 16) {
                Button {
                    model.moveSentence(by: -1)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title3)
                        .frame(width: 44, height: 36)
                }

                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 52, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(studentPurple)

                Button {
                    model.moveSentence(by: 1)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title3)
                        .frame(width: 44, height: 36)
                }

                Spacer()

                Picker(tr("Playback speed"), selection: $model.playbackRate) {
                    Text("0.5×").tag(Float(0.5))
                    Text("0.75×").tag(Float(0.75))
                    Text("1×").tag(Float(1))
                    Text("1.25×").tag(Float(1.25))
                    Text("1.5×").tag(Float(1.5))
                }
                .labelsHidden()
                .frame(width: 90)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(studentPurple.opacity(0.12)) }
    }

    // MARK: - Helpers

    private func choiceButton(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(tint, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(ink)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(tint.opacity(0.28), lineWidth: 1.5) }
    }

    private func uploadCard(
        systemImage: String,
        title: String,
        message: String,
        buttonTitle: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(tint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.18)) }
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
        let name = suggestedFilename(for: text)
        model.importTypedText(text, suggestedName: name)
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
                photoErrorMessage = .format("Could not read the photo: %@", error.localizedDescription)
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
        let name = suggestedFilename(for: text)
        model.importTypedText(text, suggestedName: name)
    }

    private func saveRecordingAndStartDictation() {
        guard let tempURL = model.prepareRecordingForSave() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let recordingsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings")
        do {
            try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
            let dest = recordingsDir
                .appendingPathComponent("Recording \(formatter.string(from: Date()))")
                .appendingPathExtension("wav")
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: dest)
            }
            model.clearSavedRecording()
            model.importAudio(.success([dest]))
        } catch {
            model.reloadRecordingPreview()
            model.showError(.format("Could not save the recording: %@", error.localizedDescription))
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
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private func tr(_ key: String, _ arguments: String...) -> String {
        localization.string(LocalizableText(key: key, arguments: arguments.map(LocalizableArgument.text)))
    }

    private func localized(_ text: LocalizableText) -> String {
        localization.string(text)
    }

    private func suggestedFilename(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-"))
        let cleaned = String(firstLine.unicodeScalars.filter { allowed.contains($0) })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limited = String(cleaned.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? tr("Practice") : limited
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
    let studentPurple: Color
    let cardFill: Color
    let canvasFill: Color

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
                    .foregroundStyle(.secondary)
                Button {
                    model.toggleReviewPlayback(at: index)
                } label: {
                    Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .tint(studentPurple)
                .controlSize(.mini)
            }

            VStack(alignment: .leading, spacing: 7) {
                TextField("", text: $editedText, axis: .vertical)
                    .focused($isFocused)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(8)
                    .background(canvasFill, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(status.isOverLimit ? Color.red : studentPurple.opacity(0.16),
                                          lineWidth: status.isOverLimit ? 2 : 1)
                    }
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
                            .foregroundStyle(status.isOverLimit ? Color.red : Color.secondary)
                    }
                    if status.isEmpty {
                        Text(tr("A sentence can't be empty.")).foregroundStyle(.red)
                    } else if status.isOverLimit {
                        Text(tr("Too many words changed. Revert or reduce the changes to continue.")).foregroundStyle(.red)
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
                .font(.caption)
                .buttonStyle(.borderless)
                .tint(studentPurple)

                if isEdited {
                    Text(tr("Recognized: %@", sentence.originalText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(status.isOverLimit ? Color.red.opacity(0.08) : cardFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(status.isOverLimit ? Color.red.opacity(0.55) : studentPurple.opacity(0.13))
        }
    }
}

// MARK: - Settings Sheet

private struct SettingsSheet: View {
    @ObservedObject var model: DictationModel
    @ObservedObject var localization: AppLocalization
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(localization.string("App language"), selection: $localization.appLanguage) {
                        Text(localization.string("System")).tag("system")
                        ForEach(AppLocalization.choices, id: \.id) { choice in
                            Text(choice.title).tag(choice.id)
                        }
                    }
                }
                Section {
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
                } footer: {
                    Text(localization.string("Defaults are used when you start. A language you pick while adding text or audio applies only to that session."))
                }
                Section {
                    Picker(localization.string("Voice"), selection: voiceSelection) {
                        Text(localization.string("Automatic")).tag(String?.none)
                        ForEach(availableVoices, id: \.identifier) { voice in
                            Text(voiceLabel(voice)).tag(String?.some(voice.identifier))
                        }
                    }
                } footer: {
                    Text(localization.string(.format(
                        "The voice used to read %@. Change the spoken language above to choose a voice for a different language.",
                        localization.languageName(for: model.defaultSpeechLocale)
                    )))
                }
            }
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
