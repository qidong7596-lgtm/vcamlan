# ==================================================================
#  VCamLAN（TrollStore 版）—— 裸 dylib 产物，不用 tweak.mk，不产出 deb
#
#  编法（装了 Theos 的机器上，Linux / macOS / WSL 都行）：
#      export THEOS=$HOME/theos
#      make clean all
#  产物：
#      .theos/obj/VCamLAN.dylib   ← 同时会被复制到工程根目录的同名文件
#  只想要文件、不要 deb：
#      make all
#  （make package 也能跑，但 deb 里的 /usr/lib 路径对 TrollStore 没意义，别装它）
#
#  ARCHS 同时出 arm64 与 arm64e：TrollStore 支持的机型两者都有。
# ==================================================================

ifeq ($(THEOS),)
$(error THEOS 未设置，先执行：export THEOS=$$HOME/theos)
endif

ARCHS  := arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = VCamLAN

# VCamLANMain.m            —— 6 个 swizzle 点 + 自绘「网源」按钮 + 输入框 + 100ms×30 轮询
# VCamLANPrefs.m           —— com.douyin.stream.plist 读写（按反汇编结论重写）+ 地址解析 + 自有配置
# VCamLANHTTPFLVPuller.m   —— HTTP-FLV 拉流器主体（flv_parser.h 增量解析 + VT 硬解 + 上屏）
VCamLAN_FILES = VCamLANMain.m VCamLANPrefs.m VCamLANHTTPFLVPuller.m

VCamLAN_CFLAGS = -fobjc-arc \
                 -Wno-deprecated-declarations \
                 -Wno-unused-function \
                 -Wno-unused-variable \
                 -Wno-nullability-completeness \
                 -Wno-nullability-declspec \
                 -Wno-unguarded-availability-new \
                 -Wno-shorten-64-to-32 \
                 -I$(THEOS_PROJECT_DIR)

# 上屏走 CoreVideo / CoreMedia，硬解走 VideoToolbox，UI 走 UIKit，时间用 QuartzCore 的 CACurrentMediaTime
VCamLAN_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox QuartzCore

# Theos 默认已经带 -undefined dynamic_lookup；这里显式写一遍，换成别的构建系统时别丢。
# 注意：本工程对 Cam.dylib 的类**不产生** _OBJC_CLASS_$_ 未定义符号（全部走 NSClassFromString），
# 所以即使注入顺序是"我们比 Cam 先加载"，也不会出现 dyld: Symbol not found 的启动崩溃。
VCamLAN_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/library.mk

# 把产物复制到工程根目录，方便直接拖进 TrollFools
after-all::
	@if [ -f "$(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib" ]; then \
	    cp -f "$(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib" "$(THEOS_PROJECT_DIR)/$(LIBRARY_NAME).dylib"; \
	    echo "== 产物: $(THEOS_PROJECT_DIR)/$(LIBRARY_NAME).dylib =="; \
	fi

# 产物自检：确认没有 substrate 依赖，且确实有 6 个 swizzle 相关符号
after-all::
	@if [ -f "$(THEOS_PROJECT_DIR)/$(LIBRARY_NAME).dylib" ] && command -v otool >/dev/null 2>&1; then \
	    echo "== LC_LOAD_DYLIB =="; otool -L "$(THEOS_PROJECT_DIR)/$(LIBRARY_NAME).dylib"; \
	    if otool -L "$(THEOS_PROJECT_DIR)/$(LIBRARY_NAME).dylib" | grep -qi substrate; then \
	        echo "!! 发现 substrate 依赖，构建有问题"; exit 1; else echo "== OK: 无 substrate 依赖 =="; fi; \
	fi
