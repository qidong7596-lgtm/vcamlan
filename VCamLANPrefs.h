//
//  VCamLANPrefs.h —— 配置读写（TrollStore / 无 Substrate 版）
//
//  ============ 两套配置，别搞混 ============
//
//  ① Cam 自己的那份（**真正生效的那份**）
//     +[VCamStreamConfig preferencesPath]   imp=0x8328  → tail-call _VCamPreferencesPath 0x834c
//     _VCamPreferencesPath:
//         bl _NSHomeDirectory                                        (0x8358)
//         stringByAppendingPathComponent:@"Library/Preferences"       (C 串 0x5fe01)
//         createDirectoryAtPath:withIntermediateDirectories:YES       (0x83d0，目录自建)
//         stringByAppendingPathComponent:@"com.douyin.stream.plist"   (C 串 0x5fe15)
//     ⇒ <NSHomeDirectory()>/Library/Preferences/com.douyin.stream.plist
//     rootful / rootless 完全同一条（二进制里 var/ / var/jb / var/mobile 命中 0）
//     TrollStore 下 NSHomeDirectory() 就是抖音的 data container ⇒ 在 App 沙盒内，同进程直接可写
//
//     读：+[VCamStreamConfig loadFromPreferences] imp=0x8430
//         [NSDictionary dictionaryWithContentsOfFile:] (thunk 0x56320)
//         读不到 → @{} → 全默认值。**没有任何 fallback 路径**：
//         NSUserDefaults / standardUserDefaults / initWithSuiteName: / CFPreferences* 全部 0 命中
//     写：-[VCamFloatingPanel savePrefs:reloadPipeline:] imp=0x40a30
//         [dict writeToFile:<同一路径> atomically:YES] (0x40aa8)
//         成功 → loadFromPreferences → FrameStore/AudioStore setReplaceEnabled: →
//                notify_post("com.douyin.stream.reload") (0x40c90，C 串 0x5fd44)
//                → 200ms 后刷 UI
//
//  ② 本工程自有配置（**记录用户上次填的地址，给输入框做默认值**）
//     路径见 VCamLANOwnConfigCandidates()，第一优先 /var/mobile/Documents/VCamLAN.plist
//     （Filza 里一眼能找到；写不进去就自动退到 App 容器的 Documents）
//     键：url（完整地址，主键）/ 最近一次 scheme / 时间戳
//
//  ============ 写 ① 时必须一起写的四个键（少一个就不出画面）============
//     mediaTransport = "wifi"   ← 缺这个 prefersUSB=YES（loadFromPreferences 0x8ef0 派生）
//                                  → reloadConfig 里 doRtsp = inject && sourceType==1 && !usbConnected && !netUsb
//                                  其中 netUsb = inject && sourceType==1 && prefersUSB → 直接抢走，RTSP/FLV 永不启动
//     source         = "rtmp"   ← source→sourceType 映射（0x8be0-0x8c60）：
//                                  rtmp/network→1、file/album→2、**其余（含 "rtsp"）→0（= USB 未配置）**
//                                  写 "rtsp" 是新手最容易踩的坑，必须写 "rtmp" 或 "network"
//     transport      = "flv"    ← http:// 走自研 FLV puller 的标记；rtsp:// 保留 "rtsp" 走 Cam 自带 puller
//     enabled        = @YES      ← isReplaceActive = enabled && hasConfiguredSource（0x91d8）
//                                  少这个 FrameStore.replaceEnabled 不上，上屏通路整条断掉
//
//  ============ 端口钳制（别试图绕，绕不过）============
//     loadFromPreferences 0x8d30..0x8d90：
//       port == 0                 → 8554
//       port == 8888              → 8554      ← MediaMTX 的 HTTP-FLV 端口会被钳成 RTSP 端口
//       transport=="rtmp" && 1935 → 8554
//     ⇒ 所以 http:// 模式**不能靠 host+port+path 拼**，只能把完整 URL 塞进 path
//       （path 只做前导 '/' 剥离，不做任何端口相关的处理；本工程把它当权威地址用）
//
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ---- ① Cam 自己的 plist ----
extern NSString * const VCamLANPreferencesFileName;   // @"com.douyin.stream.plist"
extern NSString * const VCamLANNotifyReload;          // @"com.douyin.stream.reload"

// ---- ② 本工程自有配置 ----
extern NSString * const VCamLANOwnConfigFileName;     // @"VCamLAN.plist"

// ---- 本工程写进 ① 的标记键（Cam 不认识它，会原样保留；用来判断"当前是网源模式"）----
extern NSString * const VCamLANURLKey;                // @"lanURL"

#pragma mark - ① 路径与读写

