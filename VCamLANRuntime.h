//
//  VCamLANRuntime.h —— 运行时取类 / 发消息的小工具（TrollStore 专用）
//
//  为什么要这么写（不是风格问题，是启动崩溃问题）：
//    普通 tweak 里可以直接写 [[VCamVTDecoder alloc] init]，编译器会生成一个
//    未定义符号 `_OBJC_CLASS_$_VCamVTDecoder`，靠 Theos 默认的 -undefined dynamic_lookup
//    在**加载期**由 dyld 到所有已加载镜像里找。
//    越狱环境下 MobileSubstrate 保证「目标 App 先加载、插件后注入」，所以总能找到。
//    TrollStore / TrollFools 是直接往 Mach-O 里塞 LC_LOAD_DYLIB，**顺序由注入器决定**：
//    一旦我们的 dylib 排在 Cam.dylib 之前，dyld 找不到那几个类符号就会
//    `Symbol not found: _OBJC_CLASS_$_VCamXXX` 直接 abort —— 不是「等会再试」，是当场崩，
//    下面的 100ms 轮询根本没机会跑。
//    ⇒ 所以本工程对 Cam 的类**一律**用 NSClassFromString 取，类符号零引用；
//      类还没到就返回 nil，轮询循环接着等。dylib 单独加载也不会有任何未解析符号。
//
//  另一条硬约束：**所有自底向上取 IMP 的调用都先验方法是否存在**。
//    Cam 下一个版本删掉某个 selector 时，这里会打一行日志然后安全返回默认值，
//    不会变成 +[NSObject doesNotRecognizeSelector:] 崩溃。
//
#pragma once

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// 取类（等价 NSClassFromString，只为可读性 / 便于 lint 统计）
static inline Class VCamLANDynClass(NSString *name)
{
    return NSClassFromString(name);
}

/// [[Cls alloc] init]，类不在就返回 nil
static inline id VCamLANDynAllocInit(NSString *className)
{
    Class c = NSClassFromString(className);
    if (!c) {
        NSLog(@"[VCamLAN] %@ 尚未加载，跳过实例化（稍后重试由调用方轮询）", className);
        return nil;
    }
    return [[c alloc] init];
}

/// [Cls someClassMethod]，类 / 方法不在就返回 nil
static inline id VCamLANDynClassMsg(NSString *className, NSString *selName)
{
    Class c = NSClassFromString(className);
    if (!c) return nil;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getClassMethod(c, sel);
    if (!m) {
        NSLog(@"[VCamLAN] %@ 没有类方法 %@", className, selName);
        return nil;
    }
    id (*fn)(id, SEL) = (id (*)(id, SEL))method_getImplementation(m);
    return fn((id)c, sel);
}

/// 取实例方法的 IMP；方法不存在返回 NULL 并打日志（调用方据此走默认值）
static inline IMP VCamLANDynInstanceIMP(id obj, NSString *selName)
{
    if (!obj) return NULL;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m) {
        NSLog(@"[VCamLAN] %@ 没有方法 %@", NSStringFromClass(object_getClass(obj)), selName);
        return NULL;
    }
    return method_getImplementation(m);
}

/// 无参 void 实例方法。取的是**当前** IMP —— 已被 swizzle 过就走我们的 hook，链不会断。
static inline void VCamLANDynCallVoid(id obj, NSString *selName)
{
    IMP imp = VCamLANDynInstanceIMP(obj, selName);
    if (!imp) return;
    void (*fn)(id, SEL) = (void (*)(id, SEL))imp;
    fn(obj, NSSelectorFromString(selName));
}

/// 一个对象参数的 void 实例方法（例：savePrefs:）
static inline void VCamLANDynCallVoidObj(id obj, NSString *selName, id arg)
{
    IMP imp = VCamLANDynInstanceIMP(obj, selName);
    if (!imp) return;
    void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))imp;
    fn(obj, NSSelectorFromString(selName), arg);
}

/// 一个 BOOL 参数的 void 实例方法（例：setReplaceEnabled: / setDetectPageVisible:）
/// 注：arm64 上 BOOL 是 bool（1 字节寄存器传参与 int 一致），直接按 BOOL 传安全。
static inline void VCamLANDynCallVoidBool(id obj, NSString *selName, BOOL arg)
{
    IMP imp = VCamLANDynInstanceIMP(obj, selName);
    if (!imp) return;
    void (*fn)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))imp;
    fn(obj, NSSelectorFromString(selName), arg);
}

/// 无参对象返回值实例方法（例：transport / host / statusLabel）
static inline id _Nullable VCamLANDynObj(id obj, NSString *selName)
{
    IMP imp = VCamLANDynInstanceIMP(obj, selName);
    if (!imp) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))imp;
    return fn(obj, NSSelectorFromString(selName));
}

/// 无参 BOOL 返回值实例方法（例：prefersUSB / expanded / isRunning）
static inline BOOL VCamLANDynBool(id obj, NSString *selName)
{
    IMP imp = VCamLANDynInstanceIMP(obj, selName);
    if (!imp) return NO;
    BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))imp;
    return fn(obj, NSSelectorFromString(selName));
}

/// 无参整型返回值实例方法（例：sourceType，types=q16@0:8，NSInteger 即 long）
static inline long VCamLANDynInteger(id obj, NSString *selName)
{
    IMP imp = VCamLANDynInstanceIMP(obj, selName);
    if (!imp) return 0;
    long (*fn)(id, SEL) = (long (*)(id, SEL))imp;
    return fn(obj, NSSelectorFromString(selName));
}

/// 无符号整型返回值（例：port，types=Q16@0:8，NSUInteger 即 unsigned long）
static inline unsigned long VCamLANDynUnsigned(id obj, NSString *selName)
{
    IMP imp = VCamLANDynInstanceIMP(obj, selName);
    if (!imp) return 0;
    unsigned long (*fn)(id, SEL) = (unsigned long (*)(id, SEL))imp;
    return fn(obj, NSSelectorFromString(selName));
}

NS_ASSUME_NONNULL_END
