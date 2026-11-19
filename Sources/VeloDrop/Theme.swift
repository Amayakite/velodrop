import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeloCore

/// Shared visual language for VeloDrop. The accent is intentionally fixed rather
/// than following the system accent so the app keeps a recognizable identity.
enum VD {
    static let accent = Color(red: 0.212, green: 0.463, blue: 0.945)
    static let accentBright = Color(red: 0.376, green: 0.639, blue: 1.0)
    static let green = Color(red: 0.141, green: 0.651, blue: 0.404)
    static let orange = Color(red: 0.937, green: 0.569, blue: 0.129)
    static let red = Color(red: 0.878, green: 0.290, blue: 0.290)
    static let purple = Color(red: 0.529, green: 0.396, blue: 0.949)
    static let teal = Color(red: 0.114, green: 0.620, blue: 0.647)
    static let pink = Color(red: 0.878, green: 0.357, blue: 0.612)

    static var card: Color { Color(nsColor: .controlBackgroundColor) }
    static var sidebar: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor(calibratedWhite: 0.105, alpha: 1)
                        : NSColor(calibratedWhite: 0.958, alpha: 1)
        })
    }
    static var hairline: Color { Color(nsColor: .separatorColor).opacity(0.55) }
    static var subtleFill: Color { Color.primary.opacity(0.045) }
    static var rowHover: Color { Color.primary.opacity(0.032) }

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentBright, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func cardShadow(_ content: some View) -> some View {
        content.shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
    }
}

extension TransferState {
    var tint: Color {
        switch self {
        case .downloading: VD.accent
        case .queued: Color.secondary
        case .awaitingConfirmation: VD.purple
        case .paused: VD.orange
        case .completed: VD.green
        case .failed: VD.red
        case .canceled: Color.secondary
        case .handedToBrowser: VD.teal
        }
    }

    var badgeSymbol: String? {
        switch self {
        case .downloading: "arrow.down"
        case .queued: "clock"
        case .awaitingConfirmation: "questionmark"
        case .paused: "pause.fill"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .canceled: "xmark"
        case .handedToBrowser: "arrowshape.turn.up.right"
        }
    }

    var shortStatusKey: LocalizedStringKey {
        switch self {
        case .downloading: "Downloading"
        case .queued: "Queued"
        case .awaitingConfirmation: "Confirm"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .canceled: "Canceled"
        case .handedToBrowser: "In Edge"
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(VD.accentGradient)
            Image(systemName: "arrow.down")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(.white)
                .offset(y: -size * 0.01)
        }
        .frame(width: size, height: size)
        .shadow(color: VD.accent.opacity(0.32), radius: size * 0.18, x: 0, y: size * 0.07)
        .accessibilityHidden(true)
    }
}

struct FileIconTile: View {
    let transfer: Transfer
    var size: CGFloat = 40

    private var type: UTType? {
        UTType(filenameExtension: (transfer.displayName as NSString).pathExtension)
    }

    private var tint: Color {
        guard let type else { return VD.accent }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return VD.purple }
        if type.conforms(to: .pdf) { return VD.red }
        if type.conforms(to: .image) { return VD.pink }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return VD.accent }
        if type.conforms(to: .audio) { return VD.orange }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return VD.teal }
        return VD.accent
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .strokeBorder(tint.opacity(0.14), lineWidth: 0.8)
                )
                .frame(width: size, height: size)
                .overlay {
                    Image(nsImage: NSWorkspace.shared.icon(for: type ?? .data))
                        .resizable()
                        .frame(width: size * 0.60, height: size * 0.60)
                }
            if let symbol = transfer.state.badgeSymbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.185, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.37, height: size * 0.37)
                    .background(transfer.state.tint, in: Circle())
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: size * 0.05))
                    .offset(x: size * 0.04, y: size * 0.04)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let state: TransferState
    let text: LocalizedStringKey
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.tint)
                .frame(width: compact ? 4 : 5, height: compact ? 4 : 5)
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: compact ? 10 : 10.5, weight: .semibold))
        .foregroundStyle(state.tint)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, compact ? 2.5 : 3)
        .background(state.tint.opacity(0.11), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct VDProgressBar: View {
    var fraction: Double?
    var tint: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.075))
                if let fraction {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.72), tint],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geometry.size.width * min(max(fraction, 0), 1)))
                } else {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.35))
                        .frame(width: geometry.size.width * 0.22)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(VD.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(VD.hairline.opacity(0.55), lineWidth: 0.7)
        )
    }
}

struct SectionEyebrow: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct VDPrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 26 : 30)
            .background(VD.accentGradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: VD.accent.opacity(configuration.isPressed ? 0.15 : 0.28),
                    radius: configuration.isPressed ? 2 : 5, x: 0, y: 2)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct VDSecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 10 : 13)
            .frame(height: compact ? 26 : 30)
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.055),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(VD.hairline, lineWidth: 0.8)
            )
    }
}

struct VDDangerButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(VD.red)
            .padding(.horizontal, compact ? 10 : 13)
            .frame(height: compact ? 26 : 30)
            .background(VD.red.opacity(configuration.isPressed ? 0.14 : 0.075),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(VD.red.opacity(0.22), lineWidth: 0.8)
            )
    }
}

struct VDDestructiveButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 26 : 30)
            .background(
                LinearGradient(colors: [VD.red.opacity(0.92), VD.red],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .shadow(color: VD.red.opacity(configuration.isPressed ? 0.12 : 0.24),
                    radius: configuration.isPressed ? 2 : 5, x: 0, y: 2)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct VDIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var tint: Color = .primary
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(hovering ? Color.primary.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

struct SpeedSparkline: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let peak = max(samples.max() ?? 0, 1)
            var line = Path()
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for (index, sample) in samples.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(samples.count - 1)
                let normalized = CGFloat(sample / peak)
                let y = size.height - (size.height - 2) * normalized
                if index == 0 { line.move(to: CGPoint(x: x, y: y)) }
                else { line.addLine(to: CGPoint(x: x, y: y)) }
                area.addLine(to: CGPoint(x: x, y: y))
                if index == samples.count - 1 {
                    area.addLine(to: CGPoint(x: x, y: size.height))
                    area.closeSubpath()
                }
            }
            context.fill(area, with: .linearGradient(
                Gradient(colors: [VD.accent.opacity(0.22), VD.accent.opacity(0.01)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(VD.accent.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 74, height: 18)
        .accessibilityHidden(true)
    }
}

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 9)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = context.coordinator
        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

extension View {
    func vdCard(radius: CGFloat = 12, fill: Color = VD.card, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(VD.hairline, lineWidth: 0.8)
            )
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func rate(_ value: Int64) -> String {
        value > 0 ? bytes(value) + "/s" : "0 KB/s"
    }

    static var appLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    static func when(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = appLocale
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    static func compactRate(_ value: Int64) -> String {
        guard value > 0 else { return "0" }
        let megabytes = Double(value) / 1_000_000
        if megabytes >= 100 { return String(format: "%.0f MB/s", megabytes) }
        if megabytes >= 10 { return String(format: "%.1f MB/s", megabytes) }
        return String(format: "%.2f MB/s", megabytes)
    }
}
