import AVFoundation
import SwiftUI

/// The app's settings, laid out as tappable choices. The same screen is the setup step of
/// onboarding (with a back arrow and a "Start using Echo Quill" button) and the Settings sheet.
struct SettingsView: View {
    enum Mode {
        /// Onboarding: `onBack` returns to the welcome screen, `onFinish` goes to Home.
        case setup(onBack: () -> Void, onFinish: () -> Void)
        /// The Settings sheet. `onReplayWelcome` closes Settings and shows the welcome screen again.
        case settings(onReplayWelcome: () -> Void)
    }

    static let tipShownKey = "hasShownSetupTip"

    @ObservedObject var model: DictationModel
    @ObservedObject var localization: AppLocalization
    let mode: Mode
    @ObservedObject private var storageFolder = StorageFolder.shared
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .light
    @AppStorage(SettingsView.tipShownKey) private var hasShownTip = false
    @Environment(\.dismiss) private var dismiss
    @State private var showsFolderPicker = false
    @State private var folderErrorMessage: String?

    private var isSetup: Bool {
        if case .setup = mode { return true }
        return false
    }

    /// The first-time coach mark points at the first question while everything else dims.
    private var showsTip: Bool { isSetup && !hasShownTip }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heading

                    VStack(alignment: .leading, spacing: 16) {
                        learningLanguageSection
                            .overlay { if showsTip { CoachMarkRing().padding(-8) } }
                        if showsTip {
                            tipBubble
                                .transition(.opacity.combined(with: .offset(y: 8)))
                        }
                    }

