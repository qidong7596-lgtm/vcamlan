//
//  VCamLANHTTPFLVPuller.m —— HTTP-FLV 拉流 → H.264 硬解 → 上屏
//
//  为什么走这条路（依据，来自 work/Cam_pipeline_contract.md + Cam_integration_route.md）：
//    · VCamStreamPipeline 的 puller 是具名具体类型 ivar（_rtspPuller @"VCamRTSPPuller" +0x20），
//      但 pipeline 对 puller 只发 4 条消息，且**全部经 objc_msgSend、运行期不校验静态类型**：
//        -applyConfig: (imp 0x38600) / -stop (0x37b70) / -isRunning (0x3797c) / -lastError (0x382e0)
//      ⟹ 把本类实例塞进 _rtspPuller 完全合法，只要实现这 4 条。
//    · reloadConfig (0x37af4) 里所有 puller 取用都走属性 getter（-[VCamStreamPipeline rtspPuller] imp 0x393b4），
//      没有一处直读 ivar 偏移 ⟹ hook 一个 getter 就能整体换源。
//    · 帧上屏唯一通路：[[VCamFrameStore sharedStore] updatePixelBuffer:presentationTime:]（imp 0xaa00）
//    · FLV 的 video tag body 是 AVCC 长度前缀，与 -decodeAvccSample: 期望格式**完全一致**，零转换；
//      AVCDecoderConfigurationRecord 与 -setAvccExtra: 期望格式同构，直接透传。
//
//  线程模型：
//    _ioQueue（串行，label = com.dycj.flv.io）—— 收流/解析：开始/停止、NSURLSession 回调、
//      FLV 解析、看门狗、重连调度全部在它上面串行执行。
//    NSURLSession 的 delegateQueue 是把 underlyingQueue 指向 _ioQueue 的单并发 NSOperationQueue，
//      所以 -URLSession:dataTask:didReceiveData: 天然落在 _ioQueue 上，解析器不需要额外加锁。
//    _decodeQueue（串行，label = com.dycj.flv.decode）—— 解码：io 队列只负责把 access unit 拷一份
//      投递过去，绝不同步解码（同步解码会堵住 recv → TCP 背压 → 推流端积压甚至断流）。
//      每次 rebuildDecoder 递增 _decodeGeneration，队列里世代过期的旧样本直接丢弃，
//      避免旧样本污染新解码器（对应 RTSP 的 decodeGeneration，0x1b74c）。
//    _stateLock（NSLock）—— 只保护跨线程可见的那几个小状态：_running / _lastErrorMessage /
//      _appliedURL / _urlOverride / _rotation / _mirrored / _muted / _stats（含解码积压计数）。
//    VT 的 onFrame 回调在 VideoToolbox 自己的线程，只做两件事：转发 FrameStore + 记账（加锁）。
//
//  重连：断流后指数退避 1s → 2s → 4s → 8s（上限 8s），成功吃到第一个完整 tag 后退避归零。
//  时间戳：
//    · FLV tag header 是 32 位毫秒（24 位 + 扩展字节），24 位回绕在 flv_parser.h 里按
//      "raw 变小且差值 > 0x800000 就累加 0x1000000" 处理；video tag 再加 CompositionTime（有符号 24 位）。
//    · 视频 **timescale = 90000**，value = (tsMs + cts - 首帧Ms) * 90
//      —— 与 -[VCamRTSPPuller flushVideoAccessUnit] 完全一致（0x1b280 mov w1,#0x5f90 /
//      0x1b284 movk w1,#1,lsl#16 → 0x15F90 = 90000；value 来自 0x1b264 videoRtpBase 相减）。
//      不用 1000 是因为 FrameStore 会把这个 CMTime 原样带进 CMSampleBuffer 的 PTS，
//      1000 在 30/60fps 下会有毫秒级抖动，还会让 VCamAudioStore 的 A/V 对齐缓慢漂移。
//    · 音频 timescale = AAC 的 clock rate（ASC 里解析出 44100/48000…），value 同样减去首帧基准。
//  预热 + 积压抑制：
//    suppressOutput = (还没见过 IDR 且本帧不是关键帧) || (解码积压 > 6)
//      后半段与 RTSP 同式（0x1b84c `subs x8,x8,#6 ; cset w8,gt`）；
//      前半段是原任务书要求的"IDR 前只解不上屏"。见到第一个 IDR（NAL type 5 或 frameType==1）后转 NO。
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <math.h>

#import "VCamLAN.h"
#import "flv_parser.h"
#import "VCamLANPrefs.h"

#define FLVLOG(fmt, ...) NSLog(@"[VCamLAN] " fmt, ##__VA_ARGS__)

static const char * const kVCamLANIOQueueLabel     = "com.dycj.flv.io";
static const char * const kVCamLANDecodeQueueLabel = "com.dycj.flv.decode";

static const NSTimeInterval kVCamLANConnectTimeout = 15.0;   // 建连超时
static const NSTimeInterval kVCamLANStallTimeout   = 3.0;    // 连续多久没新帧就重建解码器
static const NSTimeInterval kVCamLANStarveTimeout  = 15.0;   // 连续多久没收到任何字节就重连
static const NSTimeInterval kVCamLANMaxBackoff     = 8.0;    // 退避上限
static const NSUInteger     kVCamLANDefaultHTTPPort = 8888;  // MediaMTX HTTP-FLV 默认端口

// 解码积压抑制阈值。RTSP 侧的原式：0x1b84c `subs x8,x8,#6 ; cset w8,gt`
// → suppressOutput = (pendingDecodeJobs > 6)。跟它保持一致。
static const int64_t        kVCamLANMaxPendingDecodes = 6;

// 视频 timescale。RTSP 侧的原值：0x1b280 `mov w1,#0x5f90` + 0x1b284 `movk w1,#1,lsl#16`
// → 0x15F90 = 90000。音频用 AAC 的 clock rate（44100 / 48000 …）。
static const int32_t        kVCamLANVideoTimescale = 90000;

// 队列身份标记（用于 assert 是否在 io 队列上）
static char kVCamLANQueueKey;

#pragma mark - 统计

typedef struct {
    int64_t bytes;
    int64_t video_tags;
    int64_t audio_tags;
    int64_t script_tags;
    int64_t avcc_records;
    int64_t video_samples;
    int64_t audio_samples;
    int64_t idr_frames;
    int64_t delivered_frames;
    int64_t decode_errors;
    int64_t reconnects;
    int64_t nal_total;
    int64_t nal_idr;
    int64_t nal_sps;
    int64_t nal_pps;
    int64_t nal_sei;
    int64_t nal_other;
    int64_t pending_decode_jobs;     // 已投递到 _decodeQueue 但还没解完的样本数
    int64_t dropped_decode_jobs;     // 因世代失效被丢弃的样本数
    double  last_video_frame_at;
} VCamLAN_stats_t;

