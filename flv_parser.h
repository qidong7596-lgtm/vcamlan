//
//  flv_parser.h —— 可移植 FLV 增量解析器（纯 C99，不依赖 ObjC / Foundation）
//
//  设计目标：
//    1. HTTP 分片边界会从任意位置切开一个 tag，所以解析器必须是"累积 + 够一个完整 tag 才回调"
//       的增量状态机，喂多少次、每次多长都无所谓。
//    2. 全部函数 `static`，头文件自包含 —— 单翻译单元包含即可，不产生重复符号，
//       也不需要单独 .c 文件（Theos 只编译 Tweak.xm / *.m，不额外挂 .c）。
//    3. 与 verify_offline.py 里的 Python 版 `FlvParser` 逐行对应，离线就能验证解析行为。
//
//  时间戳：FLV tag header 里 timestamp 是 24 位 + 1 字节扩展 = 实际 32 位，单位毫秒。
//          很多推流端只用到 24 位并会回绕（0xFFFFFF → 0x000000），
//          这里按 FFmpeg 的做法处理：raw 值比上次小且差值 > 0x800000 时认为发生了 24 位溢出，
//          累加 0x1000000 到 ts_offset，输出 64 位单调时间戳。
//
#ifndef VCAM_FLV_PARSER_H
#define VCAM_FLV_PARSER_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------- 常量
#define FLV_TAG_AUDIO        8
#define FLV_TAG_VIDEO        9
#define FLV_TAG_SCRIPT       18

#define FLV_INIT_CAP         (64u * 1024u)          // 初始累积缓冲
#define FLV_SHRINK_CAP       (64u * 1024u)          // 空闲时收缩回这个大小
#define FLV_SHRINK_THRESHOLD (1u * 1024u * 1024u)   // 超过 1MB 且缓冲空才收缩
#define FLV_MAX_TAG_BYTES    (16u * 1024u * 1024u)  // 单 tag 上限，防畸形流把内存撑爆
#define FLV_ERR_MAX          192

#define FLV_NAL_TYPE_NON_IDR 1
#define FLV_NAL_TYPE_IDR     5
#define FLV_NAL_TYPE_SEI     6
#define FLV_NAL_TYPE_SPS     7
#define FLV_NAL_TYPE_PPS     8
#define FLV_NAL_TYPE_AUD     9

// ---------------------------------------------------------------- 数据结构
typedef struct {
    uint8_t        type;        // 8 音频 / 9 视频 / 18 script data
    uint32_t       data_size;   // tag body 长度
    int64_t        timestamp;   // 已做 24 位回绕扩展，单位 ms
    uint32_t       stream_id;   // 恒为 0
    const uint8_t *data;        // 指向解析器内部缓冲，仅在回调期间有效
    uint32_t       data_len;
} flv_tag_t;

typedef void (*flv_tag_fn)(void *user, const flv_tag_t *tag);

typedef struct {
    uint8_t  *buf;              // 累积缓冲
    size_t    cap;
    size_t    len;              // 缓冲内有效字节
    int       header_done;      // 0 = 还没吃到完整 FLV header
    int       need_prev0;       // 1 = 还差 "PreviousTagSize0" 这 4 个字节没跳过
    int       failed;           // 1 = 致命错误，后续 feed 直接返回 -1
    int       have_last_raw;    // 是否已有上一 tag 的 raw 时间戳
    uint32_t  last_raw;         // 上一 tag 的 32 位原始时间戳
    int64_t   ts_offset;        // 回绕累加量（0x1000000 的整数倍）
    uint8_t   flv_version;
    uint8_t   flv_flags;
    uint32_t  header_size;
    uint64_t  bytes_in;         // 累计喂入字节
    uint64_t  tags;             // 累计完整 tag 数
    uint64_t  audio_tags;
    uint64_t  video_tags;
    uint64_t  script_tags;
    uint64_t  unknown_tags;
    uint64_t  bad_prev_tag_size; // PreviousTagSize 与实际不符的次数（容错，不失败）
    int64_t   last_timestamp;    // 最近一个 tag 的时间戳
    char      err[FLV_ERR_MAX];
} flv_parser_t;

