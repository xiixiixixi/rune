import AppKit
import SwiftUI

/// Rune 的生产视觉系统：黑色工作面 + 单一嵌入式流体玻璃 + 光谱细边。
///
/// 视觉效果图只定义外观；所有组件仍由真实的 AppKit / SwiftUI 控件承载。
/// 玻璃只用于工具、检查器和临时操作，不用于长文本或大面积内容。
enum RuneTheme {
    // MARK: - Palette

    static let workspace = Color(red: 0.020, green: 0.022, blue: 0.030)
    static let graphite = Color(red: 0.045, green: 0.050, blue: 0.064)
    static let graphiteRaised = Color(red: 0.066, green: 0.072, blue: 0.090)
    static let glassTint = Color(red: 0.075, green: 0.085, blue: 0.115)

    static let textPrimary = Color(red: 0.945, green: 0.940, blue: 0.955)
    static let textSecondary = Color(red: 0.650, green: 0.635, blue: 0.680)
    static let textMuted = Color(red: 0.420, green: 0.410, blue: 0.455)
    static let separator = Color.white.opacity(0.085)

    static let cyan = Color(red: 0.23, green: 0.78, blue: 0.96)
    static let aubergine = Color(red: 0.46, green: 0.22, blue: 0.77)
    static let magenta = Color(red: 0.92, green: 0.26, blue: 0.64)
    static let amber = Color(red: 0.98, green: 0.54, blue: 0.31)
    static let signal = Color(red: 0.94, green: 0.24, blue: 0.30)

