//
//  VCamLANMain.m —— 「网源」（局域网片源）按钮 + 换源接线（TrollStore 版）
//
//  ============================================================================
//  一、这个文件干的三件事
//  ============================================================================
//    1) 在 SkyCam 悬浮面板上补一个按钮「网源」（tag = 0x4C414E，即 'LAN'）；
//    2) 点它弹出输入框，填 rtsp:// 或 http:// 地址；
//    3) 点「确定」后自动跑完「恢复 → 写配置 → 重载 → 出画面」三步，
//       不需要用户自己去点面板上的「恢复」再切源。
//
//  ============================================================================
//  二、为什么必须挂 -refreshStatus（0x40e90），不能挂别的方法
//  ============================================================================
//    面板 VCamFloatingPanel 共 87 个方法，逐个核过 __objc_selrefs 引用数：
//      -refreshStatus         imp 0x40e90   12 处引用   ← 面板每次刷新都走，唯一可靠挂载点
//      -layoutForState        imp 0x3f074   零引用      ← 不要 hook
//      -networkTapped         imp 0x423dc   零引用      ← 死代码，UI 上根本没有这个按钮
//      -albumTapped           imp 0x43184   零引用      ← 死代码
//      -fileTapped            imp 0x432cc   零引用      ← 死代码
//      -transportTapped       imp 0x43f78   1 处（直连，写死 mediaTransport="usb"）
//      -restoreTapped         imp 0x44ed4   1 处（拉流 / 恢复，同一个按钮两种状态）
//      -mirrorTapped 0x449dc / -rotateTapped 0x44dc4 / -muteTapped 0x44acc
//      -detectTapped 0x441f4 / -detectStartTapped 0x4462c / -collapseTapped 0x422f8
//    「零引用」的意思是：全 __text 里既没有 __objc_selrefs 的 ldr/add 引用，
//    也没有 _objc_msgSend$xxx 这个 thunk 符号 —— 那些按钮从来没被接线过，
//    hook 它们等于装了个空壳还自以为成功。
//
//  ============================================================================
//  三、-restoreTapped（0x44ed4）到底改了什么 —— 逐条反汇编结论
//  ============================================================================
//  函数体 0x44ed4..0x45510，400 条指令。它的本质是 **把 enabled 取反的一次 toggle**，
//  不是"复位"。逐句（地址 → 语义）：
//
//    0x44f04  [self stopDetectPreviewLink]                        停侦测预览链路
//    0x44f14  [[VCamFrameStore sharedStore] setDetectPreviewActive:NO]
//    0x44f54  [[VCamStreamPipeline sharedPipeline] setPreviewPullRequested:NO]
//    0x44f88  [self setDetectPageVisible:NO]
//    0x44f94  prefs = [self loadPrefsMutable]                     读出可变字典
//    0x44fb0  cfg   = [VCamStreamConfig loadFromPreferences]      从磁盘重建 config
//    0x44fc8  if (![cfg hasConfiguredSource]) {                    ← 没有片源就走"空状态"分支
//    0x44ff8       [statusLabel setText:@""]                       （cfstring+0x35c0，空串）
//    0x45018       [statusLabel setTextColor:systemOrangeColor]
//                 然后直接跳尾声，**一个键都不写**，返回
//             }
//    0x45080  w8 = ![cfg isReplaceActive]                        ← 关键：取反，不是置 NO
//                  （因为此分支下 hasConfiguredSource==YES，所以 isReplaceActive == enabled）
//                  ⇒ newEnabled = !enabled
//    0x450cc  [prefs setObject:@(newEnabled) forKeyedSubscript:@"enabled"]   ← **唯一写入的键**
//    0x45110  [[VCamFrameStore sharedStore] setReplaceEnabled:newEnabled]
//    0x45154  [[VCamAudioStore  sharedStore] setReplaceEnabled:newEnabled]
//    0x4516c  if (!newEnabled) {
//    0x451a0       [[VCamAudioStore sharedStore] setCaptureActive:NO]
//    0x451d4       [[VCamAudioStore sharedStore] reset]
//             }
//    0x451fc  _VCamDebugLog(@"A", @"VCamFloatingPanel.m:restoreTapped", @"inject toggle",
//                            @{@"wantInject":@(newEnabled),
//                              @"monitor":@(![prefs[@"muted"] boolValue])})   ← muted 只用于打日志
//    0x45334  [self savePrefs:prefs]        ← writeToFile:atomically: → loadFromPreferences
//                                            → setReplaceEnabled → notify_post → 200ms 后刷 UI
//    0x45340  [self layoutForState]
//    0x45388  [statusLabel setText:<cfstring 0x3740 / 0x3760 二选一>]
//    0x453d4/0x4540c  statusLabel.textColor = newEnabled ? systemGreenColor : systemOrangeColor
//
//  结论（三句话）：
//    ① **它不碰 host / port / path / source / mediaTransport / localPath**，
//       只写 `enabled` 一个键 —— 所以"切片源前点一次恢复"清不掉旧地址，
//       它只是把注入关掉（FrameStore/AudioStore replaceEnabled=NO），让 pipeline 停下来；
//    ② 因为它是**取反**，所以"在已经停机的状态下点恢复"会反向把注入打开（用的是旧地址）——
//       ⇒ 我们**绝不能**直接调 -restoreTapped 来实现"回停机态"，
//          必须自己按"newEnabled == NO"那条路径重写（见下面 VCamLANGoIdle）；
//    ③ 它最后一定走 -savePrefs:，也就是一定会 writeToFile + notify_post + 刷 UI，
//       这解释了用户「每次切换片源都要先点恢复」的手感：靠它把 pipeline 停干净再重来。
//
//  ============================================================================
//  四、两种地址的分叉（同一个按钮，两条链路）
//  ============================================================================
//    rtsp://192.168.1.216:8554/live/obs
//        → transport="rtsp"，host/port/path 分开写，**让 Cam 自带的 VCamRTSPPuller 干活**
//          （它的 pullURL 0x9230 拼 rtsp://host:port/path；实测 DESCRIBE 200 OK + 出画面）
//        → 我们的 rtspPuller hook 返回 orig，完全不插手
//
//    http://192.168.1.216:8888/live/obs
//        → transport="flv"，**path 里存完整 URL**（因为 8888 会被 loadFromPreferences 钳成 8554）
//        → 我们的 rtspPuller hook 返回自研 VCamLANHTTPFLVPuller（HTTP-FLV 增量解析 + VideoToolbox 硬解）
//        → 上屏走同一条通路：decoder.onFrame → [[VCamFrameStore sharedStore] updatePixelBuffer:presentationTime:]
//
//  ============================================================================
//  五、加载顺序
//  ============================================================================
//    __attribute__((constructor)) 先试装一轮；没齐就 100ms × 30 轮询（最多约 3 秒）。
//    对 Cam 的类**零类符号引用**（全部 NSClassFromString），所以即使我们的 dylib
//    排 Cam.dylib 之前加载也不会 dyld abort。
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <errno.h>

