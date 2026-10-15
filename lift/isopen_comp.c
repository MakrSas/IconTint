// Открытый движок: разделение иконки на знак и фон (Dark-изображение и маска Tinted).
// Работает по маске знака (isopen_seg.c): размечает пиксели, оценивает цвета знака и фона и по их виду выбирает способ вырезания.
#include "isopen_math.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <float.h>
#include <limits.h>
#include <arm_neon.h>

static inline float4 rgb_at(const uint8_t *px, size_t i) {
    return (float4){(float)px[i * 4], (float)px[i * 4 + 1], (float)px[i * 4 + 2], 0} / (float4)255.0f;
}
static inline float norm3c(float4 v) { float4 q = v * v; return sqrtf(q[2] + (q[0] + q[1])); }
static inline int imin(int a, int b) { return a < b ? a : b; }
static inline int imax(int a, int b) { return a > b ? a : b; }

void iso_stage_flags(int strict, int w, int h, const uint8_t *px, uint8_t *F) {
    const int thr = strict ? 2 : 150;
    // 1. знак: сама альфа выше порога, либо почти все соседи (кроме одного) — знак (заделывает дырки в 1 пиксель)
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            int a = px[((size_t)y * w + x) * 4 + 3];
            if (a > thr) { F[(size_t)y * w + x] = 1; continue; }
            int total = 0, fg = 0;
            for (int xx = imax(x - 1, 0); xx <= imin(x + 1, w - 1); xx++)
                for (int yy = imax(y - 1, 0); yy <= imin(y + 1, h - 1); yy++) {
                    total++;
                    if (thr < px[((size_t)yy * w + xx) * 4 + 3]) fg++;
                }
            F[(size_t)y * w + x] = fg >= total - 1;
        }
    // 2. внутренние пиксели: все соседи 3×3 того же класса
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            uint8_t v = F[(size_t)y * w + x];
            int total = 0, same = 0;
            for (int xx = imax(x - 1, 0); xx <= imin(x + 1, w - 1); xx++)
                for (int yy = imax(y - 1, 0); yy <= imin(y + 1, h - 1); yy++) {
                    total++;
                    if ((F[(size_t)yy * w + xx] & 1) == (v & 1)) same++;
                }
            if (same == total) F[(size_t)y * w + x] = v | ISO_INTERIOR;
        }
    // 3. пригодные для выборки: любой пиксель фона и пиксели знака с ≥6 похожими соседями
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            uint8_t v = F[(size_t)y * w + x];
            if (!(v & 1)) { F[(size_t)y * w + x] = v | ISO_USABLE; continue; }
            float4 c = rgb_at(px, (size_t)y * w + x);
            int similar = 0;
            for (int xx = imax(x - 1, 0); xx <= imin(x + 1, w - 1); xx++)
                for (int yy = imax(y - 1, 0); yy <= imin(y + 1, h - 1); yy++) {
                    float4 d = c + (float4){-rgb_at(px, (size_t)yy * w + xx)[0], -rgb_at(px, (size_t)yy * w + xx)[1], -rgb_at(px, (size_t)yy * w + xx)[2], 0};
                    if ((double)norm3c(d) <= 0.0392156862745098) similar++;
                }
            if (similar > 5) F[(size_t)y * w + x] = v | ISO_USABLE;
        }
}

int iso_stripe_check(int w, int h, const uint8_t *F) {
    (void)h;
    const double W = (double)w;
    for (int g = 11; g < 18; g++) {
        int total = 0, rowsFg = 0, mixedRows = 0;       // по строкам
        int total2 = 0, colsFg = 0, mixedCols = 0;      // по столбцам
        for (int r = 0; r < g; r++) {
            int y = (int)((((double)(float)r + 0.5) * W) / (double)g);
            int sgn = (r & 1) ? 1 : -1, sum = 0;
            for (int c = 0; c < g; c++) {
                int x = (int)((((double)(float)c + 0.5) * W) / (double)g);
                sum += (F[(size_t)y * w + x] & 1) ? sgn : -sgn;
            }
            total += sum;
            if (sum == g) rowsFg++;
            mixedRows += (sum == -g) ? 0 : (sum != g);
        }
        for (int c = 0; c < g; c++) {
            int x = (int)((((double)(float)c + 0.5) * W) / (double)g);
            int sgn = (c & 1) ? 1 : -1, sum = 0;
            for (int r = 0; r < g; r++) {
                int y = (int)((((double)(float)r + 0.5) * W) / (double)g);
                sum += (F[(size_t)y * w + x] & 1) ? sgn : -sgn;
            }
            total2 += sum;
            if (sum == g) colsFg++;
            mixedCols += (sum == -g) ? 0 : (sum != g);
        }
        int half = (g * g) >> 1;
        if (total >= half && (unsigned)rowsFg >= (unsigned)(g >> 1) && mixedRows == 0) return 0;
        if (total + half <= 0 && (unsigned)mixedRows >= (unsigned)(g >> 1) && rowsFg == 0) return 0;
        if (total2 >= half && (unsigned)colsFg >= (unsigned)(g >> 1) && mixedCols == 0) return 0;
        if (total2 <= -half && (unsigned)mixedRows >= (unsigned)(g >> 1) && colsFg == 0) return 0;
    }
    return 1;
}

int iso_stage_samples(int w, int h, const uint8_t *px, const uint8_t *F, int N, float4 *samples, int *nfg, int *nbg) {
    unsigned seed = 10;
    int fg = 0, bg = 0;
    const float fw = (float)w, fh = (float)h, inv31 = 4.656612873077393e-10f;
    for (int i = 0; i < N; i++) {
        int x = (int)(((fw * (float)rand_r(&seed)) * inv31));
        int y = (int)(((fh * (float)rand_r(&seed)) * inv31));
        size_t idx = (size_t)y * w + x;
        uint8_t fl = F[idx];
        if ((fl & 0x12) == 0x12) {
            float4 c = rgb_at(px, idx);
            if (fl & 1) samples[fg++] = c; else { bg++; samples[N - bg] = c; }
        }
        if (!(fg < 1100 || bg < 1100)) break;
    }
    *nfg = fg; *nbg = bg;
    return fg >= 10 && bg >= 10;
}

