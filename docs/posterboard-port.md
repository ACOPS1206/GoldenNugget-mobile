# GoldenNugget PosterBoard 移植：范围、投递与限制

> **状态：已落地（2026-09-27），0 次真机验证。** `scripts/typecheck.sh` 在排除两处厂商
> 陈旧模块造成的幻影错误后，**新增的 8 个源文件 0 error 0 warning**；官方门禁当前回
> 28 error（`Core/AfcFileExplorer.swift` 那组已知幻影错误）、**0 warning**——**你重建
> Vendor 后那 2 个点名 `appFactoryEntry` / `applications:` 的幻影错误会消失**。
>
> 无设备门禁全过：`tweak-port-diff.py`（426 例，含 `TweakPayload` 改动后的复跑）·
> `blob-shape-check.swift` · `skipsetup-check.swift` · `check-daemons-merge.swift` ·
> 四个 `gen-*` 生成器 `--check` · `sync-pbxproj-sources.py --check`。
>
> **未验证的部分**：一段真机 restore 都没跑过。风险最高的两处不是代码逻辑，而是
> **设备契约**：(1) 定向备份是否真能把 `com.apple.PosterBoard` 容器拉下来（设备自己
> 决定上传什么）；(2) 写回的 sqlite 是否被 PosterBoard 接受。两者都有参照实现背书，
> 但参照在别的宿主上跑。

移植对象：`~/GoldenNugget`（Python）
承接方：`Nugget/Core/PosterBoard*.swift`、`Nugget/Views/PosterBoardView.swift`
参照文件：`src/tweaks/posterboard/{posterboard_tweak,tendie_file,pb_config_manager,pb_config_item}.py` ·
`src/restore/{posterboard_backup,protective}.py` · `src/controllers/{video_handler.py,aar/aar.py}` ·
`src/gui/ios/posterboard.py` · `files/posterboard/`

---

## 1. PosterBoard 是什么，为什么它和 tweak 不一样

一个壁纸**同时是两样东西**：

```
<PosterBoard 容器>/Library/Application Support/PRBPosterExtensionDataStore/<v>/
    Extensions/<provider 扩展>/configurations/<海报 UUID>/…      ← 描述符目录
PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3                 ← 商店自己的库
```

只写文件不写库，壁纸不会出现在选择器里；只写库不写文件，选择器里有一个找不到文件的
条目。所以一次 apply 必须有**三步**：拿设备自己的库 → 往它的副本里加行 → 文件与库一起
投递。

而库**只能从设备拿**：`poster` / `posterAttributes` / `posterRoleMembership` 三张表里是
设备自己的 provider 注册和选择器排序用的 usage metadata，`posterAttributes` 还有
`UNIQUE(posterUUID, roleId, attributeIdentifier)` 约束——猜着合成一张库，轻则壁纸不显示，
重则商店损坏。

## 2. 投递通道：没有新增第二条

全部载荷仍然是 `AppDomain-com.apple.PosterBoard` 一个域，走的还是既有的
`TweakPayload → TweakInjector`。这一条不是选择而是事实依据：**`AppDomain-*` 是本项目
唯一已有产线证据的域类**（app 容器 PoC 与 footnote 的同类行），行形状早就在
`TweakRowProfile` 里测过。PosterBoard 没有带来任何新的行形状。

一次 PosterBoard apply：

```
① PosterBoardBackup.fetch     定向备份，FactoryInfo 只列 com.apple.PosterBoard
                              （设备自报的 app 记录原样转发）→ Manifest.db 按文件名取库
                              → WAL 合并 → <Documents>/PosterBoard/<udid>.sqlite3
② PosterBoard.compile         解包 .tendies → recursive_add 路由 + UUID/ID 随机化 + plist 改写
                              → PosterBoardStore.stitch 往库的副本里加行 → [TweakPayload]
③ deliver（与 tweak apply 同一条尾巴）
                              保护性备份（授权会话）→ prune → inject → restore
```

