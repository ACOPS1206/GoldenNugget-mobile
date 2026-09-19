import Foundation

// The device-transport failure model.
//
// WHY THIS TYPE EXISTS
//
// `IdeviceGateway` reports every failure as
// `IdeviceGatewayError(.serviceError, reason: String)` — the FFI error code is
// discarded and only the message survives.  The engine therefore had to decide
// "is this worth retrying?" by grepping `String(describing: error).lowercased()`,
// which is how two overlapping predicates appeared
// (`isTransientRestoreError` matched any message containing "mobilebackup2" —
// its own doc comment called that "too broad" — and `isTransientChannelError`
// matched the socket literals).  The retry ladder then had no way to know WHICH
// layer was broken, so it escalated by attempt number instead.
//
// This enum is the single place where the raw text becomes a type.  Everything
// downstream — the retry decision, the recovery level, the operator-facing
// message — reads the type, not the string.

/// Which layer's cached state has to be discarded before a retry can work.
///
/// Ordered: each level does everything the previous one does.
enum RecoveryLevel: Int, Comparable {
    /// Release the cached RSD adapter + handshake, so the next attempt dials a
    /// fresh RemotePairing session.
    case dropRSD = 1
    /// Also re-discover the tunnel peer.  A tunnel flap leaves the cached
    /// `deviceEndpointIp` stale, and every attempt then dies identically no
    /// matter how often the adapter is dropped.
    case refreshEndpoint = 2
    /// Also re-pin the endpoint and rebuild the muxer plumbing.  A fresh jktcp
    /// connection gets a clean sequence space, which is the only thing that
    /// closes a hole this stack has no gap recovery for.
    case restartMuxer = 3