// NAL 扫描统计（AVCC 长度前缀样本 → 各类型 NAL 计数）
typedef struct {
    int length_size;   // 1..4，来自 AVCDecoderConfigurationRecord 的 lengthSizeMinusOne+1
    int count;         // 成功的 NAL 个数
    int idr;
    int sps;
    int pps;
    int sei;
    int aud;
    int non_idr;
    int other;
    int broken;        // 长度字段越界/为 0 的次数
} flv_nalu_stat_t;

// ---------------------------------------------------------------- 字节序辅助
static inline uint32_t flv_be24(const uint8_t *b)
{
    return ((uint32_t)b[0] << 16) | ((uint32_t)b[1] << 8) | (uint32_t)b[2];
}

static inline uint32_t flv_be32(const uint8_t *b)
{
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
           ((uint32_t)b[2] << 8)  | (uint32_t)b[3];
}

// FLV video tag 的 CompositionTime 是 24 位有符号
static inline int32_t flv_si24(const uint8_t *b)
{
    int32_t v = (int32_t)flv_be24(b);
    if (v & 0x800000) v -= 0x1000000;
    return v;
}

// ---------------------------------------------------------------- 生命周期
static inline int flv_parser_init(flv_parser_t *p)
{
    if (!p) return -1;
    memset(p, 0, sizeof(*p));
    p->cap = FLV_INIT_CAP;
    p->buf = (uint8_t *)malloc(p->cap);
    if (!p->buf) {
        p->cap = 0;
        snprintf(p->err, FLV_ERR_MAX, "%s", "内存不足：FLV 缓冲分配失败");
        p->failed = 1;
        return -1;
    }
    return 0;
}

static inline void flv_parser_free(flv_parser_t *p)
{
    if (!p) return;
    free(p->buf);
    p->buf = NULL;
    p->cap = p->len = 0;
}

// 保留缓冲，只重置解析状态（重连时用，避免反复 malloc）
static inline void flv_parser_reset(flv_parser_t *p)
{
    if (!p) return;
    p->len = 0;
    p->header_done = 0;
    p->need_prev0 = 0;
    p->failed = 0;
    p->have_last_raw = 0;
    p->last_raw = 0;
    p->ts_offset = 0;
    p->flv_version = 0;
    p->flv_flags = 0;
    p->header_size = 0;
    p->bytes_in = 0;
    p->tags = 0;
    p->audio_tags = 0;
    p->video_tags = 0;
    p->script_tags = 0;
    p->unknown_tags = 0;
    p->bad_prev_tag_size = 0;
    p->last_timestamp = 0;
    p->err[0] = '\0';
}

static inline void flv_parser_fail(flv_parser_t *p, const char *msg)
{
    p->failed = 1;
    if (msg) {
        snprintf(p->err, FLV_ERR_MAX, "%s", msg);
    } else {
        p->err[0] = '\0';
    }
}

static inline const char *flv_parser_error(const flv_parser_t *p)
{
    if (!p || !p->err[0]) return "";
    return p->err;
}

static inline int flv_parser_ensure(flv_parser_t *p, size_t need)
{
    if (need <= p->cap) return 1;
    size_t ncap = p->cap ? p->cap : FLV_INIT_CAP;
    while (ncap < need) {
        size_t next = ncap * 2;
        if (next < ncap) return 0;      // 溢出
        ncap = next;
    }
    uint8_t *nb = (uint8_t *)realloc(p->buf, ncap);
    if (!nb) return 0;
    p->buf = nb;
    p->cap = ncap;
    return 1;
}

