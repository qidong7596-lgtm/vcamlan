//
//  VCamLANPrefs.m —— 配置读写实现
//
//  行为契约全部来自反汇编（见 VCamLANPrefs.h 顶部的地址索引）：
//    ① Cam 的 plist 路径 = <NSHomeDirectory()>/Library/Preferences/com.douyin.stream.plist
//       读：dictionaryWithContentsOfFile:（thunk 0x56320），nil → @{}
//       写：writeToFile:atomically:YES（0x40aa8）→ notify_post（C 串 0x5fd44）
//    ⇒ 本文件不发明任何新规则，只做三件事：
//       1) 把用户那条地址拆成 Cam 认识的键；
//       2) 把"少了就不出画面"的四个键一起补上（mediaTransport / source / transport / enabled）；
//       3) 写完回读校验 + 修权限 + 发重载通知。
//
#import <Foundation/Foundation.h>
#import <notify.h>
#include <sys/stat.h>
#include <string.h>
#include <errno.h>

#import "VCamLANPrefs.h"

NSString * const VCamLANPreferencesFileName = @"com.douyin.stream.plist";
NSString * const VCamLANNotifyReload       = @"com.douyin.stream.reload";
NSString * const VCamLANOwnConfigFileName  = @"VCamLAN.plist";
NSString * const VCamLANURLKey             = @"lanURL";

// 默认值（与 loadFromPreferences 的缺键默认完全一致，改这里等于改 Cam 的行为，别乱动）
static NSString * const kVCamLANDefaultPath        = @"live/obs";   // CF@0x71b80
static const NSInteger  kVCamLANDefaultRTSPPort    = 8554;          // 0x216a
static const NSInteger  kVCamLANDefaultHTTPPort    = 8888;          // MediaMTX 的 HTTP-FLV

#pragma mark - 小工具

/// Cam 的目录会在写盘时自动建（createDirectoryAtPath:withIntermediateDirectories:YES，0x83d0），
/// 这里保持一致：父目录不在就先建出来，免得 writeToFile: 静默失败返回 NO。
static BOOL VCamLANEnsureParentDirectory(NSString *path)
{
    if (path.length == 0) return NO;
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (dir.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:dir isDirectory:&isDir]) return isDir;
    NSError *err = nil;
    BOOL ok = [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err];
    if (!ok) {
        NSLog(@"[VCamLAN] 建目录失败 %@：%@", dir, err.localizedDescription);
    }
    return ok;
}

/// 写盘后把权限修回 0644。
/// 为什么需要：TrollStore 下容器里偶尔出现 0600 的 plist（前一次以别的 uid 写的），
/// 抖音进程读不到就变成"全默认值"，表现是"改了配置完全没反应"，很难查。
static void VCamLANFixPermissions(NSString *path)
{
    if (path.length == 0) return;
    const char *p = path.fileSystemRepresentation;
    if (!p) return;
    chmod(p, 0644);
}

/// 判断字典里某个键是不是等于给定值（大小写不敏感，非字符串一律当不相等）
static BOOL VCamLANStringEquals(NSString *value, NSString *expect)
{
    if (![value isKindOfClass:[NSString class]]) return NO;
    return [value caseInsensitiveCompare:expect] == NSOrderedSame;
}

#pragma mark - ① Cam 的 plist 路径

NSString *VCamLANTruthPreferencesPath(void)
{
    // 与 _VCamPreferencesPath（0x834c）逐句一致：
    //   NSHomeDirectory() + "/Library/Preferences" + "/com.douyin.stream.plist"
    NSString *home = NSHomeDirectory();
    if (home.length == 0) return @"";
    return [[home stringByAppendingPathComponent:@"Library/Preferences"]
            stringByAppendingPathComponent:VCamLANPreferencesFileName];
}

