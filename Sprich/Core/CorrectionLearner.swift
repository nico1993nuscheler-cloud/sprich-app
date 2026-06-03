import Foundation
import AppKit
import ApplicationServices

/// Auto-learn from corrections (P1-PRD-24).
///
/// After a successful dictation, `PipelineCoordinator` calls
/// `watchForCorrection(targetPid:originalText:mode:)`. For up to 30 s we
/// observe Accessibility value-change events on the target process. If
/// the user retypes the pasted text into a corrected form, we propose
/// adding `<wrong> → <typed>` to `glossaryReplacements` via a non-modal
/// banner.
///
/// Clean-room reimplementation of the algorithm in
/// OpenWhispr v1.7.1 `src/utils/correctionLearner.js` (MIT,
/// github.com/OpenWhispr/openwhispr) — algorithm referenced, no source
/// imported. Algorithm + 7 guardrails locked in
/// `~/Claude/40_Projects/Sprich/03_dev-plan.md` (P1-PRD-24).
@MainActor
final class CorrectionLearner {

    static let shared = CorrectionLearner()

    // MARK: - Tuning (locked from OW audit 2026-05-05)

    /// Time window after a dictation in which we look for corrections.
    private static let windowSeconds: TimeInterval = 30
    /// Polling cadence for the AXObserver fallback path.
    private static let pollIntervalSeconds: TimeInterval = 0.5
    /// Number of consecutive ticks the field must be unchanged before
    /// we run the diff. Prevents firing mid-keystroke ("sync" caught
    /// at "syn" gives a bogus `sync → syn` learn). 3 ticks ≈ 1.5 s of
    /// quiet — long enough that a normal typing burst won't trigger,
    /// short enough that the user gets feedback quickly after pausing.
    private static let stabilityTicksRequired = 3
    /// Max field-value size we will diff. Prevents auto-learn from
    /// scanning 10 MB documents. Locked at 10 KB.
    private static let maxOutputBytes = 10_240
    /// Edit-distance ratio threshold: a pair is allowed iff
    /// `distance / max(len) <= editDistanceRatio`.
    private static let editDistanceRatio: Double = 0.65
    /// If more than this fraction of words in the original changed,
    /// treat it as a rewrite, not a correction (privacy guard).
    private static let rewriteFraction: Double = 0.5
    /// Minimum corrected-word length to consider.
    private static let minCorrectedWordLen = 3
    /// Sliding-window match threshold for `findEditedRegion`.
    private static let regionMinOverlap: Double = 0.30
    /// When true, the corrected word must start with the same letter
    /// (case-insensitive) as the original. Real Whisper mishearings
    /// almost always preserve the first sound ("synch"→"sync",
    /// "Shunade"→"Sinead", "their"→"there"). Without this guard, words
    /// that happen to share inner letters slip through the
    /// edit-distance check — e.g. "Thank"→"Hunt" passes at ratio 0.60
    /// despite sounding nothing alike.
    private static let requireFirstLetterMatch = true

    /// Bundle IDs that benefit from the Chromium "Grammarly trick":
    /// AXEnhancedUserInterface forces them to build their AX tree.
    private static let chromiumBundleIDPrefixes: [String] = [
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",    // Arc
        "com.tinyspeck.slackmacgap",     // Slack
        "com.hnc.Discord",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.anthropic.claudefordesktop",// Claude Desktop
        "notion.id",                     // Notion
        "md.obsidian",                   // Obsidian
        "com.linear",                    // Linear
        "com.figma.Desktop"              // Figma
    ]

    // MARK: - Active session

    private final class Session {
        let targetPid: pid_t
        let originalText: String
        let originalWords: [String]
        let deadline: Date
        let appBundleID: String?
        var seenPairs: Set<String> = []
        var observer: AXObserver?
        var element: AXUIElement
        var pollTimer: Timer?
        var enhancedUIPoked = false
        /// Counters for diagnostic throttling.
        var tickCount = 0
        var lastReportedFieldLen = -1
        /// Debounce state. We only diff when the field has been
        /// unchanged for `stabilityTicksRequired` consecutive ticks, and
        /// only once per stable state — keeps a long pause from
        /// re-firing the same proposal.
        var lastSeenFieldValue: String? = nil
        var lastChangeTick: Int = 0
        var lastDiffedValue: String? = nil

        init(targetPid: pid_t, originalText: String, appBundleID: String?) {
            self.targetPid = targetPid
            self.originalText = originalText
            self.originalWords = Self.tokenize(originalText)
            self.deadline = Date().addingTimeInterval(CorrectionLearner.windowSeconds)
            self.appBundleID = appBundleID
            self.element = AXUIElementCreateApplication(targetPid)
        }

