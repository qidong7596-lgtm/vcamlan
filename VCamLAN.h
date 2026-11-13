//
//  VCamLAN.h —— VCamLAN 工程的公共声明（Cam.dylib 接口子集 + 本工程新增类）
//
//  全部 @interface / selector / 类型来自对 Cam.dylib 的 ObjC 元数据还原：
//    来源：work/objc_full.json（class_ro_t 全量快照，含每个 selector 的 imp 与 types）
//          work/Cam_interface.h（1721 行，ivar 绝对偏移 + type encoding 全解码）
//          work/Cam_config_keys.md / Cam_pipeline_contract.md
//  这里只摘录本工程用得到的最小必要子集，**selector 名字与签名原样保留**，不做任何改写。
//
//  ivar 块有意省略：本工程所有字段访问都走属性 getter / setter，
//  不直接读 ivar 偏移，因此不需要在重声明里复刻内存布局。
//
//  ⚠️ 本文件里声明的 Cam 类**只用于编译期类型检查**（指针类型、属性名）。
//     运行时取对象一律走 NSClassFromString / VCamLANRuntime.h 里的工具，
//     **任何地方都不出现 `_OBJC_CLASS_$_VCamXXX` 类符号**（否则 TrollFools 注入顺序一变就 dyld abort）。
//
#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

// 运行时取类 / 调用工具（对 Cam 的类零符号引用，见该头文件顶部说明）
#import "VCamLANRuntime.h"

// 本工程新增类
#import "VCamLANHTTPFLVPuller.h"

// 注意：#import 必须放在 NS_ASSUME_NONNULL_BEGIN 之前，
// 否则 clang 报 "cannot #include files inside '#pragma clang assume_nonnull'"
NS_ASSUME_NONNULL_BEGIN

@class VCamStreamConfig;
@class VCamRTSPPuller;
@class VCamUSBPuller;
@class VCamLocalPlayer;
@class VCamVTDecoder;
@class VCamAACDecoder;
@class VCamHTTPFLVPuller;
@class VCamLANHTTPFLVPuller;

// ==================================================================
// VCamStreamConfig : NSObject   instanceStart=0x8 instanceSize=0x48
//   ivar 布局（来自 class_ro_t / ivar_list）：
//     +0x08 _enabled(BOOL)  +0x10 _host  +0x18 _port  +0x20 _path
//     +0x28 _rotationDegrees  +0x30 _sourceType  +0x38 _localPath
//     +0x40 _transport  +0x09 _mirrored  +0x0a _muted  +0x0b _prefersUSB
// ==================================================================
@interface VCamStreamConfig : NSObject

@property (copy, nonatomic) NSString *host;                              // T@"NSString",C,N,V_host
@property (nonatomic) NSUInteger port;                                   // TQ,N,V_port
@property (copy, nonatomic) NSString *path;                              // T@"NSString",C,N,V_path
@property (nonatomic, getter=isEnabled) BOOL enabled;                    // TB,N,GisEnabled,V_enabled
@property (nonatomic) BOOL mirrored;                                     // TB,N,V_mirrored
@property (nonatomic) BOOL muted;                                        // TB,N,V_muted
@property (nonatomic) NSInteger rotationDegrees;                         // Tq,N,V_rotationDegrees
@property (nonatomic) NSInteger sourceType;                              // Tq,N,V_sourceType
@property (copy, nonatomic) NSString *localPath;                         // T@"NSString",C,N,V_localPath
@property (copy, nonatomic) NSString *transport;                         // T@"NSString",C,N,V_transport
@property (nonatomic) BOOL prefersUSB;                                   // TB,N,V_prefersUSB
@property (readonly, copy, nonatomic) NSString *pullURL;                  // T@"NSString",R,C,N  imp=0x9230
@property (readonly, copy, nonatomic) NSString *sourceTitle;              // T@"NSString",R,C,N  imp=0x9300

- (BOOL)hasConfiguredSource;                                             // imp=0x9080 types=B16@0:8
- (BOOL)isReplaceActive;                                                 // imp=0x91d8 types=B16@0:8
+ (NSString *)preferencesPath;                                           // imp=0x8328 types=@16@0:8
+ (instancetype)loadFromPreferences;                                     // imp=0x8430 types=@16@0:8

