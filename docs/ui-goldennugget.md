# UI：GoldenNugget Mobile 设计系统移植

> **状态：已落地（2026-09-25）。** `scripts/typecheck.sh` **0 error，未新增 warning**
> （35 sources，改动前 33）。**只在真机上跑过一版旧外观**，新版外观未上机（本机不能构建）。
>
> 功能与信息结构**一处未改**：所有绑定、动作、字符串、日志、弹窗、文件选择器、分享项都保持原样，
> 变的只有配色、字体、组件样式、间距与布局。

承接方：`Nugget/Views/GoldenTheme.swift`（令牌）、`Nugget/Views/GoldenComponents.swift`（组件）、
`Nugget/Views/PoCView.swift`（主页面）、`Nugget/Views/TweaksView.swift`（Tweaks 页）。
参照：`~/GoldenNugget` 的 **iOS GUI**——那是 GoldenNugget Mobile 外观唯一被写下来的地方。

---

## 1. 参照的三个文件

| 参照 | 提供了什么 |
|---|---|
| `src/gui/theme/colors.py` | `DARK` 主题的**全部颜色槽**（bg/text/accent/semantic/border）。iOS GUI 默认就是这个主题 |
| `src/gui/theme/styles.py` | 组件样式：圆角、内边距、字号/字重、字距、开关轨道色、按钮渐变、`section_header`/`settings_row`/`primary_button`/`danger_button`/`value_label`/`safety_note`/`home_*`/`process_status_*` |
| `src/gui/ios/components.py` | 移动端组件集与固定尺寸：`IOSCard` `IOSNavBar`(56) `IOSSectionHeader` `IOSSettingsRow` `IOSPrimaryButton`(50) `IOSDangerButton`(50) `IOSSwitch`(51×31) `IOSValueLabel`、home 的 logo 80×80/圆角 14 |
| `src/gui/ios/home.py` · `tweaks.py` | 两个页面的**布局本身**：页边距/间距、`_CardGrid` 的响应式回流规则（`MIN_CARD_WIDTH=200`、`SPACING=12`）、卡片 56pt 头部带、sections 的渲染顺序 |

## 2. 颜色（逐槽对应，非近似）

| 参照槽 | 值 | 本项目 |
|---|---|---|
| `bg_primary` | `#1E1E1E` | `GoldenTheme.backgroundPrimary`（页面底） |
| `bg_secondary` | `#1C1C1E` | `backgroundSecondary`（卡片/行/导航条/输入框） |
| `bg_tertiary` | `#2C2C2E` | `backgroundTertiary`（feature 卡身/悬停） |
| `bg_input` | `#1C1C1E` | `backgroundInput` |
| `text_primary` | `#FFFFFF` | `textPrimary` |
| `text_secondary` | `#8E8E93` | `textSecondary`（副标题/说明/id 之外的弱文本） |
| `text_disabled` | `#787878` | `textDisabled`（禁用行、tweak id） |
| `accent` / `_hover` / `_pressed` | `#007AFF` / `#0066CC` / `#0055AA` | `accent` / `accentPressed`（按钮渐变的两端）；`_hover` 只服务于桌面 hover，iOS 无对应态，不落地 |
| `success` | `#30D158` | `success`（开关轨道） |
| `error` / `_pressed` | `#FF453A` / `#C2322A` | `error` / `errorPressed`（危险按钮、破坏性行、失败状态） |
| `warning` | `#FFD60A` | `warning` |
| `border` / `divider` | `#3A3A3C` | `border` / `divider` |
| `surface_hover` | `#2C2C2E` | `surfaceHover`（行按下反馈） |

`ACCENT_PRESETS`（8 组主题色）**不移植**：参照靠设置页切换，本项目没有设置页。

## 3. 排版

参照把所有平台钉在一个**捆绑的 `Inter Variable`** 上；本项目的字号字重**逐条照抄**：

| 参照槽 | 字号/字重 | 本项目 |
|---|---|---|
| `home_title` | 32 / 700 | `GoldenFont.homeTitle` |
| `nav_title` · `home_card_title` | 17 / 600 | `navTitle` · `cardTitle` |
| `settings_row` · 开关行 · 输入控件 | 15 / 400 | `rowTitle` · `field` |
| `value_label` · 默认 `QLabel` | 14 / 400 | `value` · `body` |
| `home_subtitle` · `process_status_*` | 14 / 400 · 14 / 500 | `homeSubtitle` · `status` |
| `home_card_subtitle` · 段说明 | 13 / 400 | `cardSubtitle` |
| `section_header` | 13 / 600 +大写 + 字距 0.5 | `sectionHeader`（`.tracking(0.5)` + `.textCase(.uppercase)`） |
| `safety_note` | 12 / 斜体 / danger | `safetyNote` |