#import "VCamLAN.h"
#import "VCamLANPrefs.h"

#define VCAMLAN_VERSION "1.0.0-troll"

#define LANLOG(fmt, ...) NSLog(@"[VCamLAN] " fmt, ##__VA_ARGS__)

// 严格校验 method type encoding：Cam 升级后签名若变了，这一层会拦住错误 hook。
#define VCAMLAN_STRICT_TYPES 1

// 「网源」按钮的 tag：0x4C414E = 'LAN'
#define VCAMLAN_BUTTON_TAG 0x4C414E

// 卡片配色（用户指定：背景 #E6F0FF、文字深蓝）
#define VCAMLAN_BTN_BG_R 0.902f
#define VCAMLAN_BTN_BG_G 0.941f
#define VCAMLAN_BTN_BG_B 1.000f
#define VCAMLAN_BTN_TITLE_R 0.055f
#define VCAMLAN_BTN_TITLE_G 0.204f
#define VCAMLAN_BTN_TITLE_B 0.529f

// 状态缓存的刷新间隔（秒）：rtspPuller / sourceTitle 会被高频调用，不能每次都读盘
static const NSTimeInterval kVCamLANCacheTTL = 0.5;

// ==================================================================
#pragma mark - 日志落盘（无越狱也能看）
// ==================================================================

/// 无越狱环境下 idevicesyslog 要装 libimobiledevice，很多人没有。
/// 这里把 stderr 直接重定向到 App 容器 Documents/VCamLAN.log：
/// NSLog 在 iOS 上写 stderr，重定向之后**所有**日志（含 Cam 自己的）都会落进这个文件。
static NSString *VCamLANLogFilePath(void)
{
    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:documents]) {
        [fm createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return [documents stringByAppendingPathComponent:@"VCamLAN.log"];
}

static void VCamLANStartFileLog(void)
{
    NSString *path = VCamLANLogFilePath();
    if (path.length == 0) return;
    FILE *fp = freopen(path.fileSystemRepresentation, "a", stderr);
    if (fp) {
        setvbuf(stderr, NULL, _IONBF, 0);
        fprintf(stderr, "\n===== VCamLAN %s attach pid=%d %s =====\n",
                VCAMLAN_VERSION, (int)getpid(), NSHomeDirectory().UTF8String);
        fflush(stderr);
    }
}

// ==================================================================
#pragma mark - 当前网源地址缓存
// ==================================================================

static NSString *sVCamLANURL = nil;          // 当前生效的网源地址（nil / 空串 = 没启用）
static NSTimeInterval sVCamLANURLAt = 0;     // 上次从磁盘读的时刻

static NSLock *VCamLANCacheLock(void)
{
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

/// 直接塞缓存（刚写完配置时用，避免 0.5s 内读到旧值）
static void VCamLANSetCachedLANURL(NSString *url)
{
    NSLock *lock = VCamLANCacheLock();
    [lock lock];
    sVCamLANURL = ([url isKindOfClass:[NSString class]] && url.length) ? [url copy] : nil;
    sVCamLANURLAt = [NSDate timeIntervalSinceReferenceDate];
    [lock unlock];
}

/// 取当前网源地址（0.5s TTL，过期就重新读盘）。
/// 读的是 Cam 的 com.douyin.stream.plist 里的 lanURL 标记键（Cam 不认识它，会原样保留）。
/// 用户若只在 Filza 里改了自有配置 VCamLAN.plist，这里也能兜到。
static NSString *VCamLANCachedLANURL(void)
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    NSLock *lock = VCamLANCacheLock();
    [lock lock];
    NSString *cached = sVCamLANURL;
    NSTimeInterval at = sVCamLANURLAt;
    [lock unlock];

    // 注意：TTL 判断要看"上次读盘时刻"，不能看 "cached 是否非空"。
    // 否则"当前没有网源"这种情况下每次调用都会去读一遍 plist（rtspPuller 会被高频调用）。
    if (at > 0 && (now - at) <= kVCamLANCacheTTL) {
        return cached.length ? cached : nil;
    }

    NSString *fresh = nil;
    @try {
        NSDictionary *prefs = VCamLANLoadPrefs();
        id u = prefs[VCamLANURLKey];
        if ([u isKindOfClass:[NSString class]] && [u length]) fresh = u;
        if (!fresh.length) fresh = VCamLANOwnConfigURL();   // 兜底：自有配置
    } @catch (NSException *e) {
        LANLOG(@"读网源配置异常：%@", e.reason);
    }

    NSLock *lock2 = VCamLANCacheLock();
    [lock2 lock];
    sVCamLANURL = fresh.length ? [fresh copy] : nil;
    sVCamLANURLAt = now;
    [lock2 unlock];

    return fresh.length ? fresh : nil;
}

/// 当前配置是不是"网源模式"。
/// 光看 lanURL 不够 —— 用户在面板上点「直连」时 Cam 会把 mediaTransport 写回 "usb"，
/// 但 loadPrefsMutable 带出来的字典里 lanURL 还在。不加这四个条件就会把「直连」抢掉。
static BOOL VCamLANConfigIsLAN(id cfg)
{
    NSString *lan = VCamLANCachedLANURL();
    if (lan.length == 0) return NO;
    if (cfg == nil) return YES;   // 拿不到 config（类还没就绪）就按标记键算

    @try {
        if (VCamLANDynBool(cfg, @"prefersUSB")) return NO;          // mediaTransport != "wifi"
        if (VCamLANDynInteger(cfg, @"sourceType") != 1) return NO;  // 不是网络片源
        NSString *host = VCamLANDynObj(cfg, @"host");
        NSString *lanHost = VCamLANHostOfURL(lan);
        if ([host isKindOfClass:[NSString class]] && host.length
            && lanHost.length && ![host isEqualToString:lanHost]) {
            return NO;    // 用户手填了别的主机 → 不是我们写进去的那条
        }
        if (VCamLANURLLooksFLV(lan)) {
            NSString *transport = VCamLANDynObj(cfg, @"transport");
            if (![transport isKindOfClass:[NSString class]]) return NO;
            if (![[transport lowercaseString] isEqualToString:@"flv"]) return NO;
        }
        return YES;
    } @catch (NSException *e) {
        LANLOG(@"判定网源模式异常：%@", e.reason);
        return NO;
    }
}

/// http(s) → 自研 FLV puller；rtsp → Cam 自带 RTSPPuller
static BOOL VCamLANWantsFLVPuller(void)
{
    NSString *lan = VCamLANCachedLANURL();
    return VCamLANURLLooksFLV(lan);
}

// ==================================================================
#pragma mark - 面板 / 视图取用
// ==================================================================

static UIWindow *VCamLANPanelWindow(id panel)
{
    @try {
        id w = VCamLANDynObj(panel, @"window");
        if ([w isKindOfClass:[UIWindow class]]) return (UIWindow *)w;
    } @catch (NSException *e) {
        LANLOG(@"取 panel.window 异常：%@", e.reason);
    }
    return nil;
}

static UIViewController *VCamLANKeyRootViewController(void)
{
    @try {
        UIWindow *key = UIApplication.sharedApplication.keyWindow;
        if (key.rootViewController) return key.rootViewController;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow && w.rootViewController) return w.rootViewController;
        }
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.rootViewController) return w.rootViewController;
        }
    } @catch (NSException *e) {
        LANLOG(@"取 keyWindow.rootViewController 异常：%@", e.reason);
    }
    return nil;
}

