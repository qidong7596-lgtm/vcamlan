#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lint_lan.py —— VCamLAN 工程静态自检（不依赖 clang / Theos，Windows 上也能跑）

跑法：
    python lint_lan.py            # 在 work/VCamLAN 目录里跑
    python lint_lan.py --dir .    # 指定目录

检查项（任一条 FAIL 都是真的会出问题，不是风格问题）：
  1  括号配平                 （大括号 / 小括号 / 方括号）
  2  @interface <-> @end 计数   （少一个就是"类没结束"，编译必炸）
  3  不许出现 substrate.h
  4  不许出现 %hook / %orig / %ctor / %init（Logos 宏，TrollStore 下无运行时）
  5  不许对 Cam 的类名做类消息（[VCamStreamConfig sharedStore] 这种会生成 _OBJC_CLASS_$_ 符号）
  6  #import "xxx.h" 必须能解析到本目录文件
  7  6 个 swizzle 点的 types 必须与 objc_full.json 一致
  8  source 键只允许写 "rtmp"
  9  mediaTransport 键只允许写 "wifi"
 10  必须发 com.douyin.stream.reload 重载通知
 11  文件行数下限：VCamLANMain.m ≥ 700，VCamLANPrefs.m ≥ 200
"""

import argparse
import json
import os
import re
import sys

# Windows 控制台默认是 GBK，中文 + 特殊符号会直接抛 UnicodeEncodeError。
# 统一把 stdout 切成 UTF-8，编码不了就替换成 '?'，不让输出本身把检查打断。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:      # noqa: BLE001
    pass

# ---------------------------------------------------------------- 期望签名
# 来源：work/objc_full.json（Cam.dylib class_ro_t 快照）
EXPECT_TYPES = {
    ("VCamStreamPipeline", "rtspPuller"): "@16@0:8",
    ("VCamStreamPipeline", "reloadConfig"): "v16@0:8",
    ("VCamStreamPipeline", "applyRuntimeFlags"): "v16@0:8",
    ("VCamStreamConfig", "sourceTitle"): "@16@0:8",
    ("VCamStreamConfig", "pullURL"): "@16@0:8",
    ("VCamFloatingPanel", "refreshStatus"): "v16@0:8",
}

CAM_CLASSES = [
    "VCamStreamConfig", "VCamStreamPipeline", "VCamFrameStore", "VCamAudioStore",
    "VCamVTDecoder", "VCamAACDecoder", "VCamFloatingPanel", "VCamRTSPPuller",
    "VCamUSBPuller", "VCamLocalPlayer",
]

SOURCE_EXT = (".m", ".h", ".mm")

results = []


def record(ok, name, detail=""):
    results.append((ok, name, detail))
    print(("PASS  " if ok else "FAIL  ") + name + (("  —— " + detail) if detail else ""))


def _drop_pragma_lines(text):
    """`#pragma mark - xxx` 不是注释，但整行都是给人看的说明文字。
    里面出现 substrate.h / %ctor 这类字样时不该算命中，先整行删掉。"""
    return re.sub(r"(?m)^[ \t]*#[ \t]*pragma[^\n]*$", "", text)


def strip_comments(text):
    """只抹注释，保留字符串内容（检查 7 需要读 "v16@0:8" 这类字面量）。"""
    text = _drop_pragma_lines(text)
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
        elif c == "/" and nxt == "*":
            i += 2
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                if text[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def strip_comments_and_strings(text):
    """把注释和字符串内容抹成空格，避免注释里的字样 / 字符串里的 ')' 影响检查。"""
    text = _drop_pragma_lines(text)
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
        elif c == "/" and nxt == "*":
            i += 2
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                if text[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        elif c == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                i += 1
            i += 1
            out.append(" ")
        elif c == "'":
            i += 1
            while i < n and text[i] != "'":
                if text[i] == "\\":
                    i += 1
                i += 1
            i += 1
            out.append(" ")
        else:
            out.append(c)
            i += 1
    return "".join(out)


def check_braces(path, text):
    clean = strip_comments_and_strings(text)
    pairs = [("{", "}"), ("(", ")"), ("[", "]")]
    problems = []
    for open_ch, close_ch in pairs:
        depth = 0
        line = 1
        worst = 0
        for ch in clean:
            if ch == "\n":
                line += 1
            elif ch == open_ch:
                depth += 1
            elif ch == close_ch:
                depth -= 1
                if depth < 0:
                    worst = line
                    depth = 0
        if depth != 0 or worst:
            problems.append("%s%s 差 %d 且在行 %s 处出现多余的 %s"
                            % (open_ch, close_ch, depth, worst or "-", close_ch))
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=".")
    ap.add_argument("--objc-json", default=None,
                    help="objc_full.json 路径（默认依次找 ./objc_full.json、../objc_full.json）")
    args = ap.parse_args()

    root = os.path.abspath(args.dir)
    if not os.path.isdir(root):
        print("目录不存在: " + root)
        return 2

    files = sorted(f for f in os.listdir(root) if f.endswith(SOURCE_EXT))
    if not files:
        print("目录里没有 .m/.h 源文件: " + root)
        return 2

    texts = {}
    for f in files:
        with open(os.path.join(root, f), "r", encoding="utf-8", errors="replace") as fh:
            texts[f] = fh.read()

    print("=" * 78)
    print("检查目录: " + root)
    print("源文件: " + ", ".join(files))
    print("=" * 78)

    # ---- 1 括号配平 ----
    all_problems = []
    for f in files:
        probs = check_braces(f, texts[f])
        all_problems.extend("%s: %s" % (f, p) for p in probs)
    record(not all_problems, "[1] 括号配平", "; ".join(all_problems[:6]))

    # ---- 2 @interface / @end ----
    # 每个 .h 里 @interface 数量必须等于 @end；.m 里 @interface + @implementation 数量等于 @end。
    # 统计前先抹掉注释 —— 注释里写一句 "@interface 少一个就炸" 不该被当成真的声明。
    bad = []
    for f in files:
        clean = strip_comments_and_strings(texts[f])
        n_if = len(re.findall(r"@interface\b", clean))
        n_end = len(re.findall(r"@end\b", clean))
        n_impl = len(re.findall(r"@implementation\b", clean))
        if n_if + n_impl != n_end:
            bad.append("%s: @interface=%d @implementation=%d @end=%d"
                       % (f, n_if, n_impl, n_end))
    record(not bad, "[2] @interface<->@end 配对", "; ".join(bad))

    # ---- 3 无 substrate ----
    bad = []
    for f in files:
        clean = strip_comments_and_strings(texts[f])
        if re.search(r"substrate", clean, re.I):
            bad.append(f)
    record(not bad, "[3] 无 substrate.h", ", ".join(bad))

    # ---- 4 无 Logos 宏 ----
    logos_re = re.compile(r"(%hook\b|%orig\b|%ctor\b|%init\b|%new\b)")
    bad = []
    for f in files:
        clean = strip_comments_and_strings(texts[f])
        for m in logos_re.finditer(clean):
            bad.append("%s: %s" % (f, m.group(1)))
    record(not bad, "[4] 无 %hook/%orig/%ctor/%init", ", ".join(bad[:8]))

    # ---- 5 不对 Cam 的类做类消息 ----
    # 允许：[(VCamStreamConfig *)cfg xxx]（类型转换）、NSClassFromString(@"VCamStreamConfig")
    # 禁止：[VCamStreamConfig sharedStore] —— 会生成 _OBJC_CLASS_$_VCamStreamConfig 未定义符号
    cls_alt = "|".join(CAM_CLASSES)
    bad = []
    for f in files:
        clean = strip_comments_and_strings(texts[f])
        for m in re.finditer(r"\[\s*(?:" + cls_alt + r")\s+[A-Za-z_]\w*\s*\]", clean):
            bad.append("%s: %s" % (f, m.group(0).strip()))
    record(not bad, "[5] 无 Cam 类名字面量消息", ", ".join(bad[:8]))

    # ---- 6 #import "" 可解析 ----
    bad = []
    for f in files:
        for m in re.finditer(r'#\s*(?:import|include)\s+"([^"]+)"', texts[f]):
            inc = m.group(1)
            if not os.path.exists(os.path.join(root, inc)):
                bad.append("%s → %s" % (f, inc))
    record(not bad, "[6] #import \"\" 可解析", ", ".join(bad))

    # ---- 7 6 个 swizzle 点 types ----
    # 在源码里找 vcaml_swizzle_checked(<clsVar>, @selector(<sel>), ..., "<types>")
    main_file = None
    for f in files:
        if "vcaml_swizzle_checked" in texts[f]:
            main_file = f
            break
    if main_file is None:
        record(False, "[7] 6 个 swizzle 点 types", "找不到任何 vcaml_swizzle_checked 调用")
    else:
        src = strip_comments(texts[main_file])   # 保留字符串：types 字面量就在字符串里
        # 先抓 "Class xxxCls = VCamLANDynClass(@\"VCamXXX\");" 这种变量别名
        alias = {}
        for m in re.finditer(r'Class\s+(\w+)\s*=\s*VCamLANDynClass\(@"(\w+)"\)', src):
            alias[m.group(1)] = m.group(2)
        got = {}
        pat = re.compile(
            r'vcaml_swizzle_checked\(\s*(\w+)\s*,\s*@selector\(\s*(\w+)\s*\)'
            r'[\s\S]{0,400}?"([^"]*)"\s*\)', re.S)
        for m in pat.finditer(src):
            cls = alias.get(m.group(1), m.group(1))
            got[(cls, m.group(2))] = m.group(3)

        missing, wrong = [], []
        for key, want in EXPECT_TYPES.items():
            have = got.get(key)
            if have is None:
                missing.append("%s -%s" % key)
            elif have != want:
                wrong.append("%s -%s: 读到 %s 期望 %s" % (key[0], key[1], have, want))
        detail = "; ".join(missing + wrong)
        record(not missing and not wrong,
               "[7] 6 个 swizzle 点 types 与 objc_full.json 一致",
               detail if detail else "6/6 匹配")

        # 额外：和磁盘上的 objc_full.json 交叉核对（如果给得到）
        cand = [args.objc_json] if args.objc_json else []
        cand += [os.path.join(root, "objc_full.json"), os.path.join(root, "..", "objc_full.json")]
        for c in cand:
            if c and os.path.isfile(c):
                try:
                    with open(c, "r", encoding="utf-8") as fh:
                        data = json.load(fh)
                    truth = {}
                    for cdef in data.get("classes", []):
                        for meth in cdef.get("methods", []):
                            truth[(cdef["name"], meth["name"])] = meth["types"]
                    mism = []
                    for key, want in EXPECT_TYPES.items():
                        real = truth.get(key)
                        if real is not None and real != want:
                            mism.append("%s -%s: 表里写 %s，元数据是 %s"
                                        % (key[0], key[1], want, real))
                    record(not mism, "[7b] EXPECT_TYPES 与 objc_full.json 交叉核对",
                           "; ".join(mism) if mism else os.path.basename(c))
                except Exception as exc:      # noqa: BLE001
                    record(False, "[7b] 读 objc_full.json", str(exc))
                break

    # ---- 8 source 只写 rtmp ----
    # 只看"赋值行"（含 forKeyedSubscript: / forKey:），不含日志行 —— 日志里当然会打印这个键名。
    bad = []
    for f in files:
        for lineno, line in enumerate(texts[f].splitlines(), 1):
            code = line.split("//")[0]
            if not re.search(r'(forKeyedSubscript:@?"source"|forKey:@?"source")', code):
                continue
            if '@"rtmp"' not in code:
                bad.append("%s:%d %s" % (f, lineno, code.strip()[:90]))
    record(not bad, "[8] source 键只写 \"rtmp\"", "; ".join(bad))

    # ---- 9 mediaTransport 只写 wifi ----
    bad = []
    for f in files:
        for lineno, line in enumerate(texts[f].splitlines(), 1):
            code = line.split("//")[0]
            if not re.search(r'(forKeyedSubscript:@?"mediaTransport"|forKey:@?"mediaTransport")', code):
                continue
            if '@"wifi"' not in code:
                bad.append("%s:%d %s" % (f, lineno, code.strip()[:90]))
    record(not bad, "[9] mediaTransport 键只写 \"wifi\"", "; ".join(bad))

    # ---- 10 必发重载通知 ----
    has_name = any("com.douyin.stream.reload" in t for t in texts.values())
    has_post = any(("notify_post" in t) or ("CFNotificationCenterPostNotification" in t)
                   for t in texts.values())
    record(has_name and has_post, "[10] 发 com.douyin.stream.reload 重载通知",
           "通知名=%s 发送调用=%s" % (has_name, has_post))

    # ---- 11 行数下限 ----
    limits = {"VCamLANMain.m": 700, "VCamLANPrefs.m": 200}
    bad = []
    stats = []
    for f, low in limits.items():
        if f not in texts:
            bad.append("%s 不存在（要求 ≥ %d 行）" % (f, low))
            continue
        n = len(texts[f].splitlines())
        stats.append("%s=%d" % (f, n))
        if n < low:
            bad.append("%s 只有 %d 行（要求 ≥ %d）" % (f, n, low))
    record(not bad, "[11] 文件行数下限", "; ".join(bad) if bad else ", ".join(stats))

    # ---- 汇总 ----
    fails = [r for r in results if not r[0]]
    print("=" * 78)
    print("共 %d 项：PASS %d / FAIL %d" % (len(results), len(results) - len(fails), len(fails)))
    if fails:
        print("失败项：")
        for _, name, detail in fails:
            print("  - " + name + (("  " + detail) if detail else ""))
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