- **两次 mobilebackup2 交换**，有意不合并：保护性备份的 `FactoryInfo` 说的是「不要 app
  容器」（`{"Applications": {}}`），那正是它快、也是它被现有产线证据覆盖的原因。为了省一次
  交换去改那条已知能工作的路径，不划算。
- **② 的产物可以很大**（视频壁纸是几百张 JPEG + 视频本体），所以 `TweakPayload` 现在
  **要么在内存要么在磁盘**（`source:` / `contents:` 二选一，消费者一律走 `bytes()` /
  `byteCount`）。注入器每个载荷只读一次：写、取长度、算 Digest 共用同一次读。
- 数据库取回**在 compile 之前**（compile 需要它），但仍然**在昂贵的保护性备份之前**。
  纯重置不需要库，所以重置路线是完整的「先编译后碰设备」。

## 3. 设备契约：这一节是本次移植新增的唯一接口

### 3.1 让设备上传指定容器

设备上传哪些 app 容器，取决于它拿到的 factory info。这个 PoC 此前只会发
`{"Applications": {}}`。新增：

| 层 | 改动 |
|---|---|
| `Vendor/MinimuxerGateway/idevice/IdeviceGateway.swift` | `syncAppFactoryEntry(bundleId:)`（instproxy 取设备自报的 app 记录）、`plistNode(from:)`（Foundation → `plist_t`，按 CF 类型区分 Bool 与 NSNumber）、`factoryInfo(applications:)`；`backupBackup(…, applications:)` 新参数 |
| `Vendor/MinimuxerSources/MinimuxerApi.swift` | 同两层：`appFactoryEntry(bundleId:)` + `backupBackup(…, applications:)` |
| `Nugget/Core/HostManifests.swift` | `ensure(…, applications:)`——同一份字典要同时进 `Info.plist`（pymobiledevice3 交给设备读的就是它）和 `FactoryInfo` 消息（minimuxer 走的那条）。两处一致才安全，因为哪一处生效没在真机上分辨过 |

**记录是转发的，不是拼的。** 参照的 `_add_posterboard_container` 手工拼 `Container` /
`ApplicationSINF` / `iTunesMetadata` / `PlaceholderIcon`（后两个在系统 app 上通常就是
默认值）；这里直接把 `installation_proxy` 给的那份字典转发回去——形状是设备的契约，手拼
一份就得跟每个 iOS 版本重新核对。`plistNode(from:)` 里 Bool 用
`CFGetTypeID(number) == CFBooleanGetTypeID()` 判定而不是 `as? Bool`：plist 整数是
`NSNumber`，而 `NSNumber(1) as? Bool` 是 `true`，用后者会把记录里每个 1 变成布尔。

### 3.2 库的取回与合并（`PosterBoardBackup`）

- **按文件名匹配**，不按路径：iOS 26 上传成
  `AppDomain-com.apple.PosterBoard/…`，iOS 27 在物理树下（`/.b/<n>/Containers/…`），
  商店目录名在后者里不总出现。取路径**降序的第一个**（结构版本号排序，取最新布局）。
- **WAL 必须合并**：商店是 WAL 模式，最近的壁纸数据可能在 `-wal` 里，裸拷主文件会丢。
  用 SQLite 在线备份 API（参照的 `src.backup(merged)`），**不拷贝 `-shm`**——陈旧的
  共享内存与 WAL 不同步，是「database disk image is malformed」的经典来源。合并失败或
  校验不过就退回裸主文件（与参照一致）。
- **结构版本从路径里读**（`PRBPosterExtensionDataStore/<v>/`），读不出才退回 61——这是参照
  的兜底，只在路径里没有商店目录名时才可能触发。版本号错了，注入的库会落进设备永远不读的
  死目录。

### 3.3 记账（`PosterBoardStore`）