static UIViewController *VCamLANRootOfPanel(id panel)
{
    UIViewController *root = VCamLANPanelWindow(panel).rootViewController;
    if (root) return root;
    return VCamLANKeyRootViewController();
}

/// 按钮要加在哪个视图上：优先面板自己的容器视图（panel.panel，T@"UIView" ivar +0x50），
/// 它的 bounds 就是面板本体尺寸 —— 相对定位比放在全屏 window 上稳得多。
/// 容器还没布局好（尺寸太小）就退到 window 的 rootViewController.view。
static UIView *VCamLANPanelHostView(id panel)
{
    UIView *panelView = nil;
    @try {
        id v = VCamLANDynObj(panel, @"panel");
        if ([v isKindOfClass:[UIView class]]) panelView = (UIView *)v;
    } @catch (NSException *e) { /* 取不到就往下走 */ }

    if (panelView && panelView.bounds.size.width > 100 && panelView.bounds.size.height > 100) {
        return panelView;
    }

    UIWindow *w = VCamLANPanelWindow(panel);
    UIView *root = w.rootViewController.view ?: w;
    if (panelView && root == nil) return panelView;
    return root;
}

// ==================================================================
#pragma mark - 回「停机态」（复刻 -restoreTapped 的 newEnabled==NO 那条路径）
// ==================================================================
//
//  ⚠️ 不能直接调 -restoreTapped：
//     它的核心是 `newEnabled = ![cfg isReplaceActive]`（0x45080），是一枚 toggle。
//     在「已经停机」的状态下点它 = 用旧地址把注入重新打开，
//     那正好和我们要的"先停干净再换源"相反。
//
//  所以这里按 0x44f04..0x451e8 那一段逐句重写一遍，只走"关"的半支：
//    停侦测预览 → FrameStore.detectPreviewActive=NO → previewPullRequested=NO
//    → detectPageVisible=NO → enabled=NO → FrameStore/AudioStore.replaceEnabled=NO
//    → AudioStore.captureActive=NO → AudioStore.reset → savePrefs:（写盘 + notify + 刷 UI）
//    → layoutForState → 停掉自研 puller
//
static void VCamLANGoIdle(id panel)
{
    LANLOG(@"—— 第一步：回停机态（复刻 restoreTapped 的关闭半支，enabled=NO）");

    @try {
        VCamLANDynCallVoid(panel, @"stopDetectPreviewLink");

        id frameStore = VCamLANDynClassMsg(@"VCamFrameStore", @"sharedStore");
        VCamLANDynCallVoidBool(frameStore, @"setDetectPreviewActive:", NO);

        id pipeline = VCamLANDynClassMsg(@"VCamStreamPipeline", @"sharedPipeline");
        VCamLANDynCallVoidBool(pipeline, @"setPreviewPullRequested:", NO);

        VCamLANDynCallVoidBool(panel, @"setDetectPageVisible:", NO);

        // 取面板自己的可变字典（Cam 的读法），保留 rotation / mirrored / muted 等原值
        NSMutableDictionary *prefs = nil;
        id p = VCamLANDynObj(panel, @"loadPrefsMutable");
        if ([p isKindOfClass:[NSMutableDictionary class]]) {
            prefs = (NSMutableDictionary *)p;
        } else {
            prefs = VCamLANLoadPrefs();
        }
        if (!prefs) prefs = [NSMutableDictionary dictionary];

        [prefs setObject:@NO forKeyedSubscript:@"enabled"];   // ← restoreTapped 唯一写的键

        VCamLANDynCallVoidBool(frameStore, @"setReplaceEnabled:", NO);

        id audioStore = VCamLANDynClassMsg(@"VCamAudioStore", @"sharedStore");
        VCamLANDynCallVoidBool(audioStore, @"setReplaceEnabled:", NO);
        VCamLANDynCallVoidBool(audioStore, @"setCaptureActive:", NO);
        VCamLANDynCallVoid(audioStore, @"reset");

        VCamLANWritePrefsDict(prefs);
        VCamLANDynCallVoidObj(panel, @"savePrefs:", prefs);
        VCamLANDynCallVoid(panel, @"layoutForState");
        VCamLANPostReloadNotification();

        [[VCamLANHTTPFLVPuller shared] stop];
    } @catch (NSException *e) {
        LANLOG(@"回停机态异常：%@", e.reason);
    }
}