void iso_mask_single_on_gradient(int w, int h, const uint8_t *px, uint8_t *tint, uint8_t *dark, float4 fg, float scale) {
    float4 tl = rgb_at(px, 0), tr = rgb_at(px, (size_t)w - 1), bl = rgb_at(px, (size_t)(h - 1) * w), br = rgb_at(px, (size_t)h * w - 1);
    float4 dTop = tr - tl, dBottom = br - bl;
    float fw1 = (float)(w - 1), fh1 = (float)(h - 1);
    for (int y = 0; y < h; y++) {
        float sy = (float)y / fh1;
        for (int x = 0; x < w; x++) {
            size_t p = (size_t)y * w + x;
            float t = norm3c(rgb_at(px, p) - fg) / scale;
            t = fminf(fmaxf(t, 0.0f), 1.0f);
            float a = 1.0f - t;
            if (tint) tint[p] = (uint8_t)(int)(a * 255.0f);
            if (dark) {
                float sx = (float)x / fw1;
                float4 top, bottom, e;
                for (int i = 0; i < 4; i++) { top[i] = fmaf(dTop[i], sx, tl[i]); bottom[i] = fmaf(dBottom[i], sx, bl[i]); }
                float4 diff = bottom - top;
                for (int i = 0; i < 4; i++) e[i] = fmaf(diff[i], sy, top[i]);
                float4 v = {e[0] * 255.0f, e[1] * 255.0f, 255.0f * e[2], 255.0f};
                v = v * a;
                for (int i = 0; i < 4; i++) dark[p * 4 + i] = (uint8_t)(int)v[i];
            }
        }
    }
}

int iso_should_generate_dark(int enhance, float4 *out, float4 fg, float4 bg) {
    const double C = 0.23529411764705882;
    int fgExtreme = (double)norm3c(fg) <= C || (double)norm3c(fg + (float4)-1.0f) <= C;      // знак почти чёрный или почти белый
    int bgMid = (double)norm3c(bg) > C && (double)norm3c(bg + (float4)-1.0f) > C;              // фон ни чёрный, ни белый
    int fgLow = iso_contrast_ratio(fg, (float4)0.0784f) < 3.0f;
    int needFix = fgLow | bgMid;
    if (enhance) {
        if (!needFix) { iso_lighten(fg, out); return 1; }
        if (!fgExtreme) {
            int ok = iso_lighten(fg, out);
            return (bgMid | !ok) ? 0 : 1;
        }
        if (iso_contrast_ratio(bg, (float4)0.0784f) >= 3.0f) { iso_lighten(bg, out); return 1; }
        int ok = iso_lighten(fg, out);
        if (!(bgMid | !ok)) return 1;
        return iso_lighten(bg, out) ? 1 : 0;
    }
    if (!needFix) { if (out) *out = fg; return 1; }
    if (!fgExtreme) return 0;
    if (iso_contrast_ratio(bg, (float4)0.0784f) < 3.0f) return 0;
    if (out) *out = bg;
    return 1;
}

void iso_flag_more_confidence(int w, int h, uint8_t *F) {
    for (int x = 0; x < w; x++)
        for (int y = 0; y < h; y++) {
            uint8_t v = F[(size_t)y * w + x];
            if (!(v & 2)) continue;
            int total = 0, interior = 0;
            for (int xx = imax(x - 1, 0); xx <= imin(x + 1, w - 1); xx++)
                for (int yy = imax(y - 1, 0); yy <= imin(y + 1, h - 1); yy++) { total++; interior += (F[(size_t)yy * w + xx] >> 1) & 1; }
            if (interior == total) F[(size_t)y * w + x] = v | 4;
        }
}

void iso_flag_extra_confidence(int w, int h, uint8_t *F) {
    for (int x = 0; x < w; x++)
        for (int y = 0; y < h; y++) {
            uint8_t v = F[(size_t)y * w + x];
            if (!(v & 2)) continue;
            int total = 0, interior = 0;
            for (int xx = imax(x - 2, 0); xx <= imin(x + 2, w - 1); xx++)
                for (int yy = imax(y - 2, 0); yy <= imin(y + 2, h - 1); yy++)
                    if (abs(xx - x) + abs(yy - y) <= 2) { total++; interior += (F[(size_t)yy * w + xx] >> 1) & 1; }
            if (interior == total) F[(size_t)y * w + x] = v | 8;
        }
}

// Ветка «знак одного цвета, фон — градиент»
static int segment_bg_gradient(int w, int h, uint8_t *px, uint8_t *F, uint8_t *tint, uint8_t *dark, int recoloring,
                               float4 meanF, const float4 *bgSamples, int nbg, int texLimit) {
    const size_t n = (size_t)w * h;
    iso_flag_extra_confidence(w, h, F);
    if (dark) {
        if (!recoloring) return 0;
        if ((F[0] & 3) != 2 || (F[w - 1] & 3) != 2 || (F[(size_t)(h - 1) * w] & 3) != 2 || (F[n - 1] & 3) != 2) return 0;
        float4 tl = rgb_at(px, 0), tr = rgb_at(px, (size_t)w - 1), bl = rgb_at(px, (size_t)(h - 1) * w), br = rgb_at(px, n - 1);
        const float4 gray = (float4)0.0784f;
        if (iso_contrast_ratio(tl, gray) < 3.0f || iso_contrast_ratio(tr, gray) < 3.0f || iso_contrast_ratio(bl, gray) < 3.0f || iso_contrast_ratio(br, gray) < 3.0f) return 0;
        // фон должен быть похож на билинейный градиент между углами
        float4 dTop = tr - tl, dBottom = br - bl;
        float fw1 = (float)(w - 1), fh1 = (float)(h - 1);
        int off = 0;
        for (int y = 0; y < h && off <= 60; y++) {
            float sy = (float)y / fh1;
            for (int x = 0; x < w; x++) {
                if ((F[(size_t)y * w + x] & 9) != 8) continue;
                float sx = (float)x / fw1;
                float4 top, bottom, e;
                for (int i = 0; i < 4; i++) { top[i] = fmaf(dTop[i], sx, tl[i]); bottom[i] = fmaf(dBottom[i], sx, bl[i]); }
                float4 diff = bottom - top;
                for (int i = 0; i < 4; i++) e[i] = fmaf(diff[i], sy, top[i]);
                if (norm3c(rgb_at(px, (size_t)y * w + x) - e) > 0.20392157137393951f) off++;
            }
        }
        if (off > 60) return 0;
    }
    // цвет знака не должен быть одновременно насыщенным и светлым
    float4 hsv = iso_rgb2hsv(meanF);
    if (hsv[1] >= 0.5f && hsv[2] >= 0.5f) return 0;
    // и должен заметно отличаться от всех цветов фона
    float minDist = FLT_MAX;
    for (int i = 0; i < nbg; i++) { float d = norm3c(meanF - bgSamples[i]); if (d < minDist) minDist = d; }
    if (minDist < 0.14509804546833038f) return 0;
    // «текстура»: места, где фон не гладкий (вторая разность цвета выше порога)
    int rough = 0;
    if (w >= 5)
        for (int c = 2; c < w - 2; c++)
            for (int r = 2; r < h - 2; r++) {
                size_t q = (size_t)r * w + c;
                if ((F[q] & 9) != 8 || (F[q - 1] & 9) != 8 || (F[q + 1] & 9) != 8 || (F[q - w] & 9) != 8 || (F[q + w] & 9) != 8) continue;
                float4 ctr = rgb_at(px, q), l = rgb_at(px, q - 1), rr = rgb_at(px, q + 1), u = rgb_at(px, q - w), d = rgb_at(px, q + w);
                float4 k = (float4)-2.0f, a = l + rr, b = u + d;
                for (int i = 0; i < 4; i++) { a[i] = fmaf(k[i], ctr[i], a[i]); b[i] = fmaf(k[i], ctr[i], b[i]); }
                float e = (norm3c(a) * norm3c(a) + norm3c(b) * norm3c(b)) * 0.25f;
                (void)e;
                float4 a2 = a * a, b2 = b * b;
                float sa = a2[2] + (a2[0] + a2[1]), sb = b2[2] + (b2[0] + b2[1]);
                if ((sa + sb) * 0.25f > 0.0027450979687273502f) rough++;
            }
    if (rough > texLimit) return 0;
    iso_mask_single_on_gradient(w, h, px, tint, dark, meanF, minDist);
    return 1;
}