    static let spectralGradient = LinearGradient(
        colors: [cyan, aubergine, magenta, amber],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let accent = aubergine
    static let accentFill = aubergine
    static let accentPressed = aubergine.opacity(0.82)
    static let accentDim = aubergine.opacity(0.14)
    static let primaryFill = graphiteRaised
    static let primaryOnFill = textPrimary
    static let annotationAccent = magenta
    static let ink = textPrimary
    static let background = workspace
    static let card = graphiteRaised

    static let nsBackground = NSColor(calibratedRed: 0.020, green: 0.022, blue: 0.030, alpha: 1)
    static let nsAccent = NSColor(calibratedRed: 0.46, green: 0.22, blue: 0.77, alpha: 1)
    static let nsCyan = NSColor(calibratedRed: 0.23, green: 0.78, blue: 0.96, alpha: 1)
    static let nsMagenta = NSColor(calibratedRed: 0.92, green: 0.26, blue: 0.64, alpha: 1)
    static let nsAmber = NSColor(calibratedRed: 0.98, green: 0.54, blue: 0.31, alpha: 1)
    static let nsSignal = NSColor(calibratedRed: 0.94, green: 0.24, blue: 0.30, alpha: 1)

    // Historical names retained so existing functional views do not need to fork their logic.
    static let paperBackground = workspace
    static let paperCard = graphiteRaised
    static let paperInk = textPrimary
    static let paperTextSecondary = textSecondary
    static let paperTextMuted = textMuted
    static let paperSeparator = separator
    static let paperControl = graphiteRaised
    static let paperAccent = aubergine
    static let editorWorkspace = workspace
    static let nsPaperBackground = nsBackground
    static let nsPaperAccent = nsAccent

    static let chromeBase = Color(red: 0.030, green: 0.033, blue: 0.044)
    static let chromeElevated = Color(red: 0.070, green: 0.075, blue: 0.095)
    static let chromeLine = Color.white.opacity(0.10)
    static let chromeText = textPrimary
    static let chromeMuted = textSecondary
    static let chromeBlue = cyan
    static let chromeBlueFill = aubergine

    // MARK: - Geometry

    static let chipCorner: CGFloat = 5
    static let buttonCorner: CGFloat = 6
    static let plateCorner: CGFloat = 8
    static let cardCorner: CGFloat = 8
    static let barCorner: CGFloat = 8
    static let barHeight: CGFloat = 58
    static let iconButtonSize: CGFloat = 38

    // MARK: - Shared components

    static var barBackground: some View {
        RuneGlassBackground(cornerRadius: barCorner, elevation: .floating)
    }

    static func primaryButtonLabel(_ text: String, systemImage: String? = nil) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(RuneFont.swiftUI(size: 12.5, weight: .semibold))
        .foregroundStyle(textPrimary)
        .padding(.horizontal, 15)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                .fill(graphiteRaised.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7)
        )
        .overlay(
            RuneSpectralBorder(cornerRadius: buttonCorner, lineWidth: 0.65)
                .opacity(0.58)
        )
    }

    static func secondaryButtonLabel(_ text: String, systemImage: String? = nil) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(RuneFont.swiftUI(size: 12.5, weight: .medium))
        .foregroundStyle(textSecondary)
        .padding(.horizontal, 13)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                .fill(graphiteRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                .strokeBorder(separator, lineWidth: 1)
        )
    }

    static func compactButtonLabel(
        _ text: String,
        systemImage: String? = nil,
        emphasized: Bool = false,
        destructive: Bool = false
    ) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
        .foregroundStyle(
            destructive
                ? signal
                : (emphasized ? textPrimary : textSecondary)
        )
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                .fill(graphiteRaised.opacity(emphasized ? 0.96 : 0.82))
        )
        .overlay {
            if emphasized {
                RuneSpectralBorder(cornerRadius: buttonCorner, lineWidth: 0.65)
                    .opacity(0.58)
            } else {
                RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                    .strokeBorder(
                        destructive ? signal.opacity(0.34) : separator,
                        lineWidth: 0.7
                    )
            }
        }
    }

    static func toolIcon(_ systemImage: String, active: Bool) -> some View {
        RuneGlyph(systemImage: systemImage, isActive: active)
            .frame(width: iconButtonSize, height: iconButtonSize)
    }

    static var hairline: some View {
        Rectangle().fill(separator).frame(height: 1)
    }

    static var verticalHairline: some View {
        Rectangle().fill(separator).frame(width: 1)
    }

    struct RunePressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .opacity(configuration.isPressed ? 0.72 : 1)
        }
    }

    static func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(RuneFont.mono(size: 9.5, weight: .medium))
            .foregroundStyle(textMuted)
            .monospacedDigit()
    }

    static var cardBackground: some View {
        RuneCardBackground()
    }

    static func proofCardBackground(showingCropMarks: Bool = false) -> some View {
        cardBackground
    }

    static func stampLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(RuneFont.mono(size: 9.5, weight: .medium))
            .foregroundStyle(textMuted)
    }

    static func whitePillSelected<Content: View>(
        selected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .foregroundStyle(selected ? textPrimary : textSecondary)
            .overlay(alignment: .bottom) {
                if selected {
                    RuneSelectionUnderline(width: 28)
                        .offset(y: 2)
                }
            }
    }
}

// MARK: - Brand and icon language

struct RuneBrandIcon: View {
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: NSImage(named: "RuneEggplant") ?? NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct RuneGlyph: View {
    let systemImage: String
    var isActive = false
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: systemImage)
            .font(RuneFont.swiftUI(size: size, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(isActive ? RuneTheme.textPrimary : RuneTheme.textSecondary)
            .overlay(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(isActive ? AnyShapeStyle(RuneTheme.spectralGradient) : AnyShapeStyle(RuneTheme.textMuted))
                    .frame(width: 4.5, height: 1)
                    .rotationEffect(.degrees(-22))
                    .offset(x: 3, y: -2)
            }
    }
}

struct RuneSelectionUnderline: View {
    var width: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(RuneTheme.spectralGradient)
            .frame(width: width, height: 2)
    }
}

/// The small, persistent glass object that travels between mutually exclusive
/// controls. The content stays put; only this compositor-backed surface moves.
/// This keeps the liquid treatment meaningful instead of turning every button
/// into a separate glass card.
enum RuneSelectionAxis: Equatable {
    case horizontal
    case vertical
}