        static func tokenize(_ s: String) -> [String] {
            s.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        }
    }

    private var current: Session?

    private init() {}

    // MARK: - Public API

    /// Begin watching `targetPid` for a user correction of `originalText`
    /// for the next 30 s. Cancels any prior in-flight session — only one
    /// dictation can be the "most recent" at a time.
    func watchForCorrection(
        targetPid: pid_t,
        originalText: String,
        mode: TranscriptionMode,
        onCorrection: @escaping (_ from: String, _ to: String) -> Void
    ) {
        teardown()

        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.utf8.count <= Self.maxOutputBytes else { return }

        let bundleID = NSRunningApplication(processIdentifier: targetPid)?.bundleIdentifier
        let session = Session(targetPid: targetPid, originalText: trimmed, appBundleID: bundleID)
        current = session

        #if DEBUG
        print("[Sprich] CorrectionLearner: watching pid=\(targetPid) bundle=\(bundleID ?? "?") originalWords=\(session.originalWords.count)")
        #endif

        attachObserver(session: session, onCorrection: onCorrection)
        startPollTimer(session: session, onCorrection: onCorrection)
        maybePokeEnhancedUI(session: session)
    }

    /// Cancel the current watch (e.g. on app quit).
    func cancel() { teardown() }

    // MARK: - Observer wiring

