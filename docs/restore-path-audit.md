# 恢复链路审计：变慢与丢任务

> **状态：全部已落地（2026-09-19）。** 6 条主问题 + 次要项都已改；`scripts/typecheck.sh`
> **0 error，且未新增 warning**。
>
> 一处**待你本地验证**：`Vendor/` 改了三个文件（`IdeviceGateway.swift`、`MinimuxerApi.swift`、
> `MobileBackup2Delegate.swift`），但 `typecheck.sh` 读的是已构建的 `.swiftmodule`，所以两个
> 调用点（`ProtectiveBackup.swift:115`、`RestoreRunner.swift:69`）会报
> `extra argument 'cancellationRequested' in call` —— 这是**幻影错误**，Xcode 重建一次即消失。
> 我用「临时注释掉这两个实参 → 0 error → 恢复」的方式验证了**其余所有改动都是干净的**。
> 真机构建仍需要你本地跑 `scripts/build-ipa.sh`（我这边 SwiftPM manifest 求值被沙箱挡住）。
>
> 顺带修了一个**工具链 bug**：`scripts/relink-core-sources.py` 之前**不可重复执行**。它在第一次
> 成功运行时把组名从 `Sparserestore` 改成 `Core`，而 `rewrite_group()` 只认旧名，所以**第二次跑
> 直接 `ValueError: substring not found`**。后果很隐蔽：`Package.swift` 与 `project.pbxproj`
> 两条构建路径会分叉（SPM 编得过、xcodebuild 少一个文件）。现已接受两种拼写，并验证连跑两次输出
> 一致。

审计范围：`Nugget/Core/*`（自家代码）与 `Vendor/MinimuxerGateway/idevice/*`（SideStore fork，
改动需付上游合并成本）。**`Vendor/MinimuxerSources/` 是转发层——改签名必须两层一起改**
（`MinimuxerApi.swift:298/320` ↔ `IdeviceGateway.swift:2864/2896`）。

结论：**6 个问题里 3 个是"丢任务/丢数据"级别，不是慢**。变慢的大头只有 2 个，
其余是可靠性。逐条如下。

---

## 落地清单

| # | 问题 | 改动位置 |
|---|---|---|
| 1 | 取消标志从未接线 | 新增 `Nugget/Core/InFlightCall.swift`；`MobileBackup2Delegate.swift`（注入 `cancellationRequested`）；`IdeviceGateway.swift` + `MinimuxerApi.swift`（两层加参数）；`ProtectiveBackup.swift`、`RestoreRunner.swift`（传 `CancelFlag`） |
| 2 | 被放弃调用没有回收闸门 | `StallGuard.swift`（enter/leave/noteAbandoned）；`ChannelRecovery.swift`（有界等排空才重试）；`PoCEngine.swift`（入口闸门，且**在 `clearCancel()` 之前**） |
| 3 | 诊断拆自己的会话 | `Diagnostics.swift`（有在飞调用时整段跳过会话探针；单次快照替代两次全量读） |
| 4 | 握手静默每 5 s 全文重读 | `WireCensus.swift`（两个计数器 + `handshakeSilent`）；`RustLog.swift`（`deviceSilentAtHandshake()` 缩成一行，删除 `since:` 参数） |
| 5 | 修剪逐行 `stat` + 扫到 `Snapshot/` | `ManifestStore.swift`（`isShardName`、单次遍历分片树、`removeOrphanPayloads(shards:keepIDs:)`、`PruneReport.stagingKept`） |
| 6 | `_keep` 无索引 | `ManifestStore.swift`（`createKeepTable` 带 `PRIMARY KEY`） |
| 7 | 次要项 | `RestoreRunner.swift`（defer 阶段计时器）、`MobileBackup2Delegate.swift`（`open_file_read` 单次复制、`setvbuf` 1 MiB）、`Logging.swift`（批量异步 sink + `flush()` + `print` 只在 DEBUG）、`PoCView.swift`（稳定日志 id + 批量裁剪） |

---

## 总览

| # | 问题 | 类别 | 严重度 | 位置 |
|---|---|---|---|---|
| 1 | 取消标志从未接线，Stop 只停住了等待 | 丢任务 + 并发写坏 | P0 | `MobileBackup2Delegate.swift:57` |
| 2 | 被放弃的调用没有回收闸门就重试 | 丢任务 + use-after-free | P0 | `StallGuard.swift:267` → `ChannelRecovery.swift:73` |
| 3 | 诊断块在放弃路径上调用会 `invalidateConnection()` 的读 | 同上（自我拆台） | P0 | `Diagnostics.swift:34` |
| 4 | 握手静默检测每 5 s 全文重读+解码日志 | 拖慢 | P1 | `RustLog.swift:248` |
| 5 | 修剪 manifest 逐行 `stat`；且把 `Snapshot/` 当分片扫 | 拖慢 + 静默删数据 | P1 | `ManifestStore.swift:204/271` |
| 6 | `_keep` 无索引 + `NOT IN` 子查询 | 拖慢 | P2 | `ManifestStore.swift:222/245` |

次要项（§7）：恢复阶段计时器在抛错路径不落盘、`open_file_read` 整文件驻留内存、
`RotatingFileSink` 逐行 open/stat/seek/write/close。

---