struct RuneLiquidSelectionPlate: View {
    var cornerRadius: CGFloat = RuneTheme.buttonCorner
    var axis: RuneSelectionAxis = .horizontal

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSettled = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if reduceTransparency {
                shape.fill(RuneTheme.graphiteRaised)
            } else if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(
                        Glass.regular.tint(RuneTheme.glassTint).interactive(),
                        in: shape
                    )
            } else {
                shape.fill(.ultraThinMaterial)
            }

            shape.fill(Color.white.opacity(reduceTransparency ? 0.045 : 0.065))
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.17), lineWidth: 0.7))
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color.white.opacity(reduceTransparency ? 0.08 : 0.22))
                .frame(height: 0.7)
                .padding(.horizontal, 9)
                .padding(.top, 1)
        }
        .overlay(alignment: .bottom) {
            RuneSelectionUnderline(width: 20)
                .opacity(reduceTransparency ? 0 : 0.72)
        }
        .shadow(color: .black.opacity(0.24), radius: 6, y: 2)
        .scaleEffect(
            x: reduceMotion || isSettled ? 1 : (axis == .horizontal ? 1.08 : 0.97),
            y: reduceMotion || isSettled ? 1 : (axis == .vertical ? 1.08 : 0.97)
        )
        .opacity(reduceMotion || isSettled ? 1 : 0.94)
        .onAppear {
            guard !reduceMotion else {
                isSettled = true
                return
            }
            withAnimation(RuneSelectionMotion.animation) {
                isSettled = true
            }
        }
        .accessibilityHidden(true)
    }
}

enum RuneSelectionMotion {
    static let duration = 0.18
    static let animation = Animation.easeOut(duration: duration)
}

struct RuneSpectralBorder: View {
    let cornerRadius: CGFloat
    var lineWidth: CGFloat = 1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(RuneTheme.spectralGradient, lineWidth: lineWidth)
    }
}

/// A restrained icon container for transient tools and status surfaces. The
/// glyph stays neutral; the active state is carried by a thin refractive rim.
struct RuneOpticalIconPlate: View {
    let systemImage: String
    var isActive = true
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                .fill(RuneTheme.graphiteRaised.opacity(0.92))

            if isActive {
                RuneSpectralBorder(
                    cornerRadius: RuneTheme.buttonCorner,
                    lineWidth: 0.7
                )
                .opacity(0.62)
            } else {
                RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                    .strokeBorder(RuneTheme.separator, lineWidth: 0.7)
            }

            RuneGlyph(systemImage: systemImage, isActive: isActive, size: size * 0.46)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Shared selection marker for galleries and compact saved-state feedback.
/// It avoids the old solid-purple check circle while remaining obvious on
/// photographic content.
struct RuneSelectionMark: View {
    let isSelected: Bool
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            if isSelected {
                RuneOpticalLens(size: size - 3, spectralOpacity: 0.95, showsCaustic: true)
                Image(systemName: "checkmark")
                    .font(RuneFont.swiftUI(size: size * 0.46, weight: .bold))
                    .foregroundStyle(RuneTheme.textPrimary)
            } else {
                Circle()
                    .fill(RuneTheme.graphite.opacity(0.52))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.88), lineWidth: 1.2))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.34), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

/// Compact segmented selection for inspector tabs. The selected segment is a
/// neutral optical inset with a refractive underline, never a solid accent block.
struct RuneOpticalSegmentedPicker<Selection: Hashable>: View {
    let options: [(value: Selection, label: String)]
    @Binding var selection: Selection
    var accessibilityLabel: String
    var animatesSelection = false

    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plateSelection: Selection?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.value == selection
                let showsSelectionPlate = option.value == (plateSelection ?? selection)

                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(RuneFont.swiftUI(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? RuneTheme.textPrimary : RuneTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            if animatesSelection {
                                if showsSelectionPlate {
                                    RuneLiquidSelectionPlate(cornerRadius: 5)
                                        .matchedGeometryEffect(
                                            id: "rune-optical-segment-selection",
                                            in: selectionNamespace
                                        )
                                }
                            } else if isSelected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.white.opacity(0.060))
                                    .overlay(alignment: .bottom) {
                                        RuneSelectionUnderline(width: 22)
                                            .offset(y: 1)
                                    }
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(accessibilityLabel)，\(option.label)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(RuneTheme.graphite.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7)
        )
        .onAppear {
            plateSelection = selection
        }
        .onChange(of: selection) { _, newSelection in
            if animatesSelection && !reduceMotion {
                withAnimation(RuneSelectionMotion.animation) {
                    plateSelection = newSelection
                }
            } else {
                plateSelection = newSelection
            }
        }
    }
}