static inline float sumsq3(float4 v) { float4 q = v * v; return q[2] + (q[0] + q[1]); }
static inline float dot3(float4 a, float4 b) { float4 q = a * b; return q[2] + (q[0] + q[1]); }
static inline float clamp01(float v) { return fminf(fmaxf(v, 0.0f), 1.0f); }

// 1/sqrt(x) в два шага уточнения оценки (как делает векторное устройство)
static inline float rsqrt_refined(float x) {
    float32x2_t v = {x, 0.0f};
    float32x2_t e = vrsqrte_f32(v);
    e = vmul_f32(e, vrsqrts_f32(v, vmul_f32(e, e)));
    e = vmul_f32(e, vrsqrts_f32(v, vmul_f32(e, e)));
    return e[0];
}

void iso_ratio_alpha(float4 a, float4 b, float4 c, float *ratio, float *alpha) {
    const float na = sqrtf(sumsq3(a)), nb2 = sumsq3(b);
    const double dna = na;
    const double dnb = sqrtf(nb2);
    float nc2 = sumsq3(c);
    if (dnb * 1e-05 > dna && (double)sqrtf(nc2) * 1e-05 > dna) { *ratio = 0; *alpha = 0; return; }
    float4 cb = c - b;
    float4 ub = b * rsqrt_refined(nb2), uc = c * rsqrt_refined(nc2);
    if ((double)dot3(ub, uc) > 0.9992) {
        *ratio = dot3(a - b, cb) / sumsq3(cb);
        *alpha = 1.0f;
        return;
    }
    float bcb = dot3(b, cb), cc = sumsq3(cb);
    float det = fmaf(nb2, cc, -(bcb * bcb));
    if ((double)det < 1e-06) {
        *ratio = dot3(a - b, cb) / cc;
        *alpha = 1.0f;
        return;
    }
    float nbcb = -bcb;
    float ab = dot3(a, b), acb = dot3(a, cb);
    float al = fmaf(cc, ab, acb * nbcb) / det;
    float be = fmaf(nb2, acb, ab * nbcb) / det;
    *ratio = be / al;
    *alpha = al;
}

void iso_connected_background(int w, int h, uint8_t *F) {
    const size_t n = (size_t)w * h;
    for (size_t i = 0; i < n; i++) F[i] &= 0x7f;
    // отметить пиксель фона, если он на краю картинки или рядом с уже отмеченным
    #define MARK(px_, py_) do { int X_ = (px_), Y_ = (py_); size_t id_ = (size_t)Y_ * w + X_; int fl_; \
        if (X_ == 0 || X_ == w - 1 || Y_ == 0 || Y_ == h - 1) fl_ = 1; else { fl_ = 0; \
            for (int yy = Y_ - 1; yy <= Y_ + 1; yy++) for (int xx = X_ - 1; xx <= X_ + 1; xx++) fl_ |= (F[(size_t)yy * w + xx] >> 7); } \
        if (!(F[id_] & 1) && fl_) F[id_] |= 0x80; } while (0)
    int xmax = w - 1, ymax = h - 1;
    for (int d = 0; ymax >= 0 && xmax >= 0; ) {
        for (int x = 0; x < w; x++) { MARK(x, d); MARK(x, ymax); }
        for (int x = w - 1; x >= 0; x--) { MARK(x, d); MARK(x, ymax); }
        for (int y = 0; y < h; y++) { MARK(d, y); MARK(xmax, y); }
        for (int y = h - 1; y >= 0; y--) { MARK(d, y); MARK(xmax, y); }
        xmax--;
        if (d >= xmax) break;
        ymax--;
        int nd = d + 1;
        if (!(d < ymax)) break;
        d = nd;
    }
    #undef MARK
}

// Один проход «глаза» от пикселя p в сторону dir (+1/-1) на count пикселей: тёмная полоса, затем цветной пиксель. *run — длина тёмной части.
static int eye_scan(const uint8_t *px, size_t p, int dir, int count, int *run) {
    const float4 zero = {0, 0, 0, 0}, one = {1, 1, 1, 1};
    int state = 0, found = 0;
    for (int i = 0; i < count; i++, p += dir) {
        float4 c = rgb_at(px, p);
        int dark = norm3c(c) < 0.3529411852359772f;
        int greyish = norm3c(c - iso_clamped_project(c, zero, one)) < 0.19607843458652496f;
        if (state == 0) {
            if (dark) { state = 1; continue; }
            if (!greyish) break;
        } else {
            if (dark) { state++; continue; }
            if (norm3c(c - one) < 0.27450981736183167f) break;
            if (!greyish) { found = 1; break; }
        }
    }
    *run = state;
    return found;
}

int iso_test_eye(int w, int h, int x, int y, const uint8_t *px, const uint8_t *F) {
    const size_t n = (size_t)w * h;
    float4 c = rgb_at(px, (size_t)y * w + x);
    if (!(norm3c(c + (float4)-1.0f) < 0.27450981736183167f)) return 0;
    for (int yy = imax(y - 3, 0); yy <= imin(y + 3, h - 1); yy++)
        for (int xx = imax(x - 3, 0); xx <= imin(x + 3, w - 1); xx++)
            if (F[(size_t)yy * w + xx] & 0x80) return 0;
    int r = w / 20, lim = (int)(n / 100000);
    size_t p = (size_t)y * w + x;
    int lrun, rrun;
    int lf = eye_scan(px, p, -1, x - imax(x - r, 0) + 1, &lrun);
    int rf = eye_scan(px, p, +1, imin(x + r, w - 1) - x + 1, &rrun);
    if (rrun <= lim || lrun <= lim) return 0;
    return lf || rf;
}

// Цвета «в тон фону»: вторая и третья проходки по флагам перед выбором способа вырезания

// Допуск «текстуры» знака в запасном пути многоцветной ветки: 16 — наша настройка (фактурные иконки допускаются), 1 — строго как в iOS 18.
static int gTextureScale = 16;
void iso_set_texture_scale(int scale) { gTextureScale = scale < 1 ? 1 : scale; }