// ==================================================================
#pragma mark - 应用一条地址（三步：恢复 → 写配置 → 重载）
// ==================================================================

/// 第二步 + 第三步：写新片源配置并启动。
/// 放在 250ms 之后执行，是为了让第一步的 enabled=NO / notify_post 在 pipeline 里先落地，
/// 同时对齐 -savePrefs: 内部「200ms 后刷 UI」的节奏（0x40c90 之后那一段）。
static void VCamLANCommitURL(id panel, NSString *normalized)
{
    @autoreleasepool {
        LANLOG(@"—— 第二步：按新地址写配置 %@", normalized);

        VCamLANSetCachedLANURL(normalized);

        NSMutableDictionary *prefs = nil;
        id p = VCamLANDynObj(panel, @"loadPrefsMutable");
        if ([p isKindOfClass:[NSMutableDictionary class]]) {
            prefs = (NSMutableDictionary *)p;
        } else {
            prefs = VCamLANLoadPrefs();
        }
        if (!prefs) prefs = [NSMutableDictionary dictionary];

        if (!VCamLANFillPrefsWithURL(prefs, normalized)) {
            LANLOG(@"写配置失败：地址解析不过（见上一条日志）");
            return;
        }

        BOOL ok = VCamLANWritePrefsDict(prefs);
        VCamLANSaveOwnConfigURL(normalized);

        @try {
            // 交给 Cam 自己的保存路径再走一遍：
            // writeToFile → loadFromPreferences → FrameStore/AudioStore setReplaceEnabled
            //   → notify_post("com.douyin.stream.reload") → 200ms 后刷 UI
            VCamLANDynCallVoidObj(panel, @"savePrefs:", prefs);
            VCamLANDynCallVoid(panel, @"layoutForState");
        } @catch (NSException *e) {
            LANLOG(@"savePrefs:/layoutForState 异常（已用自己写的那份兜底）：%@", e.reason);
        }

        LANLOG(@"—— 第三步：发重载通知 + 让 pipeline 重读配置（写盘%@）", ok ? @"成功" : @"失败");
        VCamLANPostReloadNotification();

        @try {
            id pipeline = VCamLANDynClassMsg(@"VCamStreamPipeline", @"sharedPipeline");
            VCamLANDynCallVoid(pipeline, @"reloadConfig");

            // reloadConfig 里的门槛（0x37af4）：
            //   netUsb = inject && sourceType==1 && prefersUSB
            //   doRtsp = inject && sourceType==1 && !usbConnected && !netUsb  → 才 applyConfig:
            // 拔了数据线、mediaTransport=wifi、source=rtmp 时它必然成立；
            // 万一不成立（比如线还插着、usbConnected=YES），这里补一次 applyConfig:，
            // 让自研 puller 自己去看配置 —— 它不依赖 usbConnected。
            VCamLANHTTPFLVPuller *flv = [VCamLANHTTPFLVPuller shared];
            if (VCamLANWantsFLVPuller()) {
                id cfg = VCamLANDynObj(pipeline, @"config");
                if (cfg && (![flv isRunning] || ![[flv appliedStreamURL] isEqualToString:normalized])) {
                    LANLOG(@"reloadConfig 之后 puller 仍未在跑，补一次 applyConfig:");
                    [flv applyConfig:(VCamStreamConfig *)cfg];
                }
            }
        } @catch (NSException *e) {
            LANLOG(@"reloadConfig 异常：%@", e.reason);
        }

        LANLOG(@"网源已切换：%@（状态文案会显示「网源 <host>」）", normalized);
    }
}

/// 用户点「确定」后的完整流程。return NO 表示地址本身不合法（此时配置一点没动）。
static BOOL VCamLANApplyURLText(NSString *rawText, id panel)
{
    NSString *scheme = nil, *host = nil, *path = nil, *norm = nil;
    NSInteger port = 0;
    if (!VCamLANParseStreamURL(rawText, &scheme, &host, &port, &path, &norm)) {
        return NO;
    }

    LANLOG(@"收到地址：%@ → 归一化 %@（%@，走 %@）",
          rawText, norm, scheme, VCamLANURLLooksFLV(norm) ? @"自研 FLV puller" : @"Cam 自带 RTSP puller");

    // 第一步：先停机（等价于用户手动点一次「恢复」，但不会反向打开注入）
    VCamLANGoIdle(panel);

    // 第二、三步：250ms 后写新片源 + 启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        VCamLANCommitURL(panel, norm);
    });

    return YES;
}

// ==================================================================
#pragma mark - 输入框
// ==================================================================

static void VCamLANPresentInput(id panel)
{
    UIViewController *root = VCamLANRootOfPanel(panel);
    if (!root) {
        LANLOG(@"拿不到 rootViewController，无法弹出输入框");
        return;
    }

    @try {
        if (root.presentedViewController) {
            [root.presentedViewController dismissViewControllerAnimated:NO completion:nil];
        }
    } @catch (NSException *e) { /* 收不起来也能继续弹 */ }

    NSString *current = VCamLANCachedLANURL();
    if (current.length == 0) current = VCamLANOwnConfigURL();

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"局域网片源（网源）"
                                            message:@"填 rtsp:// 或 http:// 地址。点「确定」会自动完成：\n"
                                                    @"① 先回停机态（等价于点一次「恢复」）\n"
                                                    @"② 按这条地址写配置\n"
                                                    @"③ 重载 pipeline 并出画面\n\n"
                                                    @"rtsp:// 走 Cam 自带 RTSP 拉流（8554）\n"
                                                    @"http:// 走本插件的 HTTP-FLV 拉流（8888）"
                                     preferredStyle:UIAlertControllerStyleAlert];

    __weak UIAlertController *weakAlert = alert;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"rtsp://192.168.1.216:8554/live/obs";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.spellCheckingType = UITextSpellCheckingTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.returnKeyType = UIReturnKeyDone;
        if (current.length) tf.text = current;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSString *text = weakAlert.textFields.firstObject.text;
        if (!VCamLANApplyURLText(text, panel)) {
            LANLOG(@"地址不合法，已忽略：%@", text);
            // 弹一个小提示，别让用户以为按钮没反应
            UIAlertController *warn =
                [UIAlertController alertControllerWithTitle:@"地址不合法"
                                                    message:@"示例：rtsp://192.168.1.216:8554/live/obs\n"
                                                            @"或 http://192.168.1.216:8888/live/obs"
                                             preferredStyle:UIAlertControllerStyleAlert];
            [warn addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
            UIViewController *r = VCamLANRootOfPanel(panel);
            if (r) [r presentViewController:warn animated:YES completion:nil];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    dispatch_async(dispatch_get_main_queue(), ^{
        [root presentViewController:alert animated:YES completion:nil];
    });
}

// ==================================================================
#pragma mark - 「网源」按钮
// ==================================================================

/// UIButton 的 target 必须是个对象，所以补一个本工程自己的小类（不是 hook，就是个普通类）
@interface VCamLANButtonTarget : NSObject
+ (instancetype)shared;
- (void)lanTapped:(id)sender;
@end

@implementation VCamLANButtonTarget

+ (instancetype)shared
{
    static VCamLANButtonTarget *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[VCamLANButtonTarget alloc] init];
    });
    return inst;
}

