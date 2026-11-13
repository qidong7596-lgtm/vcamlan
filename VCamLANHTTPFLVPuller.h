//
//  VCamLANHTTPFLVPuller.h —— 本工程新增类（不属于 Cam.dylib）
//
//  pipeline 对 puller 只发 4 条消息（见 Cam_pipeline_contract.md §3.3，全部经 objc_msgSend，
//  运行期**不做**静态类类型校验 —— Cam 内部 43 处 isKindOfClass 已逐一排除，零命中）：
//    -applyConfig:  imp 0x38600   发送点
//    -stop          imp 0x37b70
//    -isRunning     imp 0x3797c
//    -lastError     imp 0x382e0
//  所以下面 4 条是硬性契约，签名必须与 VCamRTSPPuller 对应方法一致，其余是本工程自用的扩展接口。
//
//  实现体 VCamLANHTTPFLVPuller.m 从 work/VCamLAN/ 原样搬入，逻辑一行未改
//  （只改了 #import 与一处 sharedStore 取法，见 .m 顶部说明）。
//
#pragma once

#import <Foundation/Foundation.h>

@class VCamStreamConfig;

NS_ASSUME_NONNULL_BEGIN

@interface VCamLANHTTPFLVPuller : NSObject

// ---- pipeline 契约（4 条）----
- (void)applyConfig:(VCamStreamConfig *)config;   // 异步：内部 dispatch_async 到 _ioQueue，不阻塞调用方
- (void)stop;
- (BOOL)isRunning;
- (nullable NSError *)lastError;                   // 无错误返回 nil，有错误返回带中文描述的 NSError

// ---- 本工程扩展 ----
+ (instancetype)shared;
+ (NSString *)streamURLForConfig:(VCamStreamConfig *)config;   // 按 host/port/path/transport 拼 URL
- (NSString *)streamURL;                                       // 当前生效的 URL（未启动则返回将要用的 URL）
- (void)setStreamURL:(NSString *)url;                          // 直接指定完整 URL（覆盖 config 拼装结果）
- (NSString *)appliedStreamURL;                                // 最近一次真正开始拉流的 URL（供 diff 用）
- (void)updateRuntimeFlagsFromConfig:(VCamStreamConfig *)config;  // 同步 mirrored/muted/rotation
- (void)requestKeyframe;                                       // FLV 无 PLI：只做「重建解码器等 IDR」兜底
- (NSString *)diagnosticLine;                                  // 一行诊断：url / 收字节 / tag 数 / 帧数 / NAL 统计

@end

NS_ASSUME_NONNULL_END
