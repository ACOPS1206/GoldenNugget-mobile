# GoldenNugget tweaks 移植：范围、兼容性限制与用法

> **状态：已落地（2026-09-24）。** `scripts/typecheck.sh` **0 error，未新增 warning**
> （33 sources，改动前 25）。编译段与参照实现做了**差分对拍：142 个选择 × 3 种设备档
> = 426 例，逐字段（含 plist 类型）全部一致**。
>
> **一处未验证**：注入器为 `ManagedPreferencesDomain` / `HomeDomain` /
> `SystemPreferencesDomain` / `DatabaseDomain` 合成的行形状取自真机备份**实测**，但
> **尚未跑过一次真机 restore**。`AppDomain-*` 与 `SysSharedContainerDomain-*` 两个类沿用
> 本项目已有产线证据的路径，字节未变。
>
> **2026-09-25**：真机 apply 回 `205 — "Manifest references files not in backup"`，定位到这 4 个域的
> 文件行缺 `Digest`（设备在这些域恒定写它，在 AppDomain/SysSharedContainer 恒定不写），已补齐
> —— 见 §2.2。
>
> **2026-09-26**：补上 `skip_setup` 的两个文件，做成 Supervision 页的开关（**默认关**，上游默认开），
> 面板清单改为从参照生成；两处有意分歧（不合并设备现有 cloud config、不写 keybag 证书）见 §2.3 / §3.3。
>
> **2026-09-27**：**PosterBoard 独立成一条线，见 `docs/posterboard-port.md`**。本文件描述的是
> registry 那 133 个 plist tweak；PosterBoard 的壁纸 / 视频壁纸 / 重置走同一条投递通道
> （`TweakPayload → TweakInjector`，域 `AppDomain-com.apple.PosterBoard`）但有自己的编译段、
> 自己的数据库阶段和自己的页面。为此 `TweakPayload` 多了一个 `source:`（载荷可以在磁盘上），
> 见该文档 §2。
>
> 真机构建仍需你本地跑 `scripts/build-ipa.sh`。

移植对象：`~/GoldenNugget`（Python / PySide6，`src/tweaks/` 与 `src/controllers/`）。
承接方：`Nugget/Core/Tweak*.swift`、`Nugget/Core/GoldenNuggetPreset.swift`、
`Nugget/Views/TweaksView.swift`。

---

## 1. 移植范围

### 1.1 已移植：registry 的全部 133 个 tweak

| 分节（Section） | 数量 | 编辑器 |
|---|---|---|
| Liquid Glass | 98 | 开关 / 数值 |
| SpringBoard | 17 | 开关 / 文本 / 数值 |
| Internal Options | 18 | 开关 |

**逐字段生成，不是重敲。** `scripts/gen-tweaks-from-goldennugget.py` 用一个 PySide6 桩
（只替换 `QT_TRANSLATE_NOOP`）导入参照的 `src/tweaks/registry.py`，把 `TweakSpec` 表
（`id` / `section` / `title` / `location` / `key` / 默认值 / `Kind` / `min_version` /
`max_version` / `iphone_only` / `ipad_only` / `description` / `factory`）直接生成成
`Nugget/Core/TweakCatalog.swift`，`FileLocation` 枚举一并生成。`--check` 可查漂移。
→ 上游加一个 tweak，这里重跑一次脚本就出现，**不存在抄错的可能**。

同时移植的参照语义（都标了源文件与函数名，便于逐条对照）：

| 参照 | 本项目 | 说明 |
|---|---|---|
| `src/restore/path_mapping.py` | `TweakDomainMap.split(path:)` | 绝对路径 → (域, 相对路径)；容器域把首段并入域名 |
| `device_manager._apply_tweak_pass` 的**编译段** | `TweakCompiler.compile` | 同一 `FileLocation` 的键**合并**；`AdvancedPlistTweak` 整字典替换；`.GlobalPreferences.plist` 的 ManagedPreferences→HomeDomain 双写 |
| `src/gui/ios/compat.py:is_tweak_compatible` | `TweakSpec.isCompatible` | `min_version`/`max_version` + `iphone_only`/`ipad_only` |
| `Tweak.set_value(..., toggle_enabled: True)` | `TweakSelection.setValue` | 改值即启用 |
| `src/controllers/preset_manager.py`（预设 v2 JSON） | `GoldenNuggetPreset` / `GoldenNuggetPresetImport` | 见 §4.2 |
| `tweak_loader._build_spec` | 生成器把 `factory()` 的字典折进 `multiValues` | `WatchOSCompatibility` 的多键写入 |

