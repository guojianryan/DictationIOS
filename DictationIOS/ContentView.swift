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
    @State private var showsSettings = false
    /// The welcome and setup screens: on the first launch, and again from the logo or help button.
    @State private var onboarding: OnboardingFlow.Presentation? =
        UserDefaults.standard.bool(forKey: OnboardingFlow.completedKey) ? nil : .firstLaunch
    @State private var opensWelcomeAfterSettings = false
    /// The current step of the Home tour that follows onboarding, or nil when it is not showing.
    @State private var homeTourIndex: Int?
    @State private var showsGradePopup = false
    /// On iPad and Mac the dictation and speaking results show in a pop-up box in the middle of
    /// the window instead of growing the cards.
    @State private var activeResults: ResultsKind?
    @State private var resultsContentHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    @State private var choicesHaveAppeared = false
    /// Width of the window or split-view pane, which drives the adaptive layout.
    @State private var containerWidth: CGFloat = 0
    /// Height of the answer box and its feedback, so their scroll view is no taller than needed.
    @State private var answerContentHeight: CGFloat = 0
    /// Full height of the original and translation sentence lists, to size them to three sentences.
    @State private var originalListHeight: CGFloat = 0
    @State private var translationListHeight: CGFloat = 0
    @State private var showsWeeklyStats = false
    @State private var weeklyStatsHeight: CGFloat = 0
    @ObservedObject private var stats = StatsStore.shared
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
        .overlayPreferenceValue(HomeTourAnchorKey.self) { anchors in
            if let homeTourIndex, homeTourIndex < homeTourSteps.count {
                HomeTourOverlay(
                    steps: homeTourSteps,
                    index: homeTourIndex,
                    anchors: anchors,
                    localize: { tr($0) },
                    onNext: advanceHomeTour,
                    onSkip: endHomeTour
                )
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
            guard opensWelcomeAfterSettings else { return }
            opensWelcomeAfterSettings = false
            onboarding = .replay
        }) {
            SettingsView(model: model, localization: localization, mode: .settings(onReplayWelcome: {
                opensWelcomeAfterSettings = true
                showsSettings = false
            }))
            .presentationSizing(.form)
        }
        .fullScreenCover(item: $onboarding, onDismiss: {
            if !UserDefaults.standard.bool(forKey: HomeTourStep.seenKey) { startHomeTour() }
        }) { presentation in
            OnboardingFlow(model: model, localization: localization, isReplay: presentation == .replay) {
                UserDefaults.standard.set(true, forKey: OnboardingFlow.completedKey)
                onboarding = nil
            }
        }
        .sheet(isPresented: $showsWeeklyStats) {
            weeklyStatsSheet
                .presentationSizing(.fitted)
                .presentationDetents(weeklyStatsHeight > 0 ? [.height(weeklyStatsHeight), .large] : [.large])
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
        HStack(spacing: 8) {
            Button {
                onboarding = .replay
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(ClayAccent.pink.on)
                        .symbolEffect(.variableColor.iterative, isActive: model.isPlaying)
                        .frame(width: 40, height: 40)
                        .background(Clay.pink, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
                    Text(verbatim: "Echo Quill")
                        .font(.title3.weight(.bold))
                        .tracking(-0.4)
                        .foregroundStyle(Clay.ink)
                }
            }
            .buttonStyle(.clayPressable)
            .accessibilityLabel(tr("Welcome to Echo Quill"))

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                if !model.sentences.isEmpty {
                    headerButton(tr("Start over"), systemImage: "arrow.counterclockwise") {
                        returnToSetup()
                    }
                }
                headerButton(tr("Progress"), systemImage: "chart.bar") {
                    showsWeeklyStats = true
                }
                if isOnHome {
                    headerButton(tr("Tips"), systemImage: "questionmark.circle") {
                        startHomeTour()
                    }
                }
                headerButton(tr("Settings"), systemImage: "gearshape") {
                    showsSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            .homeTourTarget(.shortcuts)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .clayColumn(contentMaxWidth)
    }

    /// An icon over a short label, so every header action says what it does.
    private func headerButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .frame(height: 22)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Clay.body)
            .padding(4)
            .frame(minWidth: 52, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.clayPressable)
    }

    /// The Home screen: no practice open and no input flow chosen.
    private var isOnHome: Bool {
        model.sentences.isEmpty && setupChoice == nil && !model.isTranscribing
            && !model.isReviewing && !model.isEditingSourceText
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
        ScrollViewReader { scrollProxy in
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
            .onChange(of: homeTourIndex) { _, index in
                guard let index, index < homeTourSteps.count else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    scrollProxy.scrollTo(homeTourSteps[index], anchor: .center)
                }
            }
        }
    }

    // MARK: - Home Tour

    /// The tour skips "Your other practices" until there is something in it.
    private var homeTourSteps: [HomeTourStep] {
        HomeTourStep.allCases.filter { $0 != .others || !otherPractices.isEmpty }
    }

    /// Plays the Home tips, the first time Home appears and again from the Tips button.
    private func startHomeTour() {
        guard isOnHome else { return }
        withAnimation(.easeOut(duration: 0.35)) { homeTourIndex = 0 }
    }

    private func advanceHomeTour() {
        guard let homeTourIndex else { return }
        if homeTourIndex + 1 < homeTourSteps.count {
            withAnimation(.easeOut(duration: 0.35)) { self.homeTourIndex = homeTourIndex + 1 }
        } else {
            endHomeTour()
        }
    }

    private func endHomeTour() {
        UserDefaults.standard.set(true, forKey: HomeTourStep.seenKey)
        withAnimation(.easeOut(duration: 0.3)) { homeTourIndex = nil }
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
                    VStack(alignment: .leading, spacing: 24) {
                        soundWaveBanner
                        statsCard(fillsHeight: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: wideColumnHeight, alignment: .top)
                    // The column scrolls on its own, so a short window or a long practice list
                    // never squeezes its sections or pushes the heading out of view.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            makeDictationSection
                            continueSection
                            otherPracticesSection
                            privacyCaption
                        }
                        .padding(.vertical, 8)
                        .padding(.trailing, 4)
                    }
                    .scrollIndicators(.automatic)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: wideColumnHeight, alignment: .top)
                }
                .padding(.top, 24)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    soundWaveBanner
                    makeDictationSection
                    continueSection
                    otherPracticesSection
                    privacyCaption
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            choicesHaveAppeared = true
            if onboarding == nil, !UserDefaults.standard.bool(forKey: HomeTourStep.seenKey) {
                startHomeTour()
            }
        }
    }

    /// The bouncing sound wave in the brand colors at the top of Home.
    private var soundWaveBanner: some View {
        EqualizerBars(height: 72)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .background(Clay.surfaceSoft, in: RoundedRectangle(cornerRadius: Clay.Radius.xl, style: .continuous))
    }

    private var privacyCaption: some View {
        Label(tr("Everything is processed on your device"), systemImage: "lock")
            .font(.footnote)
            .foregroundStyle(Clay.muted)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Weekly Stats

    private static let weekRangeFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateTemplate = "MMMd"
        return formatter
    }()

    /// This week's practice at a glance, shown beside the start choices on iPad and Mac.
    private func statsCard(fillsHeight: Bool) -> some View {
        let week = stats.week()
        let dayLetters = Calendar.current.veryShortWeekdaySymbols
        let mondayFirst = Array(dayLetters[1...]) + [dayLetters[0]]
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(tr("This week")).clayEyebrow()
                Spacer()
                Text(Self.weekRangeFormatter.string(from: week.start, to: week.end))
                    .font(.subheadline)
                    .foregroundStyle(Clay.muted)
            }

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    statTile(tr("Streak"), systemImage: "flame", accent: Clay.peach) {
                        statValue("\(week.streak)", unit: tr("days"))
                        HStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { index in
                                VStack(spacing: 6) {
                                    Capsule()
                                        .fill(week.activeDays[index] ? Clay.peach : Clay.surfaceStrong)
                                        .frame(height: 8)
                                    Text(mondayFirst[index])
                                        .font(.caption2)
                                        .foregroundStyle(index == week.todayIndex ? Clay.ink : Clay.muted)
                                        .fontWeight(index == week.todayIndex ? .bold : .regular)
                                }
                            }
                        }
                    }
                    statTile(tr("Sentences dictated"), systemImage: "pencil", accent: Clay.ochre) {
                        statValue("\(week.sentenceCount)", unit: nil)
                        let peak = max(week.dailyCounts.max() ?? 0, 1)
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(0..<7, id: \.self) { index in
                                let count = week.dailyCounts[index]
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(count > 0 ? Clay.ochre : Clay.surfaceStrong)
                                    .frame(height: count > 0 ? max(8, 40 * CGFloat(count) / CGFloat(peak)) : 4)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: 40, alignment: .bottom)
                    }
                }
                HStack(spacing: 12) {
                    statTile(tr("Dictation accuracy"), systemImage: "scope", accent: Clay.mint) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            statValue(week.accuracy.map { "\($0)" } ?? "–", unit: "%")
                            if let change = week.accuracyChange, change != 0 {
                                Text(tr("%@ vs last week", (change > 0 ? "+" : "\u{2212}") + "\(abs(change))"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Clay.mint)
                            }
                        }
                        statBar(Double(week.accuracy ?? 0) / 100, accent: Clay.mint)
                    }
                    statTile(tr("Pronunciation"), systemImage: "mic", accent: Clay.pink) {
                        statValue(week.pronunciation.map { "\($0)" } ?? "–", unit: tr("avg score"))
                        statBar(Double(week.pronunciation ?? 0) / 100, accent: Clay.pink)
                    }
                }
            }
            .frame(maxHeight: fillsHeight ? .infinity : nil)

            if !week.wordsToReview.isEmpty {
                Text(tr("Words to review"))
                    .font(.clayTitle)
                    .padding(.top, 4)
                HStack(spacing: 8) {
                    ForEach(week.wordsToReview.prefix(4), id: \.self) { word in
                        Text(word)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Clay.surfaceStrong, in: Capsule())
                    }
                    if week.wordsToReview.count > 4 {
                        Text(verbatim: "+\(week.wordsToReview.count - 4)")
                            .font(.subheadline)
                            .foregroundStyle(Clay.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Clay.surfaceStrong, in: Capsule())
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .clayCard(Clay.surfaceSoft, radius: Clay.Radius.xl, border: nil)
    }

    private func statTile<Content: View>(
        _ title: String, systemImage: String, accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Clay.surfaceCard, in: RoundedRectangle(cornerRadius: Clay.Radius.lg, style: .continuous))
    }

    private func statValue(_ value: String, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 34, weight: .bold, design: .rounded))
            if let unit {
                Text(unit).font(.subheadline).foregroundStyle(Clay.muted)
            }
        }
    }

    private func statBar(_ fraction: Double, accent: Color) -> some View {
        Capsule()
            .fill(Clay.surfaceStrong)
            .frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(accent).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
    }

    /// The week's stats in a pop-up window, opened from the header on iPhone.
    private var weeklyStatsSheet: some View {
        NavigationStack {
            ScrollView {
                statsCard(fillsHeight: false)
                    .padding(20)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        weeklyStatsHeight = $0 + 120
                    }
            }
            .background(Clay.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { showsWeeklyStats = false }
                }
            }
        }
        .foregroundStyle(Clay.ink)
        .tint(Clay.ink)
    }

    private var makeDictationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Make a dictation from your own material"))
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr("We split it into sentences you can practice one by one."))
                    .font(.subheadline)
                    .foregroundStyle(Clay.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            // Short labels only: the Tips tour explains what each one does.
            HStack(alignment: .top, spacing: 10) {
                choiceButton(title: tr("From text"), systemImage: "text.alignleft", accent: .pink, order: 0) {
                    setupChoice = .text
                }
                .homeTourTarget(.text)
                .id(HomeTourStep.text)

                choiceButton(title: tr("From audio"), systemImage: "waveform", accent: .lavender, order: 1) {
                    setupChoice = .audio
                }
                .homeTourTarget(.audio)
                .id(HomeTourStep.audio)

                choiceButton(title: tr("From a photo"), systemImage: "camera", accent: .peach, order: 2) {
                    setupChoice = .photo
                }
                .homeTourTarget(.photo)
                .id(HomeTourStep.photo)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Practices

    /// The most recent practice, offered on its own card so it is one tap to continue.
    private var continuePractice: RecentPractice? { model.recentPractices.first }

    /// Everything else, newest first.
    private var otherPractices: [RecentPractice] { Array(model.recentPractices.dropFirst()) }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Pick up where you left off"))
                .clayEyebrow()
                .accessibilityAddTraits(.isHeader)
            if let practice = continuePractice {
                continueCard(practice)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "pencil")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(Clay.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("No practice yet"))
                            .font(.callout.weight(.bold))
                        Text(tr("Make your first dictation above. It will wait for you here."))
                            .font(.subheadline)
                            .foregroundStyle(Clay.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Clay.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .homeTourTarget(.resume)
        .id(HomeTourStep.resume)
    }

    private func continueCard(_ practice: RecentPractice) -> some View {
        let accent = practiceAccent(practice.source)
        let total = max(practice.sentenceCount, 1)
        let done = min(practice.currentSentenceIndex, total)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                practiceTile(practice, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(practice.title)
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                    Text(continueDetail(practice))
                        .font(.footnote)
                        .foregroundStyle(Clay.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    recentPracticeActions(practice)
                } label: {
                    moreOptionsLabel
                }
                .accessibilityLabel(tr("More options"))
            }
            VStack(alignment: .leading, spacing: 6) {
                Capsule()
                    .fill(Clay.hairline)
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(accent.fill)
                                .frame(width: proxy.size.width * CGFloat(done) / CGFloat(total))
                        }
                    }
                    .accessibilityHidden(true)
                Text(done == 0
                    ? tr("Not started yet")
                    : tr("%@ of %@ sentences done", "\(done)", "\(practice.sentenceCount)"))
                    .font(.footnote)
                    .foregroundStyle(Clay.body)
            }
            Button {
                model.openRecentPractice(practice)
            } label: {
                Text(tr("Continue with sentence %@", "\(min(done + 1, practice.sentenceCount))"))
                    .font(.callout.weight(.bold))
                    .foregroundStyle(Clay.onInk)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Clay.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.clayPressable)
        }
        .padding(16)
        .clayCard(Clay.surfaceCard, radius: 20, border: nil)
        .contextMenu { recentPracticeActions(practice) }
    }

    @ViewBuilder
    private var otherPracticesSection: some View {
        if !otherPractices.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Your other practices"))
                    .clayEyebrow()
                    .accessibilityAddTraits(.isHeader)
                otherPracticeRows
            }
            .homeTourTarget(.others)
            .id(HomeTourStep.others)
        }
    }

    private var otherPracticeRows: some View {
        VStack(spacing: 10) {
            ForEach(otherPractices) { practice in
                otherPracticeRow(practice)
            }
        }
    }

    private func otherPracticeRow(_ practice: RecentPractice) -> some View {
        HStack(spacing: 4) {
            Button {
                model.openRecentPractice(practice)
            } label: {
                HStack(spacing: 12) {
                    practiceTile(practice, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(practice.title)
                            .font(.callout.weight(.bold))
                            .foregroundStyle(Clay.ink)
                            .lineLimit(1)
                        Text(otherPracticeDetail(practice))
                            .font(.footnote)
                            .foregroundStyle(Clay.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.clayPressable)

            Menu {
                recentPracticeActions(practice)
            } label: {
                moreOptionsLabel
            }
            .accessibilityLabel(tr("More options"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
        .clayCard(Clay.surfaceCard, radius: Clay.Radius.lg, border: nil)
        .contextMenu { recentPracticeActions(practice) }
    }

    private var moreOptionsLabel: some View {
        Image(systemName: "ellipsis")
            .font(.body.weight(.semibold))
            .foregroundStyle(Clay.body)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func practiceTile(_ practice: RecentPractice, size: CGFloat) -> some View {
        let accent = practiceAccent(practice.source)
        return Image(systemName: sourceIcon(practice.source))
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(accent.on)
            .frame(width: size, height: size)
            .background(accent.fill, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }

    /// Practices take the color of where they came from: amber audio, mint photos, lavender text.
    private func practiceAccent(_ source: PracticeSource) -> ClayAccent {
        switch source {
        case .audioFile, .recording: .ochre
        case .photo: .mint
        case .typedText, .textFile: .lavender
        }
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

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: localization.resolvedCode)
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// "German · from audio · 2h ago"
    private func continueDetail(_ practice: RecentPractice) -> String {
        let origin = switch practice.source {
        case .audioFile, .recording: tr("from audio")
        case .photo: tr("from a photo")
        case .typedText, .textFile: tr("from text")
        }
        return [
            localization.languageName(for: practice.languageIdentifier),
            origin,
            relativeTime(practice.lastPracticed)
        ].joined(separator: " \u{00B7} ")
    }

    /// "3 of 16 sentences · 15h ago", or "Not started · 19h ago"
    private func otherPracticeDetail(_ practice: RecentPractice) -> String {
        let progress = practice.currentSentenceIndex == 0
            ? tr("Not started")
            : tr("%@ of %@ sentences", "\(practice.currentSentenceIndex)", "\(practice.sentenceCount)")
        return [progress, relativeTime(practice.lastPracticed)].joined(separator: " \u{00B7} ")
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
        systemImage: String,
        accent: ClayAccent,
        order: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .frame(height: 30)
                Text(title)
                    .font(.headline.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Dark text on every tile: white is too faint on the lighter colors.
            .foregroundStyle(Clay.onColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 104, maxHeight: .infinity, alignment: .top)
            .background(accent.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