#pragma mark - 私有方法声明

@interface VCamLANHTTPFLVPuller () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>

// ---- tag 处理（统一在 _ioQueue 上）----
- (void)handleTag:(const flv_tag_t *)tag;
- (void)handleVideoTag:(const flv_tag_t *)tag;
- (void)handleAudioTag:(const flv_tag_t *)tag;
- (void)handleScriptTag:(const flv_tag_t *)tag;

// ---- 解码 ----
- (void)flv_ensureDecodersLocked;
- (void)flv_rebuildDecoderLocked:(NSString *)reason;
- (void)applyAvccRecord:(NSData *)record;
- (void)submitVideoSample:(NSData *)sample tsMs:(int64_t)tsMs keyframe:(BOOL)keyframe;

// ---- 连接生命周期（全部只在 _ioQueue 上）----
- (void)flv_startLockedWithConfig:(VCamStreamConfig *)config;
- (void)flv_stopLocked;
- (void)flv_resetStreamStateLocked;
- (void)flv_teardownSessionLocked;
- (void)flv_scheduleReconnectLocked:(NSString *)reason;
- (void)flv_startWatchdogLocked;
- (void)flv_stopWatchdogLocked;
- (void)flv_watchdogTick;

// ---- 跨线程小状态 ----
- (void)flv_noteRunning:(BOOL)running;
- (void)flv_noteError:(NSString *)message;
- (BOOL)flv_stopRequested;
- (void)flv_setStopRequested:(BOOL)v;
- (NSString *)flv_urlForConfigLocked:(VCamStreamConfig *)config;
- (NSString *)flv_messageForHTTPStatus:(NSInteger)status;
- (NSString *)flv_messageForNSError:(NSError *)error;

@end

#pragma mark - FLV 解析回调（C 函数 → ObjC）

static void vcam_flv_tag_cb(void *user, const flv_tag_t *tag)
{
    if (!user || !tag) return;
    VCamLANHTTPFLVPuller *puller = (__bridge VCamLANHTTPFLVPuller *)user;
    [puller handleTag:tag];
}

#pragma mark - AMF0 onMetaData 里抠数值（只在 script tag 上打日志用，容错优先）

static BOOL flv_find_amf_number(const uint8_t *p, uint32_t n, const char *key, double *out)
{
    if (!p || !key) return NO;
    size_t klen = strlen(key);
    if (klen == 0 || (uint64_t)n <= (uint64_t)klen + 9u) return NO;
    for (uint32_t i = 0; (uint64_t)i + klen + 9u <= (uint64_t)n; i++) {
        if (memcmp(p + i, key, klen) != 0) continue;
        uint32_t v = i + (uint32_t)klen;
        if (p[v] != 0x00) continue;                 // AMF0 number marker
        uint64_t bits = 0;
        for (int j = 0; j < 8; j++) bits = (bits << 8) | (uint64_t)p[v + 1 + (uint32_t)j];
        double d = 0;
        memcpy(&d, &bits, sizeof(d));
        if (out) *out = d;
        return YES;
    }
    return NO;
}

// 从 AudioSpecificConfig 里取采样率（ASC: 5bit audioObjectType + 4bit samplingFrequencyIndex + ...）
static int32_t flv_aac_rate_from_asc(const uint8_t *asc, uint32_t n)
{
    static const int32_t kRates[13] = {
        96000, 88200, 64000, 48000, 44100, 32000, 24000,
        22050, 16000, 12000, 11025, 8000, 7350
    };
    if (!asc || n < 2) return 0;
    int idx = ((asc[0] & 0x07) << 1) | ((asc[1] >> 7) & 0x01);
    if (idx < 0 || idx > 12) return 0;
    return kRates[idx];
}

#pragma mark - 实现

@implementation VCamLANHTTPFLVPuller {
    // ---- 队列 ----
    dispatch_queue_t   _ioQueue;        // 唯一干活的队列：收流 / 解析 / 投递解码
    dispatch_queue_t   _decodeQueue;    // 单独的解码队列：不在 io 队列上同步解码（避免 TCP 背压）
    NSOperationQueue  *_delegateQueue;
    NSLock            *_stateLock;

    // ---- 跨线程小状态（_stateLock 保护）----
    BOOL               _running;
    BOOL               _stopRequested;
    NSString          *_lastErrorMessage;
    NSString          *_appliedURL;
    NSString          *_urlOverride;
    NSInteger          _rotation;
    BOOL               _mirrored;
    BOOL               _muted;
    VCamLAN_stats_t    _stats;

    // ---- 只在 _ioQueue 上访问 ----
    flv_parser_t              _parser;
    BOOL                      _parserInited;
    VCamStreamConfig         *_config;
    NSURLSession             *_session;
    NSURLSessionDataTask     *_task;
    BOOL                      _stopped;
    BOOL                      _reconnectScheduled;
    NSInteger                 _reconnectAttempt;
    BOOL                      _loggedFirstByte;
    BOOL                      _loggedNonAvcVideo;
    BOOL                      _loggedNonAacAudio;
    BOOL                      _loggedScriptData;

    VCamVTDecoder            *_decoder;
    VCamAACDecoder           *_aacDecoder;
    NSData                   *_lastAvcc;
    int                       _nalLengthSize;
    BOOL                      _gotAvcc;
    BOOL                      _gotIDR;

    // ---- 解码世代（对应 RTSP 的 decodeGeneration，0x1b74c）----
    // rebuildDecoders / reset 时 +1，_decodeQueue 里的旧任务看到世代变了就丢弃，
    // 避免旧样本污染新解码器。只在 _ioQueue 上写，_decodeQueue 上只读。
    uint64_t                  _decodeGeneration;

    // ---- 时间基准 ----
    int64_t                   _videoBaseMs;       // 视频首帧 ts，之后 CMTime value = (ts - base) * 90
    BOOL                      _videoTimebaseReady;
    int64_t                   _audioBaseMs;       // 音频首帧 ts
    BOOL                      _audioTimebaseReady;
    int32_t                   _audioClockRate;    // AAC clock rate（44100 / 48000 …）
    CMTime                    _lastSentTime;

    dispatch_source_t         _watchdog;
    double                    _lastAnyDataAt;
}

#pragma mark - 单例 / 生命周期

+ (instancetype)shared
{
    static VCamLANHTTPFLVPuller *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[VCamLANHTTPFLVPuller alloc] init];
    });
    return instance;
}