**一处有意分歧：字族。** 参照钉 Inter 是因为 Qt 默认字族各平台不同；而它的 iOS 组件集本身就是
**对平台外观的模仿**（51×31 绿轨道开关、17/600 居中导航标题、分组卡片）。在一台真的 iPhone/iPad 上，
系统字族才是忠实选择。`GoldenFont.font(_:_:)` 会探测 `Inter Variable` / `InterVariable`，**一旦把字体
打包进去就自动全部切换**，不需要改任何调用点。要启用：

1. 把 `~/GoldenNugget/src/qt/fonts/InterVariable.ttf`（+ Italic）放成工程资源；
2. 在 `layout/Applications/PoC.app/Info.plist` 加 `UIAppFonts`。

这两步要动 `.pbxproj` 的 Resources 段，只能在能跑 XcodeGen/真构建的环境里做——本机做不了，
所以留着钩子而不是手改工程文件。

## 4. 布局与组件

| 参照 | 值 | 本项目 |
|---|---|---|
| 页边距 / 页面间距 | 16 / 16（home）· 16,16,16,32 + 8（tweaks） | `pageMargin` 16、`sectionSpacing` 16、`rowSpacing` 8（两个页面各取其值） |
| 卡片圆角 · 行圆角 | 12 · 10 | `cardRadius` · `rowRadius` |
| 输入框内边距 / 圆角 | 12·16 / 10 | `GoldenFieldStyle` |
| 导航条 | 56，`bg_secondary` + 底部分隔线 | 平台导航条（44）+ `.toolbarBackground(backgroundSecondary, .visible)`；高度交给平台 |
| 主/危险按钮 | 高 50，圆角 12，垂直渐变，17/600；`:disabled` = `border`+`text_disabled` | `GoldenPrimaryButton` / `GoldenDangerButton` / `GoldenButtonLabel` |
| 开关 | 51×31，开=`success`，关=`border`，白钮 | 原生 `Toggle().tint(success)`（平台控件本来就是它） |
| 行的按下反馈 | `:hover` → `surface_hover` | `GoldenRowButtonStyle` |
| 段落标题 | 13/600 大写 + 左内边距 4 | `GoldenSectionHeader` |
| 设置行 | `title  (value)  ›`，圆角 10 | `GoldenRowLabel` + `GoldenActionRow` |
| feature 卡 | 56pt 头部带（17/600）+ 内容块（13 副标题） | `GoldenFeatureCardLabel`（头部带 `bg_secondary`、卡身 `bg_tertiary`） |
| 响应式卡片网格 | 每张卡 ≥200、间隙 12，尽量填满一行 | `GoldenCardGrid`（同一条回流规则） |
| home logo | 80×80，圆角 14；取不到图时用 `bg_secondary` 方块 | `GoldenLogo`（读 `AppIcon60x60@2x.png`，取不到画 `bg_secondary` + 图标） |
| 状态行 | 14/500，绿/红/蓝按结果 | `GoldenStatusText` + `outcomeTone`（Tweaks 的 apply 结果；home 的 elapsed） |

`GoldenPage` 另外加了一条参照给不出的规则：**内容最大宽度 720 并居中**。参照在桌面上永远把 iOS UI
画在手机框里（宽度天生受限），而本 app 跑在 iPad 上（`TARGETED_DEVICE_FAMILY 1,2`）——不让一行在
横屏铺满 1366pt 就是同一件事的等价做法。

## 5. 有意保留的差异

| 差异 | 为什么 |
|---|---|
| 字族用系统字（见 §3） | 参照模仿的就是平台外观；Inter 钩子已留 |
| **日志界面**参照没有 | 参照把进度打在状态行上；本项目需要可复制的完整日志（诊断靠它）。用同一套卡片外壳 + 12pt 等宽，内部滚动 300/260 高，避免一次运行把控件顶出屏幕 |
| 开关行**有内边距** | 参照的 `make_switch` 用 `setContentsMargins(0,0,0,0)`，标签会贴到卡边；这里按同一文件里的 `settings_row`（14·16）对齐 |
| tweak 的 **id + description 留在卡里** | 参照放在 tooltip；本项目要在设备上看得到、可复制，且本来就是这样 |
| 图标用 SF Symbols | 参照用 Qt 主题图标资源 |
| 主页面**只有一张 feature 卡** | 本项目只有一个二级页面；网格规则照搬，卡数随之 |
| 桌面 hover / 强调色选择器 / 手机外壳 | iOS 上无意义（前两项）或本项目不需要（第三项） |

## 6. 没有动的东西（验收清单）