## 1. 取消标志从未接线：`Stop` 只停住了"等待"，没停住设备侧操作

### 症状

点 Stop 之后：日志显示 `⏹ stop requested`、`⏹ <label>: cancelled by the user — abandoning the call`，
但**设备侧的 backup/restore 还在跑**。随后 `PoCView` 把 `running` 置回 false，
用户以为结束了；如果紧接着再点一次 Run，`runPoC` / `runPartialRestore` 开头的

```swift
try? FileManager.default.removeItem(at: backupRoot)   // PoCEngine.swift:156 / 245
```

会在一个**仍在被 Rust 写盘**的目录上执行 `rm -rf`。

### 根因

`MobileBackup2BackupContext.isCancelled` 是 Rust `is_cancelled` 钩子唯一的取值来源：

```swift
// MobileBackup2Delegate.swift:677
private func mb2_is_cancelled(_ ctx: UnsafeMutableRawPointer?) -> Bool {
    context(ctx)?.isCancelled ?? false
}
```

而全仓 grep 的结果是 **`isCancelled` 只有一处声明、一处读取，没有任何写入**：

```
$ grep -rn "isCancelled" Vendor/MinimuxerGateway/ Vendor/MinimuxerSources/ Nugget/
MobileBackup2Delegate.swift:57:    var isCancelled = false          ← 声明
MobileBackup2Delegate.swift:680:    context(ctx)?.isCancelled ?? false ← 读取
```

`CancelFlag.shared.request()` 只被 `StallGuard` 的轮询循环读到（`StallGuard.swift:134`），
它的作用止于"放弃等待"。`MobileBackup2BackupContext` 根本不知道 `CancelFlag` 存在
（gateway 不依赖 app 层，这个分层是对的——所以要在构造时注入，而不是去读全局）。

### 修复

**(a) 把取消做成注入的闭包**（`Vendor/MinimuxerGateway/idevice/MobileBackup2Delegate.swift`）：

```swift
public final class MobileBackup2BackupContext: @unchecked Sendable {
    ...
    /// Polled by Rust's `is_cancelled` hook.
    ///
    /// Injected rather than read from a global: the gateway must stay
    /// independent of the app's `CancelFlag`, and a `Bool` stored here can never
    /// work — it would have to be written by whichever thread happens to hold
    /// the context, and nothing did.  That is why the Stop button only ever
    /// stopped the *waiting*: `mb2_is_cancelled` answered `false` forever and
    /// the device-side loop never learned to stop.
    private let cancellationRequested: @Sendable () -> Bool

    public init(
        onProgress: (@Sendable (Double) -> Void)? = nil,
        shouldPreserve: (@Sendable (String, String) -> Bool)? = nil,
        onEvent: (@Sendable (String) -> Void)? = nil,
        backupRoot: String? = nil,
        cancellationRequested: @escaping @Sendable () -> Bool = { false }
    ) {
        ...
        self.cancellationRequested = cancellationRequested
    }

    var isCancelled: Bool { cancellationRequested() }
}
```

三个构造点都要传（`IdeviceGateway.swift:2553`、`2621`）：

```swift
let ctx = MobileBackup2BackupContext(
    onProgress: onProgress,
    onEvent: delegateLog,
    backupRoot: backupRoot,
    cancellationRequested: cancellationRequested
)
```

**(b) 两层 API 一起改**（否则调用点报 `extra argument 'cancellationRequested' in call`）：

```swift
// IdeviceGateway.swift — restoreBackup / backupBackup / syncRestoreBackup / syncBackupBackup
public func restoreBackup(
    backupRoot: String,
    sourceIdentifier: String,
    shouldReboot: Bool = false,
    systemFiles: Bool = true,
    onProgress: (@Sendable (Double) -> Void)? = nil,
    delegateLog: (@Sendable (String) -> Void)? = nil,
    cancellationRequested: @escaping @Sendable () -> Bool = { false }
) async throws { ... }

// MinimuxerApi.swift:298 / 320 — 同参数、同转发
func restoreBackup(
    backupRoot: String,
    sourceIdentifier: String,
    shouldReboot: Bool = false,
    systemFiles: Bool = true,
    onProgress: ((Double) -> Void)? = nil,
    delegateLog: ((String) -> Void)? = nil,
    cancellationRequested: @escaping @Sendable () -> Bool = { false }
) async throws {
    try await gw.restoreBackup(..., cancellationRequested: cancellationRequested)
}
```

**(c) 调用点传入真实标志**（`RestoreRunner.swift:40`、`ProtectiveBackup.swift:87`）：

```swift
try await minimuxer.restoreBackup(
    backupRoot: ...,
    sourceIdentifier: sourceIdentifier,
    shouldReboot: false,
    systemFiles: true,
    onProgress: { ... },
    delegateLog: { line in AppLog.write(line) },
    cancellationRequested: { CancelFlag.shared.isRequested }
)
```

**(d) 不要在取消后继续跑后续阶段。** `PoCView.run()` 已经能识别 `.cancelled`，
但 `PoCEngine` 的两个 run 方法在 `ChannelRecovery.retry` 抛出取消后直接向上冒——
这是对的。要补的是**入口闸门**：`runPoC` / `runPartialRestore` 开头
`guard !CancelFlag.shared.isRequested`（在 `clearCancel()` 之后自然成立），
以及 `clearCancel()` 之后不要立刻 `removeItem(at: backupRoot)`——见 §2 的 `InFlightCall`。