NSArray<NSString *> *VCamLANPreferencesCandidates(void)
{
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:4];

    NSString *truth = VCamLANTruthPreferencesPath();
    if (truth.length) [out addObject:truth];

    // ② App 容器 Documents 下的同名位置（旧工程在这写过一份，留着当兼容读取源）
    NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    if (docs.length) {
        NSString *alt = [[docs stringByAppendingPathComponent:@"Library/Preferences"]
                         stringByAppendingPathComponent:VCamLANPreferencesFileName];
        if ([out containsObject:alt] == NO) [out addObject:alt];
    }

    // ③④ 全局位置：TrollStore 注入进程后 NSHomeDirectory() 仍是容器，但用户可能手工放这里
    [out addObject:[@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:VCamLANPreferencesFileName]];
    [out addObject:[@"/var/jb/var/mobile/Library/Preferences" stringByAppendingPathComponent:VCamLANPreferencesFileName]];

    return out;
}

NSString *VCamLANResolvedPreferencesPath(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in VCamLANPreferencesCandidates()) {
        NSString *dir = [path stringByDeletingLastPathComponent];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) {
            if ([fm isWritableFileAtPath:dir]) return path;
        }
    }
    // 一个都不通就返回真值路径，让 writeToFile: 自己报错（比返回 nil 好排查）
    return VCamLANTruthPreferencesPath();
}

NSMutableDictionary *VCamLANLoadPrefs(void)
{
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    // 候选顺序是"前者优先"，所以倒序遍历、后面的先盖，前面的最后盖
    NSArray<NSString *> *cands = VCamLANPreferencesCandidates();
    for (NSString *path in [cands reverseObjectEnumerator]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([d isKindOfClass:[NSDictionary class]] && d.count) {
            [merged addEntriesFromDictionary:d];
        }
    }
    return merged;
}

#pragma mark - 组装 / 写入

NSDictionary *VCamLANBuildPrefsDict(NSString *transport,
                                    NSString *host,
                                    NSInteger port,
                                    NSString *path,
                                    NSString *lanURL)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:12];

    // 硬条件四键：少一个就不出画面（见 .h 顶部说明）
    [d setObject:@"rtmp" forKeyedSubscript:@"source"];           // sourceType = 1（网络拉流）
    [d setObject:@"wifi" forKeyedSubscript:@"mediaTransport"];   // prefersUSB = NO
    [d setObject:(transport.length ? transport : @"rtsp") forKeyedSubscript:@"transport"];
    [d setObject:@YES forKeyedSubscript:@"enabled"];             // isReplaceActive = enabled && hasConfiguredSource

    [d setObject:(host.length ? host : @"") forKeyedSubscript:@"host"];
    [d setObject:@(port > 0 ? port : kVCamLANDefaultRTSPPort) forKeyedSubscript:@"port"];
    [d setObject:(path.length ? path : kVCamLANDefaultPath) forKeyedSubscript:@"path"];

    // 其余键给显式默认值（与 loadFromPreferences 缺键默认一致，避免"半份配置"读出怪状态）
    [d setObject:@"" forKeyedSubscript:@"localPath"];
    [d setObject:@(0) forKeyedSubscript:@"rotation"];
    [d setObject:@NO forKeyedSubscript:@"mirrored"];
    [d setObject:@NO forKeyedSubscript:@"muted"];

    if (lanURL.length) [d setObject:lanURL forKeyedSubscript:VCamLANURLKey];

    return d;
}

