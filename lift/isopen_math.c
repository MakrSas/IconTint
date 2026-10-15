#include "isopen_math.h"
#include <math.h>
#include <float.h>
#include <string.h>
#include <stdint.h>

static const float4 kLumaW = {0.2125999927520752f, 0.7152000069618225f, 0.0722000002861023f, 0.0f};

float iso_luma(float4 c) {
    float4 p = c * kLumaW;
    return p[2] + (p[0] + p[1]);
}

// sRGB → линейный
static float lin(float c) {
    double d = c;
    if (d > 0.04045) return powf((float)((d + 0.055) / 1.055), 2.4f);
    return (float)(d / 12.92);
}

float iso_relative_luminance(float4 c) {
    float4 l = {lin(c[0]), lin(c[1]), lin(c[2]), 0};
    return iso_luma(l);
}

float iso_contrast_ratio(float4 a, float4 b) {
    float la = iso_relative_luminance(a), lb = iso_relative_luminance(b);
    float mx = fmaxf(la, lb), mn = fminf(la, lb);
    return (float)(((double)mx + 0.05) / ((double)mn + 0.05));
}

float4 iso_rgb2hsv(float4 c) {
    float r = c[0], g = c[1], b = c[2];
    float t1 = g >= b ? 1.0f : 0.0f;
    float A1[4] = {b, g, -1.0f, 0.6666666865348816f}, B1[4] = {g, b, 0.0f, -0.3333333432674408f}, p[4];
    for (int i = 0; i < 4; i++) p[i] = fmaf(B1[i] - A1[i], t1, A1[i]);
    float t2 = (p[0] > r) ? 0.0f : 1.0f;
    float A2[4] = {p[0], p[1], p[3], r}, B2[4] = {r, p[1], p[2], p[0]}, q[4];
    for (int i = 0; i < 4; i++) q[i] = fmaf(B2[i] - A2[i], t2, A2[i]);
    float d = q[0] - fminf(q[3], q[1]);
    float diff = q[3] - q[1];
    double den = fma((double)d, 6.0, 9.999999747378752e-05);
    float h = fabsf((float)((double)diff / den + (double)q[2]));
    float s = d / (q[0] + 9.999999747378752e-05f);
    return (float4){h, s, q[0], 0};
}

float4 iso_hsv2rgb(float4 hsv) {
    float4 k = {1.0f, 0.6666666865348816f, 0.3333333432674408f, 0.0f};
    float4 v1 = (float4)hsv[0] + k;
    float4 fl = {floorf(v1[0]), floorf(v1[1]), floorf(v1[2]), 0};
    v1 = v1 - fl; v1[3] = 0;
    float4 hi = {0.9999999403953552f, 0.9999999403953552f, 0.9999999403953552f, 0.0f};
    for (int i = 0; i < 4; i++) v1[i] = fminf(v1[i], hi[i]);
    float4 v3, six = 6.0f, m3 = -3.0f;
    for (int i = 0; i < 4; i++) v3[i] = fmaf(six[i], v1[i], m3[i]);
    for (int i = 0; i < 4; i++) v1[i] = fabsf(v3[i]) + (-1.0f);
    v1[3] = 0;
    for (int i = 0; i < 4; i++) v1[i] = fmaxf(v1[i], 0.0f);
    v1[3] = 0;
    for (int i = 0; i < 4; i++) v1[i] = fminf(v1[i], 1.0f);
    for (int i = 0; i < 4; i++) v1[i] = v1[i] + (-1.0f);
    float4 v2;
    for (int i = 0; i < 4; i++) v2[i] = fmaf(v1[i], hsv[1], 1.0f);
    return v2 * hsv[2];
}

float4 iso_rgb2xyz(float4 c) {
    float4 l = {lin(c[0]), lin(c[1]), lin(c[2]), 0};
    float4 m0 = {0.4124529957771301f, 0.21267099678516388f, 0.01933399960398674f, 0};
    float4 m1 = {0.3575800061225891f, 0.7151600122451782f, 0.11919300258159637f, 0};
    float4 m2 = {0.18042300641536713f, 0.0721689984202385f, 0.9502270221710205f, 0};
    float4 v;
    for (int i = 0; i < 4; i++) v[i] = fmaf(m2[i], l[2], fmaf(m1[i], l[1], m0[i] * l[0]));
    return v;
}