### 预期改善

| 项 | 修复前 | 修复后 |
|---|---|---|
| Stop 后设备侧状态 | 继续写，直到自己跑完（分钟级） | Rust 下一次 `is_cancelled` 轮询即停（通常 <1 s） |
| Stop → 再 Run 的窗口 | 新 run 的 `rm -rf` 与旧 run 的写并发 → 备份树损坏 / 载荷丢失 | 不可能发生 |
| 诊断可信度 | 「已停止」的日志与设备实际行为不符 | 一致 |

这条的主要收益是**正确性**，不是速度；它同时是 §2、§3 的前置条件——
取消如果真的生效了，"被放弃的调用"就少了一大类。

---

## 2. 被放弃的调用没有回收闸门：重试会在旧调用仍在飞行时开第二个操作

### 症状

一模一样的失败重试 3 次（`stale-connection-retry-audit` 里最经典的签名），
并且日志里偶尔出现**两套握手**（两段 `attemptPairVerify` / `createListener` 相隔几十毫秒）。
更糟的形态：第一次 restore 其实在设备侧成功了，App 却已判失败并起了第二次。

### 根因

`StallGuard` 的"放弃"是**单方面的**：它只 `once.resume(.failure(...))`，让 Swift 侧返回，
而 `body()` 跑在 `withFFIDispatch { ... }` 里——`DispatchQueue.global()` 上的一个**不可中断的
阻塞 FFI 调用**，还会继续跑到底（`FFIDispatch.swift:15`）。

紧接着 `ChannelRecovery.retry` 做两件危险的事：

```swift
// ChannelRecovery.swift:60-77
case .retry(let floor, let why):
    ...
    await recover(level: level)          // ← 里面第一句就是 invalidateConnection()
    try await Task.sleep(...)            // ← 然后立刻重开一次 body()
```

而 `recover(level:)` 的第一句（`ChannelRecovery.swift:93`）：

```swift
minimuxer.ideviceGateway?.invalidateConnection()
```

`invalidateConnection()` 释放的是**共享的** adapter 与 handshake
（`IdeviceGateway.swift:134-144`：`rsd_handshake_free` + `adapter_free`）。
本仓库自己的注释已经把这个 hazard 写清楚了：

```swift
// IdeviceGateway.swift:694-703
/// Deliberately not `fetchUDID()` / `performWithService`: both call
/// `invalidateConnection()` when a connect fails, which frees the RSD
/// adapter — and clients created from that adapter keep using it
/// (`mountPersonalizedDdiRsd` hands `adapter` to a second FFI call from
/// inside a service action).  ...
/// Freeing the adapter underneath that call to answer the question
/// would defeat the purpose.
```

于是 `.streamStalled` / `.tunnelCrawl` / `.cancelled` 这三条**恰恰是"调用仍在飞行"才产生**的
失败类型，走的正是这条恢复梯子——**在飞行中的调用下面把 adapter 释放掉**。

### 修复

**(a) 加一个飞行中闸门**（新文件 `Nugget/Core/InFlightCall.swift`）：

```swift
import Foundation

/// Records that a Rust call is *still running*, as opposed to "we stopped
/// waiting for it".
///
/// Those are different facts and the retry ladder conflated them.  A Rust read
/// blocked on a socket cannot be interrupted, so `StallGuard` abandons the
/// *wait* — but the call keeps running on `DispatchQueue.global()` and keeps
/// using the shared RSD adapter.  Starting a second operation on top of it,
/// after `recover(level:)` has freed that adapter, is how a run gets two
/// concurrent mobilebackup2 exchanges and a use-after-free at once.
final class InFlightCall: @unchecked Sendable {
    static let shared = InFlightCall()

    private let lock = NSLock()
    private var depth = 0
    private var abandoned = false

    func enter() {
        lock.lock(); depth += 1; lock.unlock()
    }

    func leave() {
        lock.lock()
        depth -= 1
        if depth <= 0 { depth = 0; abandoned = false }   // drained: clean again
        lock.unlock()
    }

    /// The guard walked away from a call that is still running.
    func noteAbandoned() {
        lock.lock(); abandoned = true; lock.unlock()
    }

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return depth > 0 }
    var hasAbandonedCall: Bool { lock.lock(); defer { lock.unlock() }; return abandoned }
}
```

**(b) `StallGuard.run` 记账**（`StallGuard.swift:102-108`），四处 `once.resume(.failure(...))`
之前都要 `InFlightCall.shared.noteAbandoned()`：

```swift
let once = OnceResumer<T>()
return try await withCheckedThrowingContinuation { cont in
    once.attach(cont)
    Task {
        InFlightCall.shared.enter()
        defer { InFlightCall.shared.leave() }      // ← 只有真正返回了才清
        do { once.resume(.success(try await body())) }
        catch { once.resume(.failure(error)) }
    }
    Task {
        ...
        if CancelFlag.shared.isRequested {
            InFlightCall.shared.noteAbandoned()    // ← 我们放弃了，但它还在跑
            once.resume(.failure(TransportFailure.cancelled(label: label)))
            return
        }
        ...
    }
}
```
（`handshakeSilent` / `tunnelCrawl` / `streamStalled` 三处 resume 同样加一句。）