- 主页面：pairing 选择/重置、`.app/.ipa` 选择并读 bundleID、bundle/file/contents 三个字段、
  Run/Stop、`ALTPairingFile` 自举、`onOpenURL`、两个 alert、诊断四项 + 分享、日志上限 600 行、
  ~~`init()` 里的 `UIDocumentPickerViewController` swizzle~~ —— 2026-09-26 删除：它查的
  `fix_initForOpeningContentTypes:asCopy:` 全仓**没有定义**（只有这一处查找），所以
  `class_getInstanceMethod` 恒返回 nil、交换从未发生；而它作为自定义 `init()` 又会
  顶掉 memberwise 构造，是本次两个编译错误的根因之一。
- Tweaks 页：`DeviceIdentity.read()`、兼容性过滤（不兼容的不显示）、三个分节的 `(on/total)`、
  开关/文本/数值编辑器（数值仍带草稿 + 钳制 + `numberHint`）、`autosave.json` 导入与四类报告、
  Clear all、apply 的成功/取消/失败三分支、最近 30 行日志。
- `PoCEngine` / `BackupInjector` / `ManifestStore` 等**一行未改**——这是纯视图层改动。

## 7. 窗口宽度（Split View / Slide Over）

参照是桌面 GUI，只有"画在手机框里"这一个宽度；本 app 跑在一个**宽度由系统决定**的窗口里：
Slide Over 320、Split View 三分之一/二分之一、iPadOS 26 的自由缩放窗口。所以 §4 那张表之外
还要回答"变窄了怎么办"。

**先说结论：Info.plist 不需要改。** 进 Split View 的三个条件逐条已经满足，可复核：

| 条件 | 本项目的取值 |
|---|---|
| 不要求全屏 | 没有 `UIRequiresFullScreen` 键（缺省即 false） |
| iPad 支持四向 | `UISupportedInterfaceOrientations~ipad` 四项齐全 |
| 用 launch storyboard | `UILaunchScreen`（不是 launch image） |

另有 `UIDeviceFamily = 1,2` 与 `UIApplicationSceneManifest / UIApplicationSupportsMultipleScenes = true`
（多窗口），两者也是对的。也就是说：如果 iPad 上拖不出 Split View，原因在下一节的布局，不在这里。

窄窗口下的四条规则（最窄按 Slide Over 320 算：减去 2×16 页边距，内容宽 288）：

| 位置 | 窄窗口会怎样 | 规则 |
|---|---|---|
| `GoldenHeader` 标题 | 80 的 logo + 16 间距 + 36 的按钮后只剩 156；32pt 的 "GoldenNugget" 约 210 → 折成三行的塔，把整页往下顶 | `lineLimit(1)` + `minimumScaleFactor(0.6)`：缩不折（0.6 时约 19pt，仍可读） |
| `GoldenRowLabel` 标题 / 值 | 图标 20 + 箭头 13 + 内边距 32 后剩约 170，标题与值平分 → 值折行、标题被截成碎片 | 标题 `layoutPriority(1)`（最后才被挤），值 `lineLimit(1)` + `minimumScaleFactor(0.7)`（数字折行会读成两个事实） |
| `FilesView` 面包屑 | `/var/mobile/Containers/Data/Application/<UUID>/…` 单段就超过 300 → 每段一行，卡高度随目录深度增长，"/" 与它分隔的名字越离越远 | `ScrollView(.horizontal)` + 每段 `.fixedSize()`：一行、自然宽、横滑；短路径外观不变 |
| `FilesView` 文件名 | 40+ 字符折 2–3 行，长条目变成块，列表不再能扫 | `lineLimit(1)` + `truncationMode(.middle)`：保留扩展名 |

**本来就自适应、没有动的**：`GoldenCardGrid`（`gridMinCardWidth` 200，288 宽自然落到 1 列，
规则与参照一致）、`GoldenPage` 的 720 上限（只在窗口比它宽时居中，窄窗口不生效）、
`GoldenLogView` 的高度（Slide Over 仍是全高）。

### 外壳：`NavigationSplitView`（`Nugget/Views/AppShell.swift`）

宽窗口下是「侧栏 + 详情」两列，窄窗口下系统自己塌成一列——**这正是选它的理由**：本 app 跑在宽度
由系统决定的窗口里，而 `NavigationStack` 只有第二种形态。

三条不显然的约束，改这个文件时按它们核对：

1. **主页是详情栏的栈底，不是侧栏的一项。** 分栏视图在切换选中项时会**销毁**详情视图，而主页持有
   运行（Apply / 进度 / 日志）与启动自举。所以侧栏选中是往 `path` 里压栈（`path = [dest]`），
   主页永远不被移除、只被盖住；`path` 为空 = 主页，这也是侧栏高亮的唯一真源（`path.last ?? .home`）。