BOOL VCamLANFillPrefsWithURL(NSMutableDictionary *prefs, NSString *rawURL)
{
    if (!prefs) return NO;

    NSString *scheme = nil, *host = nil, *path = nil, *norm = nil;
    NSInteger port = 0;
    if (!VCamLANParseStreamURL(rawURL, &scheme, &host, &port, &path, &norm)) {
        NSLog(@"[VCamLAN] 地址解析失败，配置未改动：%@", rawURL);
        return NO;
    }

    BOOL flv = VCamLANURLLooksFLV(norm);

    // 硬条件四键
    [prefs setObject:@"rtmp" forKeyedSubscript:@"source"];
    [prefs setObject:@"wifi" forKeyedSubscript:@"mediaTransport"];
    [prefs setObject:(flv ? @"flv" : @"rtsp") forKeyedSubscript:@"transport"];
    [prefs setObject:@YES forKeyedSubscript:@"enabled"];

    // host 永远写"纯 IP/域名"：hasConfiguredSource 里 sourceType==1 && !prefersUSB 只校验 host.length>0；
    // 面板文案（sourceTitle / pullURL）也是拿 host 显示的，塞整条 URL 进去会很难看。
    [prefs setObject:(host.length ? host : @"") forKeyedSubscript:@"host"];
    [prefs setObject:@(port > 0 ? port : kVCamLANDefaultRTSPPort) forKeyedSubscript:@"port"];

    if (flv) {
        // http:// 模式：端口会被 loadFromPreferences 钳制（8888 → 8554），
        // 所以**不靠 host+port+path 拼**，直接把完整地址写进 path。
        // VCamLANHTTPFLVPuller 的 streamURLForConfig: 第一优先级就是"path 本身是完整 URL"。
        [prefs setObject:norm forKeyedSubscript:@"path"];
    } else {
        // rtsp:// 模式：交给 Cam 自带的 VCamRTSPPuller（pullURL 0x9230 拼 rtsp://host:port/path）
        [prefs setObject:(path.length ? path : kVCamLANDefaultPath) forKeyedSubscript:@"path"];
    }

    [prefs setObject:norm forKeyedSubscript:VCamLANURLKey];

    // 其它键缺失就补默认（已存在的不动，保留用户的旋转 / 镜像 / 静音 / 相册选择）
    if (!prefs[@"localPath"]) [prefs setObject:@"" forKeyedSubscript:@"localPath"];
    if (!prefs[@"rotation"])  [prefs setObject:@(0) forKeyedSubscript:@"rotation"];
    if (!prefs[@"mirrored"])  [prefs setObject:@NO forKeyedSubscript:@"mirrored"];
    if (!prefs[@"muted"])     [prefs setObject:@NO forKeyedSubscript:@"muted"];

    NSLog(@"[VCamLAN] 配置组装完成：mode=%@ host=%@ port=%ld path=%@ lanURL=%@",
          flv ? @"flv(http)" : @"rtsp",
          host, (long)port, prefs[@"path"], norm);
    return YES;
}

BOOL VCamLANWritePrefsDict(NSDictionary *dict)
{
    if (![dict isKindOfClass:[NSDictionary class]] || dict.count == 0) {
        NSLog(@"[VCamLAN] 写配置失败：字典为空");
        return NO;
    }

    NSString *truth = VCamLANTruthPreferencesPath();
    NSString *chosen = VCamLANResolvedPreferencesPath();
    NSFileManager *fm = [NSFileManager defaultManager];

    // ① 真值路径一定写（目录不在就建）
    BOOL ok = NO;
    if (VCamLANEnsureParentDirectory(truth)) {
        ok = [dict writeToFile:truth atomically:YES];
        if (ok) VCamLANFixPermissions(truth);
    }
    if (!ok) {
        NSLog(@"[VCamLAN] 写 %@ 失败（errno=%d）", truth, errno);
    }

    // ② 其余候选只在"文件已存在 + 目录可写"时跟着写一份，避免在全局路径乱建文件
    for (NSString *path in VCamLANPreferencesCandidates()) {
        if ([path isEqualToString:truth]) continue;
        if (![fm fileExistsAtPath:path]) continue;
        if ([fm isWritableFileAtPath:path] == NO) continue;
        if ([dict writeToFile:path atomically:YES]) {
            VCamLANFixPermissions(path);
            NSLog(@"[VCamLAN] 同步写入候选路径 %@", path);
        }
    }

    // 回读校验：写进去的和读出来的必须一致，否则后面全是玄学问题。
    // 注意两点：
    //   ① 回「停机态」时写的是 enabled=NO，所以这里只校验"键在"，不校验它是不是 YES；
    //   ② lanURL 可能是两边都为 nil，`[nil isEqual:nil]` 会返回 NO —— 必须单独把 nil 判掉。
    NSDictionary *back = [NSDictionary dictionaryWithContentsOfFile:truth];
    BOOL verified = NO;
    if ([back isKindOfClass:[NSDictionary class]]) {
        id backURL = back[VCamLANURLKey];
        id wantURL = dict[VCamLANURLKey];
        BOOL urlOK = (backURL == nil && wantURL == nil) || [backURL isEqual:wantURL];
        BOOL enabledOK = [back[@"enabled"] isKindOfClass:[NSNumber class]];
        verified = VCamLANStringEquals(back[@"mediaTransport"], @"wifi")
                && VCamLANStringEquals(back[@"source"], @"rtmp")
                && enabledOK
                && urlOK;
        if (!verified) {
            NSLog(@"[VCamLAN] 回读明细：mediaTransport=%@ source=%@ enabled=%@ lanURL=%@",
                  back[@"mediaTransport"], back[@"source"], back[@"enabled"], backURL);
        }
    }
    NSLog(@"[VCamLAN] 写盘%@：%@（校验%@，enabled=%@）",
          ok ? @"成功" : @"失败", truth, verified ? @"通过" : @"未通过", dict[@"enabled"]);

    return ok && verified;
}