`PBConfigManager.update_sqlite` 的逐条移植，全在一个事务里，**update 先行、查不到才 insert**
（新取的库里可能已经有同 UUID 的行，且 attribute/membership 可能留着上次失败 apply 的孤儿）。
`posterId` 从 `MAX(posterId)` 往上数，**不是** `sqlite_sequence.seq + 1`：删过行的库里序列
会漂移，主键撞车就是一次失败或一张损坏的库。

`attributePayload` 的 JSON 手写成与参照同样的键序，三处时间戳是三次独立取时钟（参照就是
三次 `time.time()` 调用，不是一次时钟加偏移）。

## 4. 编译段（`PosterBoard`）

`apply_tweak` 的移植。三个要点：

1. **`recursive_add` 的两种模式**是全部算法。非 adding 时找两种目录：`container/`（整库快照，
   从商店根开始走）与名字含 `descriptor` 的目录（壁纸，路由到
   `Extensions/<扩展>/configurations`）。adding 时只在 `descriptors/` 标记下的**第一层**目录
   改名成新 UUID 并登记成壁纸——递归调用**不传 `randomizeUUID`**，所以 `versions/0/contents/`
   保持设备自己的命名。这一条读错过一次：以为每层都改名，那会把商店布局整个改掉。
2. **三个 plist 改写**（`update_plist_id` + `update_for_family`）：`provider.descriptor.identifier`
   写成数字文本、`contents.userInfo` 的 `wallpaperRepresentingIdentifier`、`*Wallpaper.plist` 的
   顶层 `identifier` 再对齐 Marble 模型（family/name 强制 Lavender，嵌套 id 与顶层同步）。
   MercuryPoster 的扩展**整个跳过**——它的标识符是文本（`v6x.colorB`），改写会断掉
   `lookInidentifier` 的查找链。
3. **`update_for_family` 输出 XML**（`plistlib.dumps` 默认），**重置偏好 plist 输出二进制**
   （参照显式 `FMT_BINARY`）。两者不同是参照自己写的，不是笔误。

**有意分歧**（都写进日志）：

| 分歧 | 原因 |
|---|---|
| tendie 解包目录用**包名**而不是 `uuid4()` | 参照按 `os.listdir` 序走 UUID 名目录，即文件系统序；这里要可复现 |
| 三个 configconversion plist 按**名字序**注入 | 同上，`os.listdir` 序不是契约（清单按路径键） |
| 既无描述符也无容器的包**在导入时就拒** | 否则是一次什么都不做的 apply |
| 没有模板参数 | Templates 未移植，见 §6 |

## 5. 视频（`PosterBoardVideo`）

参照的两条路线都移植了：

- **live photo**（Loop 关）：视频进 Photos poster 描述符，`.aar` 容器由 `aar.py` 的
  两个硬编码头拼出来（长度 ≤64 KB 用 2 字节 blob，否则子类型字节翻成 `B` 并整体 +2 字节，
  头部长度字段随之改）。**必须选冻结帧**——参照在没有缩略图时直接抛错，这里同样抛。
- **CoreAnimation 循环**（Loop 开）：逐帧解码成 JPEG + `main.caml` 关键帧动画，上限 400 帧。

与参照的差异：

| 项 | 参照 | 这里 |
|---|---|---|
| 解码 | OpenCV（iOS 上没有） | `AVAssetReader` + `VTCreateCGImageFromPixelBuffer`，顺序解码（`AVAssetImageGenerator` 会 seek 400 次） |
| 帧尺寸 | cv2 的存储朝向，**不套** rotation | 同上，**故意保持一致**——caml 的 `bounds` 必须等于 JPEG 的真实像素；带旋转的片子会在锁屏上是躺的，这一点**会写进日志** |
| MOV 转换 | `ffmpeg -c:v copy -c:a copy` | `AVAssetExportPresetPassthrough`（等价的重封装） |
| 内存 | 整个视频读成 `bytes` | `.aar` 用文件句柄流式拼接；帧逐张写盘 |