@end

// ==================================================================
// VCamFrameStore : NSObject   instanceStart=0x8 instanceSize=0x180
//   上屏唯一通路：updatePixelBuffer:presentationTime:
//     imp=0xaa00  types=v48@0:8^{__CVBuffer=}16{?=qiIq}24
// ==================================================================
@interface VCamFrameStore : NSObject

+ (instancetype)sharedStore;                                             // imp=0x9b2c types=@16@0:8
- (void)updatePixelBuffer:(CVPixelBufferRef)pixelBuffer
         presentationTime:(CMTime)presentationTime;                     // imp=0xaa00
- (void)setReplaceEnabled:(BOOL)replaceEnabled;                           // imp=0xa73c types=v20@0:8B16
- (BOOL)replaceEnabled;                                                   // imp=0x126b4 types=B16@0:8
- (void)setDetectPreviewActive:(BOOL)active;                              // imp=0x129e0 types=v20@0:8B16

@end

// ==================================================================
// VCamAudioStore : NSObject   instanceSize=0x119600（环形缓冲很大，不要 alloc 第二个）
//   restoreTapped 里对它的三连：setReplaceEnabled: → setCaptureActive:NO → reset
// ==================================================================
@interface VCamAudioStore : NSObject

+ (instancetype)sharedStore;                                             // imp=? 与 FrameStore 同一个 thunk 0x5b740
- (void)setReplaceEnabled:(BOOL)replaceEnabled;                           // imp=0x2b7d8 types=v20@0:8B16
- (void)setCaptureActive:(BOOL)active;                                    // imp=0x2ce8c types=v20@0:8B16
- (void)reset;                                                           // imp=0x2e5e0 types=v16@0:8

@end

// ==================================================================
// VCamVTDecoder : NSObject   instanceSize=0x50
// ==================================================================
@interface VCamVTDecoder : NSObject

// void (^)(CVPixelBufferRef, CMTime)  —— 由 __block_descriptor 反解：
// ___block_descriptor_40_e8_32w_e31_v40?0^{__CVBuffer=}8{?=qiIq}16l
@property (copy, nonatomic) void (^onFrame)(CVPixelBufferRef, CMTime);           // T@?,C,N,V_onFrame
// void (^)(int, unsigned int) —— ___block_descriptor_40_e8_32w_e11_v16?0i8I12l
@property (copy, nonatomic) void (^onOutputFailure)(int, unsigned int);          // T@?,C,N,V_onOutputFailure
@property (nonatomic) BOOL waitingKeyframe;                                      // TB,N,V_waitingKeyframe

- (id)init;                                                              // imp=0x27388 types=@16@0:8
- (void)invalidate;                                                      // imp=0x274e8 types=v16@0:8
- (void)requestKeyframe;                                                 // imp=0x28024 types=v16@0:8
- (BOOL)setAvccExtra:(NSData *)avcc error:(NSError **)error;              // imp=0x28174 types=B32@0:8@16^@24
- (BOOL)decodeAvccSample:(NSData *)sample
               timestamp:(CMTime)timestamp
                   error:(NSError **)error;                              // imp=0x28bfc types=B56@0:8@16{?=qiIq}24^@48
- (BOOL)decodeAvccSample:(NSData *)sample
               timestamp:(CMTime)timestamp
          suppressOutput:(BOOL)suppressOutput
                   error:(NSError **)error;                              // imp=0x28ca0 types=B60@0:8@16{?=qiIq}24B48^@52

@end

// ==================================================================
// VCamAACDecoder : NSObject   instanceSize=0x28
// ==================================================================
@interface VCamAACDecoder : NSObject

- (void)reset;                                                           // imp=0x29de4 types=v16@0:8
- (BOOL)configureWithASC:(NSData *)asc error:(NSError **)error;           // imp=0x29e4c types=B32@0:8@16^@24
- (BOOL)decodeAACFrame:(NSData *)frame
                   pts:(CMTime)pts
                 error:(NSError **)error;                                // imp=0x2a214 types=B56@0:8@16{?=qiIq}24^@48

@end