BOOL VCamLANWritePrefs(NSString *transport,
                       NSString *host,
                       NSInteger port,
                       NSString *path,
                       NSString *lanURL)
{
    NSDictionary *d = VCamLANBuildPrefsDict(transport, host, port, path, lanURL);
    return VCamLANWritePrefsDict(d);
}

BOOL VCamLANWritePrefsFromURL(NSString *fullURL)
{
    NSMutableDictionary *prefs = VCamLANLoadPrefs();
    if (!VCamLANFillPrefsWithURL(prefs, fullURL)) return NO;
    return VCamLANWritePrefsDict(prefs);
}

void VCamLANPostReloadNotification(void)
{
    // 主通道：Cam 只监听这一个（registerReloadNotification 0x37580 注册，C 串 0x5fd44）
    notify_post(VCamLANNotifyReload.UTF8String);

    // 双保险：Darwin notify 中心同一路径再发一次（等价写法，某些系统版本上顺序会更早进队列）
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)VCamLANNotifyReload,
                                         NULL, NULL, true);
    NSLog(@"[VCamLAN] 已发重载通知 %@", VCamLANNotifyReload);
}

#pragma mark - 地址解析

BOOL VCamLANURLLooksFLV(NSString *url)
{
    if (![url isKindOfClass:[NSString class]] || url.length == 0) return NO;
    NSString *l = [url lowercaseString];
    return [l hasPrefix:@"http://"] || [l hasPrefix:@"https://"];
}

NSString *VCamLANHostOfURL(NSString *url)
{
    if (![url isKindOfClass:[NSString class]] || url.length == 0) return @"";
    NSString *rest = url;
    NSRange r = [rest rangeOfString:@"://"];
    if (r.location != NSNotFound) rest = [rest substringFromIndex:r.location + r.length];
    NSRange slash = [rest rangeOfString:@"/"];
    if (slash.location != NSNotFound) rest = [rest substringToIndex:slash.location];
    NSRange colon = [rest rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound) rest = [rest substringToIndex:colon.location];
    return rest ?: @"";
}

/// 去首尾空白 + 去用户粘贴时常带的尖括号 / 引号
static NSString *VCamLANTrimInput(NSString *raw)
{
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *t = [(raw ?: @"") stringByTrimmingCharactersInSet:ws];
    NSCharacterSet *junk = [NSCharacterSet characterSetWithCharactersInString:@"\"'<>「」"];
    t = [t stringByTrimmingCharactersInSet:junk];
    t = [t stringByTrimmingCharactersInSet:ws];
    return t;
}