**(c) `ChannelRecovery.retry` 在重试前等它排空，排不空就不重试**：

```swift
case .retry(let floor, let why):
    if attempt >= attempts { ...throw }

    // The abandoned call keeps running on DispatchQueue.global() and keeps
    // using the shared adapter.  recover(level:) frees that adapter, so
    // retrying while it is in flight is worse than not retrying: a second
    // mobilebackup2 exchange starts on a session the first one still holds.
    // Wait, bounded, for it to drain; do not rush it.
    if InFlightCall.shared.isBusy {
        var waited = 0
        while InFlightCall.shared.isBusy, waited < 20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }
        if InFlightCall.shared.isBusy {
            AppLog.write("\(label): the abandoned call is STILL running after \(waited)s — refusing "
                + "to start a second one on the same session (the blocked Rust read cannot be "
                + "interrupted). Reopen the app to get a clean runtime.")
            if let diagnostics { AppLog.write(await diagnostics()) }
            throw error
        }
        AppLog.write("\(label): the abandoned call drained after \(waited)s — recovering and retrying.")
    }

    let delay = min(delaySeconds << UInt64(attempt - 1), 8)
    let level = min(max(floor.rawValue, attempt), RecoveryLevel.restartMuxer.rawValue)
    await recover(level: level)
    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
```

**(d) 同理，`PoCEngine` 两个 run 入口在动手前先看闸门**：

```swift
guard !InFlightCall.shared.isBusy else {
    throw PoCError("A previous device operation is still running after being abandoned. "
        + "Force-quit the app and reopen it before starting another run.")
}
```

### 预期改善

| 项 | 修复前 | 修复后 |
|---|---|---|
| 重试时的并发操作数 | 2（旧的 + 新的） | 1 |
| `invalidateConnection()` 与在飞调用 | 必然重叠 | 排空后才释放 |
| 双握手 / 双会话 | 会出现 | 不会 |
| "重试永远一模一样失败" | 可能是双会话互踩 | 不再由本因造成 |
| 最坏情况耗时 | 3 次 ×3 s 退避 + 3 次无效重试 | 20 s 有界等待后**明确失败并说明**，不再假装重试 |

这是"重试但症状完全一样"这一类的**代码级根因**之一：不是缓存陈旧，是我们在旧调用还在用
adapter 的时候把它释放了。

---

## 3. 诊断块在放弃路径上调用会 `invalidateConnection()` 的读

### 症状

放弃一次长调用之后，日志里紧跟一份 diagnostics 块，然后**下一次尝试的失败模式和上一次逐字节相同**；
或者设备侧出现一次莫名其妙的会话失效。

### 根因

```swift
// Diagnostics.swift:34
let udid = try? await minimuxer.core.fetchUDID()
```

而 `fetchUDID` 在 connect 失败时会释放共享 adapter（`IdeviceGateway.swift:759-761`）：

```swift
if let firstErr = connectErr {
    idevice_error_free(firstErr)
    invalidateConnection()          // ← 同一个 hazard
```

`Diagnostics.report()` 的调用点正是"刚放弃一个还在飞的调用"：

```swift
// ChannelRecovery.swift:57（.failFast：取消、握手静默）
if let diagnostics { AppLog.write(await diagnostics()) }
// ChannelRecovery.swift:63（重试用尽：停滞、隧道爬行）
if let diagnostics { AppLog.write(await diagnostics()) }
```

也就是说：**§2 的整改对象里，诊断块自己也在做同样的事**——用一次探测把在飞调用的 adapter 拆掉。
`probeLockdownAlive()` 的注释（`IdeviceGateway.swift:696-703`）已经说明了正确做法，
而 `Diagnostics.report()` 却没照做（它调 `fetchUDID()`，而文件里另外那个
`deviceLivenessProbe()` 才是只读的）。

附带问题：`report()` 对**整个** `minimuxer.log` 走三遍——
`excerpt()` 一遍（`Data(contentsOf:)` + 全量 UTF-8 解码 + 40 个关键字 contains + 全部行的
DL 直方图）、`tail()` 又一遍全量读、`transportLine(lines)` 再把所有行扫一遍。

### 修复

```swift
static func report() async -> String {
    let minimuxer = Minimuxer.shared()
    var lines: [String] = ["── diagnostics ──"]

    // Snapshot the Rust evidence FIRST — these probes write into the very same
    // log we are about to read (see the note at the top of this file).
    let logStatus = RustLog.status()
    let excerpt = RustLog.excerpt()
    let tail = RustLog.tail(30, since: RustLog.mark)

    lines.append("  tunnel: \(Tunnel.describe())")
    lines.append("  peer \(Tunnel.peerIP):\(Tunnel.servicePort) reachable: \(Tunnel.probePeer())")
    if let gw = minimuxer.ideviceGateway {
        lines.append("  gateway endpoint IP: \(gw.deviceEndpointIp ?? "nil")")
    } else {
        lines.append("  gateway: not IdeviceGateway")
    }
    lines.append("  pairing type: \(minimuxer.core.getPairingFileType())")

    // Nothing below may reach for `fetchUDID()` / `performWithService`:
    // both call `invalidateConnection()` when a connect fails, which frees the
    // RSD adapter — and the whole reason this dump exists is that a long
    // mobilebackup2 call may still be parked on it (the very hazard
    // `probeLockdownAlive`'s doc describes).  When a call IS still in flight,
    // do not touch the session at all: dump the log evidence and say so.
    if InFlightCall.shared.isBusy {
        lines.append("  session probes: SKIPPED — an abandoned device call is still in flight; "
            + "probing it would free the adapter it is still using")
    } else {
        let alive = await deviceLivenessProbe()          // read-only, no invalidate
        lines.append("  lockdown: \(alive.alive) — \(alive.detail)")
        if case .success(let ready) = await minimuxer.core.isReady(withNetworkCheck: true) {
            lines.append("  isReady: \(ready)")
        } else {
            lines.append("  isReady: FAILED")
        }
    }
    lines.append("  rust log: \(logStatus)")
    lines.append("  wire: \(WireCensus.healthLine())")
    ...
}
```