### 1.2 未移植（4 个 feature）

UI 里直接不出现；导入预设时**逐条报告原因**，不静默丢弃。

| 未移植 | 原因 |
|---|---|
| Templates | 独立的 `.template` 格式（`config.json` + 五种 option）+ 模板资源库；与 PosterBoard 正交，见 `docs/posterboard-port.md` §6 |
| Status Bar | 需要 `StatusBarOverrideData` 结构体走 CFFI（`status_bar/status_bar_c/status_setter.py`） |
| Icon Themes | 需要图标资源持久库 |
| Daemons（含 `ClearScreenTimeAgentPlist`） | 强制关 launchd daemon，风险最高；且需要 90 个 `INTERFACE_KEY` 的逐项开关 UI |

**PosterBoard 不在这张表里了**（2026-09-27 移植，壁纸 + 视频壁纸 + 重置；Templates 仍缺）——
但参照把它排除出预设（"device-specific and heavy, so they must not travel with a preset"），
所以导入一个含 `PosterBoard` 条目的预设仍然会把它列进「不在本次移植内」，理由已改为
「参照自己不导出壁纸，请用 PosterBoard 页」。

---

## 2. 投递方式

沿用本项目既有链路，**不新增第二条通道**（单通道仍然成立）：

```
TweakCompiler.compile（不碰设备）
        ↓
ProtectiveBackup（阶段 1）→ prune（阶段 2）→ TweakInjector（阶段 3）→ RestoreRunner（阶段 4）
```

- 编译在**碰设备之前**跑完：空选择 / 全被跳过会直接报错，不会先付一次备份的代价。
- `BackupInjector.pruneAndInject` 新增可选的 `tweakPayloads`；`bundleID` 改成可选——因为
  参照的 tweak-only apply **根本不投 app 容器**（`_apply_tweak_pass` 的文件列表只由 tweak 组成）。
- 每个 tweak 文件写 3 类行：域根行、逐级父目录行（`flags=2`）、文件行（`flags=1`）+ 载荷
  放到 `<aa>/<fileID>`。inode 从 manifest 现有最大值往上数，**保证唯一**——参照明确要求
  （"the agent deduplicates by inode — a clone sharing the donor's inode gets restored with
  the donor's content"）。
- 注入一律在 **prune 之后**，理由与既有的 footnote 注入相同：prune 只保留参照的 keep-set，
  这些行不在其中，先写会被剪掉。

### 2.1 行形状（实测，非猜测）

来源：`~/Library/Application Support/MobileSync/Backup/00008130-001431082E40001C`
（iPad16,2 / iOS 27.0 24A5424a）。**设备自己的产出是唯一契约。**

| 域 | 文件 Mode | User/Group | ProtectionClass | EA publisher | 文件行 Digest |
|---|---|---|---|---|---|
| `ManagedPreferencesDomain` | 0755(3)/0644(1) | 501/501 | 4 | `com.apple.BackupAgent2` | **有** 4/4 |
| `HomeDomain` | 0600(526)/0644(181) | 501/501 | 4 | `com.apple.BackupAgent2` | **有** 708/708 |
| `SystemPreferencesDomain` | 0644 | 0/0 | 4 | **无** | **有** 9/9 |
| `DatabaseDomain` | 0644(2)/0755(1) | 0/0 | 4 | `com.apple.BackupAgent2` | **有** 3/3 |
| `SysSharedContainerDomain-*` | 0644 | -2/-2 | 4 | `com.apple.containermanagerd_system` | **无** 0/10 |
| `AppDomain-*` | 0644 | 501/501 | 3 | `com.apple.containermanagerd_system` | **无** 0/2760 |

目录行：域根 `0/0`（`SysSharedContainerDomain-*` 根是 class 0），中间目录随域
（`ManagedPreferencesDomain` 是 501/501 class 4，`HomeDomain` 是 501/501 class 0）。
目录行与符号链接行**任何域都不写 Digest**。

> 参照给每个 plist tweak 盖 `Tweak.__init__` 的默认 `owner=501, group=501`，但**设备自己的行
> 按域不同**（footnote 是 `-2/-2`、`DatabaseDomain` 是 `0/0`）。设备记录更权威，所以
> owner/group/protectionClass/EA 收敛到 `TweakRowProfile`，按域取，而不是照抄 501。

### 2.2 `Digest`：按域分成两类，2026-09-25 补齐

`Digest` = 载荷的 SHA-1。**它不是"可有可无的元数据"，而是设备按域恒定写或不写的字段**：
真机备份里 110 个有文件行的域，没有一个混用两种形状（`scripts/blob-shape-check.swift` §4
每次重跑都复核这一条）。