// MARK: - Spectral glass controls

/// Rune's shared switch treatment. Interaction remains a native SwiftUI
/// `Toggle`; this style only replaces its visual presentation.
struct RuneGlassToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RuneGlassSwitchTrack(isOn: configuration.isOn)
                .contentShape(Rectangle())
        }
        .buttonStyle(RuneGlassControlPressStyle())
        .accessibilityValue(configuration.isOn ? "开启" : "关闭")
    }
}

extension ToggleStyle where Self == RuneGlassToggleStyle {
    static var runeGlass: RuneGlassToggleStyle { RuneGlassToggleStyle() }
}

private struct RuneGlassSwitchTrack: View {
    let isOn: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let track = RoundedRectangle(cornerRadius: 7, style: .continuous)

        ZStack {
            Group {
                if reduceTransparency {
                    track.fill(RuneTheme.graphiteRaised)
                } else {
                    track.fill(.ultraThinMaterial)
                }
            }

            // the moving optical lens, not to a decorative filled switch.
            track.fill(Color.black.opacity(0.18))
            track.strokeBorder(Color.white.opacity(isOn ? 0.18 : 0.13), lineWidth: 0.7)

            RuneOpticalLens(
                size: 16,
                spectralOpacity: isOn ? 0.95 : 0.28,
                showsCaustic: isOn
            )
                .offset(x: isOn ? 9 : -9)
        }
        .frame(width: 38, height: 20)
        .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct RuneGlassControlPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}

/// A native `Slider` remains in the hierarchy for pointer, keyboard, focus and
/// accessibility behavior. The overlay provides Rune's spectral liquid-glass
/// rendering without reimplementing the control's interaction model.
struct RuneGlassSlider<Value>: View where Value: BinaryFloatingPoint, Value.Stride: BinaryFloatingPoint {
    @Binding private var value: Value

    private let bounds: ClosedRange<Value>
    private let step: Value.Stride?
    private let accessibilityLabel: String
    private let accessibilityValue: String?
    private let onEditingChanged: (Bool) -> Void

    @FocusState private var isFocused: Bool