- (id)init
{
    self = [super init];
    if (!self) return nil;

    _ioQueue = dispatch_queue_create(kVCamLANIOQueueLabel, DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_ioQueue, &kVCamLANQueueKey, (void *)&kVCamLANQueueKey, NULL);

    // 独立的解码队列：绝不在 io 队列上同步解码，否则 recv 被阻塞 → TCP 背压 → 推流端积压
    _decodeQueue = dispatch_queue_create(kVCamLANDecodeQueueLabel, DISPATCH_QUEUE_SERIAL);
    _decodeGeneration = 1;
    _audioClockRate = 44100;   // ASC 解析出来之后再覆盖

    _delegateQueue = [[NSOperationQueue alloc] init];
    _delegateQueue.maxConcurrentOperationCount = 1;
    _delegateQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    _delegateQueue.name = @"com.dycj.flv.session";
    _delegateQueue.underlyingQueue = _ioQueue;   // NSURLSession 回调直接落在 _ioQueue

    _stateLock = [[NSLock alloc] init];
    _nalLengthSize = 4;
    _parserInited = (flv_parser_init(&_parser) == 0);
    if (!_parserInited) FLVLOG(@"FLV 解析器初始化失败（内存不足），拉流不可用");

    FLVLOG(@"VCamLANHTTPFLVPuller init（队列 %s）", kVCamLANIOQueueLabel);
    return self;
}

- (void)dealloc
{
    [self flv_stopWatchdogLocked];
    if (_parserInited) flv_parser_free(&_parser);
    [_decoder invalidate];
    _decoder = nil;
    _aacDecoder = nil;
}

#pragma mark - pipeline 契约（4 条）

- (void)applyConfig:(VCamStreamConfig *)config
{
    if (!config) {
        FLVLOG(@"applyConfig: nil → 当作停止处理");
        [self stop];
        return;
    }
    // VCamStreamConfig 实现了 copyWithZone:（imp 0x957c），拷一份避免 pipeline 侧后续改配置串到我们
    VCamStreamConfig *copy = nil;
    @try {
        copy = [config copy];
    } @catch (NSException *e) {
        copy = config;
    }
    if (!copy) copy = config;

    [self flv_setStopRequested:NO];
    [self flv_noteRunning:YES];   // 先乐观置位：pipeline 的 applyRuntimeFlags 会马上读 isRunning

    __weak typeof(self) weakSelf = self;
    dispatch_async(_ioQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_reconnectAttempt = 0;   // 新配置 → 退避归零
        [strongSelf flv_startLockedWithConfig:copy];
    });
}

- (void)stop
{
    [self flv_setStopRequested:YES];
    [self flv_noteRunning:NO];
    __weak typeof(self) weakSelf = self;
    dispatch_async(_ioQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf flv_stopLocked];
    });
}

- (BOOL)isRunning
{
    [_stateLock lock];
    BOOL r = _running;
    [_stateLock unlock];
    return r;
}

- (NSError *)lastError
{
    [_stateLock lock];
    NSString *msg = _lastErrorMessage;
    [_stateLock unlock];
    if (msg.length == 0) return nil;
    return [NSError errorWithDomain:@"VCamLAN"
                               code:-1
                           userInfo:@{ NSLocalizedDescriptionKey : msg,
                                       NSLocalizedFailureReasonErrorKey : msg }];
}

#pragma mark - 扩展接口

+ (NSString *)streamURLForConfig:(VCamStreamConfig *)config
{
    if (!config) return @"";

    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *host = [(config.host ?: @"") stringByTrimmingCharactersInSet:ws];
    NSString *path = [(config.path ?: @"") stringByTrimmingCharactersInSet:ws];
    NSString *tl   = [(config.transport ?: @"") lowercaseString];
    NSUInteger port = config.port;

    // ① path 本身就是完整 URL —— 直接当地址用（用户填 http://ip:port/live/x.flv 的场合）
    NSString *pl = [path lowercaseString];
    if ([pl hasPrefix:@"http://"] || [pl hasPrefix:@"https://"]) {
        return path;
    }
    // ② host 本身就是完整 URL（面板只有一个 host 框时用户可能整条塞进来）
    NSString *hl = [host lowercaseString];
    if ([hl hasPrefix:@"http://"] || [hl hasPrefix:@"https://"]) {
        if (path.length == 0) return host;
        return [host stringByAppendingFormat:@"/%@", [path hasPrefix:@"/"] ? [path substringFromIndex:1] : path];
    }
    if (host.length == 0) return @"";

    if (port == 0) port = kVCamLANDefaultHTTPPort;

    // ③ 端口纠偏：8554 是 RTSP 默认端口；而 plist 里写 8888 会被 loadFromPreferences 钳成 8554
    //    （imp 0x8d48：port == 0x22b8 → 8554）。所以 flv 模式下见到 8554/1935 一律按 8888 处理，
    //    想用别的端口就把完整地址整条写进 path。
    if ([tl isEqualToString:@"flv"] && (port == 8554 || port == 1935)) {
        port = kVCamLANDefaultHTTPPort;
    }

    while ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];
    if (path.length == 0) path = @"live/obs";

    return [NSString stringWithFormat:@"http://%@:%lu/%@", host, (unsigned long)port, path];
}

- (NSString *)streamURL
{
    [_stateLock lock];
    NSString *u = _appliedURL.length ? _appliedURL : _urlOverride;
    [_stateLock unlock];
    return u ?: @"";
}

- (void)setStreamURL:(NSString *)url
{
    NSString *u = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [_stateLock lock];
    _urlOverride = [u copy];
    [_stateLock unlock];
    FLVLOG(@"setStreamURL: %@", u.length ? u : @"(空)");
}

- (NSString *)appliedStreamURL
{
    [_stateLock lock];
    NSString *u = _appliedURL;
    [_stateLock unlock];
    return u ?: @"";
}

- (void)updateRuntimeFlagsFromConfig:(VCamStreamConfig *)config
{
    if (!config) return;
    NSInteger rot = config.rotationDegrees;
    // rotation 只接受 0/90/180/270（loadFromPreferences 已钳过，这里再兜一层，防手工改内存）
    if (rot != 0 && rot != 90 && rot != 180 && rot != 270) rot = 0;
    BOOL mir = config.mirrored ? YES : NO;
    BOOL mut = config.muted ? YES : NO;

    NSInteger oldRot; BOOL oldMut; BOOL oldMir;
    [_stateLock lock];
    oldRot = _rotation; oldMut = _muted; oldMir = _mirrored;
    _rotation = rot; _mirrored = mir; _muted = mut;
    [_stateLock unlock];

    if (rot != oldRot || mut != oldMut || mir != oldMir) {
        FLVLOG(@"运行时参数 rotation=%ld→%ld mirrored=%d→%d muted=%d→%d",
               (long)oldRot, (long)rot, (int)oldMir, (int)mir, (int)oldMut, (int)mut);
    }
    // 旋转 / 镜像由 VCamFrameStore 在 updatePixelBuffer: 内部应用（orientedImageFromPixelBuffer:rotationDegrees:），
    // 拉流侧不需要重建解码器；muted 直接决定 audio tag 是否送 AAC 解码（见 handleAudioTag:）。
}