static float labf(float t) {
    double d = t;
    if (d > 0.008856) return powf(t, 0.3333333432674408f);
    return (float)fma(d, 7.787, 0.13793103448275862);
}

float4 iso_xyz2lab(float4 xyz) {
    float4 w = {1.0521265268325806f, 1.0f, 0.9184810519218445f, 0};
    float4 s = xyz * w;
    float fx = labf(s[0]), fy = labf(s[1]), fz = labf(s[2]);
    float L = (float)fma((double)fy, 116.0, -16.0);
    float a = (fx - fy) * 500.0f;
    float b = (fy - fz) * 200.0f;
    return (float4){L, a, b, 0};
}

float4 iso_rgb2lab(float4 rgb) { return iso_xyz2lab(iso_rgb2xyz(rgb)); }

static float labfinv(float t) {
    double d = t;
    if (d > 0.206897) return t * (t * t);
    return (float)(((double)d + (-0.13793103448275862)) / 7.787);
}

float4 iso_lab2xyz(float4 lab) {
    double d1 = ((double)lab[0] + 16.0) * 0.008620689623057842;
    float fy = (float)d1;
    float fx = fmaf(0.0020000000949949026f, lab[1], fy);
    float fz = fmaf(-0.004999999888241291f, lab[2], fy);
    float4 v = {labfinv(fx), labfinv(fy), labfinv(fz), 0};
    float4 w = {0.9504560232162476f, 1.0f, 1.0887540578842163f, 0};
    return v * w;
}

float4 iso_xyz2rgb(float4 xyz) {
    float4 m0 = {3.240478992462158f, -0.9692559838294983f, 0.05564799904823303f, 0};
    float4 m1 = {-1.5371500253677368f, 1.875991940498352f, -0.20404300093650818f, 0};
    float4 m2 = {-0.49853500723838806f, 0.04155600070953369f, 1.0573110580444336f, 0};
    float4 v;
    for (int i = 0; i < 4; i++) v[i] = fmaf(m2[i], xyz[2], fmaf(m1[i], xyz[1], m0[i] * xyz[0]));
    double o[3];
    for (int i = 0; i < 3; i++) {
        double d = v[i];
        o[i] = d > 0.0031308 ? fma(pow(d, 0.4166666666666667), 1.055, -0.055) : d * 12.92;
    }
    return (float4){(float)o[0], (float)o[1], (float)o[2], 0};
}

float4 iso_lab2rgb(float4 lab) { return iso_xyz2rgb(iso_lab2xyz(lab)); }

// Функция распределения хи-квадрат с 3 степенями свободы по таблице с шагом 1/200.
float iso_chi2cdf3(float x) {
    static float table[4000]; static int ready;
    if (!ready) {
        for (int i = 0; i < 4000; i++) {
            double t = i / 200.0;
            table[i] = (float)(round((erf(sqrt(t / 2)) - sqrt(2 * t / M_PI) * exp(-t / 2)) * 1e6) / 1e6);   // в таблице значения округлены до 6 знаков
        }
        ready = 1;
    }
    int idx = (int)(x * 200.0f);
    if (idx < 0) return 0;
    if ((unsigned)idx > 0xf9f) return 1.0f;
    return table[idx];
}