                    Group {
                        translationSection
                        voiceSection
                        appLanguageSection
                        themeSection
                        folderSection
                        if case .settings(let onReplayWelcome) = mode {
                            replayWelcomeButton(onReplayWelcome)
                        }
                    }
                    .opacity(showsTip ? 0.25 : 1)
                    .allowsHitTesting(!showsTip)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .clayColumn(600)
            }
            .scrollBounceBehavior(.basedOnSize)

            if case .setup(_, let onFinish) = mode {
                VStack(spacing: 10) {
                    Button {
                        hasShownTip = true
                        onFinish()
                    } label: {
                        Text(tr("Start using Echo Quill"))
                            .onboardingPrimaryLabel()
                    }
                    .buttonStyle(.clayPressable)
                    Text(tr("You can change these anytime in Settings"))
                        .font(.footnote)
                        .foregroundStyle(Clay.muted)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .clayColumn(600)
                .opacity(showsTip ? 0.25 : 1)
                .allowsHitTesting(!showsTip)
            }
        }
        .foregroundStyle(Clay.ink)
        .tint(Clay.ink)
        .background(Clay.canvas.ignoresSafeArea())
        .animation(.easeOut(duration: 0.3), value: showsTip)
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
                folderErrorMessage = tr("Could not use this folder.")
            }
        }
        .onChange(of: appearance) { _, newValue in newValue.apply() }
    }

    // MARK: - Header

    private var topBar: some View {
        HStack {
            if case .setup(let onBack, _) = mode {
                Button(action: onBack) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Clay.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Back"))
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
            Spacer()
            Text(isSetup ? tr("Set up \u{00B7} a few quick choices") : tr("Settings"))
                .font(isSetup ? .subheadline : .headline)
                .foregroundStyle(isSetup ? Clay.muted : Clay.ink)
            Spacer()
            if isSetup {
                Color.clear.frame(width: 44, height: 44)
            } else {
                Button(tr("Done")) { dismiss() }
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .clayColumn(600)
    }

    @ViewBuilder
    private var heading: some View {
        if isSetup {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Let's make it yours"))
                    .font(.system(.title, design: .rounded, weight: .heavy))
                    .tracking(-0.4)
                Text(tr("This decides the voice and translations you get."))
                    .font(.subheadline)
                    .foregroundStyle(Clay.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Sections

    private var learningLanguageSection: some View {
        section(tr("Which language are you learning?")) {
            chips(
                model.speechLanguages.map { ($0.identifier, localization.languageName(for: $0.identifier)) },
                selection: $model.defaultSpeechLocale
            )
        }
    }

    private var translationSection: some View {
        section(
            tr("Translate into"),
            footer: tr("Defaults are used when you start. A language you pick while adding text or audio applies only to that session.")
        ) {
            chips(
                TranslationLanguage.supported.map { ($0.code, localization.languageName(for: $0.code)) },
                selection: $model.defaultTranslationLanguage
            )
        }
    }

    private var voiceSection: some View {
        section(
            tr("Voice"),
            footer: localization.string(.format(
                "The voice used to read %@. Change the spoken language above to choose a voice for a different language.",
                localization.languageName(for: model.defaultSpeechLocale)
            ))
        ) {
            chips(
                [("", tr("Automatic"))] + availableVoices.map { ($0.identifier, voiceLabel($0)) },
                selection: Binding(
                    get: { voiceSelection.wrappedValue ?? "" },
                    set: { voiceSelection.wrappedValue = $0.isEmpty ? nil : $0 }
                )
            )
        }
    }

    private var appLanguageSection: some View {
        section(tr("App language")) {
            chips(
                [("system", tr("System"))] + AppLocalization.choices.map { ($0.id, $0.title) },
                selection: $localization.appLanguage
            )
        }
    }

    private var themeSection: some View {
        section(tr("Theme")) {
            HStack(spacing: 8) {
                ForEach(AppAppearance.allCases) { option in
                    let isOn = appearance == option
                    Button {
                        appearance = option
                        option.apply()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: themeIcon(option))
                                .font(.system(size: 18, weight: .semibold))
                            Text(localization.string(LocalizableText(key: option.title)))
                                .font(.footnote.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .optionStyle(isOn: isOn, radius: Clay.Radius.lg)
                    }
                    .buttonStyle(.clayPressable)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }

    private var folderSection: some View {
        section(tr("Saved files"), footer: folderFooter) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ClayAccent.ochre.on)
                        .frame(width: 36, height: 36)
                        .background(Clay.ochre, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Folder"))
                            .font(.footnote)
                            .foregroundStyle(Clay.muted)
                        Text(storageFolder.displayName ?? tr("Documents (default)"))
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    smallButton(tr("Choose Folder")) { showsFolderPicker = true }
                    if storageFolder.chosenURL != nil {
                        smallButton(tr("Use Documents Folder")) {
                            storageFolder.useDocumentsFolder()
                            folderErrorMessage = nil
                        }
                    }
                }
            }
            .padding(14)
            .clayCard(Clay.surfaceCard, border: Clay.hairline)
        }
    }

    private var folderFooter: String {
        folderErrorMessage ?? [
            tr("Speech, recordings, and practice progress are saved in this folder. Choose a folder in iCloud Drive to use the same files in the Mac app."),
            tr("If you choose a folder in iCloud Drive, you can continue your practice on your other Apple devices.")
        ].joined(separator: " ")
    }

    private func replayWelcomeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "play.circle")
                    .font(.system(size: 18, weight: .semibold))
                Text(tr("Replay the welcome animation"))
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Clay.muted)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .clayCard(Clay.surfaceCard, border: Clay.hairline)
        }
        .buttonStyle(.clayPressable)
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            content()
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(folderErrorMessage != nil && footer == folderErrorMessage ? Clay.errorText : Clay.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Single-choice pill chips that wrap onto as many lines as they need.
    private func chips(_ options: [(id: String, title: String)], selection: Binding<String>) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.id) { option in
                let isOn = selection.wrappedValue == option.id
                Button {
                    selection.wrappedValue = option.id
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .optionStyle(isOn: isOn, radius: 22)
                }
                .buttonStyle(.clayPressable)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(Clay.canvas, in: Capsule())
                .overlay { Capsule().strokeBorder(Clay.hairline, lineWidth: 1.5) }
                .contentShape(Capsule())
        }
        .buttonStyle(.clayPressable)
    }

    // MARK: - First-time tip

    private var tipBubble: some View {
        CoachMarkBubble(
            title: tr("Tap to choose"),
            message: tr("Pick one answer in each group. Not sure? Keep the suggestion. You can change everything later in Settings."),
            counter: tr("1 of 1"),
            primaryTitle: tr("Got it"),
            onPrimary: { hasShownTip = true }
        )
        .padding(.top, 4)
    }

    // MARK: - Helpers

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
        case .enhanced: "\(voice.name) (\(tr("Enhanced")))"
        case .premium: "\(voice.name) (\(tr("Premium")))"
        default: voice.name
        }
    }

    private func themeIcon(_ option: AppAppearance) -> String {
        switch option {
        case .light: "sun.max"
        case .dark: "moon"
        case .cool: "snowflake"
        }
    }

    private func tr(_ key: String) -> String {
        localization.string(LocalizableText(key: key))
    }
}

private extension View {
    /// Selected options fill with the accent; the rest sit on a card with a hairline border.
    func optionStyle(isOn: Bool, radius: CGFloat) -> some View {
        foregroundStyle(isOn ? ClayAccent.pink.on : Clay.ink)
            .background(isOn ? Clay.pink : Clay.surfaceCard, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isOn ? Clay.pink : Clay.hairline, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Lays its children out left to right and wraps them onto new lines when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
