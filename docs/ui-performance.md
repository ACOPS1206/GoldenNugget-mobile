# UI 性能：审计、已修与待办（2026-09-26）

> 目标：找出"卡顿 / 响应缓慢"的真实来源，而不是猜测。**本机不能真跑**（无设备、无 Instruments），所以
> 结论来自静态审计 + 逐条代价推理，每条都给 `file:line`；已改的三项都是"按构造即可判定"的改动
> （见 §3 的效果论证）。真机量化方法见 §5。

## 1. 结论排序（按真实代价，不按代码行数）

| # | 来源 | 机制 | 代价 | 状态 |
|---|---|---|---|---|
| 1 | **`mediaDetail` 在 `body` 里读盘 + JSON 解码** | `GoldenNuggetView` 的 Media 卡片徽标调用 `AfcMediaBackup.read()`（`Data(contentsOf:)` + `JSONDecoder().decode`），它在 `body` 里，**每次渲染都跑一次**，在主线程 | 媒体清单按每个已拉文件一条记录，几千条就是几百 KB～MB 级 JSON ⇒ **每次渲染数毫秒～数十毫秒** | **已修**（源头 memoize） |
| 2 | **一行日志 = 整页重渲染** | `logs: [String]` 是 `GoldenNuggetView` 的 `@State`，`AppLog` 的 UI handler 每行 append 一次 ⇒ 每行触发整页 `body` 重算，第 1 条随之再跑一遍 | 一次运行 10² 数量级的日志行（进度、delegate 账、重试、诊断块）⇒ 10² 次整页重算，每次都附带第 1 条那次读盘 | **已修**（日志独立 store） |
| 3 | **长列表不是惰性的** | `GoldenPage` 的内层是 `VStack`：页面一出现就把**所有**行都建出来并常驻。Tweaks 页单是 Liquid Glass 就 98 个子卡（每张 = 标题 + 开关/输入框 + id + 说明），Files 每个条目 3 行 | 首次绘制 + 之后任何 diff 都在为屏幕外的行付费 | **已修**（`LazyVStack`） |
| 4 | **`MediaView.hasStoredFiles` 每渲染走两遍目录树** | 该谓词遍历 store 找 `.afcpartial`，却写在两个 `.disabled(...)` 里 ⇒ 每次重渲染**两次**全树遍历，主线程 | 文件越多越慢（拉过一次媒体后就是几千个文件） | **已修**（算一次进 state） |
| 5 | 日志窗口滑动时 identity 全体位移 | `ForEach(Array(lines.enumerated()), id: \.offset)`：`removeFirst` 后每个 offset 都变 ⇒ 600 行全部**重建** | 只在超过 600 行后发生，正好是长运行的后半段 | **已修**（稳定 id） |
| 6 | `TweaksView` 每次渲染过滤目录 4 遍 | `visibleSpecs`（133 × `isCompatible`，内含版本字符串 split）被 `.count` 与 3 个分节各调一次 | 微秒级，**噪声** | 不修（见 §4） |
| 7 | `DaemonsView` 每渲染按分节过滤 `DaemonGroups.all` | 同上量级 | 噪声 | 不修 |
| 8 | `MemoryLogSink` 无上限 | 设计如此（诊断尾巴要用它）；视图侧曾有 600 窗口 ✓ 现在窗口在 `RunLog` | 只在 dump 诊断时复制整个数组 | 保持 |

第 1、2 条是同一个根因的两半：**`body` 里做了 I/O**，而**高频事件（日志）又落在页面状态上**，于是读盘被乘以日志行数。

## 1.5 第二轮：用户反馈"还是慢"后找到的两条（先看这个）

用户复测：**打开一个 NavigationLink 要等约 3 秒，滑动主页有时卡死**。原表里漏掉了两条更重的。

