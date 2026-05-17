import SwiftUI
import AppKit

// MARK: - Overlay Window Controller

@MainActor
class RecordingOverlayController {
    static let shared = RecordingOverlayController()

    private var window: NSPanel?
    private let state = RecordingOverlayState()

    // Pill dimensions match the landing HUD's compact-mode rendering.
    // Width is intrinsic in SwiftUI; we host the SwiftUI view in a panel
    // sized generously and let the Capsule shrink to fit content.
    private let panelWidth: CGFloat = 460
    private let panelHeight: CGFloat = 130

    private init() {}

    func show(mode: TranscriptionMode, badge: String? = nil, displayName: String? = nil) {
        state.mode = mode
        state.phase = .recording
        state.audioLevel = 0
        state.transcribedText = nil
        state.modeBadge = badge ?? mode.defaultBadgeLetter
        state.modeDisplayName = (displayName ?? mode.displayName).uppercased()
        state.startWaveformClock()

        if window == nil {
            createWindow()
        }

        positionWindow()
        window?.alphaValue = 0
        window?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.window?.animator().alphaValue = 1
        }
    }

    func updateAudioLevel(_ level: Float) {
        state.audioLevel = level
    }

    func showProcessing() {
        state.phase = .processing
        state.stopWaveformClock()
    }

    func showTranscribedText(_ text: String) {
        state.transcribedText = text
        state.phase = .cleaning
    }

    func dismiss() {
        state.stopWaveformClock()
        let win = window
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            win?.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                win?.orderOut(nil)
            }
        })
    }

    private func createWindow() {
        let hostingView = NSHostingView(rootView: RecordingOverlayView(state: state))
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // shadow rendered in SwiftUI for design control
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = hostingView
        panel.hidesOnDeactivate = false
        self.window = panel
    }

    private func positionWindow() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let window = window else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - window.frame.width / 2
        let y = screenFrame.minY + 60
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - State

class RecordingOverlayState: ObservableObject {
    enum Phase { case recording, processing, cleaning }

    @Published var phase: Phase = .recording
    @Published var mode: TranscriptionMode = .literal
    @Published var audioLevel: Float = 0
    @Published var transcribedText: String?
    @Published var modeBadge: String = "L"
    @Published var modeDisplayName: String = "LITERAL"

    /// Continuously-incrementing clock the waveform reads. Time-driven so bars
    /// have a voice-shaped baseline animation even during silent moments;
    /// audio level then scales their amplitude. Matches `useRaf` in landing's
    /// `hud.jsx#LiveWaveform` (dt * 6 increment).
    @Published var waveformClock: Double = 0
    @Published var smoothedLevel: Float = 0     // EMA of audioLevel for steady amplitude

    private var clockTimer: Timer?
    private var lastTick: CFTimeInterval = 0

    func startWaveformClock() {
        stopWaveformClock()
        waveformClock = 0
        smoothedLevel = 0
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickWaveform()
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    func stopWaveformClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func tickWaveform() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now

        // Match landing hud.jsx: t += dt * 6 — gives the right perceptual cadence
        // for the composite-sine-wave bars below.
        waveformClock += dt * 6.0

        // Smooth audio level so transients don't make the waveform jitter,
        // but real speech rhythm still comes through.
        let alpha: Float = 0.28
        smoothedLevel += alpha * (audioLevel - smoothedLevel)
    }
}

// MARK: - Main View
//
// 1:1 port of the landing HUD pill (`project/shared/hud.jsx#LiveHUD`):
//
//   ┌──────────────────────────────────────────────────────────────────┐
//   │ [S logo]  [───  bar waveform  ───]  │  [● LITERAL]                │  ← cream pill
//   └──────────────────────────────────────────────────────────────────┘
//                                      ▲
//                                      └ vertical hairline divider
//
// Spacing tokens carry directly from hud.jsx's compact-mode (gap:12, padding:10×16):
//   - Outer pill: cream bg, 1px border, full radius, 24/2-radius drop shadow
//   - S logo: 28×28 forest rounded square with cream "S"
//   - Waveform: 28 mode-colored bars
//   - Divider: 1×22 border-color hairline
//   - Mode sub-pill: mode-color bg, ink text + ink dot, 6×14 padding, full radius

struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    @ObservedObject private var networkIndicator = NetworkStatusIndicator.shared

    private var accent: Color { state.mode.accentColor }

    var body: some View {
        VStack(spacing: 8) {
            // Main HUD pill — matches LiveHUD compact rendering
            HStack(spacing: 12) {
                SprichAppIcon()
                    .frame(width: 28, height: 28)

                BarWaveform(state: state, color: accent)
                    .frame(width: 132, height: 32)

                // Vertical hairline divider — exact match to hud.jsx line 133/140
                Rectangle()
                    .fill(Color.sprichBorder)
                    .frame(width: 1, height: 22)

                ModeBadge(state: state, accent: accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.sprichCream)
                    .shadow(color: Color.sprichInk.opacity(0.12), radius: 24, x: 0, y: 8)
                    .shadow(color: Color.sprichInk.opacity(0.05), radius: 2, x: 0, y: 1)
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.sprichBorder, lineWidth: 1)
            )
            .fixedSize()  // shrink Capsule to intrinsic content width

            // Network-status chip — Sprint 2F P2-LLM-14. Tells the user, in
            // real time, whether THIS dictation will touch the network.
            // 🟢 Offline = both STT + LLM are local; 🟡 = at least one leg
            // uses the cloud. Spec: `network-off-proof-ui-spec.md` Surface 1.
            networkStatusChip
                .transition(.opacity)

            // Transcribed text bubble (appears after STT, before LLM cleanup)
            if let text = state.transcribedText, !text.isEmpty {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.sprichInk2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.sprichCreamAlt)
                            .shadow(color: Color.sprichInk.opacity(0.08), radius: 8, x: 0, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.sprichBorder, lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.phase == .cleaning)
        .animation(.easeOut(duration: 0.15), value: state.transcribedText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Small pill that names the configured network state for this
    /// dictation. Green = 🟢 Offline; amber = 🟡 + provider name; ⚪ for the
    /// brief license-heartbeat window. Honest by construction: derives
    /// directly from `NetworkStatusIndicator.shared.route`.
    @ViewBuilder
    private var networkStatusChip: some View {
        HStack(spacing: 6) {
            Text(networkIndicator.route.glyph)
                .font(.system(size: 11))
            Text(networkIndicator.route.shortLabel)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(networkChipTextColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(networkChipBackground)
        )
        .overlay(
            Capsule()
                .strokeBorder(networkChipBorder, lineWidth: 0.5)
        )
    }

    private var networkChipBackground: Color {
        switch networkIndicator.route {
        case .offline:           return Color.green.opacity(0.12)
        case .licenseHeartbeat:  return Color.secondary.opacity(0.10)
        default:                 return Color.orange.opacity(0.12)
        }
    }

    private var networkChipBorder: Color {
        switch networkIndicator.route {
        case .offline:           return Color.green.opacity(0.35)
        case .licenseHeartbeat:  return Color.secondary.opacity(0.25)
        default:                 return Color.orange.opacity(0.35)
        }
    }

    private var networkChipTextColor: Color {
        switch networkIndicator.route {
        case .offline:           return Color.green.opacity(0.85)
        case .licenseHeartbeat:  return Color.secondary
        default:                 return Color.orange.opacity(0.85)
        }
    }
}

// MARK: - Sprich App Icon
//
// Programmatic render of `assets/logo/app-icon-s-forest.svg` — forest rounded
// square with the cream "S" wordmark. SwiftUI shapes give us perfect Retina
// scaling without needing to ship the SVG as an asset, and it inherits any
// future ModeTokens.swift palette changes for free.

struct SprichAppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.sprichForest)
            Text("S")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundColor(Color.sprichCream)
                .offset(y: -0.5)  // optical centering for the rounded glyph
        }
    }
}

// MARK: - Mode Badge
//
// Right-side sub-pill carrying the active mode. Mode-colored bg, ink dot + text.
// During recording: ink dot. During processing/cleaning: small mode-tinted spinner.

struct ModeBadge: View {
    @ObservedObject var state: RecordingOverlayState
    let accent: Color

    /// Per-mode contrast color for content rendered on top of the mode-color
    /// capsule. Lavender (Formal) needs cream to be legible; mint and peach
    /// can keep ink. See `TranscriptionMode.accentForeground`.
    private var foreground: Color { state.mode.accentForeground }

    var body: some View {
        HStack(spacing: 8) {
            switch state.phase {
            case .recording:
                Circle()
                    .fill(foreground)
                    .frame(width: 7, height: 7)
            case .processing, .cleaning:
                ProgressView()
                    .controlSize(.mini)
                    .tint(foreground)
                    .frame(width: 7, height: 7)
            }

            Text(state.modeDisplayName)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .tracking(1.0)
                .foregroundColor(foreground)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(accent)
        )
    }
}

// MARK: - Bar Waveform
//
// Swift port of the landing's `LiveWaveform` (project/shared/hud.jsx) — 28 bars
// driven by composite sine waves so the shape feels voice-organic, not robotic.
// Heights are then scaled by smoothed audio level so loud speech visibly lifts
// the whole bank and silent stretches settle to a calm baseline.

struct BarWaveform: View {
    @ObservedObject var state: RecordingOverlayState
    let color: Color

    private let barCount = 28
    private let barWidth: CGFloat = 3
    private let barGap: CGFloat = 2
    private let cornerRadius: CGFloat = 1.5

    var body: some View {
        // Read once per render — SwiftUI repaints when @Published clock changes.
        let t = state.waveformClock
        let level = Double(state.smoothedLevel)
        // Map raw RMS (~0.1–0.5 typical) into a 0–1 amplitude range. Sqrt curve
        // so mid-level speech reads as clearly mid-bright, not floor.
        let boosted = min(1.0, level * 2.6)
        let intensity = sqrt(boosted) * 0.5 + 0.5  // 0.5 floor → bars never collapse

        HStack(spacing: barGap) {
            ForEach(0..<barCount, id: \.self) { i in
                let height = barHeight(index: i, t: t, intensity: intensity)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color)
                    .frame(width: barWidth, height: height)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// Composite sine waves — matches the landing's LiveWaveform formula 1:1.
    /// `base + mid + hi` ride atop an envelope so the whole bar bank breathes.
    private func barHeight(index i: Int, t: Double, intensity: Double) -> CGFloat {
        let base = 0.28 + 0.28 * sin(t * 0.9 + Double(i) * 0.35)
        let mid  = 0.22 * sin(t * 1.7 - Double(i) * 0.22)
        let hi   = 0.12 * sin(t * 3.3 + Double(i) * 0.6)
        let env  = 0.72 + 0.28 * sin(t * 0.33 + Double(i) * 0.1)
        let raw  = max(0.12, (base + mid + hi) * env * intensity)
        // 32pt is the container's intrinsic height; scale unit-height into pt.
        return CGFloat(min(1.0, raw)) * 32.0
    }
}