- (void)requestKeyframe
{
    // FLV 是单向 HTTP 拉流，没有 RTCP PLI / FIR 通道，无法向推流端索要 IDR。
    // 唯一能做的本地兜底：重建解码器 + 重新等 sequence header / IDR。
    FLVLOG(@"requestKeyframe：FLV 无 PLI 通道，改为重建解码器等 IDR");
    __weak typeof(self) weakSelf = self;
    dispatch_async(_ioQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf flv_rebuildDecoderLocked:@"手动请求关键帧"];
    });
}

- (NSString *)diagnosticLine
{
    [_stateLock lock];
    VCamLAN_stats_t s = _stats;
    NSString *err = _lastErrorMessage;
    NSString *url = _appliedURL;
    [_stateLock unlock];

    return [NSString stringWithFormat:
            @"url=%@ bytes=%lld V=%lld A=%lld S=%lld avcc=%lld vS=%lld aS=%lld "
            @"idr=%lld 上屏=%lld 解错=%lld 重连=%lld 积压=%lld 弃=%lld "
            @"NAL=%lld(IDR%lld SPS%lld PPS%lld SEI%lld 其它%lld)%@",
            url.length ? url : @"(无)",
            s.bytes, s.video_tags, s.audio_tags, s.script_tags, s.avcc_records,
            s.video_samples, s.audio_samples, s.idr_frames, s.delivered_frames,
            s.decode_errors, s.reconnects, s.pending_decode_jobs, s.dropped_decode_jobs,
            s.nal_total, s.nal_idr, s.nal_sps, s.nal_pps, s.nal_sei, s.nal_other,
            err.length ? [NSString stringWithFormat:@" 错误=%@", err] : @""];
}

#pragma mark - 跨线程小状态

- (void)flv_noteRunning:(BOOL)running
{
    [_stateLock lock];
    _running = running;
    [_stateLock unlock];
}

- (void)flv_noteError:(NSString *)message
{
    [_stateLock lock];
    _lastErrorMessage = [message copy];
    [_stateLock unlock];
    if (message.length) FLVLOG(@"错误状态：%@", message);
}

- (BOOL)flv_stopRequested
{
    [_stateLock lock];
    BOOL v = _stopRequested;
    [_stateLock unlock];
    return v;
}

- (void)flv_setStopRequested:(BOOL)v
{
    [_stateLock lock];
    _stopRequested = v;
    [_stateLock unlock];
}

- (NSString *)flv_urlForConfigLocked:(VCamStreamConfig *)config
{
    [_stateLock lock];
    NSString *override = _urlOverride;
    [_stateLock unlock];
    if (override.length) return override;
    return [[self class] streamURLForConfig:config];
}

#pragma mark - 开始 / 停止

- (void)flv_startLockedWithConfig:(VCamStreamConfig *)config
{
    if (!_parserInited) {
        [self flv_noteError:@"FLV 解析器初始化失败（内存不足），请重启 App 再试"];
        [self flv_noteRunning:NO];
        return;
    }

    NSString *want = [self flv_urlForConfigLocked:config];
    if (want.length == 0) {
        [self flv_noteError:@"HTTP-FLV 地址为空：请在悬浮窗填完整地址，或在 plist 里写 host + path"
                           @"（transport=flv 时端口避开 8554/1935，或直接把整条 http:// 地址填进 path）"];
        [self flv_noteRunning:NO];
        return;
    }

    // URL 没变且连接还活着 → 不重连，只同步运行时参数
    BOOL sameURL = NO;
    [_stateLock lock];
    NSString *cur = _appliedURL;
    sameURL = (cur.length > 0 && [cur isEqualToString:want]);
    [_stateLock unlock];
    if (sameURL && _task && !_stopped) {
        FLVLOG(@"URL 未变，沿用现有连接：%@", want);
        [self updateRuntimeFlagsFromConfig:config];
        [self flv_noteRunning:YES];
        return;
    }

    [self flv_teardownSessionLocked];
    [self flv_resetStreamStateLocked];

    _stopped = NO;
    _reconnectScheduled = NO;
    _loggedFirstByte = NO;
    _config = config;
    [self updateRuntimeFlagsFromConfig:config];

    NSURL *url = [NSURL URLWithString:want];
    if (!url || url.scheme.length == 0 || url.host.length == 0) {
        [self flv_noteError:[NSString stringWithFormat:@"HTTP-FLV 地址无效：%@（需要 http://host:port/path 形态）", want]];
        [self flv_noteRunning:NO];
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = kVCamLANConnectTimeout;
    [req setValue:@"video/x-flv, application/x-flv, */*" forHTTPHeaderField:@"Accept"];
    [req setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [req setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [req setValue:@"VCamLAN/1.0 (iPhone; HTTP-FLV puller)" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionConfiguration *sc = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    sc.timeoutIntervalForRequest  = kVCamLANConnectTimeout;
    // 拉流是"永不结束"的响应，资源超时必须放大，否则默认 7 天外还会被掐
    sc.timeoutIntervalForResource = 86400.0 * 30.0;
    sc.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    sc.URLCache = nil;
    sc.HTTPMaximumConnectionsPerHost = 1;
    sc.networkServiceType = NSURLNetworkServiceTypeVideo;
    sc.allowsCellularAccess = YES;
    sc.HTTPShouldSetCookies = NO;
    sc.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;

    _session = [NSURLSession sessionWithConfiguration:sc delegate:self delegateQueue:_delegateQueue];
    _task = [_session dataTaskWithRequest:req];
    [_task resume];

    [_stateLock lock];
    _appliedURL = [want copy];
    _lastErrorMessage = nil;
    [_stateLock unlock];

    _lastAnyDataAt = CACurrentMediaTime();
    [self flv_startWatchdogLocked];
    [self flv_noteRunning:YES];

    NSString *tp = [(config.transport ?: @"") lowercaseString];
    FLVLOG(@"开始拉流 %@（transport=%@ sourceType=%ld port=%lu rotation=%ld mirrored=%d muted=%d）",
           want, tp.length ? tp : @"(空)", (long)config.sourceType, (unsigned long)config.port,
           (long)config.rotationDegrees, (int)config.mirrored, (int)config.muted);
}

- (void)flv_stopLocked
{
    _stopped = YES;
    _reconnectScheduled = NO;
    _decodeGeneration++;             // 让 _decodeQueue 里排队的样本立刻作废
    [self flv_stopWatchdogLocked];
    [self flv_teardownSessionLocked];

    if (_decoder) {
        _decoder.onFrame = nil;
        _decoder.onOutputFailure = nil;
        [_decoder invalidate];
        _decoder = nil;
    }
    if (_aacDecoder) {
        [_aacDecoder reset];
        _aacDecoder = nil;
    }
    _gotAvcc = NO;
    _gotIDR = NO;
    _lastAvcc = nil;
    if (_parserInited) flv_parser_reset(&_parser);

    [_stateLock lock];
    _appliedURL = nil;
    _stats.last_video_frame_at = 0;
    [_stateLock unlock];

    [self flv_noteRunning:NO];
    FLVLOG(@"已停止拉流（%s）", [self diagnosticLine].UTF8String);
}

- (void)flv_teardownSessionLocked
{
    if (_task) {
        [_task cancel];
        _task = nil;
    }
    if (_session) {
        NSURLSession *s = _session;
        _session = nil;
        [s invalidateAndCancel];   // 释放 delegate 的强引用
    }
}

- (void)flv_resetStreamStateLocked
{
    _decodeGeneration++;             // 新连接：旧样本全部作废
    if (_parserInited) flv_parser_reset(&_parser);
    _gotAvcc = NO;
    _gotIDR = NO;
    _lastAvcc = nil;
    _nalLengthSize = 4;
    _videoTimebaseReady = NO;
    _videoBaseMs = 0;
    _audioTimebaseReady = NO;
    _audioBaseMs = 0;
    _audioClockRate = 44100;
    _loggedNonAvcVideo = NO;
    _loggedNonAacAudio = NO;
    _loggedScriptData = NO;
    _lastSentTime = kCMTimeZero;
    _lastAnyDataAt = CACurrentMediaTime();
    [_stateLock lock];
    _stats.last_video_frame_at = 0;
    [_stateLock unlock];
    [self flv_ensureDecodersLocked];
}

- (void)flv_scheduleReconnectLocked:(NSString *)reason
{
    if (_stopped || [self flv_stopRequested] || _reconnectScheduled) return;
    _reconnectScheduled = YES;

    NSInteger attempt = _reconnectAttempt;
    _reconnectAttempt = MIN(_reconnectAttempt + 1, 3);
    NSTimeInterval delay = MIN(kVCamLANMaxBackoff, pow(2.0, (double)attempt));   // 1 2 4 8

    [_stateLock lock];
    _stats.reconnects++;
    [_stateLock unlock];

    FLVLOG(@"%@ → %.0f 秒后重连（第 %ld 次）", reason.length ? reason : @"连接中断",
           delay, (long)(attempt + 1));

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _ioQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_reconnectScheduled = NO;
        if (strongSelf->_stopped || [strongSelf flv_stopRequested]) {
            FLVLOG(@"重连取消（已停止）");
            return;
        }
        [strongSelf flv_teardownSessionLocked];
        [strongSelf flv_startLockedWithConfig:strongSelf->_config];
    });
}

#pragma mark - 看门狗

- (void)flv_startWatchdogLocked
{
    [self flv_stopWatchdogLocked];
    _watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _ioQueue);
    if (!_watchdog) return;
    dispatch_source_set_timer(_watchdog,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                              (uint64_t)NSEC_PER_SEC,
                              (uint64_t)(200 * NSEC_PER_MSEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_watchdog, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf flv_watchdogTick];
    });
    dispatch_resume(_watchdog);
}