// Дополнительные флаги для знака-градиента. out: бит 0 — рядом есть заметный перепад цвета (окно 3x3);
// при grad: бит 1 — всё окно 3x3 — «чистый» знак, бит 2 — то же для соседей, бит 3 — то же в ромбе радиуса 2.
void iso_flag_additional_gradient(int w, int h, int grad, const uint8_t *px, const uint8_t *F, uint8_t *out) {
    const double thr = grad ? 0.06666666666666667 : 0.19607843137254902;
    for (int x = 0; x < w; x++)
        for (int y = 0; y < h; y++) {
            size_t p = (size_t)y * w + x;
            if (!(F[p] & 1)) { out[p] = 0; continue; }
            float4 c = rgb_at(px, p);
            int cnt = 0;
            for (int xx = imax(x - 1, 0); xx <= imin(x + 1, w - 1); xx++)
                for (int yy = imax(y - 1, 0); yy <= imin(y + 1, h - 1); yy++)
                    if (thr < (double)norm3c(c - rgb_at(px, (size_t)yy * w + xx))) cnt++;
            out[p] = cnt > 0;
        }
    if (!grad) return;
    for (int x = 0; x < w; x++)
        for (int y = 0; y < h; y++) {
            int total = 0, match = 0;
            for (int xx = imax(x - 1, 0); xx <= imin(x + 1, w - 1); xx++)
                for (int yy = imax(y - 1, 0); yy <= imin(y + 1, h - 1); yy++) { total++; match += (F[(size_t)yy * w + xx] & 0x21) == 1; }
            if (match == total) out[(size_t)y * w + x] |= 2;
        }
    for (int x = 0; x < w; x++)
        for (int y = 0; y < h; y++) {
            size_t p = (size_t)y * w + x;
            if (!(out[p] & 2)) continue;
            int total = 0, match = 0;
            for (int xx = imax(x - 1, 0); xx <= imin(x + 1, w - 1); xx++)
                for (int yy = imax(y - 1, 0); yy <= imin(y + 1, h - 1); yy++) { total++; match += (out[(size_t)yy * w + xx] >> 1) & 1; }
            if (match == total) out[p] |= 4;
        }
    for (int x = 0; x < w; x++)
        for (int y = 0; y < h; y++) {
            size_t p = (size_t)y * w + x;
            if (!(out[p] & 2)) continue;
            int total = 0, match = 0;
            for (int xx = imax(x - 2, 0); xx <= imin(x + 2, w - 1); xx++)
                for (int yy = imax(y - 2, 0); yy <= imin(y + 2, h - 1); yy++)
                    if (abs(xx - x) + abs(yy - y) <= 2) { total++; match += (out[(size_t)yy * w + xx] >> 1) & 1; }
            if (match == total) out[p] |= 8;
        }
}

// Оценка цвета знака P для пикселя c: чем ближе c к «фоновой линии» фон—знак, тем лучше. Обновляет лучшие значения.
static void gradient_candidate(float4 c, float4 bg, float4 shade, float4 P, int grad, float *best, float4 *bgEst, float4 *fgEst) {
    float4 pt1 = bg, pt2;
    if (grad) {
        float ratio, alpha;
        iso_ratio_alpha(c - P, bg - P, shade - P, &ratio, &alpha);
        float r = clamp01(ratio), a = clamp01(1.0f - alpha);
        float4 sb = shade - bg;
        for (int i = 0; i < 4; i++) pt1[i] = fmaf(sb[i], r, bg[i]);
        float4 toP = P - pt1;
        for (int i = 0; i < 4; i++) pt2[i] = fmaf(toP[i], a, pt1[i]);
    } else {
        pt2 = iso_clamped_project(c, bg, P);
    }
    float d = norm3c(c - pt2);
    if (*best > d) { *bgEst = pt1; *fgEst = P; }
    if (d < *best) *best = d;
}

int iso_fg_gradient(int w, int h, float4 gw, float4 bg, int grad, float4 shade, const uint8_t *px, uint8_t *F, const uint8_t *buf, uint8_t *tint, uint8_t *dark) {
    const size_t n = (size_t)w * h;
    float minG = 1.0f, maxG = 0.0f;
    for (size_t i = 0; i < n; i++) {
        uint8_t sel = grad ? buf[i] : F[i];
        if (!((F[i] & 1) && (sel & 8))) continue;
        float g = clamp01(dot3(rgb_at(px, i), gw));
        minG = fminf(minG, g); maxG = fmaxf(maxG, g);
    }
    const int eyeMode = (double)norm3c(bg + (float4)-1.0f) < 0.11764705882352941;
    if (eyeMode) iso_connected_background(w, h, F);
    if (w < 1) return 1;
    float range = maxG - fminf(minG, maxG + -9.999999747378752e-06f);
    float q = fminf(0.5f / range, 1.600000023841858f);
    float t0 = fmaxf(fmaf(-range, q, 1.0f), 0.5f), t1 = 1.0f - t0;
    for (int x = 0; x < w; x++) {
        for (int y = 0; y < h; y++) {
            size_t p = (size_t)y * w + x;
            if (eyeMode && iso_test_eye(w, h, x, y, px, F)) return 0;
            uint8_t fl = F[p];
            int sel = ((grad ? buf[p] : fl) & 4) != 0;
            float4 c = rgb_at(px, p);
            float4 ref = grad ? iso_clamped_project(c, bg, shade) : bg;
            float4 fgc = {0, 0, 0, 0}, bgc = bg;
            float a = 0, g = 0;
            if (!((double)norm3c(c - ref) < 0.00784313725490196)) {
                int confident = (fl & 1) && sel;
                float best = confident ? 0.0f : FLT_MAX;
                if (confident) fgc = c;
                if (!confident) {
                    const int c0 = imax(x - 7, 0), c1 = imin(x + 7, w - 1), r0 = imax(y - 7, 0), r1 = imin(y + 7, h - 1);
                    // 1. ближайшие (по манхэттенскому расстоянию) уверенные пиксели знака: их средний цвет
                    int minM = INT_MAX, cnt = 0, near = 0;
                    float4 sum = {0, 0, 0, 0};
                    for (int xx = c0; xx <= c1; xx++)
                        for (int yy = r0; yy <= r1; yy++) {
                            size_t qi = (size_t)yy * w + xx;
                            uint8_t qf = F[qi];
                            if (!((qf & 1) && ((grad ? buf[qi] : qf) & 4))) continue;
                            int m = abs(xx - x) + abs(yy - y);
                            if (m < minM) { minM = m; cnt = 0; near = 0; sum = (float4){0, 0, 0, 0}; }
                            else if (m != minM) continue;
                            float4 cq = rgb_at(px, qi);
                            cnt++;
                            sum = cq + sum;
                            near |= (double)norm3c(c - cq) < 0.00784313725490196;
                        }
                    if (cnt > 0) {
                        float4 P = near ? c : sum / (float4)(float)cnt;
                        gradient_candidate(c, bg, shade, P, grad, &best, &bgc, &fgc);
                    }
                    // 2. любой уверенный пиксель окна как кандидат
                    for (int xx = c0; xx <= c1; xx++)
                        for (int yy = r0; yy <= r1; yy++) {
                            size_t qi = (size_t)yy * w + xx;
                            uint8_t qf = F[qi];
                            if (!(qf & 1)) continue;
                            if (grad ? !(buf[qi] & 8) : (qf & 9) != 9) continue;
                            gradient_candidate(c, bg, shade, rgb_at(px, qi), grad, &best, &bgc, &fgc);
                        }
                }
                if (best > 1.2000000476837158f) return 0;
                g = clamp01(dot3(fgc, gw));
                float4 d1 = c - bgc, d2 = fgc - bgc;
                float4 pp = d1 * d2, qq = d2 * d2;
                a = clamp01((pp[2] + (pp[0] + pp[1])) / (qq[2] + (qq[0] + qq[1])));
            }
            if (tint) {
                float v = clamp01(1.0f - (maxG - g) / range);
                v = fmaf(v, t1, t0);
                tint[p] = (uint8_t)(int)((a * v) * 255.0f);
            }
            if (dark) {
                float4 v = {fgc[0] * 255.0f, fgc[1] * 255.0f, 255.0f * fgc[2], 255.0f};
                v = v * a;
                for (int i = 0; i < 4; i++) dark[p * 4 + i] = (uint8_t)(int)v[i];
            }
        }
    }
    return 1;
}