- (void)lanTapped:(id)sender
{
    (void)sender;
    LANLOG(@"点到了自绘「网源」按钮");
    id panel = VCamLANDynClassMsg(@"VCamFloatingPanel", @"shared");
    if (!panel) {
        LANLOG(@"VCamFloatingPanel 还没就绪，按钮点了没反应");
        return;
    }
    VCamLANPresentInput(panel);
}

@end

/// 取按钮网格的矩形（在 host 坐标系里）。
/// 四个有 ivar 名的按钮就能框住整个 3×2 网格：
///   transportBtn（直连，第 1 行）/ muteBtn（内录，第 1 行）
///   mirrorBtn（镜像，第 2 行）/ rotateBtn（旋转，第 2 行）
/// 相册 和 拉流 两个按钮是 setupWhenReady 里局部创建的，没有留 ivar 名，
/// 但它们的 frame 一定落在这个并集里，所以不影响定位。
static CGRect VCamLANGridRectInView(id panel, UIView *host)
{
    CGRect uni = CGRectNull;
    NSArray<NSString *> *sels = @[@"transportBtn", @"mirrorBtn", @"rotateBtn", @"muteBtn"];
    for (NSString *sel in sels) {
        id b = VCamLANDynObj(panel, sel);
        if (![b isKindOfClass:[UIView class]]) continue;
        UIView *v = (UIView *)b;
        if (v.isHidden || v.alpha < 0.05f || v.superview == nil) continue;
        CGRect f = [v convertRect:v.bounds toView:host];
        if (CGRectIsEmpty(f) || f.size.width < 8 || f.size.height < 8) continue;
        uni = CGRectIsNull(uni) ? f : CGRectUnion(uni, f);
    }
    return uni;
}

/// 计算「网源」按钮的 frame（host 坐标系）
///   首选：贴在按钮网格正下方一行（x/宽度对齐网格，高度 48，间隔 8pt）
///   避让：往下找第一个不与任何兄弟视图重叠的位置（最多推 8 次）
///   兜底：网格还没布局出来 → 贴在容器底部（左右留 12pt）
static CGRect VCamLANButtonFrameInView(id panel, UIView *host, BOOL *outFoundGrid)
{
    const CGFloat h = 48.0f;
    const CGFloat minW = 140.0f;
    CGRect bounds = host.bounds;
    CGRect grid = VCamLANGridRectInView(panel, host);

    CGFloat x = 0, y = 0, w = 0;
    BOOL foundGrid = (!CGRectIsNull(grid) && grid.size.width >= 40.0f);

    if (foundGrid) {
        x = grid.origin.x;
        w = MAX(grid.size.width, minW);
        y = CGRectGetMaxY(grid) + 8.0f;

        for (int iter = 0; iter < 8; iter++) {
            CGRect band = CGRectMake(x, y, w, h);
            CGFloat push = -1.0f;
            for (UIView *sib in host.subviews) {
                if (sib == nil || sib.isHidden || sib.alpha < 0.05f) continue;
                if (sib.tag == VCAMLAN_BUTTON_TAG) continue;
                CGRect f = [sib convertRect:sib.bounds toView:host];
                if (CGRectIsEmpty(f) || f.size.height < 8.0f) continue;
                if (CGRectIntersectsRect(f, band)) {
                    push = MAX(push, CGRectGetMaxY(f) + 8.0f);
                }
            }
            if (push < 0) break;
            y = push;
        }
    } else {
        x = 12.0f;
        w = MAX(bounds.size.width - 24.0f, minW);
        y = bounds.size.height - h - 10.0f;
    }

    // 收进容器：底部溢出就贴底，右侧溢出就缩宽
    if (y + h > bounds.size.height - 4.0f) y = MAX(bounds.size.height - h - 6.0f, 0.0f);
    if (x < 0) x = 0;
    if (x + w > bounds.size.width - 4.0f) w = MAX(bounds.size.width - x - 6.0f, minW);

    if (outFoundGrid) *outFoundGrid = foundGrid;
    return CGRectMake(x, y, w, h);
}

/// 幂等：refreshStatus 会高频调用，必须靠 viewWithTag 判重，不能每次都 addSubview。
static void VCamLANEnsureButton(id panel)
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            VCamLANEnsureButton(panel);
        });
        return;
    }

    @try {
        UIView *host = VCamLANPanelHostView(panel);
        if (!host) return;

        CGRect bounds = host.bounds;
        if (bounds.size.width < 60 || bounds.size.height < 60) return;   // 还没布局好，下次再说

        UIView *existing = [host viewWithTag:VCAMLAN_BUTTON_TAG];

        // 面板收起时把按钮一起收起来（expanded = NO 只显示一个泡泡）
        BOOL expanded = VCamLANDynBool(panel, @"expanded");
        if (!expanded) {
            if (existing) existing.hidden = YES;
            return;
        }

        BOOL foundGrid = NO;
        CGRect frame = VCamLANButtonFrameInView(panel, host, &foundGrid);

        if (existing) {
            if (!CGRectEqualToRect(existing.frame, frame)) existing.frame = frame;
            if (existing.hidden) existing.hidden = NO;
            return;
        }

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.tag = VCAMLAN_BUTTON_TAG;
        [btn setTitle:@"网源" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        [btn setTitleColor:[UIColor colorWithRed:VCAMLAN_BTN_TITLE_R
                                           green:VCAMLAN_BTN_TITLE_G
                                            blue:VCAMLAN_BTN_TITLE_B
                                           alpha:1.0]
                  forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:VCAMLAN_BTN_BG_R
                                              green:VCAMLAN_BTN_BG_G
                                               blue:VCAMLAN_BTN_BG_B
                                              alpha:1.0];
        btn.layer.cornerRadius = 10.0;
        btn.layer.masksToBounds = YES;
        btn.layer.borderWidth = 1.0;
        btn.layer.borderColor = [UIColor colorWithRed:0.72 green:0.82 blue:1.0 alpha:1.0].CGColor;
        btn.frame = frame;
        btn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
        [btn addTarget:[VCamLANButtonTarget shared]
                action:@selector(lanTapped:)
      forControlEvents:UIControlEventTouchUpInside];

        [host addSubview:btn];

        LANLOG(@"已加「网源」按钮：host=%@ bounds=%.0fx%.0f frame=(%.0f,%.0f,%.0f,%.0f) 网格%@",
              NSStringFromClass([host class]), bounds.size.width, bounds.size.height,
              frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
              foundGrid ? @"已定位" : @"未定位（贴底兜底）");
    } @catch (NSException *e) {
        LANLOG(@"加「网源」按钮异常：%@", e.reason);
    }
}