- **必须写**（11 个域）：`HomeDomain` · `SystemPreferencesDomain` · `ManagedPreferencesDomain` ·
  `DatabaseDomain` · `RootDomain` · `MobileDeviceDomain` · `WirelessDomain` · `NetworkDomain` ·
  `KeychainDomain` · `ProtectedDomain` · `InstallDomain`
- **必须不写**（99 个域）：`AppDomain*` 全族（`AppDomain-` / `AppDomainGroup-` /
  `AppDomainPlugin-`）· `SysSharedContainerDomain-*` · `SysContainerDomain-*` · `CameraRollDomain`

有 Digest 的行上，它逐字节等于 `sha1(payload)`（已抽验 4 个域各一行）；参照也写同一个值
（`inject.py:_build_mbfile_blob` / `_patch_donor_blob` 用 `hashlib.sha1(contents).digest()`）。

**为什么这条曾经是隐形的**：注入器只服务 `AppDomain-*` 时不需要它——AppDomain 恰好是"不写"
的那一类；footnote 的 `SysSharedContainerDomain-*` 同样是不写的一类。所以"从不写 Digest"在
两条有产线证据的路径上都对，只在 tweak 的 4 个域上错。设备对这种行回
`MBErrorDomain/205 — "Manifest references files not in backup"`。


---

### 2.3 `skip_setup` 的两个文件（2026-09-26 补齐）

开关在 **Supervision 页**（与上游把 `skip_setup` / `supervised` / `organization_name` 放在同一个
设置对象里一致）。打开后，每次 apply 都会在 tweak 文件**之前**投递这两个：

| 顺序 | 域 | 相对路径 | 内容来源 |
|---|---|---|---|
| 1 | `SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles` | `Library/ConfigurationProfiles/CloudConfigurationDetails.plist` | `build_cloud_config` 的 7 个固定键 + `SkipSetupCatalog.panes`（81 项） |
| 2 | `ManagedPreferencesDomain` | `mobile/com.apple.purplebuddy.plist` | 上游的三个字面量（`SetupDone` / `SetupFinishedAllSteps` / `UserChoseLanguage`） |

- **顺序与目录行**：上游 `add_skip_setup` 只 append 两个文件，目录行由注入侧按路径补。本项目让
  `TweakInjector` 从两个 payload 的路径推目录链，于是行序恰好是
  `""` → `Library` → `Library/ConfigurationProfiles` → 文件，再 `""` → `mobile` → 文件。
- **行形状**：走的是**同一个** `TweakRowProfile`——`SysSharedContainerDomain-*` → `.systemContainer`
  （`-2/-2`、class 4、EA `containermanagerd_system`、**不写 Digest**），`ManagedPreferencesDomain`
  → `.managedPreferences`（`501/501`、class 4、EA `BackupAgent2`、**写 Digest**，见 §2.2）。两类都是
  实测过的形状，所以这两个文件不需要新的测量。
- **时机**：和其它注入一样**在 prune 之后**——`SystemPreferencesDomain` 之外的域都不在 keep-set 里，
  先写会被剪掉。iOS 27（拉备份 + prune）与 iOS 26（合成 MBDB，不平铺 prune）两条分支共用同一个
  payload 数组，所以两个文件在两条路上都会投递。
- **代码**：`Nugget/Core/SkipSetup.swift`（行为）+ `Nugget/Core/SkipSetupCatalog.swift`（**生成物，
  勿手改**）。验收：`scripts/skipsetup-check.swift` 与参照产出对拍（见 §3.3）。

## 3. 兼容性限制（务必先读）

1. **注入器未经真机验证。** 除 `AppDomain-*` / `SysSharedContainerDomain-*`（已有产线证据）外，
   4 个域的行形状是从备份实测来的、合理推断，但**没跑过一次 restore**。日志里会对每个未
   验证域打一行 `note: the <domain> row shape is measured ... but has not been confirmed by a
   run yet`。首次真机验证建议**只开 1 个 tweak**（例如 Internal 里的 `SBBuildNumber`），
   确认生效后再扩量。
   **2026-09-25 补充**：首次真机 apply 回 `MBErrorDomain/205 — "Manifest references files not
   in backup"`。已定位到一处与设备契约不符之处并修掉 —— 这 4 个域的文件行必须带
   `Digest`（AppDomain/SysSharedContainer 恰好不必带，所以老实现看不出来），见 §2.2。
   `Mode` 上还留着已知偏差（设备在 `ManagedPreferencesDomain` 写 0755、`HomeDomain` 多为
   0600，我们统一写 0644）：per-row 而非 per-domain，暂不动。

