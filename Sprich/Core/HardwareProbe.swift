import Foundation
import Darwin

/// Read-only hardware eligibility probe for the on-device LLM.
///
/// Onboarding runs the probe **before** showing the "Use local LLM" step
/// so we can give the user honest expectations. The probe checks three
/// things — chip family, physical RAM, macOS version — and returns one
/// of three tiers.
///
/// Latency expectations in `tier.latencyExpectationCopy` are sourced from
/// the same benchmark numbers as the landing-page copy, so a "~1.4 s"
/// claim on marketing matches what the app says at install time.
enum HardwareProbe {

    enum Tier: Equatable {
        /// 🟢 Apple Silicon + 16 GB+ + macOS 14+
        /// "Local mode will run great." Quality presets (2B/4B) unlock.
        case recommended

        /// 🟡 Apple Silicon + 8 GB + macOS 13+
        /// "Local mode is supported." Stay on the 1B variant; bigger
        /// models may slow things down or run out of RAM.
        case eligible(reasons: [String])

        /// 🔴 Intel Mac OR < 8 GB OR macOS < 13
        /// Local mode disabled; cloud-LLM CTA shown instead.
        case notSupported(blockers: [String])

        var supportsLocalLLM: Bool {
            switch self {
            case .recommended, .eligible: return true
            case .notSupported:           return false
            }
        }

        /// True if quality-preset upgrades (Gemma 2 2B / Gemma 3 4B) are
        /// reachable from Settings without an override-with-warning step.
        var qualityPresetsUnlocked: Bool {
            switch self {
            case .recommended: return true
            default:           return false
            }
        }

        /// Short human label for Settings + onboarding.
        var displayLabel: String {
            switch self {
            case .recommended:   return "Recommended"
            case .eligible:      return "Eligible"
            case .notSupported:  return "Not supported"
            }
        }

        /// One-line latency / quality expectation. Pulled from the
        /// 2026-05 benchmark on llama.cpp Q4_K_M, M1 Pro 16 GB.
        /// Update both this string AND `benchmarks/2026-05-local-llm.md`
        /// when M1 8 GB re-measurement lands.
        var latencyExpectationCopy: String {
            switch self {
            case .recommended:
                return "Expected response time: ~1.4 s. Quality preset upgrades available in Settings."
            case .eligible:
                return "Expected response time: ~2 s. We recommend staying with the default Gemma 1B model; bigger models may slow things down or run out of RAM."
            case .notSupported:
                return "Local mode requires an Apple Silicon Mac with 8 GB+ RAM and macOS 13+. You can use Sprich with cloud LLMs instead — same dictation, your audio still never leaves your device."
            }
        }
    }

    /// Minimum macOS version Sprich supports for local LLM. Sonoma (14)
    /// is preferred but Ventura (13) is the floor — WhisperKit + llama.cpp
    /// Metal both need a recent-enough macOS for driver stability.
    static let minimumMacOSVersion = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)

    /// Bumped tier requires Sonoma+ for the smoother Metal shader behaviour
    /// observed in benchmarks.
    static let recommendedMacOSVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)

    /// Run the probe synchronously. Pure read-only sysctl + ProcessInfo
    /// calls; safe to call from any thread and from SwiftUI view-update
    /// cycles.
    static func evaluate() -> Tier {
        let isAppleSilicon = Self.isAppleSilicon()
        let physicalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let os = ProcessInfo.processInfo.operatingSystemVersion

        var blockers: [String] = []
        if !isAppleSilicon {
            blockers.append("Intel Macs are not supported for local mode — Apple Silicon required.")
        }
        if physicalMemoryGB < 7.5 {  // sysctl reports slightly under 8 on actual 8GB Macs
            blockers.append("8 GB RAM required — this Mac reports \(String(format: "%.0f", physicalMemoryGB)) GB.")
        }
        if !Self.osMeets(minimum: minimumMacOSVersion) {
            blockers.append("macOS 13 or later required — this Mac runs macOS \(os.majorVersion).\(os.minorVersion).")
        }

        if !blockers.isEmpty {
            return .notSupported(blockers: blockers)
        }

        // No blockers — recommended vs eligible split.
        let hasRecommendedRAM = physicalMemoryGB >= 15.5  // 16 GB Macs report ~16.0
        let hasRecommendedOS = Self.osMeets(minimum: recommendedMacOSVersion)
        if hasRecommendedRAM && hasRecommendedOS {
            return .recommended
        }

        var reasons: [String] = []
        if !hasRecommendedRAM {
            reasons.append("8 GB RAM — eligible but quality presets (2B/4B) are gated.")
        }
        if !hasRecommendedOS {
            reasons.append("macOS \(os.majorVersion) — Sonoma (14) or later recommended.")
        }
        return .eligible(reasons: reasons)
    }

    // MARK: - Internals

    /// True on M1 / M2 / M3 / M4 / Apple-Silicon-class hardware.
    /// False on Intel Macs (and on the rare iOS simulator scenarios that
    /// will never run Sprich, but we're defensive).
    static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        if result == 0 {
            return value == 1
        }
        // Fallback: machine arch string. `arm64` on Apple Silicon, `x86_64`
        // on Intel. If sysctl somehow failed, this is the same signal
        // through a different surface.
        var sysinfo = utsname()
        guard uname(&sysinfo) == 0 else { return false }
        let machine = withUnsafePointer(to: &sysinfo.machine) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return machine.hasPrefix("arm64")
    }

    private static func osMeets(minimum: OperatingSystemVersion) -> Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(minimum)
    }
}