int iso_lighten(float4 color, float4 *out) {
    const float4 bg = (float4)0.0784f;   // серый фон Dark (0x3da0902e)
    int ok = 0;
    float4 res = color;
    if (iso_contrast_ratio(color, bg) >= 4.5f) { ok = 1; goto done; }
    float4 cur = iso_rgb2hsv(color);
    float v = (float)((double)cur[2] + 0.05);
    cur[2] = v;
    if (!(v > 1.0f)) {
        for (;;) {   // поднимаем яркость шагами по 0.05, пока контраст не станет 4.5
            float4 rgb = iso_hsv2rgb(cur);
            if (iso_contrast_ratio(rgb, bg) >= 4.5f) { res = rgb; ok = 1; goto done; }
            float nv = (float)((double)cur[2] + 0.05);
            cur[2] = nv;
            if (nv > 1.0f) break;
        }
    }
    {   // яркость уже максимальная: уменьшаем насыщенность шагами по 0.05 до контраста 3.0
        float s = (float)((double)cur[1] + (-0.05));
        if (s < 0.0f) goto done;
        float4 hsv = {cur[0], s, 1.0f, cur[3]};
        for (;;) {
            float4 rgb = iso_hsv2rgb(hsv);
            if (iso_contrast_ratio(rgb, bg) >= 3.0f) { res = rgb; ok = 1; goto done; }
            s = (float)((double)s + (-0.05));
            hsv[1] = s;
            if (!(s >= 0.0f)) goto done;
        }
    }
done:
    if (out) *out = res;
    return ok;
}

#include <stdlib.h>

float4 iso_gray_weights_samples(int n, const float4 *s) {
    float fn = (float)n;
    float best = -FLT_MAX, bestH = 0;
    float h = 0;
    do {
        float4 c = iso_hsv2rgb((float4){h, 0.6499999761581421f, 0.5f, 0});
        float f = 1.0f / (c[2] + (c[0] + c[1]));
        float k = fmaf((float)(0.217637640824031 / (double)iso_luma(c)) - f, 0.0f, f);   // фактор подгонки яркости выключен (0)
        (void)k;
        float4 w = c * f;
        // средняя ошибка яркости на выборке
        float sumAbs = 0;
        for (int i = 0; i < n; i++) {
            float4 p = w * s[i];
            float d = p[2] + (p[0] + p[1]);
            sumAbs += fabsf(d - iso_luma(s[i]));
        }
        // контраст на случайных парах (генератор с seed 10 заново для каждого оттенка)
        unsigned seed = 10; float sumLog = 0; int cnt = 0;
        for (int it = 0; it < 300; it++) {
            int ia = (int)(fmaf((float)rand_r(&seed) * 4.656612873077393e-10f, fn, 0.0f));
            int ib = (int)(fmaf((float)rand_r(&seed) * 4.656612873077393e-10f, fn, 0.0f));
            float4 a = s[ia], b = s[ib], d = a - b; d = d * d;
            float dist = sqrtf(d[2] + (d[0] + d[1]));
            if ((double)dist > 0.0784313725490196) {
                float4 pa = w * a, pb = w * b;
                float da = pa[2] + (pa[0] + pa[1]), db = pb[2] + (pb[0] + pb[1]);
                sumLog += logf(fabsf(da - db) + 1.0f); cnt++;
            }
        }
        float meanLog = sumLog / (float)cnt;
        float t = (-sumAbs / fn) - meanLog;
        float score = fmaf(t, 0.30000001192092896f, meanLog);
        if (score > best) { best = score; bestH = h; }
        h = (float)((double)h + 0.02);
    } while (h < 1.0f);
    float hue = fminf(bestH - floorf(bestH), 0.99999994f);
    float4 c = iso_hsv2rgb((float4){hue, 0.6499999761581421f, 0.5f, 0});
    float f = 1.0f / (c[2] + (c[0] + c[1]));
    return c * f;
}

float4 iso_gray_weights(int w, int h, const uint8_t *rgba) {
    int n = w * h;
    float4 s[2000];
    unsigned seed = 10;
    for (int i = 0; i < 2000; i++) {
        int idx = (int)(((float)n * (float)rand_r(&seed)) * 4.656612873077393e-10f);
        const uint8_t *p = rgba + (size_t)idx * 4;
        s[i] = (float4){(float)p[0], (float)p[1], (float)p[2], 0} / (float4)255.0f;
    }
    return iso_gray_weights_samples(2000, s);
}