`main.caml` / `index.xml` 两份模板**不手抄**：`scripts/gen-pb-templates-from-goldennugget.py`
用 `ast.get_source_segment` 把 `video_handler.py` 里那三个字符串字面量整段取出来（保留
`{width}` 占位符原样），只做机械替换，并**校验替换后没有残留的 `{}`**——上游新增一个占位符
会让脚本失败，而不是把一个字面 `{width}` 送进设备。制表符与结尾换行都在（`swift_lines`
逐行发一个字面量：Swift 多行字面量会剥掉收尾定界符的缩进，而这些行以制表符开头）。
资源（configconversion 3 个 plist、live-photo 骨架、VideoCAML 骨架、contents.plist）
由 `scripts/gen-pb-resources-from-goldennugget.py` 以 base64 内嵌进
`Nugget/Core/PosterBoardResources.swift`——**不是 bundle 资源**：本项目由 Xcode 与 xtool
两个构建器从同一份源清单构建，只加进 `Package.swift` 的资源到不了 `project.pbxproj`，
两个 bundle 会静默地不一致。

## 6. 未移植：Templates

`.template` 是另一套文件格式（`config.json` + replace / remove / set / picker /
bundle_id 五种 option + 预览图 / banner / 样式表），依赖模板资源库；参照自己就把
Templates 与 PosterBoard 分列在未移植清单里，导出预设时也明确排除两者。要做的活是
`template_file.py`（313 行）+ `template_options/`（约 600 行）+ 一套新界面，与本次范围
正交，所以**页面上不出现**，导入预设时会按 `GoldenNuggetPresetImport.unported` 逐条说明
原因。

## 7. 使用

主页面 → **PosterBoard**：

1. **Store database** 卡片显示上次取库的时间与大小；**Fetch database from device**
   单独跑取库（对应参照的 "Fetch Database File" 向导——取库是 apply 里唯一会单独失败的
   阶段，设备自己决定传不传容器，所以值得一个单独的按钮）。下面的开关是参照的
   `auto_refresh_posterboard`（默认**开**，与上游一致）：每次 apply 多写一个
   `PBF_RESET_FILE_PROTECTIONS` 偏好文件，让 PosterBoard 开机重读商店。
2. **Wallpaper packs**：导入 `.tendies`（ZIP）。列表上直接显示描述符数量；
   `container` 包会显示「可能要先做一次重置」的警告——**这是上游的话**（`unsafe_container`），
   不是这里的判断。上限 10 个描述符，与 `verify_tendie` 一致。
3. **Video wallpaper**：选视频（必需），Loop 开时再选可选的反转/遮住时钟/计算模式；
   Loop 关时要选 `.heic` 冻结帧。Loop 开时会把视频解码成帧，**慢且占空间**，日志里会报
   帧数、分辨率、帧率、时长。
4. **Reset**：Full Reset（清空商店三个子树 + 一张空 schema 库 + 偏好 plist）或三个选择性重置
   （Collections / Suggested Photos / Gallery Cache，各自把对应目录写成 0 字节文件）。
   **重置不持久化**：它是一次性指令，跨启动的「Full Reset」是一把上了膛的枪（上游也只在
   内存里存）。
5. **Apply PosterBoard** 跑完整链路（`RunLog` 里是全量日志）。**完成后重启设备**。

## 8. 兼容性限制（务必先读）

1. **没跑过真机。** 风险集中在 §3 的两处设备契约上，代码逻辑本身有 426 例差分对拍与
   blob 形状回归背书。第一次真机建议按这个顺序：先只按 **Fetch database**（它单独失败也
   不会弄坏商店）→ 再导一个**描述符型**（非 container）小包 → 再试视频。