    private func attachObserver(
        session: Session,
        onCorrection: @escaping (String, String) -> Void
    ) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon = refcon else { return }
            let learner = Unmanaged<CorrectionLearner>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                learner.tick()
            }
        }
        let status = AXObserverCreate(session.targetPid, callback, &observer)
        guard status == .success, let obs = observer else {
            #if DEBUG
            print("[Sprich] CorrectionLearner: AXObserverCreate failed (\(status.rawValue)); polling-only mode")
            #endif
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, session.element, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, session.element, kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )
        session.observer = obs
        // Stash the user's accept-handler so tick() can dispatch it.
        self.onCorrectionHandler = onCorrection
    }

    private var onCorrectionHandler: ((String, String) -> Void)?

    private func startPollTimer(
        session: Session,
        onCorrection: @escaping (String, String) -> Void
    ) {
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        session.pollTimer = timer
        self.onCorrectionHandler = onCorrection
    }

    private func maybePokeEnhancedUI(session: Session) {
        guard let bundleID = session.appBundleID else { return }
        guard Self.chromiumBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) else { return }
        guard !session.enhancedUIPoked else { return }
        session.enhancedUIPoked = true

        // Direct AX-API set on the application element. The OW audit
        // originally suggested an AppleScript via System Events, but
        // that requires NSAppleEventsUsageDescription + a separate TCC
        // permission ("Sprich wants to control System Events"). Going
        // direct uses Sprich's existing Accessibility grant and avoids
        // the extra prompt entirely. Functionally identical — System
        // Events ultimately calls the same AXUIElementSetAttributeValue.
        let status = AXUIElementSetAttributeValue(
            session.element,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        #if DEBUG
        if status != .success {
            print("[Sprich] CorrectionLearner: AXEnhancedUserInterface poke returned \(status.rawValue) for \(bundleID) (ok to ignore — some Chromium versions reject this)")
        } else {
            print("[Sprich] CorrectionLearner: AXEnhancedUserInterface poked \(bundleID)")
        }
        #endif
    }

    // MARK: - Tick: read field, diff, guard, propose

    private func tick() {
        guard let session = current else { return }
        if Date() >= session.deadline {
            #if DEBUG
            print("[Sprich] CorrectionLearner: window expired after \(session.tickCount) ticks")
            #endif
            teardown()
            return
        }

        session.tickCount += 1

        // Read the focused element's value from the target app. We attach
        // observers to the application element, so the focused element
        // may have changed since session start; re-read each tick.
        guard let fieldValue = readFocusedFieldValue(session: session) else {
            #if DEBUG
            // Log only every 6th nil-read to keep the console readable —
            // surfaces the "Notes-shaped AX tree returns nothing" case
            // without spamming when an element is genuinely empty.
            if session.tickCount % 6 == 1 {
                print("[Sprich] CorrectionLearner: tick \(session.tickCount) — AX read returned nil (focused element has no kAXValueAttribute?)")
            }
            #endif
            return
        }
        #if DEBUG
        // Surface the read each time the field length materially changes.
        if fieldValue.count != session.lastReportedFieldLen {
            print("[Sprich] CorrectionLearner: tick \(session.tickCount) — field len=\(fieldValue.count) vs original \(session.originalText.count)")
            session.lastReportedFieldLen = fieldValue.count
        }
        #endif
        guard fieldValue.utf8.count <= Self.maxOutputBytes else {
            #if DEBUG
            print("[Sprich] CorrectionLearner: field too large (\(fieldValue.utf8.count) bytes) — skipping")
            #endif
            return
        }
        if fieldValue == session.originalText { return }

        // Debounce: wait for the field to settle. If the value changed
        // since the previous tick, restart the stability counter and
        // return without diffing — catches the typical mid-keystroke
        // state ("syn" before the user finishes typing "syncc"). Diff
        // only when the same value has been observed for N consecutive
        // ticks AND we haven't already diffed it.
        if fieldValue != session.lastSeenFieldValue {
            session.lastSeenFieldValue = fieldValue
            session.lastChangeTick = session.tickCount
            return
        }
        let stableTicks = session.tickCount - session.lastChangeTick
        if stableTicks < Self.stabilityTicksRequired { return }
        if fieldValue == session.lastDiffedValue { return }
        session.lastDiffedValue = fieldValue
        #if DEBUG
        print("[Sprich] CorrectionLearner: field stable for \(stableTicks) ticks — diffing")
        #endif

        let editedWords = Session.tokenize(fieldValue)
        let region = findEditedRegion(
            originalWords: session.originalWords,
            editedWords: editedWords
        )
        let subs = findSubstitutions(origWords: session.originalWords, editedWords: region)

        // Privacy guard: too many words changed → likely a rewrite.
        let changed = subs.count
        let origCount = max(session.originalWords.count, 1)
        if Double(changed) / Double(origCount) > Self.rewriteFraction {
            #if DEBUG
            print("[Sprich] CorrectionLearner: rewrite guard rejected — \(changed)/\(origCount) words changed")
            #endif
            return
        }

        for (from, to) in subs {
            // Meaningful-change guard: reject "corrections" that only add or
            // remove surrounding punctuation (e.g. "gratis" → "gratis'",
            // "report" → "report."). Once leading/trailing non-alphanumerics
            // are stripped and case is folded, if the two tokens are equal then
            // nothing a find-and-replace should learn actually changed — the
            // user just left a stray character. Interior punctuation is
            // preserved, so legit contraction fixes ("cant" → "can't") still
            // pass through to the edit-distance check below.
            if alphanumericCore(from) == alphanumericCore(to) {
                #if DEBUG
                print("[Sprich] CorrectionLearner: reject \(from)→\(to) — punctuation-only change, not a word correction")
                #endif
                continue
            }
            if to.count < Self.minCorrectedWordLen {
                #if DEBUG
                print("[Sprich] CorrectionLearner: reject \(from)→\(to) — corrected word <3 chars")
                #endif
                continue
            }
            if Self.requireFirstLetterMatch,
               from.first?.lowercased() != to.first?.lowercased() {
                #if DEBUG
                print("[Sprich] CorrectionLearner: reject \(from)→\(to) — different first letter (likely rewrite, not phonetic correction)")
                #endif
                continue
            }
            if !passesEditDistanceRatio(from, to) {
                #if DEBUG
                print("[Sprich] CorrectionLearner: reject \(from)→\(to) — edit-distance ratio too high")
                #endif
                continue
            }

            let key = (from + "→" + to).lowercased()
            if session.seenPairs.contains(key) { continue }
            session.seenPairs.insert(key)

            // Skip if already present in the user's replacements.
            // We check this via the handler — the handler closure has
            // a reference to AppSettings; we delegate the check there
            // by passing the candidate and letting the caller decide.
            #if DEBUG
            print("[Sprich] CorrectionLearner: proposing \(from) → \(to)")
            #endif
            onCorrectionHandler?(from, to)
        }
    }

    private func readFocusedFieldValue(session: Session) -> String? {
        var focused: CFTypeRef?
        let s1 = AXUIElementCopyAttributeValue(session.element, kAXFocusedUIElementAttribute as CFString, &focused)
        guard s1 == .success, let element = focused else { return nil }
        let axElement = element as! AXUIElement

        var value: CFTypeRef?
        let s2 = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &value)
        guard s2 == .success else { return nil }
        if let s = value as? String { return s }
        return nil
    }

    // MARK: - Diff core

    /// Returns the slice of `editedWords` that best aligns to
    /// `originalWords`. Slides a window of `originalWords.count` across
    /// `editedWords` when the edited text is much longer, otherwise
    /// returns the whole edited word array.
    func findEditedRegion(originalWords: [String], editedWords: [String]) -> [String] {
        guard !originalWords.isEmpty, !editedWords.isEmpty else { return editedWords }
        let origCount = originalWords.count
        let editCount = editedWords.count
        // When the field is similar in length, no windowing needed.
        if Double(editCount) <= Double(origCount) * 1.5 {
            return editedWords
        }

        let origSet = Set(originalWords.map { $0.lowercased() })
        var bestStart = 0
        var bestOverlap = 0.0
        let windowSize = origCount

        for start in 0...(editCount - windowSize) {
            let window = editedWords[start..<(start + windowSize)]
            let overlap = window.reduce(0.0) { acc, w in
                acc + (origSet.contains(w.lowercased()) ? 1.0 : 0.0)
            } / Double(windowSize)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestStart = start
            }
        }

        if bestOverlap >= Self.regionMinOverlap {
            return Array(editedWords[bestStart..<(bestStart + windowSize)])
        }
        return editedWords
    }

    /// Word-level LCS alignment. Returns `[(origWord, editedWord)]` pairs
    /// where a consecutive deletion-then-insertion (or insertion-then-
    /// deletion) pattern was detected — both orderings count as a
    /// substitution because LCS tie-breaking can produce either.
    func findSubstitutions(origWords: [String], editedWords: [String]) -> [(String, String)] {
        let alignment = lcsAlign(origWords, editedWords)
        var subs: [(String, String)] = []
        var i = 0
        while i < alignment.count - 1 {
            let a = alignment[i]
            let b = alignment[i + 1]
            // Pattern 1: deletion, then insertion.
            if let origWord = a.orig, a.edited == nil,
               let editedWord = b.edited, b.orig == nil {
                if origWord.lowercased() != editedWord.lowercased() {
                    subs.append((origWord, editedWord))
                }
                i += 2
                continue
            }
            // Pattern 2: insertion, then deletion. LCS reconstruction
            // can emit this ordering for the same logical substitution
            // depending on tie-breaking; treat it identically.
            if let editedWord = a.edited, a.orig == nil,
               let origWord = b.orig, b.edited == nil {
                if origWord.lowercased() != editedWord.lowercased() {
                    subs.append((origWord, editedWord))
                }
                i += 2
                continue
            }
            i += 1
        }
        return subs
    }

    private struct AlignCell {
        let orig: String?
        let edited: String?
    }

    /// Standard LCS alignment producing a stream of `(orig, edited)` cells.
    /// Matches are `(w, w)`; deletions are `(w, nil)`; insertions `(nil, w)`.
    private func lcsAlign(_ a: [String], _ b: [String]) -> [AlignCell] {
        let n = a.count
        let m = b.count
        if n == 0 { return b.map { AlignCell(orig: nil, edited: $0) } }
        if m == 0 { return a.map { AlignCell(orig: $0, edited: nil) } }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<m {
                if a[i].lowercased() == b[j].lowercased() {
                    dp[i + 1][j + 1] = dp[i][j] + 1
                } else {
                    dp[i + 1][j + 1] = max(dp[i][j + 1], dp[i + 1][j])
                }
            }
        }

        var i = n, j = m
        var out: [AlignCell] = []
        while i > 0 && j > 0 {
            if a[i - 1].lowercased() == b[j - 1].lowercased() {
                out.append(AlignCell(orig: a[i - 1], edited: b[j - 1]))
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                out.append(AlignCell(orig: a[i - 1], edited: nil))
                i -= 1
            } else {
                out.append(AlignCell(orig: nil, edited: b[j - 1]))
                j -= 1
            }
        }
        while i > 0 { out.append(AlignCell(orig: a[i - 1], edited: nil)); i -= 1 }
        while j > 0 { out.append(AlignCell(orig: nil, edited: b[j - 1])); j -= 1 }
        return out.reversed()
    }

    /// Lowercased token with leading/trailing non-alphanumeric characters
    /// stripped. Interior characters (including contraction apostrophes) are
    /// kept, so this folds away only *surrounding* punctuation and casing —
    /// exactly the noise that produced bogus learns like "gratis" → "gratis'".
    func alphanumericCore(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private func passesEditDistanceRatio(_ a: String, _ b: String) -> Bool {
        let d = levenshtein(a.lowercased(), b.lowercased())
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return false }
        return Double(d) / Double(maxLen) <= Self.editDistanceRatio
    }

    private func levenshtein(_ s: String, _ t: String) -> Int {
        let a = Array(s)
        let b = Array(t)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // deletion
                    curr[j - 1] + 1,    // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    // MARK: - Teardown

    private func teardown() {
        guard let session = current else { return }
        session.pollTimer?.invalidate()
        session.pollTimer = nil
        if let obs = session.observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(obs),
                .defaultMode
            )
        }
        session.observer = nil
        current = nil
        onCorrectionHandler = nil
    }
}