// Выборка пикселя: цвет без альфы, альфа, яркость. alphaInfo: 1 — premultiplied, 3 — не premultiplied, иначе — альфы нет.
static void sample_pixel(const uint8_t *px, int idx, int alphaInfo, float4 *color, float *alpha, float *luma) {
    const uint8_t *p = px + (size_t)idx * 4;
    float4 c = (float4){(float)p[0], (float)p[1], (float)p[2], 0} / (float4)255.0f;
    float a = 1.0f;
    if (alphaInfo == 3) a = (float)p[3] / 255.0f;
    else if (alphaInfo == 1) {
        a = (float)p[3] / 255.0f;
        if (a > 0) c = c / (float4)a;
    }
    *color = c; *alpha = a; *luma = iso_luma(c);
}

int iso_dim(int w, int h, const uint8_t *px, uint8_t *out, float targetHighlight, float targetMean, float minMeanAdjust) {
    const int alphaInfo = 1;
    int count = w * h;
    memcpy(out, px, (size_t)count * 4);
    // --- параметры: по 2000 случайным пикселям ---
    float samples[2000];
    unsigned seed = 10;
    for (int i = 0; i < 2000; i++) {
        int idx = (int)(((float)count * (float)rand_r(&seed)) * 4.656612873077393e-10f);
        float4 c; float a, l; sample_pixel(px, idx, alphaInfo, &c, &a, &l);
        samples[i] = fmaf(a, l + (-0.07840000092983246f), 0.07840000092983246f);
    }
    int hist[100] = {0};
    for (int i = 0; i < 2000; i++) { int b = (int)(samples[i] * 100.0f); if (b > 99) b = 99; hist[b]++; }   // b >= 99 → 99
    float highlight = 1.0f;
    { int cum = 0; for (int b = 99; b >= 0; b--) { cum += hist[b]; if (cum >= 300) { highlight = (float)b / 99.0f; break; } } }
    float hs = 1.0f;   // масштаб пиков
    if (highlight > targetHighlight) {
        hs = targetHighlight / highlight;
        float e = (1.0f / (1.0f - hs)) + (-1.0f);
        for (int i = 0; i < 2000; i++) { float x = samples[i]; samples[i] = x * fmaf(powf(x, e), hs - 1.0f, 1.0f); }
    }
    float sum = 0;
    for (int i = 0; i < 2000; i++) sum += samples[i];
    float mean = sum / 2000.0f;
    int dimHighlight = highlight > targetHighlight, dimMean = mean > targetMean;
    if (!(dimHighlight | dimMean)) return 0;

    // --- затемнение каждого пикселя ---
    float m3 = mean * mean * mean;
    float k = fminf(fmaxf((targetMean - m3) / (mean - m3), minMeanAdjust), 1.0f);
    float e = (1.0f / (1.0f - hs)) + (-1.0f);
    for (int i = 0; i < count; i++) {
        float4 c; float a, l; sample_pixel(px, i, alphaInfo, &c, &a, &l);
        float4 r = {0, 0, 0, 0};
        if (a != 0) {
            if (dimHighlight) c = c * fmaf(powf(l, e), hs - 1.0f, 1.0f);
            if (dimMean) {
                double d1 = fma(1.0 - (double)k, (double)(l * (l * l)), (double)(k * l));
                float s = (float)(d1 / (double)l);
                float4 lab = iso_rgb2lab(c);
                lab[0] = s * lab[0];
                c = iso_lab2rgb(lab);
            }
            c[3] = 0;
            for (int j = 0; j < 4; j++) c[j] = fmaxf(c[j], 0.0f);
            c[3] = 0;
            for (int j = 0; j < 3; j++) c[j] = fminf(c[j], 1.0f);
            c[3] = fminf(c[3], 0.0f);
            r = (float4){c[0] * 255.0f, c[1] * 255.0f, 255.0f * c[2], 255.0f};
            r = r * a;
        }
        for (int j = 0; j < 4; j++) out[(size_t)i * 4 + j] = (uint8_t)(int)r[j];
    }
    return 1;
}

#include <simd/simd.h>
extern float4 vexpf(float4);   // векторная exp из libm/Accelerate, как в эталоне

static float4 shuf(float4 v, int a, int b, int c, int d) { return (float4){v[a], v[b], v[c], v[d]}; }

