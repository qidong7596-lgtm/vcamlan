# VCamLAN —— 给 SkyCam 悬浮面板加一个「网源」按钮

> 目标：iPhone 无越狱（TrollStore + TrollFools 注入），在 SkyCam（Cam.dylib）的悬浮面板上加一个
> **「网源」** 按钮，点了能填局域网地址，走完「恢复 → 写配置 → 重载 → 出画面」，把网络流拉进虚拟摄像头。
>
> 支持两种地址，自动分叉：
>
> | 你填的地址 | 走谁 | 说明 |
> |---|---|---|
> | `rtsp://192.168.1.216:8554/live/obs` | Cam 自带的 RTSP 拉流 | 实测 `DESCRIBE 200 OK` + 出画面 |
> | `http://192.168.1.216:8888/live/obs` | 本插件的 HTTP-FLV 拉流 | 增量解析 FLV + VideoToolbox 硬解 |

---

## 0. 先说清楚：这份代码**没有在真机上编译验证过**

写这份代码的机器是 Windows：没有 Xcode、没有 iOS SDK、没有 Theos、没有 clang、没有设备。
所以下面这些是**已经确认**的，和**还没确认**的，分开放，别混着看。

### 已经确认（有反汇编 / 元数据 / 你的实拍为依据）

| 项 | 依据 |
|---|---|
| `-refreshStatus`（imp 0x40e90）有 12 处引用，是唯一可靠的挂载点 | `objc_full.json` + `__objc_selrefs` 全量扫描 |
| `-networkTapped` / `-albumTapped` / `-fileTapped` 零引用，UI 上不存在 | 同上（**所以绝对不 hook 它们**） |
| `-restoreTapped`（0x44ed4）**只**写 `enabled` 一个键，且是**取反**（`newEnabled = ![cfg isReplaceActive]`） | 0x44ed4..0x45510 逐条反汇编（见第 4 节） |
| 配置路径 `<NSHomeDirectory()>/Library/Preferences/com.douyin.stream.plist` | `_VCamPreferencesPath` 0x834c |
| `source` 必须写 `rtmp`（写 `rtsp` 会被映射成 sourceType=0 = USB） | `loadFromPreferences` 0x8be0..0x8c60 |
| `mediaTransport` 必须精确写小写 `wifi`（否则 prefersUSB=YES，网络分支被抢走） | 0x8ed4..0x8ef0 |
| `port` 的 8888 会被钳成 8554 | 0x8d48 |
| 6 个 swizzle 点的 types 与元数据一致 | `lint_lan.py` 的 [7] 与 [7b] 项，跑出来 6/6 匹配 |
| 上屏唯一通路 `decoder.onFrame → [VCamFrameStore updatePixelBuffer:presentationTime:]` | 0xaa00 / `Cam_pipeline_contract.md` |

### 还没确认（**第一次装上去请照着看日志**）

1. **能不能编译通过**。代码是按 Theos + `library.mk` 写的，`lint_lan.py` 只能做静态检查（括号、`@interface↔@end`、
   签名、禁止项），代替不了 clang。第一次跑 GitHub Actions 时如果报错，把报错行发回来。
2. **「网源」按钮的具体落点**。面板里 6 个按钮的 frame 是运行期算出来的，我只能按
   `transportBtn / mirrorBtn / rotateBtn / muteBtn` 四个有 ivar 名的按钮反推网格矩形，
   再往下让 8pt（并自动避让重叠）。**如果实际位置不好看或盖住 SKY LAB 开关**，
   改 `VCamLANButtonFrameInView()` 里的 `+ 8.0f` 和避让循环即可，不用动别的地方。
3. **面板收起时按钮会不会跟着收**。现在按 `-[VCamFloatingPanel expanded]` 判断，
   收起时把按钮 `hidden = YES`。如果发现收起后按钮还在，说明 `expanded` 这个 selector 在
   你这个版本叫别的名字，日志里会有 `VCamFloatingPanel 没有方法 expanded`。
4. **`panel` 这个 ivar 是不是真的 UIView**。我按 `T@"UIView"` 拿它当容器视图用；
   取不到就退到 `window.rootViewController.view`，日志会打
   `已加「网源」按钮：host=xxx bounds=WxH frame=(...)`，一看就知道落在哪。