- (void)flv_stopWatchdogLocked
{
    if (_watchdog) {
        dispatch_source_cancel(_watchdog);
        _watchdog = nil;
    }
}

- (void)flv_watchdogTick
{
    if (_stopped) return;
    double now = CACurrentMediaTime();

    // ① 有画面但停滞 → 重建解码器（等下一个 sequence header / IDR）
    double lastFrame;
    int64_t frames;
    [_stateLock lock];
    lastFrame = _stats.last_video_frame_at;
    frames = _stats.delivered_frames;
    [_stateLock unlock];

    if (frames > 0 && lastFrame > 0 && (now - lastFrame) > kVCamLANStallTimeout) {
        FLVLOG(@"画面停滞 %.1f 秒（累计上屏 %lld 帧）→ 重建解码器", now - lastFrame, frames);
        [self flv_rebuildDecoderLocked:@"画面停滞"];
        [_stateLock lock];
        _stats.last_video_frame_at = now;   // 复位计时，避免每秒重复重建
        [_stateLock unlock];
    }

    // ② 连接还在但一个字节都不来 → 重连
    if (_task && (now - _lastAnyDataAt) > kVCamLANStarveTimeout) {
        FLVLOG(@"%.1f 秒没收到任何数据 → 断开重连", now - _lastAnyDataAt);
        [self flv_teardownSessionLocked];
        [self flv_scheduleReconnectLocked:@"连接空转"];
    }
}

#pragma mark - 解码器

- (void)flv_ensureDecodersLocked
{
    if (!_decoder) {
        _decoder = (VCamVTDecoder *)VCamLANDynAllocInit(@"VCamVTDecoder");   // TrollStore：不绑定类符号
        __weak typeof(self) weakSelf = self;
        _decoder.onFrame = ^(CVPixelBufferRef pixelBuffer, CMTime presentationTime) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !pixelBuffer) return;
            // 上屏唯一通路（Cam_pipeline_contract.md §4.3）
            // TrollStore：类名走 NSClassFromString，不绑定 _OBJC_CLASS_$_VCamFrameStore 符号
            id store = VCamLANDynClassMsg(@"VCamFrameStore", @"sharedStore");
            [(VCamFrameStore *)store updatePixelBuffer:pixelBuffer presentationTime:presentationTime];
            [strongSelf->_stateLock lock];
            strongSelf->_stats.delivered_frames++;
            strongSelf->_stats.last_video_frame_at = CACurrentMediaTime();
            [strongSelf->_stateLock unlock];
        };
        _decoder.onOutputFailure = ^(int status, unsigned int flags) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            FLVLOG(@"VT 输出失败 status=%d flags=0x%x → 重建解码器等 IDR", status, flags);
            [strongSelf->_stateLock lock];
            strongSelf->_stats.decode_errors++;
            [strongSelf->_stateLock unlock];
            dispatch_async(strongSelf->_ioQueue, ^{
                [strongSelf flv_rebuildDecoderLocked:@"VT 输出失败"];
            });
        };
        FLVLOG(@"VCamVTDecoder 已创建");
    }
    if (!_aacDecoder) {
        _aacDecoder = (VCamAACDecoder *)VCamLANDynAllocInit(@"VCamAACDecoder");   // TrollStore：不绑定类符号
        FLVLOG(@"VCamAACDecoder 已创建");
    }
}