void iso_gmm(int n, int K, int steps, const float4 *X, float4 *means, iso_mat3 *covs, iso_mat3 *invcovs, float *weights, float *resp) {
    unsigned seed = 10;
    const iso_mat3 ID3 = {{{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}}};
    float fK1 = 1.0f / (float)K;
    for (int k = 0; k < K; k++) {   // случайные средние в [0,1)^3, единичные ковариации, равные веса
        float r0 = (float)rand_r(&seed), r1 = (float)rand_r(&seed), r2 = (float)rand_r(&seed);
        means[k] = (float4){r0, r1, r2, 0} * (float4)4.656612873077393e-10f;
        covs[k] = ID3; invcovs[k] = ID3; weights[k] = fK1;
    }
    float fn = (float)n;
    const float4 eps0 = {1.0049500360764796e-06f, 0, 0, 0}, eps1 = {0, 1.0049500360764796e-06f, 0, 0}, eps2 = {0, 0, 1.0049500360764796e-06f, 0};
    for (int iter = 0; iter < steps;) {
        // --- E-шаг: resp[k][s] = w_k · norm_k · exp(-½ d'Σ⁻¹d) ---
        for (int k = 0; k < K; k++) {
            iso_mat3 cov = covs[k], inv = invcovs[k];
            float4 mean = means[k], c1 = cov.c[1], c2 = cov.c[2];
            float4 a = shuf(c1, 1, 2, 0, 1), b = shuf(c2, 2, 0, 1, 2), cc = shuf(c1, 2, 0, 1, 2), d = shuf(c2, 1, 2, 0, 1);
            float4 t = d * (-cc), cross;
            for (int i = 0; i < 4; i++) cross[i] = fmaf(b[i], a[i], t[i]);
            float4 p = cov.c[0] * cross;
            float det = p[2] + (p[0] + p[1]);
            float norm = 1.0f / sqrtf(fmaxf(det, 1e-20f) * 0.2580122649669647f);
            float w = weights[k];
            float *out = resp + (size_t)k * n;
            int s = 0;
            for (; s + 4 <= n; s += 4) {   // блоки по 4 пикселя (векторный путь)
                float4 dx, dy, dz;
                for (int j = 0; j < 4; j++) { dx[j] = X[s + j][0] - mean[0]; dy[j] = X[s + j][1] - mean[1]; dz[j] = X[s + j][2] - mean[2]; }
                float4 ox = (dz * inv.c[0][2]) + ((dx * inv.c[0][0]) + (dy * inv.c[0][1]));
                float4 oy = (dz * inv.c[1][2]) + ((dx * inv.c[1][0]) + (dy * inv.c[1][1]));
                float4 oz = (dz * inv.c[2][2]) + ((dx * inv.c[2][0]) + (dy * inv.c[2][1]));
                float4 m = (dz * oz) + ((dx * ox) + (dy * oy));
                for (int j = 0; j < 4; j++) m[j] = fmaxf(m[j], 0.0f);
                m = m * (float4)(-0.5f);
                float4 e = vexpf(m);
                e = e * norm; e = e * w;
                for (int j = 0; j < 4; j++) out[s + j] = e[j];
            }
            for (; s < n; s++) {   // хвост (скалярный путь)
                float4 dd = X[s] - mean;
                float4 o;
                for (int j = 0; j < 4; j++) o[j] = fmaf(inv.c[2][j], dd[2], fmaf(inv.c[1][j], dd[1], inv.c[0][j] * dd[0]));
                float4 q = dd * o;
                float m = fmaxf(q[2] + (q[0] + q[1]), 0.0f) * (-0.5f);
                out[s] = w * (norm * expf(m));
            }
        }
        // нормировка по кластерам
        if (K >= 1) for (int s = 0; s < n; s++) {
            float sum = 0;
            for (int k = 0; k < K; k++) sum += resp[(size_t)k * n + s];
            if (sum != 0) for (int k = 0; k < K; k++) resp[(size_t)k * n + s] /= sum;
        }
        // --- M-шаг ---
        int converged = 1;
        for (int k = 0; k < K; k++) {
            const float *r = resp + (size_t)k * n;
            float sum = 0; float4 acc = 0;
            int s = 0;
            for (; s + 4 <= n; s += 4) {
                sum = (((sum + r[s]) + r[s + 1]) + r[s + 2]) + r[s + 3];
                acc = acc + X[s] * r[s]; acc = acc + X[s + 1] * r[s + 1]; acc = acc + X[s + 2] * r[s + 2]; acc = acc + X[s + 3] * r[s + 3];
            }
            for (; s < n; s++) { sum += r[s]; for (int j = 0; j < 4; j++) acc[j] = fmaf(X[s][j], r[s], acc[j]); }
            if (sum == 0) {
                means[k] = 0; covs[k] = ID3; invcovs[k] = ID3; weights[k] = 0;
                continue;
            }
            float4 nm = acc / (float4)sum;
            float4 a0 = 0, a1 = 0, a2 = 0;   // столбцы ковариации (до нормировки)
            s = 0;
            for (; s + 4 <= n; s += 4) {
                float4 dd[4], wd[4];
                for (int j = 0; j < 4; j++) { dd[j] = X[s + j] - nm; wd[j] = dd[j] * r[s + j]; }
                for (int j = 0; j < 4; j++) { a0 = a0 + dd[j] * wd[j][0]; a1 = a1 + dd[j] * wd[j][1]; a2 = a2 + dd[j] * wd[j][2]; }
            }
            for (; s < n; s++) {
                float4 dd = X[s] - nm, wd = dd * r[s];
                a0 = a0 + dd * wd[0]; a1 = a1 + dd * wd[1]; a2 = a2 + dd * wd[2];
            }
            float inv_sum = (float)(1.0 / (double)sum);   // fdiv d0 = 1/(double)sum → float
            (void)inv_sum;
            float is = 1.0f / sum;
            float4 n0 = eps0 + a0 * is, n1 = eps1 + a1 * is, n2 = eps2 + a2 * is;
            simd_float3x3 M = {{simd_make_float3(n0[0], n0[1], n0[2]), simd_make_float3(n1[0], n1[1], n1[2]), simd_make_float3(n2[0], n2[1], n2[2])}};
            simd_float3x3 Mi = simd_inverse(M);
            float nw = sum / fn;
            iso_mat3 oc = covs[k];
            int same = nm[0] == means[k][0] && nm[1] == means[k][1] && nm[2] == means[k][2]
                    && n0[0] == oc.c[0][0] && n0[1] == oc.c[0][1] && n0[2] == oc.c[0][2]
                    && n1[0] == oc.c[1][0] && n1[1] == oc.c[1][1] && n1[2] == oc.c[1][2]
                    && n2[0] == oc.c[2][0] && n2[1] == oc.c[2][1] && n2[2] == oc.c[2][2]
                    && nw == weights[k];
            if (!same) converged = 0;
            means[k] = nm;
            covs[k].c[0] = n0; covs[k].c[1] = n1; covs[k].c[2] = n2;
            for (int c = 0; c < 3; c++) invcovs[k].c[c] = (float4){Mi.columns[c][0], Mi.columns[c][1], Mi.columns[c][2], 0};
            weights[k] = nw;
        }
        iter++;
        if (converged || iter == steps) break;
    }
}