// ---------------------------------------------------------------- 核心：增量喂数据
// 返回 0 = 正常（可能还没凑够一个完整 tag），-1 = 致命错误（看 flv_parser_error）
static inline int flv_parser_feed(flv_parser_t *p,
                                  const void *bytes,
                                  size_t n,
                                  flv_tag_fn cb,
                                  void *user)
{
    if (!p) return -1;
    if (p->failed) return -1;

    if (n > 0) {
        if (!flv_parser_ensure(p, p->len + n)) {
            flv_parser_fail(p, "内存不足：FLV 缓冲扩容失败");
            return -1;
        }
        memcpy(p->buf + p->len, bytes, n);
        p->len += n;
        p->bytes_in += (uint64_t)n;
    }

    size_t off = 0;
    for (;;) {
        size_t avail = p->len - off;

        // ---- header 之后必须先吃掉 PreviousTagSize0（4 字节，值恒为 0）----
        // 单独用一个标志位，否则分片正好切在 header 与这 4 字节之间时，
        // 这 4 个字节会被当成下一个 tag header 的开头。
        if (p->need_prev0) {
            if (avail < 4) break;
            off += 4;
            p->need_prev0 = 0;
            continue;
        }

        // ---- FLV header：9 字节 'FLV' ver flags dataOffset(SI32) ----
        if (!p->header_done) {
            if (avail < 9) break;
            const uint8_t *h = p->buf + off;
            if (h[0] != 'F' || h[1] != 'L' || h[2] != 'V') {
                char msg[FLV_ERR_MAX];
                snprintf(msg, sizeof(msg),
                         "不是 FLV 流：首字节 %02X %02X %02X %02X（期望 46 4C 56 01；"
                         "HTTP-FLV 响应头需 Content-Type: video/x-flv）",
                         h[0], h[1], h[2], h[3]);
                flv_parser_fail(p, msg);
                return -1;
            }
            uint32_t data_offset = flv_be32(h + 5);
            if (data_offset < 9 || data_offset > 4096) {
                char msg[FLV_ERR_MAX];
                snprintf(msg, sizeof(msg), "FLV 头非法：dataOffset=%u（应在 9..4096）", data_offset);
                flv_parser_fail(p, msg);
                return -1;
            }
            p->flv_version = h[3];
            p->flv_flags = h[4];
            p->header_size = data_offset;
            p->header_done = 1;
            p->need_prev0 = 1;
            off += data_offset;
            continue;
        }

        // ---- Tag header：11 字节 ----
        if (avail < 11) break;
        const uint8_t *t = p->buf + off;
        uint8_t  type       = t[0];
        uint32_t data_size  = flv_be24(t + 1);
        uint32_t ts24       = flv_be24(t + 4);
        uint8_t  ts_ext     = t[7];
        uint32_t stream_id  = flv_be24(t + 8);

        if (data_size > FLV_MAX_TAG_BYTES) {
            char msg[FLV_ERR_MAX];
            snprintf(msg, sizeof(msg),
                     "tag 长度异常：%u 字节（上限 16MB），流已损坏或不是 FLV", data_size);
            flv_parser_fail(p, msg);
            return -1;
        }

        size_t total = 11u + (size_t)data_size + 4u;   // header + body + PreviousTagSize
        if (avail < total) break;                      // 跨包截断：等下一片

        // ---- body 之后的 PreviousTagSize（容错，不匹配只计数）----
        uint32_t prev_size = flv_be32(t + 11 + data_size);
        if (prev_size != (uint32_t)(11u + data_size)) {
            p->bad_prev_tag_size++;
        }

        // ---- 时间戳：32 位 = ts_ext(高 8) | ts24(低 24)，处理 24 位回绕 ----
        uint32_t raw = ts24 | ((uint32_t)ts_ext << 24);
        if (p->have_last_raw && raw < p->last_raw &&
            (p->last_raw - raw) > 0x800000u) {
            p->ts_offset += 0x1000000LL;
        }
        p->last_raw = raw;
        p->have_last_raw = 1;
        int64_t ts = (int64_t)raw + p->ts_offset;

        p->tags++;
        p->last_timestamp = ts;
        switch (type) {
            case FLV_TAG_AUDIO:  p->audio_tags++;  break;
            case FLV_TAG_VIDEO:  p->video_tags++;  break;
            case FLV_TAG_SCRIPT: p->script_tags++; break;
            default:             p->unknown_tags++; break;
        }

        if (cb) {
            flv_tag_t tag;
            tag.type       = type;
            tag.data_size  = data_size;
            tag.timestamp  = ts;
            tag.stream_id  = stream_id;
            tag.data       = t + 11;
            tag.data_len   = data_size;
            cb(user, &tag);
            // 回调里不允许改缓冲，也不允许重入 feed
        }

        off += total;
    }

    // ---- 紧凑化：把未消费的尾巴挪到缓冲头部 ----
    if (off > 0) {
        size_t remain = p->len - off;
        if (remain > 0) memmove(p->buf, p->buf + off, remain);
        p->len = remain;
        if (remain == 0 && p->cap > FLV_SHRINK_THRESHOLD) {
            uint8_t *nb = (uint8_t *)realloc(p->buf, FLV_SHRINK_CAP);
            if (nb) {
                p->buf = nb;
                p->cap = FLV_SHRINK_CAP;
            }
        }
    }
    return 0;
}