// Знак-градиент на однотонном фоне (и запасной путь для многоцветного знака): проверки пригодности и вызов iso_fg_gradient
static int segment_fg_gradient(int grad, float minT, int w, int h, uint8_t *px, uint8_t *F, uint8_t *tint, uint8_t *dark, int colorEnhancement,
                               float4 bgv, const float4 *fgS, int nfg, int texLimit) {
    (void)colorEnhancement;
    const size_t n = (size_t)w * h;
    if (!grad) { iso_flag_more_confidence(w, h, F); iso_flag_extra_confidence(w, h, F); }
    const float4 shade = bgv * (float4)minT;
    uint8_t *buf = malloc(n ? n : 1);
    iso_flag_additional_gradient(w, h, grad, px, F, buf);
    int ok = 0;
    float4 hsv = iso_rgb2hsv(bgv);
    // фон должен заметно отличаться от знака
    float minDist = FLT_MAX;
    for (size_t i = 0; i < n; i++) {
        uint8_t sel = grad ? buf[i] : F[i];
        if (!((F[i] & 1) && (sel & 4))) continue;
        float4 c = rgb_at(px, i);
        float d = grad ? norm3c(c - iso_clamped_project(c, bgv, shade)) : norm3c(c - bgv);
        if (d < minDist) minDist = d;
    }
    const float table[2] = {0.14509804546833038f, 0.09803921729326248f};
    float thr = hsv[2] < 0.5f ? 0.10588235408067703f : table[hsv[1] < 0.5f];
    if (minDist < thr) goto done;
    {
        // «текстура» знака: вторая разность цвета выше порога
        int rough = 0;
        for (int x = 1; x < w - 1; x++)
            for (int y = 1; y < h - 1; y++) {
                size_t q = (size_t)y * w + x;
                if ((F[q] & 3) != 3 || (buf[q] & 1)) continue;
                const size_t nb[4] = {q - 1, q + 1, q - w, q + w};
                int okn = 1;
                for (int k = 0; k < 4; k++) if ((F[nb[k]] & 3) != 3 || (buf[nb[k]] & 1)) okn = 0;
                if (!okn) continue;
                float4 ctr = rgb_at(px, q), l = rgb_at(px, q - 1), rr = rgb_at(px, q + 1), u = rgb_at(px, q - w), d = rgb_at(px, q + w);
                float4 k2 = (float4)-2.0f, a = l + rr, b = u + d;
                for (int i = 0; i < 4; i++) { a[i] = fmaf(k2[i], ctr[i], a[i]); b[i] = fmaf(k2[i], ctr[i], b[i]); }
                float4 a2 = a * a, b2 = b * b;
                float sa = a2[2] + (a2[0] + a2[1]), sb = b2[2] + (b2[0] + b2[1]);
                if ((sa + sb) * 0.25f > 0.0027450979687273502f) rough++;
            }
        if (rough > texLimit * gTextureScale) goto done;
    }
    if (dark) {
        if ((double)norm3c(bgv) > 0.23529411764705882 && (double)norm3c(bgv + (float4)-1.0f) > 0.23529411764705882) goto done;
        int total = 0, ge3 = 0, lo18 = 0, lo12 = 0;
        const float4 gray = (float4)0.0784f;
        for (size_t i = 0; i < n; i++) {
            uint8_t sel = grad ? buf[i] : F[i];
            if (!((F[i] & 1) && (sel & 4) && !(sel & 8))) continue;
            float cr = iso_contrast_ratio(rgb_at(px, i), gray);
            total++;
            if (cr >= 3.0f) ge3++;
            if ((double)cr < 1.8) lo18++;
            if ((double)cr < 1.2) lo12++;
        }
        {
            float ft = (float)total;
            if ((double)((float)ge3 / ft) < 0.4) goto done;
            if ((double)((float)lo18 / ft) > 0.08) goto done;
            if ((double)((float)lo12 / ft) > 0.02) goto done;
        }
    }
    {
        float4 gw = iso_gray_weights_samples(nfg, fgS);
        ok = iso_fg_gradient(w, h, gw, bgv, grad, shade, px, F, buf, tint, dark);
    }
done:
    free(buf);
    return ok;
}

static int segment_multi_fg(int strict, int w, int h, uint8_t *px, uint8_t *F, uint8_t *tint, uint8_t *dark, int colorEnhancement, int recoloring,
                            float4 meanF, float4 meanB, const float4 *fgS, int nfg, const float4 *bgS, int nbg, int texLimit);