iso_mat3 iso_outer(float4 a, float4 b) {
    return (iso_mat3){{a * b[0], a * b[1], a * b[2]}};
}

float4 iso_clamped_project(float4 p, float4 a, float4 b) {
    float4 d = b - a, q = p - a;
    float4 qd = q * d, dd = d * d;
    float num = qd[2] + (qd[0] + qd[1]), den = dd[2] + (dd[0] + dd[1]);
    float t = num / den;
    t = fminf(fmaxf(t, 0.0f), 1.0f);
    float4 r;
    for (int i = 0; i < 4; i++) r[i] = fmaf(d[i], t, a[i]);
    return r;
}

float iso_mahalanobis(float4 x, float4 mean, float4 c0, float4 c1, float4 c2) {
    float4 d = x - mean;
    float4 v = c0 * d[0];
    for (int i = 0; i < 4; i++) v[i] = fmaf(c1[i], d[1], v[i]);
    for (int i = 0; i < 4; i++) v[i] = fmaf(c2[i], d[2], v[i]);
    float4 p = d * v;
    return fmaxf(p[2] + (p[0] + p[1]), 0.0f);
}

// Определитель матрицы из столбцов c0,c1,c2 (порядок операций как в эталоне)
static float det3(float4 c0, float4 c1, float4 c2) {
    float4 a = shuf(c1, 1, 2, 0, 1), b = shuf(c2, 2, 0, 1, 2), cc = shuf(c1, 2, 0, 1, 2), d = shuf(c2, 1, 2, 0, 1);
    float4 t = d * (-cc), cross;
    for (int i = 0; i < 4; i++) cross[i] = fmaf(b[i], a[i], t[i]);
    float4 p = c0 * cross;
    return p[2] + (p[0] + p[1]);
}