- (void)flv_rebuildDecoderLocked:(NSString *)reason
{
    if (_stopped) return;
    FLVLOG(@"重建解码器：%@", reason.length ? reason : @"未说明原因");

    // 先把世代推上去，让 _decodeQueue 里已经排队的旧样本全部失效（对应 0x1b74c 的 decodeGeneration）
    _decodeGeneration++;

    if (_decoder) {
        _decoder.onFrame = nil;
        _decoder.onOutputFailure = nil;
        [_decoder invalidate];
        _decoder = nil;
    }
    _gotIDR = NO;
    _gotAvcc = NO;
    [self flv_ensureDecodersLocked];

    // 上次的 AVCC 还留着就立刻重喂，省掉"等下一个 sequence header"的时间；
    // 之后如果推流端重发 sequence header，会覆盖它。
    if (_lastAvcc.length >= 8) {
        NSData *cached = _lastAvcc;
        [self applyAvccRecord:cached];
    }
}

- (void)applyAvccRecord:(NSData *)record
{
    if (!_decoder) return;
    if (record.length < 8) {
        [self flv_noteError:@"AVCC 无效：AVCDecoderConfigurationRecord 长度 < 8"];
        return;
    }
    if (record.length > 0x10000) {
        [self flv_noteError:@"AVCC 截断：AVCDecoderConfigurationRecord 长度 > 64KB"];
        return;
    }

    _lastAvcc = [record copy];
    _nalLengthSize = flv_avcc_length_size((const uint8_t *)record.bytes, (uint32_t)record.length);

    NSError *err = nil;
    BOOL ok = NO;
    @try {
        ok = [_decoder setAvccExtra:record error:&err];
    } @catch (NSException *e) {
        FLVLOG(@"setAvccExtra: 抛异常 %@", e.reason);
        ok = NO;
    }
    if (!ok) {
        [self flv_noteError:[NSString stringWithFormat:@"AVCC 配置失败：%@",
                             err.localizedDescription.length ? err.localizedDescription : @"未知"]];
        FLVLOG(@"setAvccExtra: 失败 %@", err);
        return;
    }

    _gotAvcc = YES;
    [_stateLock lock];
    _stats.avcc_records++;
    [_stateLock unlock];
    FLVLOG(@"AVC sequence header 已配置：%lu 字节，NAL 长度字段 %d 字节",
           (unsigned long)record.length, _nalLengthSize);
}

- (void)submitVideoSample:(NSData *)sample tsMs:(int64_t)tsMs keyframe:(BOOL)keyframe
{
    if (_stopped || !_gotAvcc) return;
    VCamVTDecoder *decoder = _decoder;
    if (!decoder || sample.length == 0) return;

    // ---- 时间戳 ----
    // RTSP 视频路径的值 = (当前ts - videoRtpBase)（0x1b264 / 0x1b26c subs w8,w8,w0），
    // timescale 固定 90000（0x1b280 mov w1,#0x5f90 + 0x1b284 movk w1,#1,lsl#16 = 0x15F90）。
    // 这里用"首帧 ts 当 0"代替 videoRtpBase，就是同一件事。
    if (!_videoTimebaseReady) {
        _videoBaseMs = tsMs;
        _videoTimebaseReady = YES;
        FLVLOG(@"视频时间基准 = %lld ms（后续 CMTime value = (ts - base) * 90 @90000）", tsMs);
    }
    int64_t relMs = tsMs - _videoBaseMs;
    if (relMs < 0) relMs = 0;
    CMTime ts = CMTimeMake(relMs * (int64_t)90, kVCamLANVideoTimescale);

    // 预热：还没见过 IDR、且这一帧也不是关键帧 → 解码但不上屏
    const BOOL suppressPreheat = (!_gotIDR && !keyframe);
    const uint64_t gen = _decodeGeneration;
    NSData *nal = [sample copy];

    [_stateLock lock];
    _stats.pending_decode_jobs++;
    _stats.video_samples++;
    if (keyframe) _stats.idr_frames++;
    [_stateLock unlock];

    __weak typeof(self) weakSelf = self;
    dispatch_async(_decodeQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 世代校验：rebuildDecoder 之后队列里的旧样本必须丢弃，否则会污染新解码器状态
        // （对应 RTSP 的 decodeGeneration，0x1b74c）
        if (gen != strongSelf->_decodeGeneration) {
            [strongSelf->_stateLock lock];
            strongSelf->_stats.pending_decode_jobs--;
            strongSelf->_stats.dropped_decode_jobs++;
            [strongSelf->_stateLock unlock];
            return;
        }

        // 积压抑制：pendingDecodeJobs > 6 就只解不上屏（0x1b84c subs x8,x8,#6 ; cset w8,gt）
        int64_t pending = 0;
        [strongSelf->_stateLock lock];
        pending = strongSelf->_stats.pending_decode_jobs;
        [strongSelf->_stateLock unlock];
        BOOL suppress = suppressPreheat || (pending > kVCamLANMaxPendingDecodes);

        NSError *err = nil;
        BOOL ok = NO;
        @try {
            ok = [decoder decodeAvccSample:nal
                                 timestamp:ts
                            suppressOutput:suppress
                                     error:&err];
        } @catch (NSException *e) {
            FLVLOG(@"decodeAvccSample: 抛异常 %@", e.reason);
            ok = NO;
        }

        [strongSelf->_stateLock lock];
        strongSelf->_stats.pending_decode_jobs--;
        if (!ok) strongSelf->_stats.decode_errors++;
        [strongSelf->_stateLock unlock];

        if (!ok) {
            FLVLOG(@"decodeAvccSample 失败 ts=%lld/%d suppress=%d pending=%lld：%@",
                   (long long)ts.value, (int)ts.timescale, (int)suppress, (long long)pending,
                   err.localizedDescription);
        }
    });

    if (keyframe && !_gotIDR) {
        _gotIDR = YES;
        FLVLOG(@"收到首个 IDR（ts=%lldms → CMTime %lld/90000），从此帧开始上屏",
               tsMs, (long long)ts.value);
    }
}

#pragma mark - tag 分发

- (void)handleTag:(const flv_tag_t *)tag
{
    _lastAnyDataAt = CACurrentMediaTime();
    if (!tag) return;
    switch (tag->type) {
        case FLV_TAG_VIDEO:  [self handleVideoTag:tag];  break;
        case FLV_TAG_AUDIO:  [self handleAudioTag:tag];  break;
        case FLV_TAG_SCRIPT: [self handleScriptTag:tag]; break;
        default:
            // 未知类型不致命：解析器已经在 unknown_tags 里记了一笔，这里只打日志继续跑
            FLVLOG(@"未知 tag type=%u size=%u ts=%lld，跳过",
                   (unsigned)tag->type, (unsigned)tag->data_size, tag->timestamp);
            break;
    }
}