    init(
        value: Binding<Value>,
        in bounds: ClosedRange<Value>,
        step: Value.Stride? = nil,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        self.bounds = bounds
        self.step = step
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        ZStack {
            nativeSlider
                .labelsHidden()
                .opacity(0.001)
                .focused($isFocused)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(accessibilityValue ?? defaultAccessibilityValue)

            RuneGlassSliderVisual(
                fraction: fraction,
                isFocused: isFocused
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(minWidth: 62, minHeight: 20)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var nativeSlider: some View {
        if let step {
            Slider(
                value: $value,
                in: bounds,
                step: step,
                onEditingChanged: onEditingChanged
            )
        } else {
            Slider(
                value: $value,
                in: bounds,
                onEditingChanged: onEditingChanged
            )
        }
    }

    private var fraction: CGFloat {
        let lower = Double(bounds.lowerBound)
        let upper = Double(bounds.upperBound)
        guard upper > lower else { return 0 }
        return CGFloat(min(max((Double(value) - lower) / (upper - lower), 0), 1))
    }

    private var defaultAccessibilityValue: String {
        "\(Int(fraction * 100))%"
    }
}

private struct RuneGlassSliderVisual: View {
    let fraction: CGFloat
    let isFocused: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { proxy in
            let knobSize: CGFloat = 16
            let trackHeight: CGFloat = 2
            let usableWidth = max(0, proxy.size.width - knobSize)
            let knobX = knobSize / 2 + usableWidth * fraction
            let track = Capsule()

            ZStack(alignment: .leading) {
                track
                    .fill(reduceTransparency ? RuneTheme.graphiteRaised : Color.white.opacity(0.105))
                .frame(height: trackHeight)
                .overlay(track.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))

                // A short caustic is optically tied to the lens. There is no
                // coloured progress fill running across the control.
                Capsule()
                    .fill(RuneTheme.spectralGradient)
                    .opacity(reduceTransparency ? 0 : 0.20)
                    .frame(width: 22, height: 1)
                    .position(x: knobX, y: proxy.size.height / 2 + 1)

                RuneOpticalLens(
                    size: knobSize,
                    spectralOpacity: 0.82,
                    showsCaustic: true
                )
                    .position(x: knobX, y: proxy.size.height / 2)

                if isFocused {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(RuneTheme.textPrimary.opacity(0.36), lineWidth: 0.7)
                        .frame(height: 20)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .opacity(isEnabled ? 1 : 0.42)
    }
}

/// The single optical object used by Rune's sliders and switches. Its colour
/// is confined to the refractive rim and the tiny contact caustic.
private struct RuneOpticalLens: View {
    let size: CGFloat
    let spectralOpacity: Double
    let showsCaustic: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if showsCaustic && !reduceTransparency {
                Circle()
                    .fill(RuneTheme.spectralGradient)
                    .frame(width: size + 3, height: size + 3)
                    .opacity(0.18)
            }

            Circle()
                .fill(
                    reduceTransparency
                        ? AnyShapeStyle(RuneTheme.graphiteRaised)
                        : AnyShapeStyle(.regularMaterial)
                )
                .overlay(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.20), Color.black.opacity(0.16)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.38), lineWidth: 0.55))
                .overlay(
                    Circle()
                        .strokeBorder(RuneTheme.spectralGradient, lineWidth: 0.7)
                        .opacity(reduceTransparency ? 0 : spectralOpacity)
                )
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(Color.white.opacity(0.72))
                        .frame(width: 2.2, height: 2.2)
                        .padding(size * 0.23)
                }
                .shadow(color: .black.opacity(0.34), radius: 2, y: 1)
        }
        .frame(width: size + 3, height: size + 3)
    }
}

// MARK: - Opaque reading surface

struct RuneCardBackground: View {
    var cornerRadius: CGFloat = RuneTheme.cardCorner

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(RuneTheme.graphite.opacity(0.96))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(RuneTheme.separator, lineWidth: 1)
            )
    }
}

// MARK: - Workspace surfaces