// ==================================================================
// VCamStreamPipeline : NSObject   instanceSize=0x38
//   _config      +0x18  @"VCamStreamConfig"
//   _rtspPuller  +0x20  @"VCamRTSPPuller"   ← 换源就换这个 getter（imp=0x393b4，全流程经 getter）
// ==================================================================
@interface VCamStreamPipeline : NSObject

@property (strong, nonatomic) VCamStreamConfig *config;                  // T@"VCamStreamConfig",&,N,V_config
@property (strong, nonatomic) VCamRTSPPuller *rtspPuller;                // T@"VCamRTSPPuller",&,N,V_rtspPuller
@property (strong, nonatomic) VCamUSBPuller *usbPuller;                  // T@"VCamUSBPuller",&,N,V_usbPuller
@property (strong, nonatomic) VCamLocalPlayer *localPlayer;              // T@"VCamLocalPlayer",&,N,V_localPlayer
@property (copy, nonatomic) NSString *streamError;                        // T@"NSString",C,N,V_streamError
@property (nonatomic) BOOL previewPullRequested;                          // TB,N,V_previewPullRequested

+ (instancetype)sharedPipeline;                                          // imp=0x371f0 types=@16@0:8
- (void)startIfNeeded;                                                   // imp=0x376f4 types=v16@0:8
- (void)applyRuntimeFlags;                                               // imp=0x37720 types=v16@0:8
- (void)reloadConfig;                                                    // imp=0x37af4 types=v16@0:8
- (void)setPreviewPullRequested:(BOOL)requested;                          // imp=0x3933c types=v20@0:8B16

@end

// ==================================================================
// VCamFloatingPanel : NSObject   instanceSize=0xa8（87 个方法，只摘录用得到的）
//   按钮网格 3×2：相册 / 直连 / 内录(红) / 镜像 / 旋转 / 拉流(橙)
//   对应 ivar：transportBtn(直连) / muteBtn(内录) / mirrorBtn(镜像) / rotateBtn(旋转)
//              相册 / 拉流 两个由 setupWhenReady 里局部创建，没有留 ivar 名
// ==================================================================
@interface VCamFloatingPanel : NSObject

@property (strong, nonatomic) UIWindow *window;                            // T@"UIWindow",&,N,V_window
@property (strong, nonatomic) UIView *panel;                               // T@"UIView",&,N,V_panel
@property (strong, nonatomic) UILabel *statusLabel;                        // T@"UILabel",&,N,V_statusLabel
@property (strong, nonatomic) UIButton *transportBtn;                      // T@"UIButton",&,N,V_transportBtn
@property (strong, nonatomic) UIButton *mirrorBtn;                         // T@"UIButton",&,N,V_mirrorBtn
@property (strong, nonatomic) UIButton *muteBtn;                           // T@"UIButton",&,N,V_muteBtn
@property (strong, nonatomic) UIButton *rotateBtn;                         // T@"UIButton",&,N,V_rotateBtn
@property (nonatomic) BOOL expanded;                                     // TB,N,V_expanded（getter 就是 expanded）

+ (instancetype)shared;                                                  // imp=0x39688 types=@16@0:8
- (void)installIfNeeded;
- (void)setupWhenReady;
- (void)refreshStatus;                                                   // imp=0x40e90 types=v16@0:8（12 处调用）
- (void)layoutForState;                                                  // imp=0x3f074 types=v16@0:8（零引用，不 hook）
- (NSMutableDictionary *)loadPrefsMutable;                               // imp=0x40688 types=@16@0:8
- (void)applyLightPrefsFromDisk;                                         // imp=0x407b0 types=v16@0:8
- (void)savePrefs:(NSDictionary *)prefs;                                 // imp=0x409cc types=v24@0:8@16
- (void)savePrefs:(NSDictionary *)prefs reloadPipeline:(BOOL)reload;      // imp=0x40a30 types=v28@0:8@16B24
- (void)restoreTapped;                                                   // imp=0x44ed4 types=v16@0:8（enabled 取反，见 Main.m 顶部反汇编结论）
- (void)transportTapped;                                                 // imp=0x43f78（直连：写死 mediaTransport="usb"）
- (void)stopDetectPreviewLink;                                           // imp=0x43e68 types=v16@0:8
- (void)setDetectPageVisible:(BOOL)visible;                               // imp=0x47428 types=v20@0:8B16

@end

NS_ASSUME_NONNULL_END