2. **容器型 `.tendies` 是参照自己标为 `unsafe_container` 的那一类**（包里带着
   `PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3`）。参照的提示是「可能要先重置全部壁纸」。
   这里照抄这条警告，但**没有**在代码里强制先重置。
   container 分支的路径以 `/` 开头（`recursive_add(restore_path="/")`），fileID 因此与设备
   自己那套（无前导斜杠）不同。这是参照的行为，未改动；描述符型路径没有这个问题。
3. **PosterBoard 的注入是「关机才生效」**：库在开机时读。
4. **不支持加密备份**：`PosterBoardStore.isEncrypted` 会在取回的库上拦一次（明文载荷注入
   加密备份无法被还原代理解密，`MBErrorDomain/205`），但加密备份的整体拦截在
   `Diagnostics.preflightBackupEncryption()`，与本页无关。
5. **重置会让刚取回的库过期**：下一次 apply 会重新取一份，页面上会写明。
6. **`Structure version` 只有一个来源**：取回库的路径。重置-only 的 apply 没有库，用参照的
   兜底值 61——如果设备的商店目录不是 61，重置会打在错误的目录上。参照有同样的问题。
7. **`plistlib` 的键序没有复现**：Python 出 XML 时按键排序，`PropertyListSerialization`
   按字典序（哈希序）。plist 字典读出来是无序的，设备比的是值；注入器自己对这些字节算
   Digest，所以下游不受影响。

## 9. 门禁

```bash
# 从参照重生成两份声明式产物（上游改了 files/posterboard/ 或 video_handler.py 后跑）
scripts/gen-pb-resources-from-goldennugget.py [--check]
scripts/gen-pb-templates-from-goldennugget.py [--check]

# 常规门禁（增删 Nugget/ 下文件后必须跑）
scripts/typecheck.sh "" --first PosterBoard.swift
scripts/sync-pbxproj-sources.py
python3 scripts/tweak-port-diff.py            # 需要 packaging，见 tweak-port.md §4.3
```

**`scripts/typecheck.sh` 的一个坑（本次实测）**：`Core/AfcFileExplorer.swift` 恒定 28 个
幻影错误（源于陈旧的 vendored 模块），`swiftc` 报完第一个出错文件就停——所以它后面的
文件**根本没被检查**。检查新文件必须 `--first`；本次是排除 `AfcFileExplorer.swift` /
`AfcMediaBackup.swift` 后分组 hoist 跑的。

**本次顺带修掉的两个门禁缺陷**（都不是本次移植引入的，但都会把「没检查」读成「通过」）：

| 文件 | 缺陷 |
|---|---|
| `scripts/tweak-port-diff.py` | `HARNESS_SOURCES` 缺 `TweakCatalogDaemons.swift`，而 `TweakCatalog.allWithDaemons` 引用 `daemonSpecs` / `screenTimeSpec`——自 daemons 移植（2026-09-26）以来这个差分对拍**编译不过** |
| `scripts/gen-daemons-from-goldennugget.py` | `--check` 里写了 `len(DaemonGroupsCount(data))`，而它返回 int——`TypeError`，这条门禁**要么抛栈要么报 drift**，从来没有过「匹配」的结论 |

## 10. 证据

- **差分对拍**：`tweak-port-diff.py` → 426 例逐字段一致（`TweakPayload` 改成
  「内存或磁盘」之后复跑，编译段行为未变）。
- **blob 形状**：`blob-shape-check.swift` → 34918 个设备 blob 对照，0 个不可读 Mode、
  0 个引用型标量；每域 Digest 规则成立。
- **skip_setup / daemons**：两份逐键对拍 harness 全过。
- **生成器幂等**：四个 `gen-*` 的 `--check` 全部「matches」。
- **类型检查**：新增 8 文件 0 error 0 warning（排除厂商陈旧模块的幻影错误后）；
  官方门禁 28 error 均为 `AfcFileExplorer.swift` 的已知幻影组、0 warning。