注：`isReady(withNetworkCheck: true)` 也要按同样标准核一遍内部是否走 `fetchUDID`；
若是，则一并换成只读探针。

**顺手去掉一次全量读**：`excerpt()` 与 `tail()` 各自 `Data(contentsOf:)` +
`String(data:)`。改成读一次、两个视图共用：

```swift
static func evidence(maxLines: Int = 90, tailCount: Int = 30) -> (excerpt: String, tail: String) {
    guard let whole = try? Data(contentsOf: url) else { ... }
    let from = Int(min(mark ?? 0, UInt64(whole.count)))
    guard let text = String(data: whole.dropFirst(from), encoding: .utf8) else { ... }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    return (excerpt(from: lines, offset: from), tail(from: lines, count: tailCount))
}
```

### 预期改善

| 项 | 修复前 | 修复后 |
|---|---|---|
| 诊断时是否可能拆掉在飞调用的 adapter | 会 | 不会（有在飞调用时完全跳过探针） |
| 诊断对日志文件的读取次数 | 2 次全量读 + 2 次 UTF-8 解码 | 1 次 |
| 放弃路径的总代价 | 全量读 ×2 + RSD 往返 ×2 + 一次 `invalidateConnection()` | 一次全量读 |

---

## 4. 握手静默检测每 5 s 重读并解码**整个** `minimuxer.log`

### 症状

"卡住"和"只是慢"分不清的时间变长；设备越慢/日志越大，App 自己越慢。
在不丢包的运行里表现为整体吞吐比预期低；在丢包运行里恰好与其他问题叠加。

### 根因

`StallGuard` 的轮询循环**每一轮**都调用 `handshakeSilent()`（默认 `pollSeconds = 5`）：

```swift
// StallGuard.swift:143-159（每 5 s 无条件执行）
if let handshakeSilent {
    if handshakeSilent() { ... }
}
```

```swift
// RestoreRunner.swift:38 / ProtectiveBackup.swift:85
handshakeSilent: { RustLog.deviceSilentAtHandshake() }
```

```swift
// RustLog.swift:248
static func deviceSilentAtHandshake(since offset: UInt64? = nil) -> Bool {
    let from = offset ?? mark
    guard let whole = try? Data(contentsOf: url) else { return false }   // ← 全文读
    let start = Int(min(from ?? 0, UInt64(whole.count)))
    guard let text = String(data: whole.dropFirst(start), encoding: .utf8) else { return false } // ← 全文解码
    guard let lastStart = text.range(of: "Starting DeviceLink version exchange",
                                     options: .backwards) else { return false }
    return !text[lastStart.upperBound...].contains("Received DL message")
}
```

没有 `maxChunk` 上限（`WireCensus` 有 4 MB 上限），而且多做一次全量 UTF-8 解码。
**这正是 `WireCensus` 已经被修过的那个反模式**——`WireCensus.swift:56-67` 的注释原话：

> Re-reading and re-scanning a 2 MB window per poll — millions of byte comparisons,
> on the same device that is trying to drain a UDP tunnel — is load added precisely
> when the tunnel is least able to absorb it.

同类负载在 `deviceSilentAtHandshake` 里被漏掉了，而且比当初的 `WireCensus` 更重
（全文无上限 + 解码，而不只是字节比较）。触发条件是**必然**的：每一轮都跑，与是否停滞无关。

### 修复

把手势判定折进已经存在的增量 tailer——**一次扫描同时服务心跳、停滞判定和握手判定**。

**(a) `WireCensus.swift`：给样本加两个计数器**

```swift
struct RustWireSample: Sendable {
    ...
    /// `Starting DeviceLink version exchange` lines seen this run.
    var handshakeStarts = 0
    /// `Received DL message` lines since the last `handshakeStarts` line.
    ///
    /// Both literals arrive through the same scan, in log order, so one
    /// incremental pass answers the handshake question that used to cost a
    /// whole-file read plus a whole-file UTF-8 decode every 5 s.
    var dlReceivedSinceHandshakeStart = 0

    /// Parked in `dl_version_exchange()` waiting for the device's FIRST
    /// DeviceLink message: a version exchange started and nothing has arrived
    /// since.  This side has sent nothing at that point, so no client-side
    /// change can be the cause — it can only be the device daemon.
    var handshakeSilent: Bool {
        handshakeStarts > 0 && dlReceivedSinceHandshakeStart == 0
    }
}
```