// 当前缓冲里未消费的字节数（诊断用）
static inline size_t flv_parser_pending(const flv_parser_t *p)
{
    return p ? p->len : 0;
}

// ---------------------------------------------------------------- AVCC 长度前缀 NAL 扫描
// 输入是 FLV video tag body 去掉前 5 字节之后的部分（即 AVCC 样本），
// 格式：[len(1..4 字节，大端)][NALU][len][NALU]...
// 返回 1 = 至少完整扫到一个 NAL，0 = 空样本，-1 = 长度字段越界（样本被截断）
static inline int flv_scan_avcc_nalus(const uint8_t *d,
                                      uint32_t n,
                                      int length_size,
                                      flv_nalu_stat_t *out)
{
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    out->length_size = (length_size >= 1 && length_size <= 4) ? length_size : 4;
    if (!d || n == 0) return 0;

    uint32_t off = 0;
    int ok = 0;
    while (off + (uint32_t)out->length_size <= n) {
        uint32_t len = 0;
        int i;
        for (i = 0; i < out->length_size; i++) {
            len = (len << 8) | d[off + (uint32_t)i];
        }
        off += (uint32_t)out->length_size;
        if (len == 0) {                       // 0 长度：结束符，忽略
            out->broken++;
            break;
        }
        if (len > n - off) {                  // 越界：样本被截断
            out->broken++;
            break;
        }
        uint8_t nal_type = (uint8_t)(d[off] & 0x1F);
        out->count++;
        ok = 1;
        switch (nal_type) {
            case FLV_NAL_TYPE_IDR:     out->idr++;     break;
            case FLV_NAL_TYPE_SPS:     out->sps++;     break;
            case FLV_NAL_TYPE_PPS:     out->pps++;     break;
            case FLV_NAL_TYPE_SEI:     out->sei++;     break;
            case FLV_NAL_TYPE_AUD:     out->aud++;     break;
            case FLV_NAL_TYPE_NON_IDR: out->non_idr++; break;
            default:                   out->other++;   break;
        }
        off += len;
    }
    return ok ? 1 : (out->broken ? -1 : 0);
}

// 从 AVCDecoderConfigurationRecord 里取 NAL 长度字段字节数
// record: [0]=version [1]=profile [2]=compat [3]=level [4]=0xFC|lengthSizeMinusOne [5]=0xE0|numSPS ...
static inline int flv_avcc_length_size(const uint8_t *rec, uint32_t n)
{
    if (!rec || n < 5) return 4;
    int ls = (rec[4] & 0x03) + 1;
    if (ls < 1 || ls > 4) return 4;
    return ls;
}

#ifdef __cplusplus
}
#endif

#endif // VCAM_FLV_PARSER_H