int iso_segment(int strict, int w, int h, uint8_t *px, uint8_t *tint, uint8_t *dark, int colorEnhancement, int recoloring) {
    const size_t n = (size_t)w * h;
    if (!iso_foreground_mask(strict, w, h, px)) return 0;
    uint8_t *F = calloc(n, 1);
    iso_stage_flags(strict, w, h, px, F);
    if (!iso_stripe_check(w, h, F)) { free(F); return 0; }
    const int N = 8000;
    float4 *samples = calloc(N, sizeof(float4));
    int nfg, nbg;
    if (!iso_stage_samples(w, h, px, F, N, samples, &nfg, &nbg)) { free(F); free(samples); return 0; }
    float4 *bgS = samples + (N - nbg);
    float4 meanF = iso_mean(nfg, samples), meanB = iso_mean(nbg, bgS);
    iso_mat3 covF = iso_covariance(nfg, samples, meanF), covB = iso_covariance(nbg, bgS, meanB);
    float trF = covF.c[2][2] + (covF.c[0][0] + covF.c[1][1]), trB = covB.c[2][2] + (covB.c[0][0] + covB.c[1][1]);
    const double T = 0.0004;
    int texLimit = (int)n / 2000;
    int ok = 0;
    if (!((double)trF > T) && !((double)trB > T)) {
        // знак и фон однотонные
        float4 out = meanF;
        if (!dark || iso_should_generate_dark(colorEnhancement, &out, meanF, meanB))
            ok = iso_fg_multi(w, h, 1, &meanF, (float4)0.0f, meanB, px, F, tint, &out, dark);
    } else if ((double)trF > T && !((double)trB > T)) {
        ok = strict ? segment_multi_fg(strict, w, h, px, F, tint, dark, colorEnhancement, recoloring, meanF, meanB, samples, nfg, bgS, nbg, texLimit) : 0;
    } else if (!((double)trF > T) && (double)trB > T) {
        ok = segment_bg_gradient(w, h, px, F, tint, dark, recoloring, meanF, bgS, nbg, texLimit);
    }
    free(F); free(samples);
    return ok;
}

static int segment_multi_fg(int strict, int w, int h, uint8_t *px, uint8_t *F, uint8_t *tint, uint8_t *dark, int colorEnhancement, int recoloring,
                            float4 meanF, float4 meanB, const float4 *fgS, int nfg, const float4 *bgS, int nbg, int texLimit) {
    (void)strict; (void)recoloring; (void)bgS; (void)nbg; (void)texLimit;
    const size_t n = (size_t)w * h;
    const int nn = (int)n;
    float4 bgv = meanB;
    // 1. цвета знака, лежащие «вдоль» цвета фона (оттенки фона): бит 0x20
    float bgSq = sumsq3(bgv);
    for (size_t i = 0; i < n; i++) {
        if (!(F[i] & 1)) continue;
        float4 c = rgb_at(px, i);
        float t = clamp01(dot3(bgv, c) / bgSq);
        if ((double)t < 0.77) continue;
        float4 r = c - bgv * t;
        float4 rr = c - (float4){bgv[0] * t, bgv[1] * t, bgv[2] * t, bgv[3] * t};
        (void)r;
        if (norm3c(rr) < 0.011764705882352941) F[i] |= 0x20;
    }
    // 2. из них — расположенные на монотонном градиенте: бит 0x40
    for (int x = 0; x < w; x++)
        for (int y = 0; y < h; y++) {
            size_t p = (size_t)y * w + x;
            if (x == 0 || x >= w - 1 || y == 0 || y >= h - 1) continue;
            uint8_t v = F[p];
            if (!(v & 0x20)) continue;
            if ((F[p - 1] & 0x21) == 1 || (F[p + 1] & 0x21) == 1 || (F[p - w] & 0x21) == 1 || (F[p + w] & 0x21) == 1) continue;
            float4 c = rgb_at(px, p), l = rgb_at(px, p - 1), r = rgb_at(px, p + 1), u = rgb_at(px, p - w), d = rgb_at(px, p + w);
            float4 hx = (c - l) * (r - c), hy = (c - u) * (d - c);
            float mh = fminf(fminf(hx[0], hx[2]), hx[1]), mv = fminf(fminf(hy[0], hy[2]), hy[1]);
            if (fmaxf(mh, mv) > 0.0f) F[p] = v | 0x40;
        }
    int n5 = 0, n6 = 0;
    for (size_t i = 0; i < n; i++) { n5 += (F[i] >> 5) & 1; n6 += (F[i] >> 6) & 1; }
    if ((double)((float)n6 / (float)nn) > 0.14) return 0;
    float minT = 1.0f;
    int needMin = 0;
    if (n6 > nn / 1000) {
        float r65 = (float)n6 / (float)n5;
        double d1 = (double)r65;
        if (d1 > 0.525) needMin = nn >= 1;
        else if (d1 > 0.32) needMin = ((double)((float)n5 / (float)nn) < 0.038) && nn > 0;
    }
    if (needMin)
        for (size_t i = 0; i < n; i++) {
            if (!((F[i] >> 5) & 1)) continue;
            float t = clamp01(dot3(bgv, rgb_at(px, i)) / bgSq);
            minT = fminf(minT, t);
        }
    if ((double)minT < 0.92) return segment_fg_gradient(1, minT, w, h, px, F, tint, dark, colorEnhancement, bgv, fgS, nfg, texLimit);
    // 3. кластеры цветов знака
    int *labels = malloc(sizeof(int) * (size_t)nfg);
    int ncl = iso_dbscan(nfg, 10, fgS, labels, 0.04313725605607033f);
    if (ncl < 1) { free(labels); return segment_fg_gradient(0, minT, w, h, px, F, tint, dark, colorEnhancement, bgv, fgS, nfg, texLimit); }
    int *cnt = calloc(ncl, sizeof(int)); float4 *sums = calloc(ncl, sizeof(float4));
    int noise = 0;
    for (int i = 0; i < nfg; i++) { int lab = labels[i]; if (lab == -1) noise++; else { sums[lab] = sums[lab] + fgS[i]; cnt[lab]++; } }
    float4 *means = malloc(sizeof(float4) * ncl);
    for (int k = 0; k < ncl; k++) means[k] = sums[k] / (float4)(float)cnt[k];
    int ok = 0;
    if (noise >= nfg / 10) goto fallback;
    {
        float4 hsv = iso_rgb2hsv(bgv);
        float minDist = FLT_MAX;
        for (int k = 0; k < ncl; k++) { float d = norm3c(means[k] - bgv); if (d < minDist) minDist = d; }
        const float table[2] = {0.14509804546833038f, 0.09803921729326248f};
        float thr = table[hsv[1] < 0.5f];
        if (hsv[2] < 0.5f) thr = 0.10588235408067703f;
        if (minDist < thr) goto fallback;
        iso_mat3 *cov = calloc(ncl, sizeof(iso_mat3));
        for (int i = 0; i < nfg; i++) {
            int lab = labels[i];
            if (lab == -1) continue;
            float4 d = fgS[i] - means[lab];
            iso_mat3 o = iso_outer(d, d);
            for (int j = 0; j < 3; j++) cov[lab].c[j] = cov[lab].c[j] + o.c[j];
        }
        for (int k = 0; k < ncl; k++) {
            float inv = (float)(1.0 / (double)cnt[k]);
            for (int j = 0; j < 3; j++) cov[k].c[j] = cov[k].c[j] * inv;
        }
        int single = 1;
        for (int k = 0; k < ncl; k++) {
            float tr = (cov[k].c[0][0] + cov[k].c[1][1]) + cov[k].c[2][2];
            if ((double)tr > 0.0004) { single = 0; break; }
        }
        free(cov);
        if (!single) goto fallback;
        float4 out = meanF;
        const float4 gray = (float4)0.0784f;
        if (dark) {
            if (ncl == 1) { if (!iso_should_generate_dark(colorEnhancement, &out, meanF, bgv)) goto cleanup; }
            else {
                if ((double)norm3c(bgv) > 0.23529411764705882 && (double)norm3c(bgv + (float4)-1.0f) > 0.23529411764705882) goto cleanup;
                for (int k = 0; k < ncl; k++) if (iso_contrast_ratio(means[k], gray) < 3.0f) goto cleanup;
            }
        }
        if (ncl != 1) iso_flag_extra_confidence(w, h, F);
        float4 gw = iso_gray_weights_samples(nfg, fgS);
        ok = iso_fg_multi(w, h, ncl, means, gw, bgv, px, F, tint, ncl == 1 ? &out : NULL, dark);
    }
    goto cleanup;
fallback:
    ok = segment_fg_gradient(0, minT, w, h, px, F, tint, dark, colorEnhancement, bgv, fgS, nfg, texLimit);
cleanup:
    free(labels); free(cnt); free(sums); free(means);
    return ok;
}

