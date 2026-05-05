import Foundation
import IOKit
import CryptoKit

/// Stable per-Mac fingerprint for trial-abuse hardening.
///
/// Source: `IOPlatformUUID` from `IOPlatformExpertDevice` — the same
/// identifier `system_profiler` uses. Stable across reinstalls and OS
/// upgrades; resets only on logic-board replacement or a `nvram -c` wipe.
///
/// We hash the raw UUID with SHA-256 before sending. The server only ever
/// stores the hash, so the raw hardware identifier never leaves the
/// device — important for the Datenschutz claim that we don't process raw
/// hardware identifiers, only an irreversible derivative.
enum DeviceFingerprint {
    /// SHA-256 hex digest of the Mac's IOPlatformUUID, prefixed with
    /// `sprich-fp-v1:` so we can rotate the derivation later without
    /// colliding with already-stored hashes. 64 hex chars + prefix.
    static func currentHash() -> String? {
        guard let uuid = readPlatformUUID() else { return nil }
        let salted = "sprich-fp-v1:" + uuid
        let digest = SHA256.hash(data: Data(salted.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func readPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let cf = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        return (cf.takeRetainedValue() as? String)
    }
}