| # | 来源 | 机制 | 代价 | 状态 |
|---|---|---|---|---|
| **0** | **`Tunnel.probePeer()` 在 `body` 里**（主页隧道详情那一行） | `Tunnel.probePeer` = 非阻塞 `connect` + `poll(fd, POLLOUT, timeout*1000)`，**默认 `timeout: 2.0`**（`Tunnel.swift:234-260`），被直接插值进 `GoldenStatusText`（`GoldenNuggetView.swift:399` 改前）。于是**只要该 DisclosureGroup 展开**，任何一次 body 求值（滚动触发的惰性行创建、任意状态变化、点 NavigationLink 时页面重渲染）都可能在主线程停 **最多 2 秒** | 主线程 2 秒 = 滚动冻结；也是"3 秒才打开页面"的大头 | **已修** |
| **3'** | **上一轮的 `LazyVStack` 其实没解决问题** | 每个分节把行包在 `VStack` 里再作为**一个** `AnyView` 交给分节视图 ⇒ 惰性栈只看到"一个孩子"，仍会把该分节**全部**行建出来。用户这次恢复了 **172 个 tweak**（三节默认全开）⇒ 打开 Tweaks 页要同步构造 133 张卡（每张一个控件）；Files 的列表同理（每条目 3 行） | 首帧/推入时数百毫秒级，且在 3s 里占一部分 | **已修**（把"表头"与"行"拆成**兄弟**节点） |

修法：

- 隧道状态两半（`describe()` 与 `probePeer()`）改为 **state**，由 `refreshTunnelStatus()` 在
  `Task.detached` 里填充；只在**详情展开时**用 `.task(id: tunnelExpanded)` 每 5 秒探一次（收起即取消），
  另在头部刷新按钮与"Reset tunnel addresses"后各刷一次。body 里只剩字符串插值。
- `GoldenCollapsibleSection`（表头 + 内容包在 `VStack` 里）→ **`GoldenCollapsibleHeader`**：调用方把
  表头与 `if !collapsed { ForEach(rows) { … } }` 作为**兄弟**直接放进页面内容，行因此成为页面
  `LazyVStack` 的独立子节点，真正按需构造。Tweaks 与 Daemons 两页同时改，间距相同（都是 8 pt）所以
  视觉不变。
- Files 的 `Contents` 列表同样拆成 `GoldenSectionHeader` + 裸 `ForEach(entries)`。

> 用户日志里同时能看到**上一轮修的那个竞态**：`getLockdownValue(ProductVersion) … verifyInitialized()
> failed: Gateway has not been initialized`（14:57:03）——正是"页面先读到空身份 ⇒ 引擎当初走了 iOS 26
> 分支"的那次读。`readDevice()` 的有界重试与 `resolvedDeviceVersion` 已经覆盖它，这里不是新问题。
>
> 日志里其余的系统噪声（`cannot add handler to 0 from 0 - dropping`、`LaunchServices … process may not
> map database`、`personaAttributesForPersonaType failed`、`Gesture: System gesture gate timed out`）
> 是侧载进程的 launchd/LS/XPC 抱怨，不是本 app 的开销。

## 2. 证据（逐条）

- `AfcMediaBackup.read()`：`Nugget/Core/AfcMediaBackup.swift:339`（改前）= `Data(contentsOf: manifestURL)` + `JSONDecoder().decode(Manifest.self, …)`；调用点 `Nugget/Views/GoldenNuggetView.swift:178-184`（`mediaDetail`），该属性在 `tweakCards` 的 Media 卡片里用作 `detail:` ⇒ 在 `body` 里。旁边那行注释写着"read from the manifest rather than a directory walk, so it costs nothing on every body pass"——**前半句对，后半句是错的**。
- 日志：`Logging.swift:145` 把 UI handler `DispatchQueue.main.async` 派发；`GoldenNuggetView.swift:876-884`（改前）在 handler 里 `logs.append` + `logs.count > 600 { removeFirst }` ⇒ `@State` 写入 ⇒ 整页失效。
- 非惰性列表：`GoldenComponents.swift:17-35`（`GoldenPage`，改前为 `VStack`）；行源见 `TweaksView.swift:151-165`（`ForEach(specs)`）与 `FilesView.swift:143-196`。
- `MediaView` 的两次遍历：`MediaView.swift:56,60,75`（三处 `.disabled` 里的 `hasStoredFiles`）。
- 滑动窗口 identity：`GoldenComponents.swift` 的 `GoldenLogView`（改前 `id: \.offset`）。

## 3. 已改（三项 + 两个附带）