static float4 unit_dir(float4 v) { return v * rsqrt_refined(sumsq3(v)); }

// Ближайший цвет знака к c (индекс); dmin — расстояние до него.
static int nearest_fg(const float4 *fg, int K, float4 c, float *dmin) {
    float best = FLT_MAX; int bi = 0;
    for (int j = 0; j < K; j++) { float d = norm3c(c - fg[j]); if (d < best) { best = d; bi = j; } }
    *dmin = best;
    return bi;
}

// Голосование окна радиуса r: какие цвета знака встречаются среди «внутренних» пикселей знака
static int vote_window(int w, int h, int x, int y, int r, const uint8_t *px, const uint8_t *F, const float4 *fg, int K, int *counts) {
    int votes = 0;
    for (int xx = imax(x - r, 0); xx <= imin(x + r, w - 1); xx++)
        for (int yy = imax(y - r, 0); yy <= imin(y + r, h - 1); yy++) {
            size_t q = (size_t)yy * w + xx;
            if ((F[q] & 3) != 3) continue;
            float d; int j = nearest_fg(fg, K, rgb_at(px, q), &d);
            if ((double)d <= 0.0392156862745098) { counts[j]++; votes++; }
        }
    return votes;
}

// Перебор пар цветов: лучшая точка на отрезке между цветами пары (best1) и её тень к фону (best2)
static void best_pair_points(float4 c, float4 bg, const float4 *fg, int K, const int *counts,
                             float *s1o, float4 *b1o, float *s2o, float4 *b2o) {
    float s1 = FLT_MAX, s2 = FLT_MAX;
    float4 best1 = fg[0], best2 = fg[0];
    for (int i = 0; i + 1 < K; i++) {
        if (counts && counts[i] == 0) continue;
        float4 vi = fg[i] - bg;
        for (int j = i + 1; j < K; j++) {
            if (counts && counts[j] == 0) continue;
            float ratio, alpha;
            iso_ratio_alpha(c - bg, vi, fg[j] - bg, &ratio, &alpha);
            ratio = clamp01(ratio); alpha = clamp01(alpha);
            float4 q1, q2, dij = fg[j] - fg[i];
            for (int l = 0; l < 4; l++) q1[l] = fmaf(dij[l], ratio, fg[i][l]);
            float4 dq = q1 - bg;
            for (int l = 0; l < 4; l++) q2[l] = fmaf(dq[l], alpha, bg[l]);
            float d1 = norm3c(c - q1), d2 = norm3c(c - q2);
            if (s1 > d1) best1 = q1;
            if (d1 < s1) s1 = d1;
            if (s2 > d2) best2 = q1;
            if (d2 < s2) s2 = d2;
        }
    }
    *s1o = s1; *b1o = best1; *s2o = s2; *b2o = best2;
}