struct RuneAmbientBackdrop: View {
    var body: some View {
        ZStack {
            RuneTheme.workspace
            LinearGradient(
                colors: [Color.white.opacity(0.018), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

/// Compatibility layer for screens that previously rendered full-canvas glows.
/// The new system keeps refraction contained to the instrument side of the view.
struct YumYumGlow: View {
    var body: some View {
        HStack(spacing: 0) {
            Color.clear
            LinearGradient(
                colors: [.clear, RuneTheme.aubergine.opacity(0.045), RuneTheme.magenta.opacity(0.025)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(maxWidth: 280)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Historical call sites use this for elapsed-time readouts. It now renders a
/// crisp monospaced value instead of decorative dots.
struct DotMatrixText: View {
    let text: String
    var dotSize: CGFloat = 3
    var dotSpacing: CGFloat = 1.8
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(RuneFont.mono(size: max(10, dotSize * 3.5), weight: .medium))
            .foregroundStyle(color)
            .monospacedDigit()
            .accessibilityLabel(text)
    }
}

// MARK: - Glass surface

enum RuneGlassElevation {
    case embedded
    case floating

    var shadowOpacity: Double { self == .floating ? 0.28 : 0.08 }
    var shadowRadius: CGFloat { self == .floating ? 18 : 8 }
    var shadowY: CGFloat { self == .floating ? 9 : 3 }
}

struct RuneGlassBackground: View {
    let cornerRadius: CGFloat
    var tint: Color? = nil
    var interactive = false
    var elevation: RuneGlassElevation = .embedded

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if reduceTransparency {
                shape.fill(RuneTheme.graphiteRaised)
            } else if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(
                        Glass.regular.tint(tint ?? RuneTheme.glassTint).interactive(interactive),
                        in: shape
                    )
            } else {
                shape.fill(.ultraThinMaterial)
            }

            shape.fill(RuneTheme.glassTint.opacity(reduceTransparency ? 0.92 : 0.30))
        }
        .overlay(RuneSpectralBorder(cornerRadius: cornerRadius, lineWidth: 0.7).opacity(0.48))
        .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        .shadow(
            color: .black.opacity(elevation.shadowOpacity),
            radius: elevation.shadowRadius,
            y: elevation.shadowY
        )
    }
}

/// Shared right-side glass stage used by settings, library details, and other
/// inspector-style surfaces. The content remains functional SwiftUI; only the
/// material and spatial treatment are shared.
struct RuneGlassStage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        ZStack {
            RuneGlassBackground(
                cornerRadius: 9,
                tint: RuneTheme.glassTint,
                elevation: .floating
            )

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.40))

            // A restrained internal tint makes the pane feel inserted into the
            // shell while leaving the reading surface neutral.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RuneTheme.cyan.opacity(0.035),
                            Color.clear,
                            RuneTheme.aubergine.opacity(0.025),
                            RuneTheme.amber.opacity(0.025)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(nsImage: NSImage(named: "RuneEggplant") ?? NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .saturation(0)
                .opacity(0.025)
                .rotationEffect(.degrees(-20))
                .frame(width: 220, height: 220)
                .offset(x: 58, y: 190)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(RuneFont.swiftUI(size: 15, weight: .medium))
                    .foregroundStyle(RuneTheme.textPrimary)
                Text(subtitle)
                    .font(RuneFont.swiftUI(size: 10.5))
                    .foregroundStyle(RuneTheme.textSecondary)
                    .padding(.top, 5)

                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct RuneGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    let elevation: RuneGlassElevation

    func body(content: Content) -> some View {
        content.background {
            RuneGlassBackground(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive,
                elevation: elevation
            )
        }
    }
}

extension View {
    func runeGlassSurface(
        cornerRadius: CGFloat = RuneTheme.cardCorner,
        tint: Color? = nil,
        interactive: Bool = false,
        elevation: RuneGlassElevation = .embedded
    ) -> some View {
        modifier(
            RuneGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive,
                elevation: elevation
            )
        )
    }

    func toolbarBackgroundHiddenIfAvailable() -> some View {
        self
    }
}

// MARK: - AppKit chrome

/// AppKit-only transient panels share the same neutral membrane and spectral
/// hairline as their SwiftUI counterparts.
@MainActor
enum RuneAppKitChrome {
    private static let spectralLayerName = "RuneSpectralBorder"

    static func installSpectralBorder(
        on view: NSView,
        cornerRadius: CGFloat,
        opacity: Float = 0.58,
        lineWidth: CGFloat = 0.8
    ) {
        view.wantsLayer = true
        view.layer?.sublayers?
            .filter { $0.name == spectralLayerName }
            .forEach { $0.removeFromSuperlayer() }

        let gradient = CAGradientLayer()
        gradient.name = spectralLayerName
        gradient.frame = view.bounds
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        gradient.colors = [
            RuneTheme.nsCyan.cgColor,
            RuneTheme.nsAccent.cgColor,
            RuneTheme.nsMagenta.cgColor,
            RuneTheme.nsAmber.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.opacity = opacity

        let mask = CAShapeLayer()
        mask.frame = view.bounds
        mask.path = CGPath(
            roundedRect: view.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        mask.fillColor = NSColor.clear.cgColor
        mask.strokeColor = NSColor.white.cgColor
        mask.lineWidth = lineWidth
        gradient.mask = mask
        view.layer?.addSublayer(gradient)
    }

    static func styleButton(_ button: NSButton, emphasized: Bool) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.sublayers?
            .filter { $0.name == spectralLayerName }
            .forEach { $0.removeFromSuperlayer() }
        button.layer?.cornerRadius = RuneTheme.buttonCorner
        button.layer?.backgroundColor = NSColor(RuneTheme.graphiteRaised)
            .withAlphaComponent(emphasized ? 0.96 : 0.76)
            .cgColor
        button.layer?.borderWidth = 0.7
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        if emphasized {
            installSpectralBorder(
                on: button,
                cornerRadius: RuneTheme.buttonCorner,
                opacity: 0.62,
                lineWidth: 0.7
            )
        }
    }
}
