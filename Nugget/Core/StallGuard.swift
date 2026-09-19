import Foundation

/// Set by the UI's stop button; polled by `StallGuard.run`.
///
/// There is no way to interrupt a Rust read that is blocked on a socket, so
/// "cancel" means abandoning the call and unwinding — the same trade-off the
/// stall guard already makes, exposed to the person watching.
final class CancelFlag: @unchecked Sendable {
    static let shared = CancelFlag()

    private let lock = NSLock()
    private var flag = false

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func request() {
        lock.lock()
        flag = true
        lock.unlock()
        AppLog.write("⏹ stop requested — the current blocking call will be abandoned at the next check")
    }

    func clear() {
        lock.lock()
        flag = false
        lock.unlock()
    }
}

/// The deadline the mobilebackup2 FFI does not give us.
///
/// `mobilebackup2_backup` awaits the device's next DeviceLink message with no
/// timeout of its own, so a device that goes silent leaves the call blocked
/// forever — no progress, no error, no retry, and a UI that looks hung.  This
/// wraps such a call in a watchdog that turns silence into a typed verdict.
enum StallGuard {
    /// Runs `body`, but stops *waiting* for it once the device has been silent
    /// for `idleSeconds` — and only then, after checking out-of-band that the
    /// device is really gone, gives up entirely at `maxIdleSeconds`.
    ///
    /// "Silent" means BOTH clocks are quiet:
    ///   - `idle()` — the host delegate callbacks (a file arrived, a chunk
    ///     landed), i.e. payload actually moving;
    ///   - `wire()` — the wire counters in the Rust log (DeviceLink messages,
    ///     plus jktcp's out-of-order segments and the byte position it can
    ///     actually deliver).
    ///
    /// The second one is what keeps a healthy run alive: the device spends real
    /// time enumerating the host tree and preparing batches, and for minutes of
    /// that work it fires no host callback at all. Judging it by callbacks alone
    /// killed live runs — which is what "stuck at 2 %, then aborted" was.
    ///
    /// `handshakeSilent` is the tighter, third clock: a healthy version exchange
    /// is over in milliseconds, so if the log still shows "waiting for the
    /// device's first DL message" after `silentHandshakeSeconds`, the daemon is
    /// wedged and there is no point waiting out the long windows.
    ///
    /// The fourth verdict — and the one "stuck at 1 %" needed — is the *tunnel
    /// crawl*: jktcp still logging out-of-order segments while the byte position
    /// it can deliver barely moves. The device is demonstrably pushing (segments
    /// keep arriving) and lockdown still answers, so every clock above says
    /// "healthy": no host callback (nothing is delivered), no DL message (no
    /// progress can be parsed), and a liveness probe that passes. Waiting it out
    /// is pure loss — measured at 1024 bytes per ~300 ms, the peer's retransmit
    /// timer, with the device already 3 MB ahead. See the crawl check below.
    ///
    /// It comes in two shapes, and the check must accept both (see the note at
    /// the crawl term):
    ///   - the hole *grows* — the device keeps pushing new data behind a lost
    ///     range, so `seq` advances while `expected` does not;
    ///   - the hole is *static* — the device retransmits the SAME out-of-window
    ///     segment forever, so `seq` never moves, `expected` never moves, the gap
    ///     is byte-for-byte constant, and only the out-of-order counter climbs.
    ///     Observed on 2026-09-19: gap pinned at 2.5 MB for 200 s while the
    ///     counter rose +29 per 10 s poll and the run sat at 52 %.
    ///
    /// The abandoned call is safe to walk away from: the gateway runs it on
    /// `DispatchQueue.global()` via `withFFIDispatch`, so other gateway traffic
    /// keeps flowing (lockdown answers throughout the wedged run in the logs).
    /// The thread leaks until the app restarts, which is acceptable — it only
    /// ever happens on a lost run.
    @discardableResult
    static func run<T>(
        label: String,
        idleSeconds: Int,
        maxIdleSeconds: Int,
        pollSeconds: UInt64 = 5,
        silentHandshakeSeconds: Int = 45,
        crawlSeconds: Double = 15,
        crawlFloorBytesPerSecond: Double = 16 * 1024,
        crawlMinGapBytes: UInt64 = 128 * 1024,
        idle: @escaping @Sendable () -> Date,
        wire: (@Sendable () -> RustWireSample)? = nil,
        probe: (@Sendable () async -> (alive: Bool, detail: String))? = nil,
        handshakeSilent: (@Sendable () -> Bool)? = nil,
        _ body: @escaping () async throws -> T
    ) async throws -> T {
        let once = OnceResumer<T>()
        return try await withCheckedThrowingContinuation { cont in
            once.attach(cont)
            Task {
                do { once.resume(.success(try await body())) }
                catch { once.resume(.failure(error)) }
            }
            Task {
                // Two independent clocks: the handshake one is the tight, "the
                // daemon never said hello" detector, the quiet one is the
                // "the stream stopped mid-flight" episode. Sharing a single
                // variable let one reset the other and delayed the 45 s verdict.
                var handshakeSince: Date? = nil
                var quietSince: Date? = nil
                var probed = false
                var verdict: (alive: Bool, detail: String)? = nil
                var lastNotice = Date()
                var lastWire: RustWireSample?
                var lastWireAt = Date()
                // Delivery samples for the crawl verdict: (when, out-of-order
                // count, deliverable byte position, bytes stuck). Every entry is
                // one poll while a hole is open.
                var delivery: [DeliverySample] = []

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: pollSeconds * 1_000_000_000)
                    if once.isSettled { return }

                    // The user asked to stop.  The blocking FFI read cannot be
                    // interrupted, so walking away from it is the whole mechanism
                    // — and it must be possible at any point of a long wait, not
                    // only between stages.
                    if CancelFlag.shared.isRequested {
                        AppLog.write("⏹ \(label): cancelled by the user — abandoning the call")
                        once.resume(.failure(TransportFailure.cancelled(label: label)))
                        return
                    }

                    // Device never opened its side of the DeviceLink conversation:
                    // the request/authorization phase never started, so this is a
                    // device-daemon problem, not a slow transfer.
                    if let handshakeSilent {
                        if handshakeSilent() {
                            let from = handshakeSince ?? Date()
                            handshakeSince = from
                            let held = Int(Date().timeIntervalSince(from))
                            if held >= silentHandshakeSeconds {
                                AppLog.write("⏱ \(label): device has not sent its first "
                                    + "DeviceLink message for \(held)s — the mobilebackup2 daemon is "
                                    + "not answering (nothing has been sent from this side yet)")
                                once.resume(.failure(TransportFailure.handshakeSilent(
                                    label: label, heldSeconds: held)))
                                return
                            }
                        } else {
                            handshakeSince = nil
                        }
                    }

                    // Did the device say anything on the wire since the last poll?
                    // Only a *rise* counts: the counters are cumulative for the
                    // run, so a poll that sees no new lines sees no new number.
                    if let wire {
                        let s = wire()
                        if let previous = lastWire, s.dlMessages > previous.dlMessages {
                            lastWireAt = Date()
                            if quietSince != nil {
                                AppLog.write("⏱ \(label): the device is talking again "
                                    + "(\(s.dlMessages) DL message(s) this run) — dropping the stall verdict")
                                quietSince = nil
                                probed = false
                                verdict = nil
                            }
                        }
                        lastWire = s

                        // ── Tunnel crawl ────────────────────────────────────────
                        //
                        // Out-of-order segments still arriving while the
                        // deliverable byte position does not move (or crawls)
                        // means the device is pushing and the *tunnel* is what
                        // is stuck. Requiring all of it is what keeps this from
                        // firing on a healthy run: a device that is merely
                        // thinking writes no out-of-order lines at all, a hole
                        // that really was retransmitted collapses (the gap
                        // shrinks and the deliverable position jumps), and a
                        // transfer that is simply slow is above the rate floor.
                        //
                        // Measured against the run that motivated this: verdict
                        // 16 s after the loss, with 2.8 MB of the device's stream
                        // stuck and delivery crawling at 3.3 KB/s.
                        if let previous = delivery.last,
                           let previousExpected = previous.expected,
                           let expected = s.expected {
                            let dt = Date().timeIntervalSince(previous.at)
                            let moved = expected > previousExpected ? expected - previousExpected : 0
                            let instant = dt > 0 ? Double(moved) / dt : 0
                            if instant >= crawlFloorBytesPerSecond {
                                // Bytes are demonstrably moving again: whatever
                                // hole was open is closed, so the episode is over
                                // and the next window starts clean.
                                delivery.removeAll()
                            }
                        }
                        // Only samples that carry the delivery clock are usable:
                        // a window whose oldest entry predates the first
                        // out-of-order line cannot be measured (`expected` is nil,
                        // and treating that as byte 0 turns the window into a
                        // nonsense-high rate that mutes the verdict).
                        if s.expected != nil {
                            delivery.append(DeliverySample(at: Date(), outOfOrder: s.outOfOrder,
                                                           expected: s.expected, gap: s.gap))
                        }
                        let horizon = Date().addingTimeInterval(-(crawlSeconds * 3))
                        while let oldest = delivery.first, oldest.at < horizon {
                            delivery.removeFirst()
                        }
                        if let first = delivery.first, let last = delivery.last {
                            let span = last.at.timeIntervalSince(first.at)
                            let segments = last.outOfOrder - first.outOfOrder
                            // Verdict only over a window long enough that a
                            // normal reorder/recovery burst cannot be mistaken
                            // for a permanent one.
                            //
                            // The last term is "the hole is NOT closing", not
                            // "the hole is growing".  Requiring growth (the
                            // first version did, +8 KB) misses the static shape
                            // of the same failure: when the device retransmits
                            // one out-of-window segment on repeat, `seq` never
                            // moves, so the gap is byte-for-byte constant while
                            // the out-of-order counter climbs — and the veto
                            // sent a fully wedged 52 % run down the slow idle
                            // path instead, 200 s of nothing.  Any shrink at or
                            // below the crawl floor is still a crawl, so the
                            // tolerance is derived from the floor rather than
                            // hand-picked: a hole closing faster than the floor
                            // is a recovery in progress and is left alone.
                            let recoverable = UInt64(crawlFloorBytesPerSecond * crawlSeconds)
                            if span >= crawlSeconds, segments >= 8,
                               let gap = s.gap, gap >= crawlMinGapBytes,
                               let startGap = first.gap,
                               startGap <= gap + recoverable {
                                // `first.expected` is present whenever
                                // `first.gap` is (the gap is derived from it),
                                // so the `?? 0` fallback below is unreachable by
                                // construction — it is there to keep the
                                // arithmetic total.
                                let from = first.expected ?? 0
                                let to = last.expected ?? 0
                                let delivered = to > from ? to - from : 0
                                let rate = Double(delivered) / span
                                if rate < crawlFloorBytesPerSecond {
                                    // Full phrases, not fragments: "the backlog has still
                                    // growing" shipped once and read as a bug in itself.
                                    let shape = gap > (first.gap ?? gap)
                                        ? "is still growing" : "held steady"
                                    AppLog.write("⏱ \(label): the tunnel stopped delivering — "
                                        + "jktcp is holding \(gap / 1024) KB of the device's stream "
                                        + String(format: "behind an unfilled gap and crawled at %.1f KB/s "
                                            + "for %.0fs", rate / 1024, span)
                                        + " (\(segments) new out-of-order segments meanwhile, and the "
                                        + "backlog \(shape) for the whole window). Rebuilding the "
                                        + "tunnel: a fresh jktcp connection gets a clean sequence "
                                        + "space, which is the only thing that closes a hole it has "
                                        + "no recovery for.")
                                    once.resume(.failure(TransportFailure.tunnelCrawl(
                                        label: label,
                                        spanSeconds: Int(span),
                                        gapBytes: gap,
                                        deliveryBytesPerSecond: rate,
                                        outOfOrderSegments: s.outOfOrder)))
                                    return
                                }
                            }
                        }
                    }

                    let now = Date()
                    let quiet = Int(now.timeIntervalSince(max(idle(), lastWireAt)))
                    guard quiet >= idleSeconds else {
                        quietSince = nil
                        probed = false
                        verdict = nil
                        continue
                    }

                    let since = quietSince ?? now
                    quietSince = since
                    let held = Int(now.timeIntervalSince(since))

                    if !probed, let probe {
                        probed = true
                        let result = await probe()
                        verdict = result
                        AppLog.write("⏱ \(label): nothing for \(quiet)s — out-of-band check: "
                            + result.detail)
                        if !result.alive {
                            AppLog.write("⏱ \(label): abandoning the call — the device is not "
                                + "answering anything, so waiting longer cannot help")
                            once.resume(.failure(TransportFailure.streamStalled(
                                label: label, heldSeconds: held, probeVerdict: result.detail)))
                            return
                        }
                    }

                    // Keep talking while we wait: the whole point of the guard is
                    // to turn a silent hang into a visible state.
                    if now.timeIntervalSince(lastNotice) >= 30 {
                        lastNotice = now
                        let why = verdict?.alive == true
                            ? "but the device answers lockdown, so this may be a slow device-side phase"
                            : "and no probe verdict is available, so this is simply the quiet window"
                        // Report BOTH clocks.  `held` counts from the moment the
                        // threshold was crossed, so it reads "0s" right after a
                        // "nothing for 124s" line and made a 120+300 s wait look
                        // like it had just started.
                        AppLog.write("⏱ \(label): still quiet — \(quiet)s of silence since the last sign "
                            + "of life (\(held)s since this verdict window opened, \(maxIdleSeconds - held)s "
                            + "left before the call is abandoned), \(why)")
                    }

                    guard held >= maxIdleSeconds else { continue }
                    AppLog.write("⏱ \(label): device silent for \(held)s despite answering "
                        + "lockdown — abandoning the call (the mobilebackup2 daemon is not finishing "
                        + "what it started)")
                    once.resume(.failure(TransportFailure.streamStalled(
                        label: label, heldSeconds: held, probeVerdict: verdict?.detail)))
                    return
                }
            }
        }
    }
}