5. **http://（自研 FLV）这条路**在真机上的完整表现。rtsp:// 你实测过能出画面；
   FLV 这条是纯本地实现的（`flv_parser.h` + `VCamLANHTTPFLVPuller.m`，1300 行，逻辑未改），
   但**没有在你的设备上跑过**。第一次试建议先试 rtsp:// 确认按钮链路通了，再试 http://。

---

## 1. 你要做的四步（傻瓜版）

```
① 编译出 VCamLAN.dylib       → 走 GitHub Actions，见第 2 节（你不需要装任何东西）
② 注入                        → TrollFools 里选中「抖音/SkyCam」，Add 上 VCamLAN.dylib
③ 打开 SkyCam 面板            → 面板最下面多出一个浅蓝底的「网源」按钮
④ 点「网源」→ 填地址 → 确定    → 自动跑完「恢复 → 写配置 → 重载」，画面就进来了
```

详细一点：

1. **拔掉数据线**（重要，见第 3 节警告 2）。
2. 打开 SkyCam / 抖音的悬浮面板，确认状态是「停止注入」或「当前：停机」都行 —— 不用你去点「恢复」，
   「网源」按钮内部会自己先做一遍停机。
3. 点「网源」，输入框里填：
   - 走 RTSP：`rtsp://192.168.1.216:8554/live/obs`
   - 走 HTTP-FLV：`http://192.168.1.216:8888/live/obs`
   默认值会带出你上次填的地址；也可以只填 `192.168.1.216:8554/live/obs`（不带 `scheme`，
   插件会按端口猜：8554/554 → rtsp，8888/8080 → http）。
4. 点「确定」。观察面板状态文字：
   - 变成 `网源 192.168.1.216` → 配置写进 plist 了；
   - 面板状态变成「视频播放中」→ pipeline 起来了；
   - 还是「停机」→ 去看日志（第 5 节）。
5. 想切回别的片源：直接点面板上的「直连」/「相册」就行，插件会自动判断出你已经不在网源模式，
   把自研拉流器停掉（判据：`prefersUSB == YES` 或 `sourceType != 1` 或 `transport != flv`）。

---

## 2. GitHub Actions 云编译（你不用装 Xcode / Theos）

仓库里已经放好 `.github/workflows/build.yml`，`runs-on: macos-14`，SDK 下载地址写死，全自动。

**你要做的（5 步，全在浏览器里）：**

1. 打开 https://github.com/new ，新建一个仓库（Private 也行），名字随便，比如 `vcaml`。
2. 把 `work/VCamLAN/` 这个目录的**全部内容**上传上去。注意两点：
   - `Makefile` 要在仓库**根目录**（和 `.github/` 同级）；
   - `.github/workflows/build.yml` 的路径不能变，否则 GitHub 不认。
   网页上传：仓库页 → `Add file` → `Upload files` → 把文件拖进去 → `Commit changes`。
   （`work/VCamLAN/` 里现在就是编译所需的全部文件：3 个 `.m`、5 个 `.h`、`Makefile`、`.github/`。）
3. 上传完 GitHub 会自动触发一次构建：仓库页顶部 → **Actions** 标签 → 左边 `build` → 点最新那次运行。
   没自动触发就点 `Run workflow`（workflow 里已经加了 `workflow_dispatch`）。
4. 等 5～15 分钟（第一次要装 Theos + 下 SDK，慢）。绿色 ✓ = 成功；
   红色 ✗ = 点进去看哪一步红，把日志里带 `error:` 的行发回来。
5. 构建成功后在**该次运行页面最底部**的 `Artifacts` 里下载 `VCamLAN.dylib`（是个 zip，解压出 dylib）。

**workflow 到底干了什么（想自己对一遍的话）：**

| 步骤 | 内容 |
|---|---|
| `Checkout` | 拉仓库 |
| `Install build dependencies` | `brew install ldid xz` |
| `Install Theos` | `git clone --recursive https://github.com/theos/theos.git $HOME/theos`，并写进 `$GITHUB_ENV` |
| `Install iOS SDK` | 下 `https://github.com/theos/sdks/archive/refs/heads/master.tar.gz`，优先挑 `iPhoneOS15.6.sdk`，没有就退 `14.5` / `16.5` / 最新，拷进 `$THEOS/sdks/` |
| `Build` | `make clean && make -j all`（`TARGET=iphone:clang:latest:14.0`，`ARCHS=arm64 arm64e`） |
| `Verify no substrate symbol` | `otool -L` 检查产物不依赖 substrate（TrollStore 下没有这个运行时） |
| `Upload artifact` | 上传 `VCamLAN.dylib` + `.theos/obj/**/VCamLAN.dylib` |