- (void)handleVideoTag:(const flv_tag_t *)tag
{
    [_stateLock lock];
    _stats.video_tags++;
    [_stateLock unlock];

    const uint8_t *p = tag->data;
    uint32_t n = tag->data_len;
    if (!p || n < 5) {
        FLVLOG(@"video tag 太短（%u 字节），跳过", (unsigned)n);
        return;
    }

    uint8_t b0 = p[0];
    int frame_type = (b0 >> 4) & 0x0F;   // 1=关键帧 2=中间帧 3=可丢 4=生成关键帧 5=视频信息
    int codec_id   = b0 & 0x0F;          // 7 = AVC(H.264)
    if (codec_id != 7) {
        if (!_loggedNonAvcVideo) {
            _loggedNonAvcVideo = YES;
            FLVLOG(@"video codecId=%d 不是 H.264(7)：本工程只解 H.264，后续视频 tag 全部跳过", codec_id);
            [self flv_noteError:[NSString stringWithFormat:
                                 @"视频编码 codecId=%d 不是 H.264 —— 请把 OBS/SRS 的编码改成 H264", codec_id]];
        }
        return;
    }

    uint8_t avc_packet_type = p[1];
    int32_t cts = flv_si24(p + 2);       // CompositionTime（有符号 24 位）

    if (avc_packet_type == 0) {
        // AVC sequence header：body[5..] 就是 AVCDecoderConfigurationRecord，零转换直喂
        NSData *rec = [NSData dataWithBytes:(p + 5) length:(NSUInteger)(n - 5)];
        [self applyAvccRecord:rec];
        return;
    }
    if (avc_packet_type == 2) {
        FLVLOG(@"AVC end of sequence（ts=%lldms）", tag->timestamp);
        return;
    }
    if (avc_packet_type != 1) {
        FLVLOG(@"未知 AVCPacketType=%d，跳过", (int)avc_packet_type);
        return;
    }

    // NAL 样本：body[5..] 是 AVCC 长度前缀，与 -decodeAvccSample: 期望格式完全一致
    NSData *sample = [NSData dataWithBytes:(p + 5) length:(NSUInteger)(n - 5)];

    flv_nalu_stat_t st;
    int scan = flv_scan_avcc_nalus((const uint8_t *)sample.bytes,
                                   (uint32_t)sample.length,
                                   _nalLengthSize,
                                   &st);
    if (scan < 0) {
        FLVLOG(@"NAL 长度字段越界（lengthSize=%d，样本 %lu 字节），丢这一帧",
               _nalLengthSize, (unsigned long)sample.length);
        return;
    }
    [_stateLock lock];
    _stats.nal_total += st.count;
    _stats.nal_idr   += st.idr;
    _stats.nal_sps   += st.sps;
    _stats.nal_pps   += st.pps;
    _stats.nal_sei   += st.sei;
    _stats.nal_other += st.other + st.non_idr;
    [_stateLock unlock];

    BOOL keyframe = (st.idr > 0) || (frame_type == 1) || (frame_type == 4);
    int64_t tsMs = tag->timestamp + (int64_t)cts;
    if (tsMs < 0) tsMs = 0;

    [self submitVideoSample:sample tsMs:tsMs keyframe:keyframe];
}

- (void)handleAudioTag:(const flv_tag_t *)tag
{
    [_stateLock lock];
    _stats.audio_tags++;
    BOOL muted = _muted;
    [_stateLock unlock];

    const uint8_t *p = tag->data;
    uint32_t n = tag->data_len;
    if (!p || n < 2) return;

    uint8_t b0 = p[0];
    int sound_format = (b0 >> 4) & 0x0F;
    int sound_rate   = (b0 >> 2) & 0x03;   // 0=5.5k 1=11k 2=22k 3=44k
    int sound_size   = (b0 >> 1) & 0x01;   // 0=8bit 1=16bit
    int sound_type   = b0 & 0x01;          // 0=mono 1=stereo

    if (sound_format != 10) {
        if (!_loggedNonAacAudio) {
            _loggedNonAacAudio = YES;
            FLVLOG(@"audio soundFormat=%d 不是 AAC(10)（rate=%d size=%d type=%d）：本工程只解 AAC",
                   sound_format, sound_rate, sound_size, sound_type);
        }
        return;
    }
    if (n < 3) return;

    if (muted) return;   // 静音：音频 tag 直接不送解码

    uint8_t aac_packet_type = p[1];
    NSData *body = [NSData dataWithBytes:(p + 2) length:(NSUInteger)(n - 2)];
    NSError *err = nil;

    if (aac_packet_type == 0) {
        if (!_aacDecoder) {
            _aacDecoder = (VCamAACDecoder *)VCamLANDynAllocInit(@"VCamAACDecoder");   // TrollStore：不绑定类符号
        }
        int32_t ascRate = flv_aac_rate_from_asc((const uint8_t *)body.bytes, (uint32_t)body.length);
        if (ascRate > 0) {
            _audioClockRate = ascRate;
        }
        BOOL ok = NO;
        @try {
            ok = [_aacDecoder configureWithASC:body error:&err];
        } @catch (NSException *e) {
            FLVLOG(@"configureWithASC: 抛异常 %@", e.reason);
            ok = NO;
        }
        if (ok) {
            FLVLOG(@"AAC AudioSpecificConfig 已配置：%lu 字节，clockRate=%d（FLV 板载 rate=%d size=%d type=%d）",
                   (unsigned long)body.length, _audioClockRate, sound_rate, sound_size, sound_type);
        } else {
            FLVLOG(@"AAC ASC 配置失败：%@", err.localizedDescription);
            [self flv_noteError:@"AAC ASC无效 —— 音频会没声音（视频不受影响）"];
        }
        return;
    }
    if (aac_packet_type != 1) {
        FLVLOG(@"未知 AACPacketType=%d，跳过", (int)aac_packet_type);
        return;
    }
    if (!_aacDecoder) return;

    // 音频时间戳：timescale 用 AAC 的 clock rate（RTSP 侧也是用 _audioClockRate 变量当 timescale，
    // 0x1c52c ldur w1,[x29,#-0x24]），值同样减去首帧基准。
    int32_t rate = _audioClockRate > 0 ? _audioClockRate : 44100;
    if (!_audioTimebaseReady) {
        _audioBaseMs = tag->timestamp;
        _audioTimebaseReady = YES;
        FLVLOG(@"音频时间基准 = %lld ms，clockRate=%d", tag->timestamp, rate);
    }
    int64_t relMs = tag->timestamp - _audioBaseMs;
    if (relMs < 0) relMs = 0;
    CMTime pts = CMTimeMake((relMs * (int64_t)rate) / 1000, rate);

    BOOL ok = NO;
    @try {
        ok = [_aacDecoder decodeAACFrame:body pts:pts error:&err];
    } @catch (NSException *e) {
        FLVLOG(@"decodeAACFrame: 抛异常 %@", e.reason);
        ok = NO;
    }
    if (ok) {
        [_stateLock lock];
        _stats.audio_samples++;
        [_stateLock unlock];
    } else {
        FLVLOG(@"AAC 解码失败：%@", err.localizedDescription);
    }
}