**(b) `absorb` 里维护它们**（`WireCensus.swift:136`）：

```swift
static func absorb(_ lines: [Substring], into sample: inout RustWireSample) {
    for line in lines {
        if line.contains("Starting DeviceLink version exchange") {
            sample.handshakeStarts += 1
            sample.dlReceivedSinceHandshakeStart = 0   // a NEW attempt started
        }
        if line.contains("Received DL message") {
            sample.dlMessages += 1
            sample.dlReceivedSinceHandshakeStart += 1
        }
        if line.contains("Sending device link message") {
            sample.dlMessages += 1
        }
        guard line.contains("out-of-order seq=") else { continue }
        ...
    }
}
```

（注意 `wireMarkers` 原来是一个数组 + `contains(where:)`；上面的写法保留了语义，
但把 `"Received DL message"` 单独拿出来是因为它必须同时喂第二个计数器。）

**(c) `RustLog.deviceSilentAtHandshake()` 变成两行**：

```swift
/// True when the mobilebackup2 client is parked in `dl_version_exchange()`
/// waiting for the device to speak first.
///
/// This used to read and UTF-8-decode the WHOLE log on every stall-guard poll
/// (every 5 s), on the device that is simultaneously draining the tunnel — the
/// same reverse load `WireCensus` was fixed for, and heavier (no chunk cap, plus
/// a full decode).  The counters now ride the tailer that is already scanning
/// those bytes, so the check costs nothing and the guard can poll it freely.
///
/// Fail-safe direction: if more than `maxChunk` was appended between polls the
/// tailer skips ahead and may miss the handshake line, which reads as
/// "not silent" — i.e. it falls back to the long idle path and can never kill a
/// live run.
static func deviceSilentAtHandshake() -> Bool {
    WireCensus.shared.read().handshakeSilent
}
```

`since offset:` 参数可以直接删掉——grep 确认两个调用点都传的是默认值。

**(d) 顺手把两处 `Data(contentsOf:)` 常量集中一下**：`WireCensus.maxChunk` 的 4 MB 上限
已经是这个项目里"最多读多少"的口径，让所有增量读取都用它。

### 预期改善

| 项 | 修复前 | 修复后 |
|---|---|---|
| 每 5 s 的日志 I/O | 全文读（无上限） | 只读新增字节，通常几十 KB |
| UTF-8 解码 | 每次轮询全文一次 | 只解码新行 |
| 内存抖动 | 每次轮询分配/释放文件大小级别的两块缓冲 | 只有新行缓冲 |
| 随日志增长 | 线性变差（长跑越跑越慢） | 基本持平 |
| 判定延迟 | 45 s（`silentHandshakeSeconds`） | 不变（可安全下调，因为检查变免费了） |

这一条同时也是**诊断准确性**的收益：轮询不再与传输抢同一台设备的 CPU/IO 时，
"到底是谁慢"这个问题才有答案。

---

## 5. 修剪 manifest：逐行 `stat` + 把 `Snapshot/` 当分片扫（并静默删掉暂存载荷）

`ManifestStore.pruneToDiskState()` 有两个独立的问题。

### 5a. Phase 1 每个文件行一次 `fileExists`，并且每次现拼两个 `URL`

```swift
// ManifestStore.swift:204-218
while sqlite3_step(stmt) == SQLITE_ROW {
    ...
    } else if FileManager.default.fileExists(atPath: payloadURL(forFileID: fileID).path) {
```

`payloadURL(forFileID:)`（`:59`）内部是两次 `appendingPathComponent`，即两次 URL 分配。
所以每一行 = 2 次分配 + 1 次 `stat`。整机过滤备份的 manifest 规模按仓库自己的注释
（`MobileBackup2Delegate.swift:217` 提到 `filtered payloads: 28490`）是 **1e5 量级**的行数
→ 十几次万系统调用 + 二十几万次分配，全部同步、串行。

**修复：把方向倒过来——遍历一次分片树，得到"盘上有哪些 fileID"，再和行比对。**

```swift
// Phase 1: collect the payload tree ONCE instead of stat()ing per row.
//
// This used to call fileExists once per Files row, each time building two
// fresh URLs — on a filtered whole-device backup that is ~1e5 stat() calls
// plus ~2e5 URL allocations, all synchronous.  The payload tree is a flat
// two-hex-char shard layout, so one directory walk answers the same question
// in ~256 readdir calls.  removeOrphanPayloads() needs the same set anyway.
let fm = FileManager.default
var payloadsOnDisk = Set<String>()
if let shards = try? fm.contentsOfDirectory(atPath: deviceDir.path) {
    for shard in shards where ManifestSchema.isShardName(shard) {
        if let names = try? fm.contentsOfDirectory(
            atPath: deviceDir.appendingPathComponent(shard).path) {
            payloadsOnDisk.formUnion(names)
        }
    }
}
...
while sqlite3_step(stmt) == SQLITE_ROW {
    ...
    if flags == 2 { keepIDs.append(fileID) }            // directory rows never have a payload
    else if payloadsOnDisk.contains(fileID) { keepIDs.append(fileID) }
}
```