---

## 3. 三条警告（都是会真的踩到的坑）

### 警告 1：别点「启动」两次

面板上那个「拉流 / 恢复」是**同一枚按钮的两种状态**，它的实现
`-[VCamFloatingPanel restoreTapped]`（imp 0x44ed4）本质是 **`enabled` 取反**：

```objc
BOOL newEnabled = ![cfg isReplaceActive];      // 0x45080，取反，不是置 NO
[prefs setObject:@(newEnabled) forKeyedSubscript:@"enabled"];   // 唯一写入的键
```

所以连点两次 = 关掉再打开，中间必然黑一下，而且第二次会用**旧地址**把注入重新打开。
「网源」按钮内部已经排好了「先停机 → 250ms 后写新地址」的顺序，**不要再手动补点「恢复」**。

### 警告 2：拉流前把数据线拔掉

`-[VCamStreamPipeline reloadConfig]`（0x37af4）的门槛：

```
netUsb = inject && sourceType==1 && prefersUSB
doRtsp = inject && sourceType==1 && !usbConnected && !netUsb     ← 只有这里成立才会 applyConfig:
```

`usbConnected == YES` 时 `doRtsp` 不成立，网络分支根本不启动。
（插件在 `reloadConfig` 之后会补一次 `applyConfig:` 兜底，但拔线是更可靠的做法。）

### 警告 3：别开爱思助手

爱思助手会装/改描述文件、接管 USB 通道，还会占 8100 / 8888 这类本地端口。
现象是：面板显示「视频播放中」，但画面一直黑，或者拉流器一直重连。
排查时先把爱思关掉、`Documents/VCamLAN.log` 里 `重连=` 那个计数会立刻归零。

---

## 4. `-restoreTapped`（0x44ed4）逐条改了什么

函数体 `0x44ed4..0x45510`，400 条指令。**它只写 `enabled` 一个键，而且写的是取反值。**

| 地址 | 动作 |
|---|---|
| 0x44f04 | `[self stopDetectPreviewLink]` |
| 0x44f14 | `[[VCamFrameStore sharedStore] setDetectPreviewActive:NO]` |
| 0x44f54 | `[[VCamStreamPipeline sharedPipeline] setPreviewPullRequested:NO]` |
| 0x44f88 | `[self setDetectPageVisible:NO]` |
| 0x44f94 | `prefs = [self loadPrefsMutable]` |
| 0x44fb0 | `cfg = [VCamStreamConfig loadFromPreferences]` |
| 0x44fc8 | `if (![cfg hasConfiguredSource])` → 走"空状态"分支：只把 `statusLabel` 置空串 + 橙色，**一个键都不写**，直接返回 |
| 0x45080 | `newEnabled = ![cfg isReplaceActive]`（此分支下 `hasConfiguredSource==YES`，所以等价于 `!enabled`） |
| 0x450cc | **`[prefs setObject:@(newEnabled) forKeyedSubscript:@"enabled"]`** ← 唯一写入 |
| 0x45110 | `[[VCamFrameStore sharedStore] setReplaceEnabled:newEnabled]` |
| 0x45154 | `[[VCamAudioStore sharedStore] setReplaceEnabled:newEnabled]` |
| 0x4516c | `if (!newEnabled) { setCaptureActive:NO; reset; }`（AudioStore） |
| 0x451fc | `_VCamDebugLog(@"A", @"VCamFloatingPanel.m:restoreTapped", @"inject toggle", @{@"wantInject":@(newEnabled), @"monitor":@(!prefs[@"muted"].boolValue)})` ← `muted` 只用于打日志 |
| 0x45334 | `[self savePrefs:prefs]`（writeToFile + loadFromPreferences + setReplaceEnabled + notify_post + 200ms 后刷 UI） |
| 0x45340 | `[self layoutForState]` |
| 0x45388 / 0x453d4 / 0x4540c | `statusLabel.text = <0x3740 / 0x3760>`，`textColor = newEnabled ? 绿 : 橙` |