2. **两处有意的编译器分歧**（差分测试里已显式建模，所以它们不是"未测到的差异"）：
   - **不兼容的 tweak 在编译时被丢弃。** 参照的 apply 段不做这个检查（只有 GUI 隐藏），
     所以共享预设能在 UI 看不到的情况下启用一个本机不适用的 tweak。本项目宁可少写不写多写。
   - **HomeDomain 的 `.GlobalPreferences.plist` 镜像只在 GP 真有键时才写。** 参照无条件写
     `plistlib.dumps({})`——即"本次没动 GP"时会把设备真实的 HomeDomain `.GlobalPreferences.plist`
     覆盖成空字典。写法保留了参照声明的意图（"also write it to HomeDomain so tweaks that depend
     on it survive"），但不会用空字典覆盖活文件。

3. **`skip_setup` 已移植，但默认关、且有两处已知分歧。** 参照的 `_apply_tweak_pass` 会追加两个
   skip-setup 文件（`SysSharedContainerDomain-…/CloudConfigurationDetails.plist` 与
   `ManagedPreferencesDomain/mobile/com.apple.purplebuddy.plist`），由 `pref_manager.skip_setup`
   驱动。本项目把它做成 **Supervision 页上的开关**（`SupervisionSettings.skipSetupEnabled` →
   `SkipSetup.build` → 引擎在 tweak payloads **之前**拼进同一个数组，见 §2.3）。

   - **默认关**：上游默认 **开**（`preference_manager.py:19`）。这里默认关，因为 `SkipSetup` 还没
     过一次真机运行——默认开等于给每次 apply 静默加两个文件。跑通后把那一个字面量改成 `true`
     即与参照的文件集完全一致。
   - **分歧一：不与设备现有 cloud config 合并。** 上游 `build_cloud_config(existing, …)` 会先
     `MobileConfigService.get_cloud_configuration()`；本项目没有这条服务，于是只用那 7 个固定键
     写成文件，设备原有的其它键**不会保留**（每次运行都会把这条写进日志）。
   - **分歧二：不写 `SupervisorHostCertificates`。** 上游在"已监督 + 有机构名"时用
     `pymobiledevice3.ca.create_keybag_file` 生成 x509；本项目没有 keybag 生成器，于是只写
     `IsSupervised` / `OrganizationName` / `OrganizationMagic`，并**在日志里明说证书缺失**。
     `SupervisionView` 本来就写明"监督只是记录意图"，这样写至少不会把半成品装成成品。

   验收（无设备）：`scripts/skipsetup-check.swift` 把生成的两个 plist 与参照对同一台设备产出的
   两份文件**逐键对拍**（解析后比较，不比字节——plist 字典无序），并检查域名/路径/顺序与上游
   `add_skip_setup` 一致；面板清单由 `scripts/gen-skipsetup-from-goldennugget.py` 从参照
   `skip_setup27.py` 的 `SKIP_ALL_PANES` 生成（带 `--check`），不手抄。

4. **不支持加密备份。** 参照会显式跳过加密备份的注入（"a locally-injected plaintext payload has
   no matching wrapped key — the Phase 3 restore agent fails to decrypt it (MBErrorDomain/205)"）。
   本项目 `Diagnostics.preflightBackupEncryption()` 会在 run 前拦截，tweak 路径**没有**额外处理。

5. **HotLoad 没移植。** 参照有 `hotload_rules.json` kill-switch（按 app 版本 / iOS 版本 / 机型
   隐藏或禁用 tweak）。就 2026-09-24 读取到的规则而言，唯一生效的那条只针对 `Daemons`（已排除），
   对已移植的 133 个 tweak 当前无影响——但**规则是可远程更新的**，上游若新增针对别的 tweak 的规则，
   本项目不会跟随。

6. **导入不会启用"本机不兼容"的 tweak。** 见第 2 条分歧。

7. **数值类型按 registry 默认值决定。** JSON 里 `1` 与 `1.0` 分不出来（`JSONSerialization` 会把
   `1.0` 写成 `1`），所以导入时用 **registry 默认值的数字类型**决定写 int 还是 real——plist 里
   这是两种类型，framework 读到的不一样。

8. **主页面那个 footnote 输入框**只服务 app-container PoC（`runPoC`）。tweak 列表里的
   `LockScreenFootnote` 是同一 tweak 的正式入口；两条路径不会同时生效（`applyTweaks` 传
   `footnote: nil`，`runPoC` 传 `tweakPayloads: []`）。

---

## 4. 使用方式