加一个**精确**的分片判据（`ManifestSchema`，也就是唯一放 schema 规则的地方）：

```swift
/// A payload shard is exactly two lowercase hex characters — that is what
/// `fileID.prefix(2)` produces.  Everything else under the backup directory is
/// not a shard: `Manifest.db`, `Manifest.plist`, `Status.plist`, `Info.plist`,
/// and the device's `Snapshot/` staging tree.
static func isShardName(_ name: String) -> Bool {
    let utf8 = name.utf8
    guard utf8.count == 2 else { return false }
    return utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
}
```

### 5b. `removeOrphanPayloads` 把任何顶层目录都当成分片——包括 `Snapshot/`

```swift
// ManifestStore.swift:271-293
guard let shards = try? fm.contentsOfDirectory(atPath: deviceDir.path) else { return 0 }
for shard in shards {
    let shardDir = deviceDir.appendingPathComponent(shard)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: shardDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
    if let payloads = try? fm.contentsOfDirectory(atPath: shardDir.path) {
        for payload in payloads where !keepIDs.contains(payload) {
            try? fm.removeItem(at: shardDir.appendingPathComponent(payload))   // ← 递归删
```

`Snapshot/` 就在 `deviceDir` 下（`ProtectiveBackup.swift:163-164` 明确写了
`AppPaths.deviceDir(...).appendingPathComponent("Snapshot")`），它是目录、内容名不是 fileID，
于是**暂存树里所有未被提交的载荷会被静默递归删除**，连 `Snapshot/` 目录本身一起
（`if remaining.isEmpty { removeItem(at: shardDir) }`）。

后果：

1. `reportStagingLeftovers()`（`ProtectiveBackup.swift:162`，就在 prune 之前几行）刚刚
   打出的 "⚠️ N file(s) left under Snapshot/ — staged but never committed"
   **在下一个阶段被自己删掉**——证据在同一个 run 里消失。
2. 该注释自己说 "if the prune does not account for them the restore will fail"，
   而 prune 的做法是让它们物理消失，于是失败原因更难反查。

**修复：分片判据 + 只删分片，`Snapshot/` 留给 `reportStagingLeftovers` 说话。**

```swift
/// Phase 3: remove payload files that no keep row references.
///
/// Only real shards are swept.  The first version treated every directory under
/// the backup as one, which included the device's `Snapshot/` staging tree —
/// so payloads the device staged but never committed were recursively deleted
/// here, i.e. the shortfall `reportStagingLeftovers()` had just reported was
/// erased by the next stage of the same run.  Off-shard directories are left
/// alone on purpose: they are evidence, and the manifest check already drops
/// the rows that reference them.
private func removeOrphanPayloads(shardNames: [String], keepIDs: Set<String>) -> Int {
    let fm = FileManager.default
    var removed = 0
    for shard in shardNames where ManifestSchema.isShardName(shard) {
        let shardDir = deviceDir.appendingPathComponent(shard)
        guard let payloads = try? fm.contentsOfDirectory(atPath: shardDir.path) else { continue }
        for payload in payloads where !keepIDs.contains(payload) {
            guard ManifestSchema.isShardName(String(payload.prefix(2))) else { continue }
            try? fm.removeItem(at: shardDir.appendingPathComponent(payload))
            removed += 1
        }
        if let remaining = try? fm.contentsOfDirectory(atPath: shardDir.path), remaining.isEmpty {
            try? fm.removeItem(at: shardDir)
        }
    }
    return removed
}
```

并把 `reportStagingLeftovers` 的结论也带进诊断块（现在只在 `ProtectiveBackup` 的日志里）：

```swift
let leftover = stagingLeftoverCount(backupRoot: backupRoot, udid: udid)
if leftover > 0 {
    AppLog.write("⚠️ \(leftover) staged payload(s) were never committed — the restore below runs "
        + "on a partial backup. They are kept under Snapshot/ for inspection (not swept).")
}
```

### 预期改善

| 项 | 修复前 | 修复后 |
|---|---|---|
| Phase 1 系统调用 | ~1e5 × `stat` + ~2e5 次 URL 分配 | ~256 次 `readdir` |
| Phase 1 量级 | O(manifest 行数) | O(分片数 + 载荷数) |
| 暂存未提交载荷 | 被静默递归删除 | 保留，且明确计数上报 |
| 关闭时的重复开销 | 孤儿遍历 + 空目录清理各一遍 | 与 Phase 1 共用同一次遍历的结果 |

（这个阶段在 `runPartialRestore` 里是**默认路径**上的一步，所以它省下的时间是每次运行都付的。
在 1e5 行量级的 manifest 上，从"十几次万次系统调用"降到"几百次"，是这条链路里最直接的
一轮纯耗时削减。）

---

## 6. `_keep` 临时表没有索引，`NOT IN` 子查询没有保证

```swift
// ManifestStore.swift:221-250
sqlite3_exec(db, "CREATE TEMP TABLE IF NOT EXISTS _keep (fileID TEXT)", nil, nil, nil)
...
guard sqlite3_exec(db, "DELETE FROM Files WHERE fileID NOT IN (SELECT fileID FROM _keep)", ...)
```