// ==================================================================
#pragma mark - swizzle 基建（不依赖 substrate.h / Logos）
// ==================================================================

/// 手写 swizzle。幂等 + 防"orig 被我们自己的实现覆盖导致无限递归"：
///   · method_setImplementation 会**永久**改掉 IMP，重复调用时 cur 就是我们的实现；
///     此时若照旧执行 *outOrig = cur，orig 就变成我们自己 → hook 里调 orig 直接自我递归爆栈。
///   · 所以先判 cur == newImp，命中即视为"已装好"，只返回不再写 orig。
static BOOL vcaml_swizzle(Class cls, SEL sel, IMP newImp, IMP *outOrig)
{
    if (!cls || !sel || !newImp) return NO;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        LANLOG(@"%@ 没有方法 %s，跳过", NSStringFromClass(cls), sel_getName(sel));
        return NO;
    }

    IMP cur = method_getImplementation(m);
    if (cur == newImp) {
        if (outOrig && *outOrig == NULL) {
            LANLOG(@"%s 已经是本实现但 orig 未知（同库被注入两次？），保持不动", sel_getName(sel));
        }
        return YES;
    }

    if (outOrig) *outOrig = cur;
    method_setImplementation(m, newImp);
    LANLOG(@"已 swizzle %@ %s：imp %p → %p（orig=%p）",
           NSStringFromClass(cls), sel_getName(sel), (void *)cur, (void *)newImp,
           outOrig ? (void *)*outOrig : NULL);
    return YES;
}

/// 带签名复核的 swizzle：types 不一致就不 hook（签名错了必崩，宁可这一项不动）
static BOOL vcaml_swizzle_checked(Class cls, SEL sel, IMP newImp, IMP *outOrig, const char *expectTypes)
{
    if (!cls || !sel || !newImp) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        LANLOG(@"%@ 没有方法 %s，跳过", NSStringFromClass(cls), sel_getName(sel));
        return NO;
    }
#if VCAMLAN_STRICT_TYPES
    const char *t = method_getTypeEncoding(m);
    if (expectTypes && (!t || strcmp(t, expectTypes) != 0)) {
        LANLOG(@"%@ %s 的 types 不符：读到 %s，期望 %s —— 跳过这一项（签名不一致会崩）",
               NSStringFromClass(cls), sel_getName(sel), t ? t : "(null)", expectTypes);
        return NO;
    }
#else
    (void)expectTypes;
#endif
    return vcaml_swizzle(cls, sel, newImp, outOrig);
}

// ---- 6 个原实现（每个 hook 一个全局，签名与 objc_full.json 的 types 严格对应）----
static id   (*orig_rtspPuller)(id, SEL)        = NULL;   // @16@0:8
static void (*orig_reloadConfig)(id, SEL)      = NULL;   // v16@0:8
static void (*orig_applyRuntimeFlags)(id, SEL) = NULL;   // v16@0:8
static id   (*orig_sourceTitle)(id, SEL)       = NULL;   // @16@0:8
static id   (*orig_pullURL)(id, SEL)           = NULL;   // @16@0:8
static void (*orig_refreshStatus)(id, SEL)     = NULL;   // v16@0:8

// ==================================================================
#pragma mark - hook 实现：VCamStreamPipeline
// ==================================================================

// 换源核心：网源 + http(s) → 返回自己的 FLV puller；其余（含 rtsp 网源、直连、相册）走原实现
static id vcaml_rtspPuller(id self, SEL _cmd)
{
    @try {
        id cfg = VCamLANDynObj(self, @"config");
        if (VCamLANConfigIsLAN(cfg) && VCamLANWantsFLVPuller()) {
            static NSString *lastLogged = nil;
            NSString *now = VCamLANCachedLANURL();
            if (![now isEqualToString:lastLogged]) {
                lastLogged = now;
                LANLOG(@"rtspPuller → 返回自研 FLV puller（%@）", now);
            }
            return [VCamLANHTTPFLVPuller shared];
        }
    } @catch (NSException *e) {
        LANLOG(@"rtspPuller hook 异常：%@", e.reason);
    }
    if (orig_rtspPuller) return orig_rtspPuller(self, _cmd);
    return nil;
}