### 4.1 UI

主页面 → **Tweaks** → *GoldenNugget tweaks*：

- 顶部一行显示机型与 iOS 版本（lockdown `ProductType` / `ProductVersion`），
  `n of m applicable tweak(s) enabled`。**不适用的 tweak 直接不显示**——与参照的
  `is_tweak_compatible` 一致；一个永远点不动的开关比不存在的开关更糟。
- 三个分节按 registry 顺序列出，每个 tweak 带标题、id、参照的 `description` 说明。
  数值项显示 `min–max, step`，输入即按 registry 的上下界**钳制**。
- **Clear all tweaks** 清空选择。
- **Apply N tweak(s)** 跑完整链路；结束后页面底部给最近 30 行日志，主页面日志区有全量。
  **应用后需重启设备**注入的偏好才生效。

### 4.2 导入 `autosave.json`

GoldenNugget 每次改动都会把当前状态写进 **AutoSave 预设**
（`Presets/AutoSave.json`，`cli/common.py:autosave_preset`），那就是这里说的 autosave.json；
任何**导出的预设**（`exported: true`，部分导出另有 `metadata.partial` + `metadata.included`）
同样是合法输入。格式为预设 v2 JSON：

```json
{
  "tweaks": {
    "SBBuildNumber":  { "type": "BasicPlistTweak",    "enabled": true,  "value": true },
    "LockScreenFootnote": { "type": "BasicPlistTweak", "enabled": true, "value": "hello" },
    "WatchOSCompatibility": { "type": "AdvancedPlistTweak", "enabled": true, "value": { ... } }
  },
  "metadata": { "version": 2, "description": "...", "ios_version": "27.0", "tags": ["auto"] }
}
```

点 **Import autosave.json** 选文件即可。结果分四类列出并写进运行日志：

- `applied` —— 名字匹配上受支持的 tweak，按 `enabled` + `value` 还原（**enabled 与 value 分别
  取值**，不会因为"设了值"就把本来 `false` 的条目打开；这与 `Tweak.set_value` 的隐式启用不同）；
- `not part of this port` —— 5 个未移植 feature，逐条给原因；
- `switched off — not compatible` —— 本机/本版本不适用，**不启用**（见 §3.6）；
- `unknown tweak ids` —— 参照自己也是直接 `continue` 掉。

角色为 `Daemons` 的条目会在 `not part of this port` 里出现，属于预期。

### 4.3 脚本

```bash
# 从参照 registry 重新生成 TweakCatalog.swift（上游加 tweak 后跑这个）
scripts/gen-tweaks-from-goldennugget.py [--goldennugget ~/GoldenNugget] [--check]

# 从参照 skip_setup27.py 重新生成 SkipSetupCatalog.swift（上游加/改名 setup 面板后跑这个）
scripts/gen-skipsetup-from-goldennugget.py [--goldennugget ~/GoldenNugget] [--check]

# 编译段与参照的差分对拍（无设备，宿主上跑）
scripts/tweak-port-diff.py [--goldennugget ~/GoldenNugget] [-v]

# skip_setup 两个 plist 与参照产出的逐键对拍（无设备；不给参数就用这台机器上那两份）
#   编译方式见 scripts/skipsetup-check.swift 头部注释（拼成 main.swift 后 xcrun swiftc）
/local/path/to/skipsetup-check [CloudConfigurationDetails.plist] [com.apple.purplebuddy.plist]

# 常规门禁
scripts/typecheck.sh                 # 0 error 才算过
scripts/sync-pbxproj-sources.py      # 增删 Nugget/ 下文件后必须跑
```

`tweak-port-diff.py` 依赖 `packaging`（参照用它做版本比较）。宿主默认解释器没有时，用
`~/.workbuddy/binaries/python/envs/default/bin/python3`。

---

## 5. 证据

- **编译段差分对拍**：142 个选择（每个 tweak 单独一例 + 分节整体 + 全开 + 文本/数值/小数/
  `false` 默认值/多键字典）+ 3 种设备档（27.0 iPhone、26.5 iPad、27.0 iPad）= **426 例逐字段一致**。
  对拍同时校验 plist 的**类型**（`bool` / `int` / `real` / `str`）——这一条抓出过一个真实缺陷：
  最初用 JSON 中转比较，`1.0` 与 `1` 被压成同一个值，测试会漏掉类型不一致。
- **类型检查**：`scripts/typecheck.sh` → `0 error`（8 warnings，Nugget/ 占 3，与移植前基线一致）。
- **生成器可复核**：`gen-tweaks-from-goldennugget.py --check` 幂等。
