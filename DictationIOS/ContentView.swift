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

private enum FileImportKind {
    case audio
    case text

    var contentTypes: [UTType] {
        switch self {
        case .audio: [.audio]
        case .text: [.plainText, .text]
        }
    }
}

private enum ResultsKind {
    case dictation
    case speaking
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
    @State private var showsHowItWorks = false
    /// On iPad and Mac the dictation and speaking results show in a pop-up box in the middle of
    /// the window instead of growing the cards.
    @State private var activeResults: ResultsKind?
    @State private var resultsContentHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    @State private var choicesHaveAppeared = false
    @State private var recentRowHeight: CGFloat = 86
    /// Width of the window or split-view pane, which drives the adaptive layout.
    @State private var containerWidth: CGFloat = 0
    /// Height of the answer box and its feedback, so their scroll view is no taller than needed.
    @State private var answerContentHeight: CGFloat = 0
    /// Full height of the original and translation sentence lists, to size them to three sentences.
    @State private var originalListHeight: CGFloat = 0
    @State private var translationListHeight: CGFloat = 0
    @State private var howItWorksStepsHeight: CGFloat = 0
    /// Height of the choices column in the wide start screen, which the intro column matches.
    @State private var setupViewportHeight: CGFloat = 0
    /// Height of the practice page's scroll area, and of everything on it except the sentence
    /// lists. The lists take whatever is left so the answer and play cards reach the bottom.
    @State private var lessonViewportHeight: CGFloat = 0
    @State private var lessonRestHeight: CGFloat = 0
    @State private var gradePopupTask: Task<Void, Never>?
    /// SwiftUI honors only one `.fileImporter` per view, so audio and text share one.
    @State private var fileImportKind: FileImportKind?
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            containerWidth = size.width
            containerHeight = size.height
        }
        .overlay {
            if isMediumWidth, let kind = activeResults {
                resultsPopup(kind)
            }
        }
        .onChange(of: model.currentSentenceIndex) { _, _ in activeResults = nil }
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
                .presentationSizing(.form)
        }
        .sheet(isPresented: $showsHowItWorks) {
            howItWorksSheet
                .presentationSizing(.form)
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
            isPresented: Binding(
                get: { fileImportKind != nil },
                set: { if !$0 { fileImportKind = nil } }
            ),
            allowedContentTypes: fileImportKind?.contentTypes ?? [.audio],
            allowsMultipleSelection: false
        ) { result in
            let kind = fileImportKind
            fileImportKind = nil
            let urls = result.map { $0 }
            if kind == .text {
                model.importText(urls)
            } else {
                model.importAudio(urls)
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
                Text(verbatim: "Echo Quill")
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

            // iPad and Mac show the instructions on the start screen instead.
            if !isMediumWidth {
                Button {
                    showsHowItWorks = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.clayIcon)
                .accessibilityLabel(tr("How it works"))
            }

            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.clayIcon)
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel(tr("Settings"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .clayColumn(contentMaxWidth)
    }

    // MARK: - Layout

    /// Window widths at which the layout gains room: a roomier single column, then two columns.
    private var isMediumWidth: Bool { containerWidth >= 600 }
    private var isWideWidth: Bool { containerWidth >= 900 }
    /// The practice page lays its cards out in rows from this width up (iPad portrait and larger).
    private var isLessonWide: Bool { containerWidth >= 700 }

    /// The widest the content gets before it is centered with margins instead of stretching.
    private var contentMaxWidth: CGFloat {
        let isPracticing = !model.sentences.isEmpty && !model.isReviewing && !model.isEditingSourceText
        if isPracticing ? isLessonWide : (isWideWidth && model.sentences.isEmpty && setupChoice == nil) {
            return 1200
        }
        return 720
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
            .clayColumn(contentMaxWidth)
        }
        // iPad and Mac size the page to fit, so it neither bounces nor shows a scroll bar.
        .scrollBounceBehavior(isMediumWidth ? .basedOnSize : .automatic)
        .scrollIndicators(isMediumWidth ? .hidden : .automatic)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { setupViewportHeight = $0 }
    }

    /// The wide start screen's columns reach the bottom of the window, less the page padding
    /// (16 each side), the top inset (24) and some breathing room.
    private var wideColumnHeight: CGFloat {
        max(420, setupViewportHeight - 16 - 16 - 24 - 24)
    }

    private var choiceScreen: some View {
        Group {
            if isWideWidth {
                HStack(alignment: .top, spacing: 40) {
                    choiceHero(fillsHeight: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: wideColumnHeight, alignment: .top)
                    VStack(alignment: .leading, spacing: 24) {
                        choiceButtons
                        recentPracticesSection(fillsHeight: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: wideColumnHeight, alignment: .top)
                }
                .padding(.top, 24)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    choiceHero(fillsHeight: false)
                    choiceButtons
                    if !model.recentPractices.isEmpty {
                        recentPracticesSection(fillsHeight: false)
                    }
                }
            }
        }
        .onAppear { choicesHaveAppeared = true }
    }

    private func choiceHero(fillsHeight: Bool) -> some View {
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

            if isMediumWidth {
                howItWorks(fillsHeight: fillsHeight)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - How It Works

    private struct HowItWorksStep {
        let systemImage: String
        let accent: ClayAccent
        let title: String
        let detail: String
    }

    private var howItWorksSteps: [HowItWorksStep] {
        [
            HowItWorksStep(
                systemImage: "square.and.pencil", accent: .pink,
                title: tr("Choose your material"),
                detail: tr("Type or upload text, upload or record audio, or scan a photo of printed text.")
            ),
            HowItWorksStep(
                systemImage: "ear", accent: .lavender,
                title: tr("Listen"),
                detail: tr("Play the speech one sentence at a time. Tap any sentence to jump to it, and slow the speed down when you need to.")
            ),
            HowItWorksStep(
                systemImage: "pencil.and.outline", accent: .ochre,
                title: tr("Dictate"),
                detail: tr("Switch to Dictate, listen, and write the sentence from memory. Press Check to see your score and exactly which words to review.")
            ),
            HowItWorksStep(
                systemImage: "waveform.and.mic", accent: .mint,
                title: tr("Say it out loud"),
                detail: tr("After a perfect sentence, record yourself reading it and get a pronunciation score. Try as many times as you like.")
            )
        ]
    }

    /// Mac windows have room to show every step; iPad keeps the shorter scrolling card.
    private static let howItWorksMaxHeight: CGFloat = {
        #if targetEnvironment(macCatalyst)
        350
        #else
        170
        #endif
    }()

    /// The steps in a short scrolling card, so the intro stays compact on iPad and Mac.
    /// With `fillsHeight`, the card stretches to the height it is given and the steps scroll
    /// inside it; otherwise the steps get a capped height of their own.
    private func howItWorks(fillsHeight: Bool) -> some View {
        let steps = howItWorksSteps
        return VStack(alignment: .leading, spacing: 6) {
            Text(tr("How it works"))
                .clayEyebrow()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        howItWorksRow(index + 1, step, isLast: index == steps.count - 1)
                    }
                }
                .padding(.top, 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { howItWorksStepsHeight = $0 }
            }
            .scrollIndicators(.visible)
            .modifier(HowItWorksScrollHeight(
                fillsHeight: fillsHeight,
                height: howItWorksStepsHeight > 0 ? min(howItWorksStepsHeight, Self.howItWorksMaxHeight) : Self.howItWorksMaxHeight
            ))

            Label(tr("Speech, transcription, and translations all stay on your device."), systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(Clay.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .clayCard(Clay.surfaceSoft, radius: Clay.Radius.xl, border: nil)
    }

    /// The instructions in a pop-up window, available from the header on every device.
    private var howItWorksSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(howItWorksSteps.enumerated()), id: \.offset) { index, step in
                            howItWorksRow(index + 1, step, isLast: index == howItWorksSteps.count - 1)
                        }
                    }
                    Label(tr("Speech, transcription, and translations all stay on your device."), systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Clay.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .background(Clay.canvas)
            .navigationTitle(tr("How it works"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { showsHowItWorks = false }
                }
            }
        }
        .foregroundStyle(Clay.ink)
        .tint(Clay.ink)
    }

    private struct HowItWorksScrollHeight: ViewModifier {
        let fillsHeight: Bool
        let height: CGFloat

        func body(content: Content) -> some View {
            if fillsHeight {
                content.frame(minHeight: 100, maxHeight: .infinity)
            } else {
                content.frame(height: height)
            }
        }
    }

    private func howItWorksRow(_ number: Int, _ step: HowItWorksStep, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(step.accent.on)
                    .frame(width: 36, height: 36)
                    .background(step.accent.fill, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Text("\(number)")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(Clay.onInk)
                            .frame(width: 16, height: 16)
                            .background(Clay.ink, in: Circle())
                            .offset(x: 5, y: -5)
                    }
                if !isLast {
                    Capsule()
                        .fill(Clay.hairline)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.clayTitle)
                Text(step.detail)
                    .font(.subheadline)
                    .lineSpacing(2)
                    .foregroundStyle(Clay.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
    }

    private var choiceButtons: some View {
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
    }

    // MARK: - Recent Practices

    private static let recentAccents: [ClayAccent] = [.ochre, .mint, .lavender, .peach, .pink]

    /// With `fillsHeight`, the section stretches to the space it is given: the rows scroll
    /// inside it, and an empty list keeps the same footprint.
    private func recentPracticesSection(fillsHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Recent practices"))
                .clayEyebrow()

            if fillsHeight {
                ZStack {
                    if model.recentPractices.isEmpty {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(Clay.muted.opacity(0.5))
                    } else {
                        ScrollView {
                            recentPracticeRows
                                .padding(.trailing, 12)
                        }
                        .scrollIndicators(.visible)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    Clay.surfaceSoft.opacity(model.recentPractices.isEmpty ? 1 : 0),
                    in: RoundedRectangle(cornerRadius: Clay.Radius.xl, style: .continuous)
                )
            } else if model.recentPractices.count > Self.visibleRecentRows {
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
                    ) { fileImportKind = .text }
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
                    ) { fileImportKind = .audio }
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
        .clayColumn(contentMaxWidth)
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                errorBanner(message).padding(.horizontal, 16).padding(.top, 4)
                    .clayColumn(contentMaxWidth)
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
            .clayColumn(contentMaxWidth)

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
                .clayColumn(contentMaxWidth)
            }

            reviewFooter
                .clayColumn(contentMaxWidth)
        }
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                errorBanner(message).padding(.horizontal, 16).padding(.top, 4)
                    .clayColumn(contentMaxWidth)
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

                    if isLessonWide {
                        wideLessonLayout
                    } else {
                        textPanels
                        answerCard
                        playbackControls()
                            .id("playbackControls")
                        speakingSlot
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    lessonRestHeight = height - panelHeight
                }
                .padding(16)
                .clayColumn(contentMaxWidth)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lessonViewportHeight = $0 }
            // Wide windows are laid out to fit, so the page only scrolls when it has to.
            .scrollBounceBehavior(isMediumWidth ? .basedOnSize : .automatic)
            .onChange(of: isAnswerFieldFocused) { _, focused in
                guard focused else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation(.easeOut(duration: 0.25)) {
                        // Show the playback bar under the answer field.
                        proxy.scrollTo("playbackControls", anchor: .bottom)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                errorBanner(message).padding(.horizontal, 16).padding(.top, 4)
                    .clayColumn(contentMaxWidth)
            }
        }
    }

    /// The answer field, shown while dictating. In wide windows it also shows while listening,
    /// dimmed and disabled, so the page keeps the same layout in both modes.
    @ViewBuilder
    private var answerCard: some View {
        if model.sentenceOnly || isLessonWide {
            practiceCard
                .id("answerField")
                .disabled(!model.sentenceOnly)
                .opacity(model.sentenceOnly ? 1 : 0.45)
                .overlay(alignment: .top) {
                    if showsGradePopup, !model.practiceGradeTitle.isEmpty {
                        gradePopup
                            .offset(y: -30)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .onChange(of: model.gradeCheckCount) { _, _ in
                    flashGradePopup()
                    if isMediumWidth {
                        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { activeResults = .dictation }
                    }
                }
        }
    }

    /// The speaking card, always offered while dictating. In wide windows it also shows while
    /// listening, dimmed and disabled.
    @ViewBuilder
    private var speakingSlot: some View {
        if model.sentenceOnly || isLessonWide {
            speakingCard
                .disabled(!model.sentenceOnly)
                .opacity(model.sentenceOnly ? 1 : 0.45)
                .onChange(of: model.sentenceOnly) { _, dictating in
                    // Leaving dictation stops any recording and closes the results box.
                    if !dictating {
                        speaking.reset()
                        activeResults = nil
                    }
                }
                // Open the results once an attempt has been recorded and graded, not while recording.
                .onChange(of: speaking.attemptCount) { old, new in
                    // Only a new attempt opens it; clearing the count on a new sentence must not.
                    if isMediumWidth && new > old {
                        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { activeResults = .speaking }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Wide windows. The original sits beside its translation, the answer card spans the width
    /// below them, and the playback controls and speaking card share the last row at the same
    /// height. Listening keeps this layout with the answer and speaking cards disabled.
    @ViewBuilder
    private var wideLessonLayout: some View {
        textPanels
        answerCard
        HStack(alignment: .top, spacing: 16) {
            playbackControls(fillsHeight: true)
                .id("playbackControls")
                .frame(maxWidth: .infinity)
            speakingSlot
                .frame(maxWidth: .infinity)
        }
    }

    private var textPanels: some View {
        Group {
            if showsOriginalText || showsTranslation {
                panelStack {
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

    /// Original and translation sit side by side when listening in a wide window, otherwise stacked.
    @ViewBuilder
    private func panelStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if isLessonWide {
            HStack(alignment: .top, spacing: 16) { content() }
        } else {
            VStack(spacing: 12) { content() }
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

            sentencePanel(originalTexts, accent: .lavender, height: panelHeight, listHeight: $originalListHeight)

            if !model.punctuationStatus.isEmpty {
                Text(localized(model.punctuationStatus))
                    .font(.caption)
                    .foregroundStyle(Clay.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: isLessonWide ? .infinity : nil, alignment: .topLeading)
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

            sentencePanel(translatedTexts, accent: .mint, height: panelHeight, listHeight: $translationListHeight)

            // iPad and Mac leave the caption out to make room for a taller list.
            if !isMediumWidth {
                Text(translationCaption)
                    .font(.caption)
                    .foregroundStyle(Clay.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: isLessonWide ? .infinity : nil, alignment: .topLeading)
        .clayCard()
    }

    private static let visibleSentences = 3
    /// iPad and Mac lists show two more lines than three sentences take.
    private static let extraPanelLines: CGFloat = 2
    private static let panelLineHeight: CGFloat = 25
    private static let sentenceRowSpacing: CGFloat = 4

    private var originalTexts: [String] { model.sentences.map(\.text) }

    private var translatedTexts: [String] {
        model.sentences.indices.map { index in
            model.translatedSentences.indices.contains(index) ? model.translatedSentences[index] : ""
        }
    }

    /// Height of a list that shows three sentences, plus extra lines on iPad and Mac, or all of
    /// them when fewer. iPhone keeps its original fixed height.
    private func naturalPanelHeight(_ texts: [String], listHeight: CGFloat) -> CGFloat {
        guard isMediumWidth else { return 118 }
        let rowCount = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        guard rowCount > 0, listHeight > 0 else { return 120 }
        let spacing = Self.sentenceRowSpacing
        let rowHeight = (listHeight - spacing * CGFloat(rowCount - 1)) / CGFloat(rowCount)
        let visible = min(rowCount, Self.visibleSentences)
        return rowHeight * CGFloat(visible) + spacing * CGFloat(visible - 1)
            + (rowCount > Self.visibleSentences ? Self.extraPanelLines * Self.panelLineHeight : 0)
    }

    /// The original and translation lists share one height. Listening makes it three lines taller
    /// than the taller of them; dictating fills the page.
    private var panelHeight: CGFloat {
        let original = naturalPanelHeight(originalTexts, listHeight: originalListHeight)
        guard isLessonWide else { return original }
        let translated = naturalPanelHeight(translatedTexts, listHeight: translationListHeight)
        let natural = max(original, translated)
        if lessonViewportHeight > 0, lessonRestHeight > 0 {
            // The lists grow until the cards below them reach the bottom of the page.
            let available = lessonViewportHeight - 2 * 16 - lessonRestHeight - 1
            return max(natural, available)
        }
        return natural + 3 * Self.panelLineHeight
    }

    /// A scrolling list of sentences, `height` tall.
    private func sentencePanel(_ texts: [String], accent: ClayAccent, height: CGFloat, listHeight: Binding<CGFloat>) -> some View {
        return ScrollViewReader { proxy in
            ScrollView {
                sentenceRows(texts, accent: accent)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight.wrappedValue = $0 }
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
        VStack(alignment: .leading, spacing: Self.sentenceRowSpacing) {
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

    /// Wide windows keep the answer card short so the page fits without scrolling; its feedback
    /// scrolls inside the card instead.
    /// The feedback, the corrected answer and the word-by-word marks after pressing Check.
    /// The grey box with the number of differences to review.
    @ViewBuilder
    private var dictationFeedbackBox: some View {
        if !model.practiceFeedback.isEmpty {
            Text(localized(model.practiceFeedback))
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Clay.surfaceCard, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
        }
    }

    @ViewBuilder
    private func dictationResults(includesFeedback: Bool = true) -> some View {
        if includesFeedback {
            dictationFeedbackBox
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

    private var answerMaxHeight: CGFloat { isLessonWide ? 150 : (isMediumWidth ? 560 : 220) }

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
                    .frame(
                        minHeight: isLessonWide ? 64 : (isMediumWidth ? 180 : 60),
                        maxHeight: isLessonWide ? 64 : (isMediumWidth ? 360 : 90)
                    )
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .focused($isAnswerFieldFocused)
                    .clayInput(
                        border: isAnswerFieldFocused ? Clay.ink : Clay.hairline,
                        lineWidth: isAnswerFieldFocused ? 1.5 : 1
                    )

                    if !isMediumWidth {
                        dictationResults()
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerContentHeight = $0 }
            }
            .frame(height: answerContentHeight <= 0 ? answerMaxHeight : min(answerContentHeight, answerMaxHeight))
        }
        .padding(14)
        .clayCard()
    }

    /// The results box: centered in the window, about 40% of its width. Its height follows the
    /// content, up to most of the window, then scrolls. Everything else stays usable around it.
    private func resultsPopup(_ kind: ResultsKind) -> some View {
        let scale = min(0.675, max(0.375, 390 / max(containerWidth, 1)))
        // Window height minus the popup's padding (40), header (32) and spacing (10), with a margin.
        let maxScrollHeight = max(120, containerHeight * 0.85 - 82)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    kind == .dictation ? tr("Your answer") : tr("Your speaking"),
                    systemImage: kind == .dictation ? "pencil.and.outline" : "waveform.and.mic"
                )
                .font(.clayTitle)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { activeResults = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(Clay.ink.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Close"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if kind == .dictation {
                        if let score = model.practiceGradeScore {
                            resultsSummary(score: score, title: localized(model.practiceGradeTitle)) {
                                dictationFeedbackBox
                            }
                        } else {
                            dictationFeedbackBox
                        }
                        dictationResults(includesFeedback: false)
                    } else {
                        if let score = speaking.score, !speaking.isRecording {
                            resultsSummary(score: score, title: tr(speakingRatingTitle(score))) {
                                speakingRecognizedBox
                            }
                        } else {
                            speakingRecognizedBox
                        }
                        speakingResults(includesRecognized: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultsContentHeight = $0 }
            }
            .scrollIndicators(.visible)
            .frame(height: resultsContentHeight <= 0 ? nil : min(resultsContentHeight, maxScrollHeight))
        }
        .padding(20)
        .frame(width: containerWidth * scale, alignment: .topLeading)
        .background(Clay.popup, in: RoundedRectangle(cornerRadius: Clay.Radius.xl, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Clay.Radius.xl, style: .continuous).strokeBorder(Clay.ink.opacity(0.12)) }
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    /// The score badge at the top of a results box, with optional content beside it.
    private func resultsSummary<Beside: View>(
        score: Int,
        title: String,
        @ViewBuilder beside: () -> Beside = { EmptyView() }
    ) -> some View {
        let accent = scoreAccent(score)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(score)%")
                    .font(.title3.weight(.heavy).monospacedDigit())
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(accent.on)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(accent.fill, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))

            beside()
        }
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

            if isMediumWidth {
                // iPad and Mac: the buttons sit on the left with the status text beside them, and
                // the score is in the results box.
                HStack(spacing: 24) {
                    HStack(spacing: 24) {
                        speakingRecordButton
                        speakingPlayButton
                    }
                    speakingStatus(alignment: .leading)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 12) {
                    speakingRecordButton
                    speakingPlayButton
                    speakingStatus(alignment: .leading)
                    Spacer(minLength: 8)
                    speakingScoreBadge
                }
            }

            if !isMediumWidth {
                speakingResults()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: isLessonWide ? .infinity : nil, alignment: .topLeading)
        .clayCard(border: speaking.isRecording ? Clay.error : Clay.hairline)
        .onDisappear { speaking.reset() }
        .onChange(of: model.currentSentenceIndex) { _, _ in
            // The card stays up between sentences, so clear the last attempt.
            speaking.reset()
        }
    }

    private var speakingRecordButton: some View {
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
    }

    @ViewBuilder
    private var speakingPlayButton: some View {
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
    }

    private func speakingStatus(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
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
    }

    @ViewBuilder
    private var speakingScoreBadge: some View {
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

    /// What the microphone heard, shown once recording starts.
    @ViewBuilder
    private var speakingRecognizedBox: some View {
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
    }

    /// What was recognized, the word-by-word marks and any error after a speaking attempt.
    @ViewBuilder
    private func speakingResults(includesRecognized: Bool = true) -> some View {
    if includesRecognized {
        speakingRecognizedBox
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

    private func playbackControls(fillsHeight: Bool = false) -> some View {
        VStack(spacing: fillsHeight ? 8 : 12) {
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

            HStack(spacing: 8) {
                Button {
                    model.moveSentence(by: -1)
                } label: {
                    playbackStepIcon("backward.end.fill", size: fillsHeight ? 38 : 44)
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
                        .frame(width: fillsHeight ? 48 : 60, height: fillsHeight ? 48 : 60)
                        .background(Clay.cream, in: Circle())
                }
                .buttonStyle(.clayPressable)
                .accessibilityLabel(model.isPlaying ? tr("Pause") : tr("Play"))

                Button {
                    model.moveSentence(by: 1)
                } label: {
                    playbackStepIcon("forward.end.fill", size: fillsHeight ? 38 : 44)
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
            }
        }
        .padding(fillsHeight ? 12 : 16)
        .frame(maxHeight: fillsHeight ? .infinity : nil)
        .background(Clay.teal, in: RoundedRectangle(cornerRadius: Clay.Radius.xl, style: .continuous))
    }

    private func playbackStepIcon(_ systemImage: String, size: CGFloat = 44) -> some View {
        Image(systemName: systemImage)
            .font(.body.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
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
