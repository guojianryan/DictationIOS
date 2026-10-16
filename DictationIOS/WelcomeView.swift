import SwiftUI

/// The first screen of onboarding: what the app does, shown as a looping Listen, Write / Record, Check
/// demo. It appears on the first launch and again from the header's logo and help buttons.
struct WelcomeView: View {
    @ObservedObject var localization: AppLocalization
    let onSetUp: () -> Void
    /// Shown as a close button when the welcome is replayed; nil on the first launch.
    var onClose: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    brandRow
                    Text(tr("Get better at a language by writing down what you hear"))
                        .font(.system(.title, design: .rounded, weight: .heavy))
                        .tracking(-0.5)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if reduceMotion {
                        demoCard(phase: 0, time: 0, isStatic: true)
                        stepCards(activePhase: nil)
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                            let time = context.date.timeIntervalSinceReferenceDate
                            let phase = Int(time.truncatingRemainder(dividingBy: Self.cycle) / Self.phaseLength)
                            VStack(spacing: 22) {
                                demoCard(phase: phase, time: time, isStatic: false)
                                stepCards(activePhase: phase)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 16)
                .clayColumn(560)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 10) {
                Button(action: onSetUp) {
                    HStack(spacing: 8) {
                        Text(tr("Set up Echo Quill"))
                        Image(systemName: "arrow.right")
                    }
                    .onboardingPrimaryLabel()
                }
                .buttonStyle(.clayPressable)

                Label(tr("Takes a minute \u{00B7} everything stays on your device"), systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(Clay.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .clayColumn(560)
        }
        .foregroundStyle(Clay.ink)
        .background(Clay.canvas.ignoresSafeArea())
    }

    // MARK: - Brand

    private var brandRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(ClayAccent.pink.on)
                .frame(width: 40, height: 40)
                .background(Clay.pink, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
                .accessibilityHidden(true)
            Text(tr("Welcome to Echo Quill"))
                .font(.headline.weight(.bold))
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.clayIcon)
                .accessibilityLabel(tr("Close"))
            }
        }
    }

    // MARK: - Demo animation

    /// Three phases of 2.5 seconds: Listen, Write / Record, Check.
    private static let phaseLength: TimeInterval = 2.5
    private static let cycle: TimeInterval = phaseLength * 3
    private static let sentence = "Ich fahre morgen nach Berlin."
    private static let barHeights: [CGFloat] = [18, 30, 36, 24, 34, 20, 28]

    private func demoCard(phase: Int, time: TimeInterval, isStatic: Bool) -> some View {
        let local = time.truncatingRemainder(dividingBy: Self.phaseLength)
        return ZStack {
            if isStatic {
                VStack(spacing: 16) {
                    listenPhase(time: 0, isStatic: true)
                    sentenceBox(Self.sentence, showsCaret: false)
                }
            } else {
                Group {
                    switch phase {
                    case 0: listenPhase(time: time, isStatic: false)
                    case 1: writePhase(local: local, time: time)
                    default: checkPhase(local: local)
                    }
                }
                .opacity(Self.phaseOpacity(local))
                .offset(y: Self.phaseOffset(local))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 250)
        .background(Clay.surfaceCard, in: RoundedRectangle(cornerRadius: Clay.Radius.xl, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Clay.Radius.xl, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(tr("Animation: a sentence plays, the learner types it or says it out loud, and the app checks it"))
        .accessibilityAddTraits(.isImage)
    }

    /// Each phase fades in and rises over its first 0.3 s and fades out and rises over its last 0.25 s.
    private static func phaseOpacity(_ local: TimeInterval) -> Double {
        if local < 0.3 { return local / 0.3 }
        if local > phaseLength - 0.25 { return (phaseLength - local) / 0.25 }
        return 1
    }

    private static func phaseOffset(_ local: TimeInterval) -> CGFloat {
        if local < 0.3 { return 10 * (1 - local / 0.3) }
        if local > phaseLength - 0.25 { return -10 * (1 - (phaseLength - local) / 0.25) }
        return 0
    }

    private func listenPhase(time: TimeInterval, isStatic: Bool) -> some View {
        VStack(spacing: 16) {
            ZStack {
                if !isStatic {
                    ForEach(0..<2, id: \.self) { ring in
                        // Each ring grows from 1x to 1.9x and fades out over 1.6 s; the second starts 0.8 s later.
                        let progress = ((time - Double(ring) * 0.8) / 1.6).truncatingRemainder(dividingBy: 1)
                        let t = progress < 0 ? progress + 1 : progress
                        Circle()
                            .strokeBorder(Clay.pink, lineWidth: 2)
                            .frame(width: 84, height: 84)
                            .scaleEffect(1 + 0.9 * t)
                            .opacity(0.8 * (1 - t))
                    }
                }
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(ClayAccent.pink.on)
                    .frame(width: 84, height: 84)
                    .background(Clay.pink, in: Circle())
            }
            HStack(spacing: 5) {
                ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { index, height in
                    // Bars pulse between 35% and full height every 0.9 s, staggered by 0.15 s.
                    let wave = isStatic ? 1 : (1 - cos((time - Double(index) * 0.15) / 0.9 * 2 * .pi)) / 2
                    Capsule()
                        .fill(Clay.pink)
                        .frame(width: 6, height: height)
                        .scaleEffect(x: 1, y: 0.35 + 0.65 * wave)
                }
            }
            .frame(height: 36)
        }
    }

    private func writePhase(local: TimeInterval, time: TimeInterval) -> some View {
        // The sentence types itself between 0.1 s and 1.6 s into the phase.
        let progress = min(max((local - 0.1) / 1.5, 0), 1)
        let count = Int((Double(Self.sentence.count) * progress).rounded(.down))
        return VStack(spacing: 16) {
            HStack(spacing: 12) {
                ForEach(["pencil", "mic"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(ClayAccent.lavender.on)
                        .frame(width: 48, height: 48)
                        .background(Clay.lavender, in: Circle())
                }
            }
            sentenceBox(String(Self.sentence.prefix(count)), showsCaret: Int(time) % 2 == 0)
        }
    }

    private func sentenceBox(_ text: String, showsCaret: Bool) -> some View {
        HStack(spacing: 2) {
            Text(verbatim: text)
                .lineLimit(1)
            Capsule()
                .fill(Clay.ink)
                .frame(width: 2, height: 22)
                .opacity(showsCaret ? 1 : 0)
            Spacer(minLength: 0)
        }
        .font(.system(size: 19))
        .padding(.horizontal, 16)
        .frame(maxWidth: 310, minHeight: 54)
        .background(Clay.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Clay.lavender, lineWidth: 2)
        }
        .padding(.horizontal, 16)
    }

    private func checkPhase(local: TimeInterval) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(ClayAccent.peach.on)
                .frame(width: 64, height: 64)
                .background(Clay.peach, in: Circle())
                .scaleEffect(Self.popScale(local))
            Text(Self.markedSentence)
                .font(.system(size: 19))
            Text(tr("Almost perfect. You missed the full stop."))
                .font(.subheadline)
                .foregroundStyle(Clay.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
    }

    /// The typed sentence with the missing full stop marked as a mistake.
    private static var markedSentence: AttributedString {
        var sentence = AttributedString("Ich fahre morgen nach Berlin")
        var mistake = AttributedString("\u{2009}.\u{2009}")
        mistake.foregroundColor = Clay.errorText
        mistake.backgroundColor = Clay.error.opacity(0.18)
        mistake.font = .system(size: 19, weight: .bold)
        sentence.append(mistake)
        return sentence
    }

    /// Pops from 0 to 1.15 at 0.45 s, then settles to 1 at 0.68 s.
    private static func popScale(_ local: TimeInterval) -> CGFloat {
        if local < 0.45 { return 1.15 * local / 0.45 }
        if local < 0.68 { return 1.15 - 0.15 * (local - 0.45) / 0.23 }
        return 1
    }

    // MARK: - Steps

    private func stepCards(activePhase: Int?) -> some View {
        let steps: [([String], ClayAccent, String, String)] = [
            (["speaker.wave.2"], .pink, tr("Listen"), tr("Hear one sentence at a time")),
            (["pencil", "mic"], .lavender, tr("Write / Record"), tr("Type what you heard, or say it out loud")),
            (["checkmark.circle"], .peach, tr("Check"), tr("See your mistakes, then try again"))
        ]
        return HStack(alignment: .top, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let isActive = index == activePhase
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(step.0, id: \.self) { Image(systemName: $0) }
                    }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(step.1.on)
                        .frame(minWidth: 28, minHeight: 28)
                        .padding(.horizontal, step.0.count > 1 ? 6 : 0)
                        .background(step.1.fill, in: RoundedRectangle(cornerRadius: Clay.Radius.sm, style: .continuous))
                    Text(step.2)
                        .font(.subheadline.weight(.bold))
                    Text(step.3)
                        .font(.footnote)
                        .foregroundStyle(Clay.muted)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    isActive ? Clay.surfaceStrong : Clay.surfaceCard,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .offset(y: isActive ? -4 : 0)
                .animation(.easeOut(duration: 0.25), value: isActive)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tr(_ key: String) -> String {
        localization.string(LocalizableText(key: key))
    }
}

extension View {
    /// The large full-width call to action used on the onboarding screens.
    func onboardingPrimaryLabel() -> some View {
        font(.body.weight(.bold))
            .foregroundStyle(ClayAccent.pink.on)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Clay.pink, in: RoundedRectangle(cornerRadius: Clay.Radius.lg, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Clay.Radius.lg, style: .continuous))
    }
}

/// Welcome, then the setup screen. Finishing setup (or closing a replayed welcome) returns Home.
struct OnboardingFlow: View {
    enum Presentation: Identifiable {
        case firstLaunch
        case replay

        var id: Self { self }
    }

    static let completedKey = "hasCompletedOnboarding"

    @ObservedObject var model: DictationModel
    @ObservedObject var localization: AppLocalization
    let isReplay: Bool
    let onFinish: () -> Void
    @State private var showsSetup = false

    var body: some View {
        ZStack {
            if showsSetup {
                SettingsView(model: model, localization: localization, mode: .setup(
                    onBack: { withAnimation(.spring(duration: 0.4, bounce: 0.1)) { showsSetup = false } },
                    onFinish: onFinish
                ))
                .transition(.move(edge: .trailing))
            } else {
                WelcomeView(
                    localization: localization,
                    onSetUp: { withAnimation(.spring(duration: 0.4, bounce: 0.1)) { showsSetup = true } },
                    onClose: isReplay ? onFinish : nil
                )
                .transition(.move(edge: .leading))
            }
        }
        .background(Clay.canvas.ignoresSafeArea())
    }
}