**一句话结论**：
它**不碰** `host / port / path / source / mediaTransport / localPath`。
它只是把「注入」这个开关翻个面 —— 这就是为什么你「每次切换片源都要先点恢复」：
点它是为了让 pipeline 停干净（`FrameStore/AudioStore.replaceEnabled = NO`），好让下一次配置重读能从头起。

**所以插件不直接调它**（在已经停机的状态下调它 = 反向打开注入，用旧地址），
而是在 `VCamLANGoIdle()` 里按「`newEnabled == NO`」那条路径重写了一遍（只走"关"的半支）。

---

## 5. 出问题了看哪里

日志自动落盘到 App 容器的 `Documents/VCamLAN.log`（`NSLog` 的 stderr 被重定向过去了，
连 Cam 自己的日志也会进来）。用 Filza 打开：`抖音/Documents/VCamLAN.log`。

关键日志行（按出现顺序）：

```
[VCamLAN] loaded 1.0.0-troll ...
[VCamLAN] Cam 真值 plist   = ...
[VCamLAN] 自有配置文件 = ...
[VCamLAN] 已 swizzle VCamStreamPipeline rtspPuller：imp ... → ...
[VCamLAN] 6 个 swizzle 全部就位（第 N 次尝试...）
[VCamLAN] 已加「网源」按钮：host=UIView bounds=320x420 frame=(0,268,320,48) 网格已定位
[VCamLAN] 点到了自绘「网源」按钮
[VCamLAN] 地址解析：scheme=rtsp host=192.168.1.216 port=8554 path=live/obs → rtsp://...
[VCamLAN] —— 第一步：回停机态（复刻 restoreTapped 的关闭半支，enabled=NO）
[VCamLAN] 写盘成功：/var/mobile/Containers/.../com.douyin.stream.plist（校验通过）
[VCamLAN] —— 第二步：按新地址写配置 ...
[VCamLAN] —— 第三步：发重载通知 + 让 pipeline 重读配置
[VCamLAN] 网源已切换：...（状态文案会显示「网源 <host>」）
```

| 现象 | 先看什么 |
|---|---|
| 面板上没有「网源」按钮 | 日志里有没有 `已加「网源」按钮`；没有就是 `refreshStatus` 没被调用，或类没到齐（看 `Cam 的类还没到齐`） |
| 按钮在，点了没反应 | `VCamFloatingPanel 还没就绪` / `拿不到 rootViewController` |
| 点了，状态文字变了，但画面黑 | 有没有 `重连=` 在涨；拔线了吗；`mediaTransport` 回读校验过没过 |
| 切回「直连」后不工作 | 插件会自动停自研拉流器（`当前不是 http 网源模式，停止 FLV puller`） |
| 想改回来 | 点面板「直连」，或者 Filza 删掉 `com.douyin.stream.plist` 里的 `lanURL` 键 |

---

## 6. 文件清单

| 文件 | 作用 |
|---|---|
| `VCamLANMain.m` | 核心：`__attribute__((constructor))` 入口 + 6 个 swizzle + 「网源」按钮 + 输入框 + 轮询 |
| `VCamLANPrefs.h/.m` | `com.douyin.stream.plist` 读写（原子写 + 权限修复 + 回读校验）+ 地址解析 + 自有配置 |
| `VCamLANRuntime.h` | `NSClassFromString` 取类 + `method_getImplementation` 调用工具（对 Cam 零类符号引用） |
| `VCamLAN.h` | 从 `objc_full.json` 还原出来的 Cam 接口子集（只用于编译期类型检查） |
| `VCamLANHTTPFLVPuller.h/.m` | HTTP-FLV 拉流器（1300 行，逻辑未改，只换了类名与一处 `sharedStore` 取法） |
| `flv_parser.h` | 纯 C 的 FLV 增量解析器（383 行） |
| `Makefile` | `library.mk` 出裸 `VCamLAN.dylib`，`ARCHS=arm64 arm64e` |
| `.github/workflows/build.yml` | GitHub Actions 云编译 |
| `lint_lan.py` | 12 项静态自检（`python lint_lan.py`） |

### 自己跑一遍静态检查

```bash
cd work/VCamLAN
python lint_lan.py --dir . --objc-json ../objc_full.json
```

期望输出最后一行：`共 12 项：PASS 12 / FAIL 0` / `全部通过`。