`_keep` 声明为普通表，`Files.fileID` 是 `PRIMARY KEY`（于是有隐式索引），
但反过来的成员判定没有索引可供使用。SQLite 通常会为 `IN` 子查询物化一个临时索引，
所以这**不是必然**的 O(N·M)——但这是依赖规划器的行为，不是 schema 保证的；
一旦退化成 nested loop，1e5 × 1e5 就是整条流程里最大的单项。

**修复：声明主键（顺带 `DELETE` 之前不需要额外的 `DROP` 保护）**

```swift
static let createKeepTable =
    "CREATE TEMP TABLE IF NOT EXISTS _keep (fileID TEXT PRIMARY KEY)"
```

这样成员判定走 B-tree，代价从"取决于规划器"变成确定的 O(N log M)；
`INSERT INTO _keep` 的循环（已经在外层事务里、语句已经 prepare 一次）也不受影响。

### 预期改善

| 项 | 修复前 | 修复后 |
|---|---|---|
| `DELETE ... NOT IN` 复杂度 | 依赖规划器，最坏 O(N·M) | 确定 O(N log M) |
| 最坏情况 | 大 manifest 上单步耗时不可预测 | 与 manifest 规模近线性 |

---

## 7. 次要项（低风险，顺手修）

| 项 | 位置 | 问题 | 修法 |
|---|---|---|---|
| 恢复阶段计时器在失败路径不落盘 | `RestoreRunner.swift:59-60` | `beat.stop()` / `stage.done()` 在 `try await` 之后，抛错即跳过。本仓库在 `ProtectiveBackup.swift:117-124` 明确说过"缺失的阶段行让最宽的窗口无法解释" | 包成 `defer { beat.stop(); stage.done(failure ? "FAILED" : "") }`，或用 do/catch（`ProtectiveBackup` 就是这个形状，照抄） |
| `open_file_read` 让整个文件驻留内存并复制两次 | `MobileBackup2Delegate.swift:448-461` | `FileManager.contents(atPath:)` 先 alloc+read，再 `malloc` + `copyBytes` → 峰值内存 = 文件大小，且每个文件多一次全量 memcpy。恢复大载荷（视频/大容器）时是 jetsam 风险，不是吞吐问题 | 用 `open`/`fstat`/`read` 直接读进 `malloc` 的缓冲：一次复制、峰值不变但少一块中间 `Data`（避免 2× 瞬时占用） |
| `RotatingFileSink` 每行 open+stat+seek+write+close，且持全局锁 | `Logging.swift:32-53` | 每行 ~6 次系统调用，在 `AppLog` 的进程级锁内。当前调用点已被限流（delegate 的 `reportEvent` 每 50/200 条一次、心跳 10 s），所以不是热点；但超过 2 MB 时的轮转会在锁内 `Data(contentsOf:)` 全量读 + 写回一半 | 持有长开的 `FileHandle` + 内存里记 size；轮转改为分段截断；`print` 用 `#if DEBUG` 包住（设备上 console 不可达，等于丢弃） |
| UI 日志行身份不稳定 | `PoCView.swift:176-181` / `344-352` | `ForEach(Array(logs.enumerated()), id: \.offset)`：`logs.removeFirst(...)` 之后所有行 identity 平移，SwiftUI 每行都重建 | 单调递增 id（`struct LogLine: Identifiable { let id: Int; let text: String }`），并按批裁剪（一次裁掉 100 行）而不是每行裁 1 |

---

## 8. 建议的落地顺序

1. **§1 + §2 + §3 一起做**（同一件事的三个面：让取消真的生效、让重试不在在飞调用上叠加、
   让诊断不再拆自己的会话）。这三条不做，后面所有"重试策略"的调整都建在沙子上。
2. **§4**（纯收益、风险最低：删掉一次全文读+解码，判定改读现成计数器）。
3. **§5a + §6**（修剪阶段的一次性耗时削减）。
4. **§5b**（保留暂存证据；与 §5a 共用同一次遍历，所以一起改最省）。
5. §7 按需。

## 9. 验证

- `scripts/typecheck.sh` —— **0 error 才算过**。注意它按 mtime 挑最新的
  `Products/{Debug,Release}-iphoneos`，改了 `Vendor/` 必须重新构建，否则报假阳性；
  必须 `-disable-dependency-sandbox`，且**不要用 `| head` 看日志**（SIGPIPE 截断 = 假绿灯）。
- §5a 的验收：在一份真实 manifest 上对比 `fileExists` 调用次数——
  修前应该约等于行数，修后应该约等于载荷数，且 `Pruned Manifest.db: …` 那行
  `kept` 数字保持一致（行为不变是硬要求）。
- §4 的验收：在同一次运行里对比 `handshakeSilent()` 前后 `minimuxer.log` 的读取字节数
  （可以用 `fs_usage` 或临时计数），应该从"每次 ≈ 文件大小"降到"每次 ≈ 新增字节"。
- §2 的验收：故意触发一次停滞/取消，日志里应该出现
  `the abandoned call drained after Ns` 或
  `refusing to start a second one on the same session`，而**不应该**出现两次
  `Starting DeviceLink version exchange` 相隔几十毫秒的成对握手。
- §1 的验收：点 Stop，然后在设备侧观察 backup daemon 是否在下一次轮询内停止推进
  （`minimuxer.log` 的 DL 消息计数应在 1 s 内停止增长），而不是继续跑到底。