int iso_fg_multi(int w, int h, int K, const float4 *fg, float4 gw, float4 bg, const uint8_t *px, uint8_t *F, uint8_t *tint, const float4 *ovr, uint8_t *dark) {
    const size_t n = (size_t)w * h;
    int *idx = malloc(sizeof(int) * K), *counts = malloc(sizeof(int) * K), *counts2 = malloc(sizeof(int) * K);
    uint8_t *inPair = calloc(K, 1);
    int ok = 0;
    // 1. «семейства» цветов знака: для каждого — самый удалённый от фона цвет в том же направлении
    for (int i = 0; i < K; i++) {
        float4 ui = unit_dir(fg[i] - bg);
        float best = 0; int bj = 0;
        for (int j = 0; j < K; j++) {
            float4 uj = unit_dir(fg[j] - bg);
            if ((double)dot3(ui, uj) > 0.9) { float d = norm3c(bg - fg[j]); if (d > best) { best = d; bj = j; } }
        }
        idx[i] = bj;
    }
    int pairCount = 0;
    for (int i = 0; i < K; i++) for (int j = i + 1; j < K; j++) if (idx[i] == idx[j]) { pairCount += 2; inPair[i] = inPair[j] = 1; }
    const int hasPairs = pairCount != 0;
    // 2. диапазон серого у цветов знака
    float minG = 1.0f, maxG = 0.0f;
    for (int i = 0; i < K; i++) { float g = clamp01(dot3(fg[i], gw)); minG = fminf(minG, g); maxG = fmaxf(maxG, g); }
    int eyeCheck = 0;
    if (K > 2 && (double)norm3c(bg + (float4)-1.0f) < 0.11764705882352941) { iso_connected_background(w, h, F); eyeCheck = 1; }
    float lo = fminf(minG, maxG + -9.999999747378752e-06f);
    float range = maxG - lo;
    float q = fminf(0.5f / range, 1.600000023841858f);
    float t0 = fmaxf(fmaf(-range, q, 1.0f), 0.5f), t1 = 1.0f - t0;
    // 3. пороги
    const int nn = (int)n;
    int limit = (int)(((int64_t)nn * 0x68db8bad) >> 32) >> 10;
    int m = (int)(((int64_t)w * (int32_t)0x88888889) >> 32);
    m = ((m + w) >> 5) + (int)((unsigned)(m + w) >> 31);
    int counter = 0;
    // 4. по пикселям (столбец за столбцом)
    for (int x = 0; x < w; x++) {
        for (int y = 0; y < h; y++) {
            size_t p = (size_t)y * w + x;
            uint8_t fl = F[p];
            if (eyeCheck && iso_test_eye(w, h, x, y, px, F)) goto done;
            float4 c = rgb_at(px, p);
            if ((double)norm3c(c - bg) < 0.00784313725490196) {   // цвет фона: прозрачно
                if (tint) tint[p] = 0;
                if (dark) memset(dark + p * 4, 0, 4);
                continue;
            }
            const int both = (fl & 9) == 9;
            const int flagA = both ? 1 : !hasPairs, flagB = both ? 0 : hasPairs;
            float4 cand = fg[0];
            float s3 = FLT_MAX;
            if (K < 2) {
                float4 pr = iso_clamped_project(c, bg, fg[0]);
                s3 = fminf(norm3c(c - pr), FLT_MAX);
            } else {
                memset(counts, 0, sizeof(int) * K);
                int votes = vote_window(w, h, x, y, 2, px, F, fg, K, counts);
                if (votes > 0) {
                    float s7, s16; float4 best1, best2;
                    best_pair_points(c, bg, fg, K, counts, &s7, &best1, &s16, &best2);
                    if (s7 == FLT_MAX && s16 == FLT_MAX) {
                        float4 b1 = fg[0], b2 = fg[0];
                        for (int k = 0; k < K; k++) {
                            if (counts[k] == 0) continue;
                            float4 pr = iso_clamped_project(c, bg, fg[k]);
                            float dFg = norm3c(c - fg[k]), dPr = norm3c(c - pr);
                            if (dFg < s7) { s7 = dFg; b1 = fg[k]; }
                            if (dPr < s16) { s16 = dPr; b2 = fg[k]; }
                        }
                        best1 = b1; best2 = b2;
                    }
                    if (s7 < FLT_MAX && s16 < FLT_MAX) {
                        if (s7 > 0.13725490868091583f) { s3 = s16; cand = best2; } else { s3 = s7; cand = best1; }
                    }
                }
                if (!hasPairs && s3 > 0.03921568766236305f) {
                    for (int k = 0; k < K; k++) {
                        float d = norm3c(c - iso_clamped_project(c, bg, fg[k]));
                        if (s3 > d) cand = fg[k];
                        if (d < s3) s3 = d;
                    }
                }
                int w8 = flagA;
                if (!(s3 > 0.03921568766236305f)) w8 = 0;
                if (w8 == 1) {
                    float s16, s5; float4 best1, best2;
                    best_pair_points(c, bg, fg, K, NULL, &s16, &best1, &s5, &best2);
                    if (s16 < FLT_MAX && s5 < FLT_MAX) {
                        if (s16 > 0.13725490868091583f) { if (s5 < s3) { s3 = s5; cand = best2; } }
                        else { if (s16 < s3) { s3 = s16; cand = best1; } }
                    }
                }
                w8 = flagB;
                if (!(s3 > 0.03921568766236305f)) w8 = 0;
                if (w8 == 1) {
                    int kStar = 0; float bestD = FLT_MAX;
                    for (int k = 0; k < K; k++) {
                        float d = norm3c(c - iso_clamped_project(c, bg, fg[k]));
                        if (d < bestD) { bestD = d; kStar = k; }
                    }
                    if (inPair[kStar]) {
                        memset(counts2, 0, sizeof(int) * K);
                        vote_window(w, h, x, y, 3, px, F, fg, K, counts2);
                        int best = counts2[kStar], pick = kStar;
                        for (int k = 0; k < K; k++) if (idx[k] == idx[kStar] && counts2[k] > best) { best = counts2[k]; pick = k; }
                        kStar = pick;
                    }
                    float d = norm3c(c - iso_clamped_project(c, bg, fg[kStar]));
                    if (s3 > d) cand = fg[kStar];
                    if (d < s3) s3 = d;
                }
            }
            int interior = x >= m && x < w - m && y >= m && y < h - m;
            int w8v = tint ? (s3 > 1.0f && interior && K > 1) : 0;
            int farOut = interior && s3 > 0.23499999940395355f;
            int direct = (!farOut || dark == NULL) && !w8v;
            if (!direct) {
                int before = counter; counter++;
                if (tint) goto done;
                if (!(dark == NULL || before < limit)) goto done;
            }
            float g = clamp01(dot3(cand, gw));
            float4 d1 = c - bg, d2 = cand - bg;
            float4 pp = d1 * d2, qq = d2 * d2;
            float a = clamp01((pp[2] + (pp[0] + pp[1])) / (qq[2] + (qq[0] + qq[1])));
            if (tint) {
                float v = clamp01(1.0f - (maxG - g) / range);
                v = fmaf(v, t1, t0);
                tint[p] = (uint8_t)(int)((a * v) * 255.0f);
            }
            if (dark) {
                float4 col = ovr ? *ovr : cand;
                float4 v = {col[0] * 255.0f, col[1] * 255.0f, 255.0f * col[2], 255.0f};
                v = v * a;
                for (int i = 0; i < 4; i++) dark[p * 4 + i] = (uint8_t)(int)v[i];
            }
        }
    }
    ok = 1;
done:
    free(idx); free(counts); free(counts2); free(inPair);
    return ok;
}

static int dbscan_query(int n, const float4 *pts, int idx, float eps, const uint8_t *queued, int *tmp, int *out, int *nout) {
    float e2 = eps * eps;
    int count = 0;
    for (int j = 0; j < n; j++) {
        float4 d = pts[idx] - pts[j];
        float4 q = d * d;
        float s = q[2] + (q[0] + q[1]);
        if (s <= e2) tmp[count++] = j;
    }
    *nout = 0;
    for (int k = 0; k < count; k++) {
        int j = tmp[k];
        if (!((queued[j >> 3] >> (j & 7)) & 1)) out[(*nout)++] = j;
    }
    return count;
}

int iso_dbscan(int n, int minPts, const float4 *pts, int *labels, float eps) {
    const int UNSEEN = (int)0x80000000, NOISE = -1;
    for (int i = 0; i < n; i++) labels[i] = UNSEEN;
    uint8_t *queued = calloc((size_t)(n + 7) / 8 + 1, 1);
    int *tmp = malloc(sizeof(int) * (size_t)(n + 1)), *seeds = malloc(sizeof(int) * (size_t)(n + 1)), *more = malloc(sizeof(int) * (size_t)(n + 1));
    int cluster = 0;
    for (int i = 0; i < n; i++) {
        if (labels[i] != UNSEEN) continue;
        int ns;
        int cnt = dbscan_query(n, pts, i, eps, queued, tmp, seeds, &ns);
        if (cnt < minPts) { labels[i] = NOISE; continue; }
        for (int k = 0; k < ns; k++) queued[seeds[k] >> 3] |= 1 << (seeds[k] & 7);
        while (ns > 0) {
            int j = seeds[--ns];
            if (labels[j] == UNSEEN) {
                labels[j] = cluster;
                int nm;
                int cnt2 = dbscan_query(n, pts, j, eps, queued, tmp, more, &nm);
                if (cnt2 >= minPts) {
                    for (int k = 0; k < nm; k++) { seeds[ns++] = more[k]; queued[more[k] >> 3] |= 1 << (more[k] & 7); }
                }
            } else if (labels[j] == NOISE) labels[j] = cluster;
        }
        cluster++;
    }
    free(queued); free(tmp); free(seeds); free(more);
    return cluster;
}