- (void)handleScriptTag:(const flv_tag_t *)tag
{
    [_stateLock lock];
    _stats.script_tags++;
    [_stateLock unlock];

    if (_loggedScriptData) return;
    _loggedScriptData = YES;

    const uint8_t *p = tag->data;
    uint32_t n = tag->data_len;
    if (!p || n < 3) return;

    // 只做"能不能跳过"的容错 + 顺手抖出 onMetaData 里的分辨率/帧率，不做完整 AMF 解析
    BOOL hasMeta = NO;
    static const char kMeta[] = "onMetaData";
    if (n >= (uint32_t)(sizeof(kMeta) - 1)) {
        for (uint32_t i = 0; i + sizeof(kMeta) - 1 <= n; i++) {
            if (memcmp(p + i, kMeta, sizeof(kMeta) - 1) == 0) { hasMeta = YES; break; }
        }
    }
    double w = 0, h = 0, fps = 0;
    flv_find_amf_number(p, n, "width", &w);
    flv_find_amf_number(p, n, "height", &h);
    flv_find_amf_number(p, n, "framerate", &fps);
    FLVLOG(@"Script Data%s（%u 字节）：width=%.0f height=%.0f framerate=%.2f",
           hasMeta ? " onMetaData" : "", (unsigned)n, w, h, fps);
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    if (_stopped || dataTask != _task) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    NSInteger status = 200;
    NSString *mime = @"";
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *hr = (NSHTTPURLResponse *)response;
        status = hr.statusCode;
        id ct = hr.allHeaderFields[@"Content-Type"] ?: hr.allHeaderFields[@"content-type"];
        if ([ct isKindOfClass:[NSString class]]) mime = ct;
    }
    FLVLOG(@"HTTP 响应 %ld Content-Type=%@", (long)status, mime.length ? mime : @"(空)");

    if (status != 200) {
        [self flv_noteError:[self flv_messageForHTTPStatus:status]];
        completionHandler(NSURLSessionResponseCancel);
        [self flv_scheduleReconnectLocked:[NSString stringWithFormat:@"HTTP %ld", (long)status]];
        return;
    }
    if (mime.length && [mime rangeOfString:@"flv" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        FLVLOG(@"Content-Type 不是 video/x-flv（%@），仍按 FLV 解析", mime);
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    if (_stopped || dataTask != _task) return;
    if (!_parserInited || data.length == 0) return;

    if (!_loggedFirstByte) {
        _loggedFirstByte = YES;
        FLVLOG(@"收到首包 %lu 字节", (unsigned long)data.length);
    }
    [_stateLock lock];
    _stats.bytes += (int64_t)data.length;
    [_stateLock unlock];

    uint64_t tagsBefore = _parser.tags;
    int rc = flv_parser_feed(&_parser,
                             data.bytes,
                             (size_t)data.length,
                             vcam_flv_tag_cb,
                             (__bridge void *)self);

    if (rc < 0) {
        NSString *msg = [NSString stringWithFormat:@"FLV 解析失败：%s", flv_parser_error(&_parser)];
        [self flv_noteError:msg];
        FLVLOG(@"%@", msg);
        [self flv_teardownSessionLocked];
        [self flv_scheduleReconnectLocked:@"解析失败"];
        return;
    }

    if (tagsBefore == 0 && _parser.tags > 0) {
        _reconnectAttempt = 0;   // 真吃到完整 tag 了，退避归零
        FLVLOG(@"FLV 头解析成功：version=%u flags=0x%02x headerSize=%u",
               (unsigned)_parser.flv_version, (unsigned)_parser.flv_flags,
               (unsigned)_parser.header_size);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    if (task != _task) return;
    _task = nil;
    if (_stopped || [self flv_stopRequested]) return;

    if (error) {
        NSString *msg = [self flv_messageForNSError:error];
        [self flv_noteError:msg];
        FLVLOG(@"连接结束（错误 %ld %@）：%@",
               (long)error.code, error.domain, error.localizedDescription);
        [self flv_scheduleReconnectLocked:msg];
    } else {
        FLVLOG(@"连接被推流端正常关闭");
        [self flv_scheduleReconnectLocked:@"推流端关闭"];
    }
}

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
    // 自签 HTTPS（MediaMTX / SRS 开了 TLS 的场合）直接放行，否则 https 源永远连不上
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] &&
        challenge.protectionSpace.serverTrust != NULL) {
        completionHandler(NSURLSessionAuthChallengeUseCredential,
                          [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
        return;
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

#pragma mark - 错误文案

- (NSString *)flv_messageForHTTPStatus:(NSInteger)status
{
    if (status == 404) {
        return @"地址不存在(404) 先确认电脑端在推流，路径要和推流名一致"
                @"（MediaMTX 默认 live/obs，SRS 默认 live/livestream）";
    }
    if (status == 401 || status == 403) {
        return [NSString stringWithFormat:@"推流服务器拒绝访问(%ld) 检查地址是否需要鉴权", (long)status];
    }
    if (status >= 500) {
        return [NSString stringWithFormat:@"推流服务器出错(%ld) 看电脑端 MediaMTX/SRS 日志", (long)status];
    }
    return [NSString stringWithFormat:@"HTTP %ld —— 确认地址指向 HTTP-FLV 端点而不是 RTSP/HLS", (long)status];
}

- (NSString *)flv_messageForNSError:(NSError *)error
{
    if (![error.domain isEqualToString:NSURLErrorDomain]) {
        return [NSString stringWithFormat:@"连接中断：%@", error.localizedDescription];
    }
    switch (error.code) {
        case NSURLErrorCannotConnectToHost:
            return @"电脑拒绝连接，请确认 HTTP-FLV 服务已启动且端口对得上"
                    @"（MediaMTX 的 HTTP-FLV 默认 8888，SRS 默认 8080）";
        case NSURLErrorTimedOut:
            return @"连接超时，请确认手机和电脑在同一 Wi-Fi，且 IP / 端口 / 路径都正确";
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
            return @"地址解析失败，请直接填写电脑 IPv4";
        case NSURLErrorNotConnectedToInternet:
            return @"手机没联网，或抖音无局域网权限（系统设置 → 隐私与安全 → 本地网络）";
        case NSURLErrorNetworkConnectionLost:
            return @"连接中断，重连中";
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return @"明文 http 被 ATS 拦截 —— 把 host 换成 IP（IP 字面量与 .local 不受 ATS 限制）";
        default:
            return [NSString stringWithFormat:@"连接错误(%ld) %@", (long)error.code, error.localizedDescription];
    }
}

@end