2. **`tweakSelection` 与两个自举标志（`didAutoStart` / `autoImportDisabled`）提到 `RootView`。**
   主页的 `@State` 在详情页被替换时一起没了：用户选了 40 个 tweak 再点 Daemons 回来就全空。
   `didAutoStart` 同理——它守的是进程级单例（`startMinimuxer` 的锁只挡并发），标志却跟着视图死。
3. **主页的导航条只在 regular 宽度下隐藏。** 参照的 home 没有导航条，但塌成一列时**那条 bar 是回到
   侧栏的唯一入口**，隐藏它就把用户锁死在主页。所以 `navBarVisibility` 按
   `horizontalSizeClass` 分叉：compact 留、regular 藏。

侧栏用设计系统自己的行度量（`GoldenFont.rowTitle` / 20pt 图标槽）而不是平台行样式，并
`.scrollContentBackground(.hidden)` + `backgroundPrimary`，这样它和右边的页面是同一块底色。
主页卡片网格的 5 个入口改成 `NavigationLink(value:)`，与侧栏共用 `RootView` 里那一份
`navigationDestination` —— 否则卡片推了一个 `path` 不知道的页面，侧栏会继续高亮 "GoldenNugget"。

**这次没做的**：44pt 触摸目标（那是触摸精度问题，不是窗口宽度问题，已在上一次撤回里单独拿掉）。

## 8. 手机（iPhone）

**能力声明同样不用改**（可复核）：`UIDeviceFamily = 1,2` · `UISupportedInterfaceOrientations~iphone`
三向齐全 · 无 `UIRequiresFullScreen`。所以和 §7 一样，要改的是布局与交互，不是 plist。

| 项 | 手机上 | 处理 |
|---|---|---|
| 分栏外壳 | `NavigationSplitView` 在手机上自动塌成一列 | 初始 `columnVisibility` 按 `userInterfaceIdiom` 分叉：手机 `.detailOnly`（塌成一列时侧栏仍可从详情栏的返回入口进），平板 `.automatic`（记住用户上次的选择）。手机上强行并排只会把 393pt 挤成 240 + 153 |
| **键盘关不掉** | `.numberPad` / `.decimalPad` **没有 Return 键**，键盘盖住半屏且无法收起 | 新增 `GoldenKeyboardDone`（键盘上方一个 Done，用 UIKit 的 `resignFirstResponder`，不需要每个字段配 `@FocusState`），只加在这两种键盘的字段上：隧道的 Port / Prefix length、tweak 的数值编辑器 `.numbersAndPunctuation` 自带 Return，不用加 |
| 最窄 375（SE） | 内容宽 343；卡片 2 列需 `2×200+12 = 412 > 343` ⇒ 自然落 1 列 | 无改动，`GoldenCardGrid` 的回流规则自己算；页头标题靠 §7 那条 `minimumScaleFactor(0.6)` |
| 告警里的输入框（Files 的新建/重命名） | 告警自带 Cancel，不会卡住 | 无改动 |

**没做的**：44pt 触摸目标（`GoldenIconButton` 仍是参照的 36pt）——那是触摸精度问题，前两轮已单独撤掉，
本轮不夹带。

## 9. 门禁

```bash
scripts/typecheck.sh                      # 0 error（49 sources）
scripts/typecheck.sh "" --first <file>    # 把某个文件提到最前，保证它真被检查
scripts/sync-pbxproj-sources.py --check   # 工程源清单与 Package.swift 一致
```

**`typecheck.sh` 的两个坑（都踩过）**：

1. `swiftc -typecheck` 报完**第一个出错的文件就停**，排在它后面的源文件**根本没被检查**。
   本项目里 `Nugget/Core/AfcFileExplorer.swift` 因模块缓存比 Vendor 旧而恒定抛 28 个幻影 error，
   于是 Views/ 下任何新错误都会读成"通过"。新增或大改一个文件后，用 `--first` 把它提到最前再跑一次。
2. `-target` 必须跟部署目标一致（本项目 26.0）。写成 ios16.0 时，`onChange(of:initial:_:)`
   这类 iOS 17+ API 会被报成**假的** "only available in iOS 17.0 or newer"。

> `sync-pbxproj-sources.py` 不再硬编码工程文件名：项目刚由 `PoC.xcodeproj` 改名为
> `GoldenNuggetMobile.xcodeproj`，写死老名字会让它直接 `FileNotFoundError`（已修：在仓库根
> glob 唯一的 `*.xcodeproj`，多于一个就报错退出）。