| 改动 | 文件 | 为什么这样改是安全的 |
|---|---|---|
| 新增 `RunLog`（`ObservableObject`，按线程加锁的 buffer + 合并 flush）与 `RunLogCard`（**唯一**观察者） | `Nugget/Views/RunLog.swift`（新） | 页面不再读日志 ⇒ 一行日志只让那张卡重算；`append` 可从任意线程进（引擎回调今天在主队列，store 不依赖这点），突发合并成一次主队列 flush；不丢行 |
| 主页 `logs` 全部改走 store；`spawnLogPrinter`、诊断 dump、两个"开始运行"清空点；日志区无条件放入 `RunLogCard()`（空时它自己什么都不画） | `GoldenNuggetView.swift` | 行为等价：窗口仍是 600 行，诊断块仍作为一条多行条目追加；`grep` 确认全仓只有一处设置 `onLog`，不会互相覆盖 |
| `AfcMediaBackup.read()` 按"文件 size+mtime"缓存解码结果 | `AfcMediaBackup.swift` | `write` 用 `.atomic` 写：任一保存都会改变 size 或 mtime ⇒ 下次读重新解码（不会读到旧值）；文件不存在时按 `<absent>` 键缓存一个空清单 ✓ 语义与原来一致，只是不再每次解码 |
| `MediaView.hasStoredFiles` 改成 state，`loadManifest()` 里算一次（拉取路径也补了一次） | `MediaView.swift` | 谓词本身一字未改；触发时机与原逻辑一致（进入页面 / 每个动作结束） |
| `GoldenPage` 内层 `VStack` → `LazyVStack` | `GoldenComponents.swift` | 同样受 `maxWidth` 约束与居中；子视图的 `.onAppear`/`.task` 改为"出现时才跑"，对输入框草稿、日志卡都是期望语义 |
| `GoldenLogView` 用稳定 id（新增可选 `firstId`） | `GoldenComponents.swift` | 静态调用点（Tweaks 页的 30 行、Media 页的动作日志）不传 ⇒ 默认 0，行为不变 |

**效果论证（可复核，不需要 profiler）**：第 1、2 条修完后，一次运行的渲染次数从"1 + 日志行数"变成"1"，
而 `body` 里再也**没有**重活。复核命令：

```bash
grep -nE "contentsOf|JSONDecoder|enumerator|attributesOfItem|AfcMediaBackup\.read" Nugget/Views/*.swift
```

改后只剩四处，逐一看都是允许的：`GoldenComponents.swift:505-507`（`GoldenLogo` 的
`static let bundledIcon`，**一次性**加载）、`GoldenNuggetView.swift:183`（`mediaDetail` ⇒ 现在只是
`AfcMediaBackup.read()` 的 **`stat`**，解码已被 §3 的缓存吃掉）、`MediaView.swift:28,47`（都在
`loadManifest()` / `storeHasFiles()` 里，由 `.task` 或动作调用，**不在 `body`**）、其余命中都在
配对文件与预设导入等**动作**里。第 3 条让屏幕外的行不再被构造，这是首帧与 diff 的直接减少。

## 4. 看过但决定不改的（附理由）

- **`visibleSpecs` 每次渲染算 4 遍**（`TweaksView.swift:114,151`）：可以改成"父级算一次、按参数传下去"，
  但一次 = 133 × 版本字符串比较，量级是微秒 ⇒ 属于噪声。要改就等真机 Instruments 显示它是热点再改。
- **`TweakVersion.components` 每次都 split 字符串**：同上，量级更小；给它做 memo 只增加状态。
- **`DaemonsView` 的分节过滤**：同上。
- **`MemoryLogSink` 不设上限**：设计决策（诊断尾巴需要完整），视图侧已有窗口。
- **`AppLog` 每行一次 `DispatchQueue.main.async`**：`RunLog` 已把突发合并；要彻底消除得改 `AppLog` 的
  派发策略，而那会影响多处调用点，收益不如现在这条。

## 5. 真机上怎么量化（下一步）

1. **Instruments → SwiftUI** 模板（Xcode 27 自带"View Body"轨道）：先记 `GoldenNuggetView` /
   `TweaksView` 的 body 次数基线，跑一次 apply，对比改动前后。期望：改动前 ≈ 1 + 日志行数，改动后 ≈ 1。
2. **Time Profiler** 抓一次 apply：看主线程上 `JSONDecoder.decode` / `contentsOf` / `enumerator(atPath:)`
   是否还在栈上——改动后 `/Views/` 下不应再有这些符号。
3. **首帧**：进入 Tweaks 页（Liquid Glass 展开）时用 `os_signpost` 或 Instruments 的
   "Hangs / Animation Hitches" 看首帧时长；`LazyVStack` 之前它是"98 张卡全部构造"。
4. App 自带通道：`Share poc.log` / `Share diagnostics.txt`（`RunLog` 的 600 行窗口 + 引擎内存 sink 的
   完整尾巴）就是"发生了什么"的现场，改动不改变它们的可用性。