// reloadConfig 收尾：确保 FLV puller 与最新配置一致（起 / 停 / 只同步运行时参数）
static void vcaml_reloadConfig(id self, SEL _cmd)
{
    if (orig_reloadConfig) orig_reloadConfig(self, _cmd);

    @try {
        VCamLANHTTPFLVPuller *flv = [VCamLANHTTPFLVPuller shared];
        id cfg = VCamLANDynObj(self, @"config");

        BOOL lanFLV = VCamLANConfigIsLAN(cfg) && VCamLANWantsFLVPuller();
        if (lanFLV) {
            NSString *want = VCamLANCachedLANURL();
            NSString *cur = [flv appliedStreamURL];
            if (![cur isEqualToString:want] || ![flv isRunning]) {
                // orig 里可能已经 applyConfig: 过一次；URL 一致时不会重连。
                // 走到这里说明没起来（未授权早退 / previewPullRequested=NO / usbConnected=YES），补一次。
                LANLOG(@"reloadConfig：FLV puller 未在跑（当前=%@ 目标=%@），补发 applyConfig:",
                       cur.length ? cur : @"(无)", want.length ? want : @"(空)");
                if (cfg) [flv applyConfig:(VCamStreamConfig *)cfg];
            } else {
                if (cfg) [flv updateRuntimeFlagsFromConfig:(VCamStreamConfig *)cfg];
            }
            LANLOG(@"reloadConfig：网源(FLV) 模式 url=%@ running=%d", want, (int)[flv isRunning]);
        } else if ([flv isRunning]) {
            LANLOG(@"reloadConfig：当前不是 http 网源模式，停止 FLV puller");
            [flv stop];
        }
    } @catch (NSException *e) {
        LANLOG(@"reloadConfig hook 异常：%@", e.reason);
    }
}

// 运行时开关同步（原实现已经把 mirrored / muted / rotation 灌进 FrameStore，这里同步给 FLV 侧）
static void vcaml_applyRuntimeFlags(id self, SEL _cmd)
{
    if (orig_applyRuntimeFlags) orig_applyRuntimeFlags(self, _cmd);

    @try {
        id cfg = VCamLANDynObj(self, @"config");
        if (cfg && VCamLANConfigIsLAN(cfg) && VCamLANWantsFLVPuller()) {
            [[VCamLANHTTPFLVPuller shared] updateRuntimeFlagsFromConfig:(VCamStreamConfig *)cfg];
        }
    } @catch (NSException *e) {
        LANLOG(@"applyRuntimeFlags hook 异常：%@", e.reason);
    }
}

// ==================================================================
#pragma mark - hook 实现：VCamStreamConfig
// ==================================================================

// 面板上显示的名字（原实现：未选择 / USB 直连 / 本地视频 / Wi-Fi %@）
static id vcaml_sourceTitle(id self, SEL _cmd)
{
    @try {
        if (VCamLANConfigIsLAN(self)) {
            NSString *lan = VCamLANCachedLANURL();
            NSString *host = VCamLANHostOfURL(lan);
            if (host.length) return [NSString stringWithFormat:@"网源 %@", host];
            return @"网源";
        }
    } @catch (NSException *e) {
        LANLOG(@"sourceTitle hook 异常：%@", e.reason);
    }
    if (orig_sourceTitle) return orig_sourceTitle(self, _cmd);
    return @"";
}

// 诊断日志 / activeDiagnostic 里用到的 url（原实现固定拼 rtsp://host:port/path）
static id vcaml_pullURL(id self, SEL _cmd)
{
    @try {
        if (VCamLANConfigIsLAN(self)) {
            NSString *lan = VCamLANCachedLANURL();
            if (lan.length) return lan;
        }
    } @catch (NSException *e) {
        LANLOG(@"pullURL hook 异常：%@", e.reason);
    }
    if (orig_pullURL) return orig_pullURL(self, _cmd);
    return @"";
}

// ==================================================================
#pragma mark - hook 实现：VCamFloatingPanel
// ==================================================================
//
// 为什么挂 refreshStatus（12 处引用）而不是 networkTapped（0 处引用）：
//   -networkTapped (0x423dc) 在这个 build 里零引用，按钮根本没接线，hook 它等于装空壳。
//   -refreshStatus (0x40e90) 面板每次刷新都走，正好用来「确保自绘按钮存在」+ 顺带同步状态。
//
static void vcaml_refreshStatus(id self, SEL _cmd)
{
    if (orig_refreshStatus) orig_refreshStatus(self, _cmd);

    static NSTimeInterval lastSync = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    @try {
        VCamLANEnsureButton(self);
    } @catch (NSException *e) {
        LANLOG(@"refreshStatus：加按钮异常：%@", e.reason);
    }

    // 高频调用，配置侧动作节流到 0.5s
    if (now - lastSync > kVCamLANCacheTTL) {
        lastSync = now;
        @try {
            VCamLANCachedLANURL();   // 触发一次读盘刷新缓存
        } @catch (NSException *e) {
            LANLOG(@"refreshStatus：刷新网源缓存异常：%@", e.reason);
        }
    }
}

// ==================================================================
#pragma mark - 安装 / 轮询
// ==================================================================

static BOOL VCamLANAllInstalled(void)
{
    return orig_rtspPuller && orig_reloadConfig && orig_applyRuntimeFlags
        && orig_sourceTitle && orig_pullURL && orig_refreshStatus;
}

static BOOL VCamLANLoggedMissing = NO;

/// 装一轮，返回本次新装上的 hook 数
static NSUInteger VCamLANTryInstall(void)
{
    NSUInteger n = 0;

    Class pipeCls  = VCamLANDynClass(@"VCamStreamPipeline");
    Class confCls  = VCamLANDynClass(@"VCamStreamConfig");
    Class panelCls = VCamLANDynClass(@"VCamFloatingPanel");

    if (!pipeCls || !confCls || !panelCls) {
        if (!VCamLANLoggedMissing) {
            VCamLANLoggedMissing = YES;
            LANLOG(@"Cam 的类还没到齐：VCamStreamPipeline=%@ VCamStreamConfig=%@ VCamFloatingPanel=%@",
                   pipeCls ? @"有" : @"无", confCls ? @"有" : @"无", panelCls ? @"有" : @"无");
        }
    }

    if (pipeCls) {
        if (!orig_rtspPuller &&
            vcaml_swizzle_checked(pipeCls, @selector(rtspPuller),
                                  (IMP)vcaml_rtspPuller, (IMP *)&orig_rtspPuller, "@16@0:8")) {
            n++;
        }
        if (!orig_reloadConfig &&
            vcaml_swizzle_checked(pipeCls, @selector(reloadConfig),
                                  (IMP)vcaml_reloadConfig, (IMP *)&orig_reloadConfig, "v16@0:8")) {
            n++;
        }
        if (!orig_applyRuntimeFlags &&
            vcaml_swizzle_checked(pipeCls, @selector(applyRuntimeFlags),
                                  (IMP)vcaml_applyRuntimeFlags, (IMP *)&orig_applyRuntimeFlags, "v16@0:8")) {
            n++;
        }
    }

    if (confCls) {
        if (!orig_sourceTitle &&
            vcaml_swizzle_checked(confCls, @selector(sourceTitle),
                                  (IMP)vcaml_sourceTitle, (IMP *)&orig_sourceTitle, "@16@0:8")) {
            n++;
        }
        if (!orig_pullURL &&
            vcaml_swizzle_checked(confCls, @selector(pullURL),
                                  (IMP)vcaml_pullURL, (IMP *)&orig_pullURL, "@16@0:8")) {
            n++;
        }
    }

    if (panelCls) {
        if (!orig_refreshStatus &&
            vcaml_swizzle_checked(panelCls, @selector(refreshStatus),
                                  (IMP)vcaml_refreshStatus, (IMP *)&orig_refreshStatus, "v16@0:8")) {
            n++;
        }
    }

    return n;
}