/// ① 的真值路径（不探测、不猜）
NSString *VCamLANTruthPreferencesPath(void);

/// ① 的全部候选（①真值 ②App 容器 Library/Preferences ③rootful ④rootless），按优先级
NSArray<NSString *> *VCamLANPreferencesCandidates(void);

/// ① 中第一个父目录存在且可写（或可创建）的路径
NSString *_Nullable VCamLANResolvedPreferencesPath(void);

/// 读 ①（按候选顺序合并，前者优先）；读不到返回空的可变字典（不返回 nil）
NSMutableDictionary *VCamLANLoadPrefs(void);

#pragma mark - 组装与写入

/// 组装 ① 的字典（补齐上面那张"四个键"的硬条件）
///   transport 传 @"flv"（http）或 @"rtsp"（rtsp）；lanURL 传归一化后的完整地址
NSDictionary *VCamLANBuildPrefsDict(NSString *transport,
                                    NSString *host,
                                    NSInteger port,
                                    NSString *path,
                                    NSString *_Nullable lanURL);

/// 把一条局域网地址写进**已有**字典（保留 rotation / mirrored / muted / localPath 等原值）。
/// 内部会调 VCamLANParseStreamURL 做归一化；解析失败返回 NO 且不改字典。
BOOL VCamLANFillPrefsWithURL(NSMutableDictionary *prefs, NSString *rawURL);

/// 写 ①：**总是**写真值路径（目录不存在就建），其余候选只在已存在且可写时跟着写。
/// 写盘后回读校验 + 修权限（0644），并打印 `实际写入路径 = %@`。
BOOL VCamLANWritePrefsDict(NSDictionary *dict);

/// 组装 + 写 ①（path 按普通相对路径处理）
BOOL VCamLANWritePrefs(NSString *transport,
                       NSString *host,
                       NSInteger port,
                       NSString *path,
                       NSString *_Nullable lanURL);

/// 直接从一条完整地址写 ①（内部 FillPrefsWithURL + WritePrefsDict）
BOOL VCamLANWritePrefsFromURL(NSString *fullURL);

/// 发重载通知（Cam 只监听这一个）：
///   notify_post("com.douyin.stream.reload")
///   + CFNotificationCenterPostNotification(GetDarwinNotifyCenter(), …) 双保险
/// 注：旧工程还发过 com.vcamtang.stream.config-changed，那个常量在 __text 里零引用（死常量），已去掉。
void VCamLANPostReloadNotification(void);

#pragma mark - 地址解析

/// 解析用户输入的地址。允许四种写法：
///   ① 完整地址   http://192.168.1.216:8888/live/obs
///   ② rtsp 地址  rtsp://192.168.1.216:8554/live/obs
///   ③ 省略 scheme 192.168.1.216:8554/live/obs   （按端口猜：8554/554→rtsp，8888/8080/80→http）
///   ④ rtmp 地址  rtmp://192.168.1.216:1935/live/obs  （自动换成同一台机器的 rtsp 8554，MediaMTX 同一路流）
/// 输出：scheme（@"rtsp"/@"http"/@"https"）、host、port（已补默认值）、path（无前导 '/'）、
///      normalized（归一化后的完整地址，写盘用的是它）
BOOL VCamLANParseStreamURL(NSString *raw,
                           NSString *_Nullable *_Nullable outScheme,
                           NSString *_Nullable *_Nullable outHost,
                           NSInteger *outPort,
                           NSString *_Nullable *_Nullable outPath,
                           NSString *_Nullable *_Nullable outNormalized);

/// 判断一个地址是不是走自研 FLV puller（http / https）
BOOL VCamLANURLLooksFLV(NSString *_Nullable url);

/// 从地址里取 host（给面板文案用），取不到返回空串
NSString *VCamLANHostOfURL(NSString *_Nullable url);

#pragma mark - ② 自有配置

/// ② 的候选路径（按优先级）
NSArray<NSString *> *VCamLANOwnConfigCandidates(void);

/// 找到第一个可读的 ②；都不存在就挑第一个"目录存在且可写"的位置写一份模板，
/// 并把模板路径打印出来（`自有配置文件 = %@`）。返回 nil 表示实在没有可写位置。
NSString *_Nullable VCamLANEnsureOwnConfig(BOOL createTemplate);

/// 读 ②；没有文件或没有 url 返回 nil
NSDictionary *_Nullable VCamLANLoadOwnConfig(void);

/// 读 ② 里的 url 键（没有返回空串）
NSString *VCamLANOwnConfigURL(void);

/// 把一条完整地址写进 ②（覆盖 url 键，保留其它键）
BOOL VCamLANSaveOwnConfigURL(NSString *fullURL);

NS_ASSUME_NONNULL_END