    static func < (lhs: RecoveryLevel, rhs: RecoveryLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What the retry controller should do with a failure.
enum RetryDecision {
    /// Do not retry; the failure is not about the connection.
    case failFast(reason: String)
    /// Retry, and release at least this much cached state first.
    case retry(floor: RecoveryLevel, reason: String)
}

/// A classified device-transport failure.
///
/// Carries everything the retry decision and the operator-facing message need,
/// so neither has to re-parse text or re-derive context.
enum TransportFailure: Error, LocalizedError {
    /// The operator pressed stop.  Nobody should retry this.
    case cancelled(label: String)

    /// Parked in `dl_version_exchange()` waiting for the device's FIRST
    /// DeviceLink message.  This side has not sent anything yet.
    case handshakeSilent(label: String, heldSeconds: Int)

    /// Handshake completed, then the stream went quiet mid-operation.
    case streamStalled(label: String, heldSeconds: Int, probeVerdict: String?)

    /// The device is still pushing bytes but jktcp cannot deliver them: the gap
    /// is a contiguous run and the only thing that fills it is the peer's
    /// retransmit timer — which hands over one segment per timeout.
    ///
    /// (The doc used to say "a UDP segment was lost".  That is one candidate
    /// cause, not the measurement — see the note on the message below.)
    case tunnelCrawl(label: String, spanSeconds: Int, gapBytes: UInt64,
                     deliveryBytesPerSecond: Double, outOfOrderSegments: Int)

    /// The socket-level session is gone (BrokenPipe / channel closed / SSLEOF /
    /// connection terminated / reset).
    case channelLost(label: String, raw: String)

    /// The device answered, and said no.  Validation, not transport — retrying
    /// the same bytes changes nothing.
    case deviceRejected(label: String, raw: String)

    /// iOS refused the operation because the device is locked
    /// (`MBErrorDomain/208`, "Device locked").
    ///
    /// Distinct from `deviceRejected` because the operator action is different
    /// and so is the retry decision: this one is not about the backup's
    /// contents, it is "unlock the screen and run again".  It shows up on the
    /// attempt that follows a teardown, which makes it look like the retry made
    /// things worse — it did not, the screen simply went to sleep during the
    /// minutes the earlier attempt spent crawling.
    case deviceLocked(label: String, raw: String)

    /// The gateway was never started, so there is no session to retry on.
    case notReady(label: String, raw: String)

    /// Unclassified.  Treated as non-retryable, which is the conservative
    /// choice: a device-side rejection must not be retried forever.
    case unknown(label: String, raw: String)

    var label: String {
        switch self {
        case .cancelled(let l), .handshakeSilent(let l, _), .streamStalled(let l, _, _),
             .tunnelCrawl(let l, _, _, _, _), .channelLost(let l, _),
             .deviceRejected(let l, _), .deviceLocked(let l, _),
             .notReady(let l, _), .unknown(let l, _):
            return l
        }
    }

    /// True when the run ended because the operator asked it to.  The UI reads
    /// this to say "stopped" instead of "failed".
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var retryDecision: RetryDecision {
        switch self {
        case .cancelled:
            return .failFast(reason: "stopped by the user — not retrying.")

        // A handshake stall is NOT a dropped channel: the device accepted the
        // connection and never said a single word.  A fresh RSD tunnel does not
        // help — the Rust log shows the retry getting a brand-new tunnel and
        // then not even receiving the DeviceLink version exchange reply — so
        // fail fast instead of spending another whole attempt (and another
        // 2 minutes) to arrive at the same place.  Worst case: the device daemon
        // is wedged and only a reboot clears it.
        case .handshakeSilent:
            return .failFast(reason: "the device never answered the handshake")

        // A plain channel drop is a state of the session: drop the RSD adapter
        // and dial again.
        case .channelLost:
            return .retry(floor: .dropRSD, reason: "dropped the channel")

        // A MID-STREAM stall is a different animal: the exchange ran, data
        // landed, and the stream then went quiet.  The backup already on disk
        // stays (a retry is incremental), so one more attempt is cheap next to
        // throwing the run away.  Re-discovering the endpoint is included
        // because the gateway caches both the RSD adapter AND the IP the Rust
        // tunnel dials, and either being stale reproduces the stall exactly.
        case .streamStalled:
            return .retry(floor: .refreshEndpoint, reason: "went quiet mid-stream")

        // A tunnel crawl is retried for a stronger reason than "worth one more
        // try": it is a *state* of the jktcp connection, and the recovery below
        // discards that connection outright.  Rebuilding the RSD adapter creates
        // a new CDTunnel and a new jktcp session, i.e. a clean sequence space —
        // the one thing that can clear a hole this stack has no recovery for.
        //
        // The wording stays cause-neutral on purpose: "stopped delivering" is what
        // was measured, "a datagram went missing" is a hypothesis (see the note
        // on the crawl message).
        case .tunnelCrawl:
            return .retry(floor: .restartMuxer,
                          reason: "lost its tunnel (the tunnel stopped delivering)")

        case .deviceRejected:
            return .failFast(reason: "the device rejected the request")
        case .deviceLocked:
            return .failFast(reason: "the device is locked")
        case .notReady:
            return .failFast(reason: "the device gateway is not initialized")
        case .unknown:
            return .failFast(reason: "not a channel drop")
        }
    }

    var errorDescription: String? {
        switch self {
        case .cancelled(let label):
            return "\(label) stopped by the user — the in-flight call was abandoned "
                + "(a blocked Rust read cannot be interrupted, only walked away from)"

        case .handshakeSilent(let label, let held):
            return "device never sent its first DeviceLink message during \(label) "
                + "(silent for \(held)s). The mobilebackup2 client is a pure reader at this point "
                + "— the device initiates with DLMessageVersionExchange and we only answer — so nothing "
                + "the app sends can cause this, and the currently loaded binary is not a suspect. "
                + "The device-side backup daemon is the one not talking: it wedges on a request it cannot "
                + "process and stays wedged across app restarts, so REBOOT THE DEVICE (重启设备) before "
                + "retrying. Background: scripts/patch-idevice-target-identifier.sh"

        case .streamStalled(let label, let held, let verdict):
            var s = "the \(label) stream went quiet for \(held)s — neither the host callbacks "
                + "nor the DeviceLink channel moved"
            if let verdict { s += ". Out-of-band check when the silence started: \(verdict)" }
            s += ". The two causes look identical from here and the app log tells them apart: a "
                + "device-side phase that is slow but alive (the retry continues from the backup already "
                + "on disk, so it only costs the baseline), or a mobilebackup2 stream that is wedged or "
                + "desynchronised after a host-side file error (see the 'delegate errors' line)."
            return s

        case .tunnelCrawl(let label, let span, let gap, let rate, let outOfOrder):
            var s = "the \(label) tunnel stopped delivering: jktcp is still receiving segments from "
                + "the device (\(outOfOrder) out-of-order so far)"
            s += ", \(gap / 1024) KB of it stuck behind an unfilled gap"
            s += String(format: ", delivery crawled at %.1f KB/s", rate / 1024)
            s += " for \(span)s. What was measured is the transport refusing to hand bytes up. Two "
                + "numbers from the Rust log are worth reading before deciding what broke: the gap is "
                + "CONTIGUOUS (one run of segments, not scattered single losses), and the deliverable "
                + "position advances by exactly one ~1 KB segment per ~310 ms — the peer's retransmit "
                + "timer, one segment per timeout. Recovery at that rate is 3.3 KB/s against a backlog "
                + "of \(gap / 1024) KB, i.e. about \(gap / 1024 / 3) s to clear, while the peer keeps "
                + "refilling its send window with data that has to be discarded meanwhile — so it does "
                + "not clear. Everything above this layer looks healthy throughout (lockdown answers, "
                + "and a liveness probe calls the device alive)."
            // The amplifier, and the reason a small loss costs an unbounded
            // time: out-of-order data is DISCARDED, not buffered (the deliverable
            // position never jumps — it only ever steps by one segment), so the
            // peer has to resend everything that arrived behind the hole.
            // 2026-09-19 measured the ratio: a 26 KB prefix loss, then a 2.46 MB
            // burst in 45.6 ms that all had to be resent — ~100x amplification,
            // and at one segment per RTO that is ~13 minutes.
            s += " The cost is amplified by the receiver: out-of-order data is discarded rather than "
                + "buffered, so the peer has to resend everything that arrived behind the hole. A "
                + "measured run lost a 26 KB prefix of a 2.46 MB burst and paid for the whole burst."
            // Do NOT assert that a datagram was dropped.  The contiguous run
            // makes "one datagram lost" a good guess — a tunnel datagram carries
            // many segments, so losing one costs a whole consecutive range — but
            // it is a guess: nothing in the repo exposes the tunnel's datagram
            // size, so the framing cannot be checked from here.
            //
            // The discriminator that IS available is reproducibility: compare
            // this crawl's gap and out-of-order count against the previous one.
            // Identical values after a FRESH tunnel rule randomness out —
            // 2026-09-19 produced exactly that (2544 segments / 2838 KB / 85
            // files, twice, in two separate runs), which is a fixed position in a
            // replayed stream.
            s += " Whether this was one lost tunnel datagram (a contiguous hole is what that looks "
                + "like) or a deterministic stall at a fixed offset, check before concluding: if a "
                + "crawl reproduces the SAME gap and the SAME out-of-order count after a fresh tunnel, "
                + "it is not random loss."
            return s

        case .channelLost(let label, let raw):
            // `Socket(... BrokenPipe, "channel closed")` is jktcp's generic report
            // for "that TCP flow is gone" — the userspace stack drops its
            // per-port sender when the connection is torn down, so a DEVICE-SIDE
            // close and a local pump failure look identical here.  It therefore
            // cannot be read as "the device refused us".
            return "\(label) dropped the channel: \(raw). \"channel closed\" is jktcp's generic "
                + "flow-closed report — it does not distinguish a device-side teardown from a local "
                + "stack failure. See minimuxer.log (Rust, DEBUG) for the real step."

        case .deviceRejected(let label, let raw):
            return "the device rejected \(label): \(raw). This is a validation answer, not a dropped "
                + "channel, so the same bytes will be refused again — fix the backup, do not retry."

        case .deviceLocked(let label, let raw):
            return "\(label) was refused because the device is locked (\(raw)). iOS will not run a "
                + "mobilebackup2 backup or restore against a locked device, so this is not the "
                + "tunnel and not the backup — unlock the screen and keep it awake, then run again. "
                + "Worth knowing when this appears on a later attempt: a crawl leaves the screen "
                + "alone for minutes, so the device locks itself in the middle of the run and the "
                + "NEXT attempt is the one that reports it."

        case .notReady(let label, let raw):
            return "\(label) could not run: the device gateway is not ready (\(raw))"

        case .unknown(let label, let raw):
            return "\(label) failed: \(raw)"
        }
    }
}

// MARK: - Classification

/// The one place where raw gateway text becomes a `TransportFailure`.
///
/// Every literal here is deliberate.  Adding a phrase widens what gets retried,
/// so the lists stay explicit and narrow rather than clever.
enum TransportFailureClassifier {
    /// "The session is gone at the socket level."
    ///
    /// These are exactly the literals the old `isTransientChannelError` matched,
    /// kept verbatim so the retry set does not silently change.  jktcp reports a
    /// torn-down flow as `Socket(... BrokenPipe, channel closed)`; the HTTPS/TLS
    /// layer of RSD reports SSLEOF / ConnectionTerminated; the kernel reports
    /// ECONNRESET.
    static let channelLossLiterals: [String] = [
        "brokenpipe",
        "channel closed",
        "connectionterminated",
        "ssleof",
        "connection reset",
        "connectionreset",
    ]

    /// "The device is locked."
    ///
    /// Checked before `deviceRejectionLiterals` so the operator gets the
    /// actionable message.  Both spellings are real: the response carries the
    /// numeric code and a human description, and different daemons surface one
    /// or the other.
    static let deviceLockedLiterals: [String] = [
        "mberrordomain/208",
        "device locked",
    ]

    /// "The device understood and said no."
    ///
    /// Named so the log can say why a retry was skipped.  These are the
    /// validation answers seen from the restore daemon: a manifest row with no
    /// payload (MBErrorDomain/205, "Unknown domain name in file record"), a
    /// commit shortfall (MBErrorDomain/104, "Manifest references files not in
    /// backup"), and a rejected pairing identity.
    static let deviceRejectionLiterals: [String] = [
        "unknown domain name in file record",
        "manifest references files not in backup",
        "mberrordomain/205",
        "mberrordomain/104",
        "invalidhostid",
    ]

    /// Cached config that makes `deviceRejected` a false negative; checked last
    /// so a genuine socket error still wins the classification.
    static let notReadyLiterals: [String] = [
        "has not been initialized",
        "not initialized",
    ]

    /// Classify a thrown error.  An already-typed failure passes through
    /// unchanged, which is what keeps the stall guard's own verdicts intact
    /// through the retry ladder.
    static func classify(_ error: Error, label: String) -> TransportFailure {
        if let failure = error as? TransportFailure { return failure }

        let raw = String(describing: error)
        let lower = raw.lowercased()

        if channelLossLiterals.contains(where: { lower.contains($0) }) {
            return .channelLost(label: label, raw: raw)
        }
        if deviceLockedLiterals.contains(where: { lower.contains($0) }) {
            return .deviceLocked(label: label, raw: raw)
        }
        if deviceRejectionLiterals.contains(where: { lower.contains($0) }) {
            return .deviceRejected(label: label, raw: raw)
        }
        if notReadyLiterals.contains(where: { lower.contains($0) }) {
            return .notReady(label: label, raw: raw)
        }
        return .unknown(label: label, raw: raw)
    }
}
