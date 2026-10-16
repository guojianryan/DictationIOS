import SwiftUI

/// A tip bubble that points at part of the screen, from the design handoff: a title, a short
/// explanation, a step counter, and a pink button. The pointer sits on the top or bottom edge.
struct CoachMarkBubble: View {
    enum PointerEdge {
        case top
        case bottom
    }

    let title: String
    let message: String
    let counter: String
    let primaryTitle: String
    let onPrimary: () -> Void
    var skipTitle: String? = nil
    var onSkip: (() -> Void)? = nil
    var pointerEdge: PointerEdge = .top
    /// The pointer's horizontal center, measured from the bubble's leading edge.
    var pointerX: CGFloat = 41

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.bold))
            Text(message)
                .font(.subheadline)
                .lineSpacing(2)
                .foregroundStyle(Clay.onInk.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(counter)
                    .font(.footnote)
                    .foregroundStyle(Clay.onInk.opacity(0.7))
                Spacer()
                if let skipTitle, let onSkip {
                    Button(action: onSkip) {
                        Text(skipTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Clay.onInk.opacity(0.8))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onPrimary) {
                    Text(primaryTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ClayAccent.pink.on)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Clay.pink, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
                }
                .buttonStyle(.clayPressable)
            }
            .padding(.top, 4)
        }
        .foregroundStyle(Clay.onInk)
        .padding(16)
        .background(Clay.ink, in: RoundedRectangle(cornerRadius: Clay.Radius.lg, style: .continuous))
        .overlay(alignment: pointerEdge == .top ? .topLeading : .bottomLeading) {
            Rectangle()
                .fill(Clay.ink)
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(45))
                .offset(x: pointerX - 7, y: pointerEdge == .top ? -7 : 7)
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// The pink outline around the part of the screen a tip explains. It breathes from 3 pt to a
/// soft 7 pt ring every 1.6 s, or stays still with reduce motion on.
struct CoachMarkRing: View {
    var cornerRadius: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(Clay.pink.opacity(isExpanded ? 0.35 : 1), lineWidth: isExpanded ? 7 : 3)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isExpanded = true
                }
            }
    }
}

// MARK: - Home tour

/// The parts of the Home screen the tip tour explains, in order.
enum HomeTourStep: Hashable, CaseIterable {
    case shortcuts
    case text
    case audio
    case photo
    case resume
    case others

    static let seenKey = "hasSeenHomeTips"

    var title: String {
        switch self {
        case .shortcuts: "Your shortcuts"
        case .resume: "Continue where you stopped"
        case .text: "Start from text"
        case .audio: "Start from audio"
        case .photo: "Start from a photo"
        case .others: "Your other practices"
        }
    }

    var message: String {
        switch self {
        case .shortcuts: "Progress shows your streak, accuracy and pronunciation this week. Tips plays these hints again anytime. Settings changes your languages, voice and theme. Tap the logo to watch the welcome again."
        case .resume: "Your latest practice appears here. One tap on Continue takes you straight to the next sentence."
        case .others: "Up to 10 more recent practices, with how far you got. Tap one to continue, or use the ••• button to start over or remove it from the list."
        case .text: "Type or paste an article, a dialogue or your homework, open a text file, or let AI write a new text at your level on any topic. Echo Quill reads each sentence aloud and you type it."
        case .audio: "Upload an audio file, like a podcast clip, or record yourself. Echo Quill writes down what is said, so it can check your answers."
        case .photo: "Take a picture of a book page or choose one from your photos. You can fix any wrongly recognised words before you start practicing."
        }
    }

    /// The corner radius of the outline, matching the shape it surrounds.
    var ringRadius: CGFloat {
        switch self {
        case .shortcuts: 14
        case .resume, .others: 22
        default: 24
        }
    }
}

struct HomeTourAnchorKey: PreferenceKey {
    static let defaultValue: [HomeTourStep: Anchor<CGRect>] = [:]

    static func reduce(value: inout [HomeTourStep: Anchor<CGRect>], nextValue: () -> [HomeTourStep: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks the view the home tour points at for `step`.
    func homeTourTarget(_ step: HomeTourStep) -> some View {
        anchorPreference(key: HomeTourAnchorKey.self, value: .bounds) { [step: $0] }
    }
}

/// Dims Home except the current target, outlines it, and shows the step's tip beside it.
struct HomeTourOverlay: View {
    let steps: [HomeTourStep]
    let index: Int
    let anchors: [HomeTourStep: Anchor<CGRect>]
    let localize: (String) -> String
    let onNext: () -> Void
    let onSkip: () -> Void
    @State private var bubbleHeight: CGFloat = 220

    var body: some View {
        GeometryReader { proxy in
            let step = steps[index]
            let size = proxy.size
            if let anchor = anchors[step] {
                let target = proxy[anchor].insetBy(dx: -6, dy: -6)
                let bubbleWidth = min(size.width - 32, 360)
                let spaceBelow = size.height - target.maxY
                let showsBelow = spaceBelow >= bubbleHeight + 24 || spaceBelow > target.minY
                let bubbleX = min(max(target.midX - bubbleWidth / 2, 16), size.width - 16 - bubbleWidth)
                let bubbleY = showsBelow ? target.maxY + 14 : target.minY - 14 - bubbleHeight
                let pointerX = min(max(target.midX - bubbleX, 24), bubbleWidth - 24)

                ZStack(alignment: .topLeading) {
                    // Everything but the target fades back to a quarter of its strength.
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRoundedRect(in: target, cornerSize: CGSize(width: step.ringRadius, height: step.ringRadius), style: .continuous)
                    }
                    .fill(Clay.canvas.opacity(0.75), style: FillStyle(eoFill: true))
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)

                    CoachMarkRing(cornerRadius: step.ringRadius)
                        .frame(width: target.width, height: target.height)
                        .offset(x: target.minX, y: target.minY)
                        .id(step)

                    CoachMarkBubble(
                        title: localize(step.title),
                        message: localize(step.message),
                        counter: String(format: localize("%@ of %@"), "\(index + 1)", "\(steps.count)"),
                        primaryTitle: localize(index == steps.count - 1 ? "Got it" : "Next"),
                        onPrimary: onNext,
                        skipTitle: localize("Skip tips"),
                        onSkip: onSkip,
                        pointerEdge: showsBelow ? .top : .bottom,
                        pointerX: pointerX
                    )
                    .frame(width: bubbleWidth)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bubbleHeight = $0 }
                    .offset(x: bubbleX, y: bubbleY)
                    .id(index)
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
                .animation(.easeOut(duration: 0.35), value: target)
            } else {
                Color.clear
            }
        }
        .ignoresSafeArea()
    }
}
