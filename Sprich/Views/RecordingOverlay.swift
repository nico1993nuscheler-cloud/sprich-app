import SwiftUI
import AppKit

// MARK: - Overlay Window Controller

@MainActor
class RecordingOverlayController {
    static let shared = RecordingOverlayController()

    private var window: NSPanel?
    private let state = RecordingOverlayState()

    private init() {}

    func show(mode: TranscriptionMode, badge: String? = nil, displayName: String? = nil) {
        state.mode = mode
        state.phase = .recording
        state.audioLevel = 0
        state.transcribedText = nil
        state.modeBadge = badge ?? mode.defaultBadgeLetter
        state.modeDisplayName = (displayName ?? mode.displayName).uppercased()
        state.startScanner()

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
        state.stopScanner()
    }

    func showTranscribedText(_ text: String) {
        state.transcribedText = text
        state.phase = .cleaning
    }

    func dismiss() {
        state.stopScanner()
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
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 56)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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

    // Voice-driven KITT scanner — the leader position is integrated from
    // live audio level, so the scanner moves in the rhythm of your voice,
    // not a fixed clock. Near-silent → drifts slowly. Loud speech → darts.
    @Published var scannerLeader: Double = 0           // 0 ... (segmentCount - 1)
    @Published var scannerSmoothedLevel: Float = 0     // EMA of audioLevel for brightness

    private var scannerDirection: Double = 1.0
    private var scannerTimer: Timer?
    private var lastTick: CFTimeInterval = 0

    /// Max segment index the leader can reach — set by the scanner view
    /// so the state object doesn't need to know the segment count.
    var scannerMaxIndex: Double = 10.0                 // segmentCount - 1

    // Velocity tuning (segments per second)
    // AudioRecorder RMS typically sits at ~0.2–0.4 for normal speech and
    // ~0.55+ for emphasis, so we boost the input range and use a sqrt
    // curve (gentler than linear) — silence is calm, normal speech is
    // clearly kinetic, shouts whip across.
    private let idleVelocity: Double = 3.2             // always visibly moving
    private let peakVelocity: Double = 24.0            // whips across when loud
    private let levelGain: Double = 2.6                // amplify raw RMS

    func startScanner() {
        stopScanner()
        scannerLeader = 0
        scannerDirection = 1
        scannerSmoothedLevel = 0
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickScanner()
        }
        RunLoop.main.add(timer, forMode: .common)
        scannerTimer = timer
    }

    func stopScanner() {
        scannerTimer?.invalidate()
        scannerTimer = nil
    }

    private func tickScanner() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)              // clamp on hitches
        lastTick = now

        // Smooth the audio level a bit so transients don't jitter the sweep
        // but real speech rhythm (syllables, pauses) still comes through.
        let alpha: Float = 0.28
        scannerSmoothedLevel += alpha * (audioLevel - scannerSmoothedLevel)

        // Boost raw RMS into a more useful 0–1 range, then sqrt so mid-level
        // speech actually lives in the middle of the velocity range.
        let boosted = min(1.0, Double(scannerSmoothedLevel) * levelGain)
        let shaped = sqrt(boosted)
        let velocity = idleVelocity + (peakVelocity - idleVelocity) * shaped

        var pos = scannerLeader + scannerDirection * velocity * dt
        if pos >= scannerMaxIndex {
            pos = scannerMaxIndex
            scannerDirection = -1
        } else if pos <= 0 {
            pos = 0
            scannerDirection = 1
        }
        scannerLeader = pos
    }
}

// MARK: - Main View

struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState

    private let bgColor = Color(white: 0.08)
    private let borderColor = Color(white: 0.22)
    private let accentLiteral = Color(red: 0.35, green: 0.85, blue: 0.65)   // Teal-green
    private let accentFormal = Color(red: 0.55, green: 0.45, blue: 0.95)    // Indigo
    private let accentCustom = Color(red: 0.95, green: 0.65, blue: 0.35)    // Amber

    private var accent: Color {
        switch state.mode {
        case .literal: return accentLiteral
        case .formal:  return accentFormal
        case .custom:  return accentCustom
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            // Main HUD bar
            HStack(spacing: 0) {
                // Mode badge — pulsing halo driven by audio level
                Text(state.modeBadge)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(bgColor)
                    .frame(width: 24, height: 24)
                    .background(accent, in: RoundedRectangle(cornerRadius: 5))
                    .shadow(
                        color: accent.opacity(
                            state.phase == .recording
                                ? 0.3 + 0.6 * Double(state.audioLevel)
                                : 0
                        ),
                        radius: state.phase == .recording
                            ? 4 + 10 * CGFloat(state.audioLevel)
                            : 0
                    )
                    .padding(.trailing, 10)

                if state.phase == .recording {
                    // KITT-style scanner bar — color pulses with audio input
                    KITTScannerBar(state: state, color: accent)
                        .frame(width: 72, height: 26)

                    Spacer().frame(width: 10)

                    // Audio-reactive REC label
                    Text("REC")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(accent)
                        .opacity(0.55 + 0.45 * Double(state.audioLevel))
                } else {
                    // Processing spinner
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                        .scaleEffect(0.8)
                        .frame(width: 16, height: 16)

                    Spacer().frame(width: 8)

                    Text(state.phase == .processing ? "STT" : "LLM")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(accent.opacity(0.8))
                }

                Spacer()

                // Mode name
                Text(state.modeDisplayName)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(white: 0.5))
                    .tracking(1.5)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: 240)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(bgColor.opacity(0.92))
                    // Outer accent glow scales with audio level — the whole HUD "breathes" with your voice.
                    .shadow(
                        color: accent.opacity(
                            state.phase == .recording
                                ? 0.15 + 0.35 * Double(state.audioLevel)
                                : 0.15
                        ),
                        radius: state.phase == .recording
                            ? 12 + 10 * CGFloat(state.audioLevel)
                            : 12,
                        y: 2
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(borderColor.opacity(0.5), lineWidth: 0.5)
            )
            .overlay(
                // Subtle top-edge glow
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        LinearGradient(
                            colors: [accent.opacity(0.3), .clear, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )

            // Transcribed text (appears after STT)
            if let text = state.transcribedText, !text.isEmpty {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.55))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 230)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(bgColor.opacity(0.85))
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.phase == .cleaning)
        .animation(.easeOut(duration: 0.15), value: state.transcribedText)
    }

}

// MARK: - KITT Scanner Bar
// Knight-Rider-style LED sweep. A leader segment slides back and forth across
// the bar; trailing segments glow with a falling-off intensity. Audio level
// modulates brightness, segment height, glow radius, and sweep speed.

struct KITTScannerBar: View {
    @ObservedObject var state: RecordingOverlayState
    let color: Color
    private let segmentCount = 11
    private let trailWidth: Double = 3.2   // how many neighbors glow behind the leader

    var body: some View {
        let leaderPos = state.scannerLeader
        let rawLevel = CGFloat(state.scannerSmoothedLevel)
        // Mirror the velocity curve: normal speech should look mid-bright,
        // not floor-of-the-range. Boost + sqrt so ~0.3 RMS reads as ~0.88.
        let boostedLevel = min(1.0, Double(rawLevel) * 2.6)
        let shapedLevel = sqrt(boostedLevel)

        // Leader is always solidly lit. Trailing segments fall off from there.
        // Brighter floor so the bar is always visible, even in pauses.
        let audioBoost = 0.60 + shapedLevel * 0.70
        let floorBrightness = 0.22 + shapedLevel * 0.15

        HStack(spacing: 2) {
            ForEach(0..<segmentCount, id: \.self) { i in
                let dist = abs(Double(i) - leaderPos)
                let baseFalloff = max(0, 1.0 - dist / trailWidth)
                let bright = min(1.25, baseFalloff * audioBoost + floorBrightness)

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(min(1.0, bright)))
                    .frame(
                        width: 4.5,
                        height: 18 + CGFloat(bright) * 6 + CGFloat(shapedLevel) * 3
                    )
                    .shadow(
                        color: color.opacity(bright * 0.95),
                        radius: 2.5 + CGFloat(bright) * 5
                    )
            }
        }
        .onAppear {
            state.scannerMaxIndex = Double(segmentCount - 1)
        }
    }
}
