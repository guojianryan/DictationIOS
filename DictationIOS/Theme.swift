import SwiftUI
import UIKit

/// The app's design tokens and shared components, following the Clay design system in
/// `awesome-design-md/design-md/clay/DESIGN.md`: a warm cream canvas, near-black ink and
/// buttons, rounded display type, and saturated single-color cards.
enum Clay {
    // Surfaces and text adapt to dark mode; the design's dark surfaces are teal-tinted.
    static let canvas = dynamic(light: 0xFFFAF0, dark: 0x0A1A1A)
    static let surfaceSoft = dynamic(light: 0xFAF5E8, dark: 0x122424)
    static let surfaceCard = dynamic(light: 0xF5F0E0, dark: 0x1A2A2A)
    static let surfaceStrong = dynamic(light: 0xEBE6D6, dark: 0x2A3C3C)
    static let hairline = dynamic(light: 0xE5E0D2, dark: 0x2E4040)
    static let ink = dynamic(light: 0x0A0A0A, dark: 0xFFFAF0)
    static let body = dynamic(light: 0x3A3A3A, dark: 0xD9D4C7)
    static let muted = dynamic(light: 0x6A6A6A, dark: 0xA0A0A0)
    /// Text on an ink-filled (primary) button.
    static let onInk = dynamic(light: 0xFFFFFF, dark: 0x0A0A0A)

    // Brand colors are the same in both appearances.
    static let pink = Color(hex: 0xFF4D8B)
    static let teal = Color(hex: 0x1A3A3A)
    static let lavender = Color(hex: 0xB8A4ED)
    static let peach = Color(hex: 0xFFB084)
    static let ochre = Color(hex: 0xE8B94A)
    static let mint = Color(hex: 0xA4D4C5)
    static let cream = Color(hex: 0xFFFAF0)
    /// Text on a pastel brand color.
    static let onColor = Color(hex: 0x0A0A0A)

    static let success = Color(hex: 0x22C55E)
    static let error = Color(hex: 0xEF4444)
    // The semantic colors, darkened (or lightened in dark mode) so they stay readable as text.
    static let successText = dynamic(light: 0x15803D, dark: 0x4ADE80)
    static let errorText = dynamic(light: 0xDC2626, dark: 0xF87171)

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

/// A saturated card color together with the text color that is readable on it.
struct ClayAccent {
    let fill: Color
    let on: Color

    static let pink = ClayAccent(fill: Clay.pink, on: .white)
    static let teal = ClayAccent(fill: Clay.teal, on: .white)
    static let lavender = ClayAccent(fill: Clay.lavender, on: Clay.onColor)
    static let peach = ClayAccent(fill: Clay.peach, on: Clay.onColor)
    static let ochre = ClayAccent(fill: Clay.ochre, on: Clay.onColor)
    static let mint = ClayAccent(fill: Clay.mint, on: Clay.onColor)
}

private extension UIColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(UIColor(hex: hex))
    }
}

extension Font {
    // Rounded system type at medium weight stands in for the design's Plain Black display face.
    static let clayDisplay = Font.system(.largeTitle, design: .rounded, weight: .medium)
    static let clayTitle = Font.system(.title3, design: .rounded, weight: .semibold)
}

extension View {
    /// A content card: a flat fill with an optional hairline border and no shadow.
    func clayCard(_ fill: Color = Clay.canvas, radius: CGFloat = Clay.Radius.lg, border: Color? = Clay.hairline) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border)
                }
            }
    }

    /// A text input surface: canvas fill with a hairline border.
    func clayInput(border: Color = Clay.hairline, lineWidth: CGFloat = 1) -> some View {
        background(Clay.canvas, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous)
                    .strokeBorder(border, lineWidth: lineWidth)
            }
    }

    /// A pill label on a brand color.
    func clayBadge(_ accent: ClayAccent) -> some View {
        font(.footnote.weight(.semibold))
            .foregroundStyle(accent.on)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(accent.fill, in: Capsule())
    }

    /// An uppercase section label.
    func clayEyebrow() -> some View {
        font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(1.5)
            .foregroundStyle(Clay.muted)
    }
}

// MARK: - Buttons