BOOL VCamLANParseStreamURL(NSString *raw,
                           NSString **outScheme,
                           NSString **outHost,
                           NSInteger *outPort,
                           NSString **outPath,
                           NSString **outNormalized)
{
    NSString *text = VCamLANTrimInput(raw);
    if (text.length == 0) return NO;

    NSString *scheme = nil;
    NSString *rest = nil;

    NSRange sr = [text rangeOfString:@"://"];
    if (sr.location != NSNotFound) {
        scheme = [[text substringToIndex:sr.location] lowercaseString];
        rest = [text substringFromIndex:sr.location + sr.length];
        if (![scheme isEqualToString:@"rtsp"] && ![scheme isEqualToString:@"http"]
            && ![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"rtmp"]) {
            NSLog(@"[VCamLAN] 不支持的 scheme：%@（只认 rtsp / http / https / rtmp）", scheme);
            return NO;
        }
    } else {
        rest = text;
        // 没写 scheme：按端口猜。MediaMTX 的 RTSP=8554、HTTP-FLV=8888，OBS 推流 RTMP=1935
        if ([rest rangeOfString:@":8554"].location != NSNotFound
            || [rest rangeOfString:@":554"].location != NSNotFound) {
            scheme = @"rtsp";
        } else if ([rest rangeOfString:@":8888"].location != NSNotFound
                   || [rest rangeOfString:@":8080"].location != NSNotFound
                   || [rest rangeOfString:@":80/"].location != NSNotFound) {
            scheme = @"http";
        } else {
            scheme = @"rtsp";   // 兜底：MediaMTX 的默认协议
            NSLog(@"[VCamLAN] 输入没带 scheme 也没带已知端口，按 rtsp 处理：%@", rest);
        }
    }

    // rtmp:// 只是推流地址，同一路流在 MediaMTX 上同时有 RTSP(8554)。
    // 用户贴 OBS 地址是很常见的操作，这里直接换算成 rtsp，不让他去改成 http。
    if ([scheme isEqualToString:@"rtmp"]) {
        NSLog(@"[VCamLAN] rtmp 地址按同一路流的 RTSP(8554) 处理：%@", text);
        scheme = @"rtsp";
    }

    // 拆 authority / path
    NSString *authority = rest;
    NSString *pathPart = @"";
    NSRange slash = [rest rangeOfString:@"/"];
    if (slash.location != NSNotFound) {
        authority = [rest substringToIndex:slash.location];
        pathPart = [rest substringFromIndex:slash.location + 1];
    }
    // 去掉 query / fragment（MediaMTX 偶尔带 ?session=…）
    NSRange q = [pathPart rangeOfString:@"?"];
    if (q.location != NSNotFound) pathPart = [pathPart substringToIndex:q.location];
    NSRange h = [pathPart rangeOfString:@"#"];
    if (h.location != NSNotFound) pathPart = [pathPart substringToIndex:h.location];
    while ([pathPart hasPrefix:@"/"]) pathPart = [pathPart substringFromIndex:1];
    if (pathPart.length == 0) pathPart = kVCamLANDefaultPath;

    // 拆 host / port（IPv6 不处理，局域网场景用不到；真要用请写成 [::1]:8554 形式并自行改造）
    NSString *host = authority;
    NSInteger port = 0;
    NSRange colon = [authority rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound) {
        host = [authority substringToIndex:colon.location];
        NSString *portText = [authority substringFromIndex:colon.location + 1];
        port = (NSInteger)[portText integerValue];
    }
    host = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (host.length == 0) {
        NSLog(@"[VCamLAN] 地址里没解析出 host：%@", text);
        return NO;
    }

    if (port <= 0 || port > 65535) {
        BOOL httpish = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
        port = httpish ? kVCamLANDefaultHTTPPort : kVCamLANDefaultRTSPPort;
    }

    NSString *normalized = [NSString stringWithFormat:@"%@://%@:%ld/%@",
                            scheme, host, (long)port, pathPart];

    if (outScheme)     *outScheme = scheme;
    if (outHost)       *outHost = host;
    if (outPort)       *outPort = port;
    if (outPath)       *outPath = pathPart;
    if (outNormalized) *outNormalized = normalized;

    NSLog(@"[VCamLAN] 地址解析：scheme=%@ host=%@ port=%ld path=%@ → %@",
          scheme, host, (long)port, pathPart, normalized);
    return YES;
}