static const NSUInteger kVCamLANMaxAttempts = 30;          // 30 次
static const NSTimeInterval kVCamLANRetryInterval = 0.1;   // 每次 100ms → 最多等 3 秒

/// 装完打印一张表，方便对照 objc_full.json 核对
static void VCamLANLogHookTable(void)
{
    const struct { const char *cls; const char *sel; IMP *orig; } items[] = {
        { "VCamStreamPipeline", "rtspPuller",        (IMP *)&orig_rtspPuller },
        { "VCamStreamPipeline", "reloadConfig",      (IMP *)&orig_reloadConfig },
        { "VCamStreamPipeline", "applyRuntimeFlags", (IMP *)&orig_applyRuntimeFlags },
        { "VCamStreamConfig",   "sourceTitle",       (IMP *)&orig_sourceTitle },
        { "VCamStreamConfig",   "pullURL",           (IMP *)&orig_pullURL },
        { "VCamFloatingPanel",  "refreshStatus",     (IMP *)&orig_refreshStatus },
    };
    for (size_t i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
        Class cls = NSClassFromString([NSString stringWithUTF8String:items[i].cls]);
        SEL sel = sel_registerName(items[i].sel);
        Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
        const char *types = m ? method_getTypeEncoding(m) : "(无)";
        BOOL hooked = items[i].orig && *items[i].orig != NULL;
        LANLOG(@"  %-20s -%-18s types=%-8s %@",
               items[i].cls, items[i].sel, types, hooked ? @"已 hook" : @"未装上");
    }
}

static void VCamLANInstallLoop(void)
{
    for (NSUInteger i = 1; i <= kVCamLANMaxAttempts; i++) {
        NSUInteger n = VCamLANTryInstall();
        if (VCamLANAllInstalled()) {
            LANLOG(@"6 个 swizzle 全部就位（第 %lu 次尝试，累计等待约 %.1f 秒）",
                   (unsigned long)i, (i - 1) * kVCamLANRetryInterval);
            VCamLANLogHookTable();
            return;
        }
        if (n > 0) {
            LANLOG(@"第 %lu 次尝试新装 %lu 个，继续等剩下的", (unsigned long)i, (unsigned long)n);
        }
        [NSThread sleepForTimeInterval:kVCamLANRetryInterval];
    }
    LANLOG(@"轮询 %lu 次（约 %.0f 秒）仍未全部就位，缺少的那几项见下表：",
           (unsigned long)kVCamLANMaxAttempts, kVCamLANMaxAttempts * kVCamLANRetryInterval);
    VCamLANLogHookTable();
}

static dispatch_queue_t VCamLANInstallQueue(void)
{
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.vcaml.an.troll.install", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// ==================================================================
#pragma mark - 入口（__attribute__((constructor))，等价于 %ctor）
// ==================================================================

__attribute__((constructor))
static void VCamLANConstructor(void)
{
    @autoreleasepool {
        VCamLANStartFileLog();

        LANLOG(@"loaded %s —— TrollStore 版（无 substrate / 无 Logos / 纯 ObjC runtime swizzle）pid=%d",
               VCAMLAN_VERSION, (int)getpid());
        LANLOG(@"NSHomeDirectory() = %@", NSHomeDirectory());
        LANLOG(@"Cam 真值 plist   = %@", VCamLANTruthPreferencesPath());
        LANLOG(@"日志文件         = %@", VCamLANLogFilePath());

        // 自有配置文件：没有就生成模板，把路径打进日志 —— 用户照着这个路径改 url 就行
        @try {
            NSString *ownPath = VCamLANEnsureOwnConfig(YES);
            LANLOG(@"自有配置文件 = %@", ownPath ?: @"(没有可写位置)");
            NSString *ownURL = VCamLANOwnConfigURL();
            if (ownURL.length) LANLOG(@"自有配置里的地址 = %@", ownURL);
        } @catch (NSException *e) {
            LANLOG(@"初始化自有配置异常：%@", e.reason);
        }

        // 当前网源状态
        NSString *lan = VCamLANCachedLANURL();
        LANLOG(@"当前网源 = %@", lan.length ? lan : @"(未设置)");
        if (lan.length) {
            LANLOG(@"  链路 = %@", VCamLANURLLooksFLV(lan) ? @"自研 HTTP-FLV puller" : @"Cam 自带 RTSP puller");
        }

        LANLOG(@"plist 硬条件：mediaTransport=wifi + source=rtmp + transport=flv|rtsp + enabled=YES");
        LANLOG(@"提醒：别点面板上的「直连」（它会把 mediaTransport 写回 usb，网源立刻失效）");
        LANLOG(@"提醒：拉网络流时拔掉数据线（usbConnected=YES 会让 rtsp 分支被跳过）");

        // Cam 先加载时立刻生效（TrollFools 把我们的 dylib 追加载载命令尾部时就是这种顺序）
        NSUInteger n = VCamLANTryInstall();
        if (n > 0) {
            LANLOG(@"启动即装上 %lu 个 hook", (unsigned long)n);
        }

        if (VCamLANAllInstalled()) {
            VCamLANLogHookTable();
            return;
        }

        LANLOG(@"还没齐，起 100ms × %lu 次轮询（最多约 %.0f 秒）",
               (unsigned long)kVCamLANMaxAttempts, kVCamLANMaxAttempts * kVCamLANRetryInterval);
        dispatch_async(VCamLANInstallQueue(), ^{
            @autoreleasepool {
                VCamLANInstallLoop();
            }
        });
    }
}