struct ClayButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    init(kind: Kind) {
        self.kind = kind
    }

    private var isCompact: Bool {
        controlSize == .small || controlSize == .mini
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
            .padding(.horizontal, isCompact ? 12 : 20)
            .frame(minHeight: isCompact ? 32 : 44)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous).strokeBorder(Clay.hairline)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: isEnabled ? Clay.onInk : Clay.muted
        case .secondary: isEnabled ? Clay.ink : Clay.muted
        }
    }

    private var background: Color {
        switch kind {
        case .primary: isEnabled ? Clay.ink : Clay.surfaceStrong
        case .secondary: Clay.canvas
        }
    }
}

/// A round icon button with a hairline outline.
struct ClayIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Clay.ink)
            .frame(width: 40, height: 40)
            .background(Clay.canvas, in: Circle())
            .overlay { Circle().strokeBorder(Clay.hairline) }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

/// Keeps a custom label as it is and adds only the springy press feedback.
struct ClayPressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ClayButtonStyle {
    static var clayPrimary: ClayButtonStyle { ClayButtonStyle(kind: .primary) }
    static var claySecondary: ClayButtonStyle { ClayButtonStyle(kind: .secondary) }
}

extension ButtonStyle where Self == ClayIconButtonStyle {
    static var clayIcon: ClayIconButtonStyle { ClayIconButtonStyle() }
}

extension ButtonStyle where Self == ClayPressableStyle {
    static var clayPressable: ClayPressableStyle { ClayPressableStyle() }
}

/// A square icon toggle that fills with a brand color when it is on.
struct ClayChipToggleStyle: ToggleStyle {
    let accent: ClayAccent

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.3)) {
                configuration.isOn.toggle()
            }
        } label: {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(configuration.isOn ? accent.on : Clay.muted)
                .frame(width: 40, height: 40)
                .background(
                    configuration.isOn ? accent.fill : Clay.canvas,
                    in: RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Clay.Radius.md, style: .continuous)
                        .strokeBorder(configuration.isOn ? Color.clear : Clay.hairline)
                }
        }
        .buttonStyle(.clayPressable)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

// MARK: - Tabs

struct ClayTabItem<Value: Hashable> {
    let value: Value
    let title: String
    var systemImage: String? = nil
}

/// Pill-shaped tabs; the selected pill slides between items.
struct ClayTabs<Value: Hashable>: View {
    let items: [ClayTabItem<Value>]
    @Binding var selection: Value
    let iconOnly: Bool
    let compact: Bool
    @Namespace private var namespace

    init(items: [ClayTabItem<Value>], selection: Binding<Value>, iconOnly: Bool = false, compact: Bool = false) {
        self.items = items
        _selection = selection
        self.iconOnly = iconOnly
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.value) { item in
                let isSelected = item.value == selection
                Button {
                    withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
                        selection = item.value
                    }
                } label: {
                    tabLabel(item)
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Clay.ink : Clay.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, compact ? 2 : (iconOnly ? 12 : 16))
                        .padding(.vertical, 8)
                        .frame(maxWidth: iconOnly ? nil : .infinity)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Clay.surfaceStrong)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Clay.canvas, in: Capsule())
        .overlay { Capsule().strokeBorder(Clay.hairline) }
    }

    @ViewBuilder
    private func tabLabel(_ item: ClayTabItem<Value>) -> some View {
        if iconOnly, let systemImage = item.systemImage {
            Image(systemName: systemImage)
        } else {
            Text(item.title)
        }
    }
}

// MARK: - Equalizer

/// Bouncing bars in the brand colors, used as the app's illustration and its progress indicator.
struct EqualizerBars: View {
    let height: CGFloat
    let barCount: Int
    let isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(height: CGFloat = 64, barCount: Int = 9, isAnimating: Bool = true) {
        self.height = height
        self.barCount = barCount
        self.isAnimating = isAnimating
    }

    private static let colors = [Clay.pink, Clay.lavender, Clay.peach, Clay.ochre, Clay.mint]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isAnimating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 8) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(Self.colors[index % Self.colors.count])
                        .frame(height: height * Self.level(index: index, time: time))
                }
            }
            .frame(height: height)
        }
        .accessibilityHidden(true)
    }

    private static func level(index: Int, time: TimeInterval) -> CGFloat {
        let phase = Double(index) * 0.9
        let wave = sin(time * 2.4 + phase) * 0.5 + sin(time * 3.7 + phase * 1.7) * 0.5
        return CGFloat(0.55 + 0.4 * wave)
    }
}