#pragma mark - ② 自有配置

NSArray<NSString *> *VCamLANOwnConfigCandidates(void)
{
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:3];

    // ① 最优先：/var/mobile/Documents/VCamLAN.plist —— Filza 里一眼能找到、能手改
    [out addObject:[@"/var/mobile/Documents" stringByAppendingPathComponent:VCamLANOwnConfigFileName]];

    // ② App 容器 Documents（TrollStore 下一定有写权限）
    NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    if (docs.length) {
        [out addObject:[docs stringByAppendingPathComponent:VCamLANOwnConfigFileName]];
    }

    // ③ rootless 越狱机的同位置
    [out addObject:[@"/var/jb/var/mobile/Documents" stringByAppendingPathComponent:VCamLANOwnConfigFileName]];

    return out;
}

NSString *VCamLANEnsureOwnConfig(BOOL createTemplate)
{
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *path in VCamLANOwnConfigCandidates()) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    if (!createTemplate) return nil;

    for (NSString *path in VCamLANOwnConfigCandidates()) {
        NSString *dir = [path stringByDeletingLastPathComponent];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:dir isDirectory:&isDir] == NO || isDir == NO) continue;
        if ([fm isWritableFileAtPath:dir] == NO) continue;

        NSDictionary *tpl = @{
            @"url"           : @"",
            @"README"        : @"url 填 rtsp://192.168.1.216:8554/live/obs 或 http://192.168.1.216:8888/live/obs；"
                               @"面板上的「网源」按钮也会写这个文件",
            @"updatedAt"     : @([[NSDate date] timeIntervalSince1970]),
        };
        if ([tpl writeToFile:path atomically:YES]) {
            VCamLANFixPermissions(path);
            NSLog(@"[VCamLAN] 自有配置文件 = %@（模板已生成）", path);
            return path;
        }
    }
    NSLog(@"[VCamLAN] 自有配置没有可写位置；只能通过面板按钮或直接改 com.douyin.stream.plist");
    return nil;
}

NSDictionary *VCamLANLoadOwnConfig(void)
{
    for (NSString *path in VCamLANOwnConfigCandidates()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([d isKindOfClass:[NSDictionary class]] && d.count) return d;
    }
    return nil;
}

NSString *VCamLANOwnConfigURL(void)
{
    NSDictionary *d = VCamLANLoadOwnConfig();
    id u = d[@"url"];
    if ([u isKindOfClass:[NSString class]]) {
        return VCamLANTrimInput(u);
    }
    return @"";
}

BOOL VCamLANSaveOwnConfigURL(NSString *fullURL)
{
    NSString *text = VCamLANTrimInput(fullURL);
    if (text.length == 0) return NO;

    NSString *path = VCamLANEnsureOwnConfig(YES);
    if (path.length == 0) return NO;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:path];
    if ([old isKindOfClass:[NSDictionary class]]) [d addEntriesFromDictionary:old];
    [d setObject:text forKeyedSubscript:@"url"];
    [d setObject:@([[NSDate date] timeIntervalSince1970]) forKeyedSubscript:@"updatedAt"];

    BOOL ok = [d writeToFile:path atomically:YES];
    if (ok) VCamLANFixPermissions(path);
    NSLog(@"[VCamLAN] 自有配置%@：url=%@ (%@)", ok ? @"已保存" : @"保存失败", text, path);
    return ok;
}