float iso_bhattacharyya(float4 m1, float4 a0, float4 a1, float4 a2, float4 m2, float4 b0, float4 b1, float4 b2) {
    float4 s0 = (a0 + b0) * 0.5f, s1 = (a1 + b1) * 0.5f, s2 = (a2 + b2) * 0.5f;
    s0[3] = 0; s1[3] = 0; s2[3] = 0;
    simd_float3x3 S = {{simd_make_float3(s0[0], s0[1], s0[2]), simd_make_float3(s1[0], s1[1], s1[2]), simd_make_float3(s2[0], s2[1], s2[2])}};
    simd_float3x3 Si = simd_inverse(S);
    float4 i0 = {Si.columns[0][0], Si.columns[0][1], Si.columns[0][2], 0}, i1 = {Si.columns[1][0], Si.columns[1][1], Si.columns[1][2], 0}, i2 = {Si.columns[2][0], Si.columns[2][1], Si.columns[2][2], 0};
    float4 d = m1 - m2;
    float4 v = i0 * d[0];
    for (int i = 0; i < 4; i++) v[i] = fmaf(i1[i], d[1], v[i]);
    for (int i = 0; i < 4; i++) v[i] = fmaf(i2[i], d[2], v[i]);
    float4 p = d * v;
    float maha = fmaxf(p[2] + (p[0] + p[1]), 0.0f);
    float4 sc0 = (a0 + b0) * 0.5f, sc1 = s1, sc2 = s2;   // S0 с исходным lane 3 (на det не влияет)
    float detS = det3(sc0, sc1, sc2), detA = det3(a0, a1, a2), detB = det3(b0, b1, b2);
    float ratio = detS / sqrtf(detA * detB);
    double r = fma((double)maha, 0.125, (double)logf(ratio) * 0.5);   // d9=maha: fmadd(d9, 1/8, 0.5*log)
    return fmaxf((float)r, 0.0f);
}

// Нормальное распределение (полярный метод Марсальи), генератор rand_r
float iso_sample_normal(unsigned *seed) {
    float x, s;
    do {
        x = (float)((((double)(float)rand_r(seed)) * 2.0) / 2147483647.0 + (-1.0));
        float y = (float)((((double)(float)rand_r(seed)) * 2.0) / 2147483647.0 + (-1.0));
        s = fmaf(x, x, y * y);
    } while (s == 0.0f || s >= 1.0f);
    float l = logf(s) * -2.0f;
    return sqrtf(l / s) * x;
}

float4 iso_mean(int n, const float4 *x) {
    float4 s = 0;
    for (int i = 0; i < n; i++) s = s + x[i];
    return s / (float4)(float)n;
}

iso_mat3 iso_covariance(int n, const float4 *x, float4 mean) {
    float4 a0 = 0, a1 = 0, a2 = 0, p0 = 0, p1 = 0, p2 = 0;
    for (int i = 0; i < n; i++) {
        float4 d = x[i] - mean;
        float4 c0 = d * d[0], c1 = d * d[1], c2 = d * d[2];
        c0[3] = p0[3]; c1[3] = p1[3]; c2[3] = p2[3];   // lane 3 берётся из предыдущего (как в эталоне)
        a0 = a0 + c0; a1 = a1 + c1; a2 = a2 + c2;
        p0 = c0; p1 = c1; p2 = c2;
    }
    float inv = (float)(1.0 / (double)n);
    return (iso_mat3){{a0 * inv, a1 * inv, a2 * inv}};
}
