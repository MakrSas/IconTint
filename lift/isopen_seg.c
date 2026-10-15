// Открытый движок: маска знака иконки.
// Идея: цвет фона иконки берётся из полос у её краёв; пиксели выборки размножаются с небольшим шумом, по ним строится
// смесь гауссиан; кластеры, близкие к фону, объединяются; для каждого пикселя вероятность «это не фон» = произведение
// χ²-функций расстояний Махаланобиса до кластеров фона.
#include "isopen_math.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int clusters, borderWidth, maxSamples, steps, boolThreshold;
    float groupThreshold, noise;
} fg_params;

static fg_params params_for(int strict) {
    return (fg_params){10, 2, 1400, 50, strict ? 2 : 150, 1.0f, strict ? 0.01568627543747425f : 0.1764705926179886f};
}

static inline float4 color_at(const uint8_t *px, int w, int x, int y) {
    const uint8_t *p = px + ((size_t)y * w + x) * 4;
    return (float4){(float)p[0], (float)p[1], (float)p[2], 0} / (float4)255.0f;
}

static inline float norm3(float4 v) {
    float4 q = v * v;
    return sqrtf(q[2] + (q[0] + q[1]));
}

// Целочисленное деление на константу через умножение (как это делает компилятор): для неотрицательных = floor
static inline int div_mul(int v, int64_t mul, int shift) { return (int)(((int64_t)v * mul) >> 32) >> shift; }
static inline int div3(int v) { return div_mul(v, 0x55555556, 0); }
static inline int div6x(int v) { return div_mul(v, 0x2aaaaaab, 0); }
static inline int div12(int v) { return div_mul(v, 0x2aaaaaab, 1); }
static inline int div10(int v) { return div_mul(v, 0x66666667, 2); }
static inline int div2(int v) { return (v + ((unsigned)v >> 31)) >> 1; }

// Строка/столбец проверки: все ли пиксели полосы совпадают с эталоном (все 4 канала)
static int band_uniform(const uint8_t *px, int w, int x0, int x1, int y0, int y1, const uint8_t *ref) {
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++)
            if (memcmp(px + ((size_t)y * w + x) * 4, ref, 4)) return 0;
    return 1;
}

int iso_foreground_mask(int strict, int w, int h, uint8_t *px) {
    const fg_params P = params_for(strict);
    const int n = w * h;

    // --- 1. Контрольные точки у краёв: 12 на расстоянии 1 пикселя и 20 дальше (порядок важен для суммирования) ---
    int pa[12][2] = {
        {div3(w), 1}, {div2(w), 1}, {div6x(4 * w), 1},
        {1, div3(h)}, {1, div2(h)}, {1, div6x(4 * h)},
        {w - 2, div3(h)}, {w - 2, div2(h)}, {w - 2, div6x(4 * h)},
        {div3(w), h - 2}, {div2(w), h - 2}, {div6x(4 * w), h - 2},
    };
    int w12 = div12(w), h12 = div12(h), w10 = div10(w), h10 = div10(h);
    int cornerX = (int)((double)w / 8.5), cornerY = (int)((double)h / 8.5);
    int cornerX2 = (int)((double)(w - 1) - (double)w / 8.5), cornerY2 = (int)((double)(h - 1) - (double)h / 8.5);
    int pb[20][2] = {
        {div3(w), h12}, {div6x(4 * w), h12}, {div6x(4 * w), h10}, {div3(w), h10},
        {w12, div3(h)}, {w12, div6x(4 * h)}, {w10, div3(h)}, {w10, div6x(4 * h)},
        {w - 1 - w12, div3(h)}, {w - 1 - w12, div6x(4 * h)}, {w - 1 - w10, div3(h)}, {w - 1 - w10, div6x(4 * h)},
        {div3(w), h - 1 - h12}, {div6x(4 * w), h - 1 - h12}, {div3(w), h - 1 - h10}, {div6x(4 * w), h - 1 - h10},
        {cornerX, cornerY}, {cornerX2, cornerY}, {cornerX, cornerY2}, {cornerX2, cornerY2},
    };
    float4 ca[12], cb[20];
    float4 sa = 0, sb = 0;
    for (int i = 0; i < 12; i++) { ca[i] = color_at(px, w, pa[i][0], pa[i][1]); sa = sa + ca[i]; }
    for (int i = 0; i < 20; i++) { cb[i] = color_at(px, w, pb[i][0], pb[i][1]); sb = sb + cb[i]; }
    float4 meanA = sa / (float4)12.0f, meanB = sb / (float4)20.0f;
    float spreadA = 0, spreadB = 0;   // суммы квадратов расстояний до среднего (расстояние округляется до float, потом возводится)
    for (int i = 0; i < 12; i++) { float d = norm3(ca[i] - meanA); spreadA = fmaf(d, d, spreadA); }
    for (int i = 0; i < 20; i++) { float d = norm3(cb[i] - meanB); spreadB = fmaf(d, d, spreadB); }

    // Однотонная рамка у края: если средние цвета двух наборов точек сильно отличаются, а внутри каждого разброс мал,
    // то у иконки есть рамка шириной ~1/12 стороны — её пропускаем.
    int margin = 2, off = 0;
    if ((double)norm3(meanA - meanB) > 0.19607843137254902) {
        if (!((double)(spreadA / 12.0f) > 0.00392156862745098)) {
            if ((double)(spreadB / 20.0f) <= 0.00392156862745098) { margin = w12; off = w12; }
        }
    }

    // --- 2. Проверка «внутри всё одного цвета»: четыре полосы шириной borderWidth ---
    int bw = P.borderWidth;
    uint8_t ref[4]; memcpy(ref, px + ((size_t)margin * w + margin) * 4, 4);
    int uniform = 1;
    if (w - 1 - off > off && !band_uniform(px, w, off, w - 1 - off, margin, margin + bw, ref)) uniform = 0;
    if (uniform && bw >= 1 && h - 1 - off > off && !band_uniform(px, w, w - 1 - margin - bw, w - 1 - margin, off, h - 1 - off, ref)) uniform = 0;
    if (uniform && w - 1 - off > off && !band_uniform(px, w, off, w - 1 - off, h - 1 - margin - bw, h - 1 - margin, ref)) uniform = 0;
    if (uniform && bw >= 1 && !band_uniform(px, w, margin, margin + bw, off, h - 1 - off, ref)) uniform = 0;
    if (uniform) {
        // Однотонный фон: прозрачность = «цвет пикселя заметно отличается от фона» (порог зависит от яркости фона)
        float4 rc = (float4){(float)ref[0], (float)ref[1], (float)ref[2], 0};
        float4 rn = rc / (float4)255.0f;
        float lum = (rn[2] + (rn[0] + rn[1])) / 3.0f;
        float thrStrict = fmaf(lum, -1.100000023841858f, 7.409999847412109f);
        float thrLoose = fmaf(lum, -36.99999237060547f, 139.5229949951172f);
        float thr = strict ? thrStrict : thrLoose;
        for (int i = 0; i < n; i++) {
            float4 c = (float4){(float)px[i * 4], (float)px[i * 4 + 1], (float)px[i * 4 + 2], 0};
            px[i * 4 + 3] = norm3(c - rc) > thr ? 255 : 0;
        }
        return 1;
    }

    // --- 3. Выборка цветов фона из четырёх полос (с шумом), затем смесь гауссиан ---
    unsigned seed = 10;
    const int K = P.clusters;
    float4 *samples = malloc(sizeof(float4) * (size_t)P.maxSamples);
    int ns = 0;
    const float offF = (float)off, marginF = (float)margin;
    const float xr = (float)(w - off) - offF, yr = (float)(h - off) - offF;
    const int attempts = P.maxSamples >> 2;
    const float inv31 = 4.656612873077393e-10f;
#define UNIT() ((float)rand_r(&seed) * inv31)
    for (int band = 0; band < 4 && P.maxSamples >= 4; band++) {
        for (int it = 0; it < attempts; it++) {
            int x, y;
            float u1 = UNIT(), u2 = UNIT();
            switch (band) {
            case 0: x = (int)fmaf(u1, xr, offF); y = (int)fmaf(u2, (float)(bw + margin) - marginF, marginF); break;                     // верх
            case 1: x = (int)fmaf(u1, (float)(w - margin) - (float)(w - margin - bw), (float)(w - margin - bw)); y = (int)fmaf(u2, yr, offF); break;   // право
            case 2: x = (int)fmaf(u1, xr, offF); y = (int)fmaf(u2, (float)(h - margin) - (float)(h - margin - bw), (float)(h - margin - bw)); break;   // низ
            default: x = (int)fmaf(u1, (float)(bw + margin) - marginF, marginF); y = (int)fmaf(u2, yr, offF); break;                  // лево
            }
            float4 c = color_at(px, w, x, y);
            float lumaC = iso_luma(c);
            float u3 = UNIT();
            if (u3 > fmaf(lumaC, -0.476190447807312f, 1.0f)) continue;   // тёмные пиксели берём охотнее
            // сколько соседей (3×3) похожи на этот пиксель
            int xmin = x > 1 ? x - 1 : 0, xmax = x + 1 >= w - 1 ? w - 1 : x + 1;
            int ymin = y > 1 ? y - 1 : 0, ymax = y + 1 >= h - 1 ? h - 1 : y + 1;
            int similar = 0;
            for (int xx = xmin; xx <= xmax; xx++)
                for (int yy = ymin; yy <= ymax; yy++) {
                    float4 nb = color_at(px, w, xx, yy);
                    float4 diff = c + (float4){-nb[0], -nb[1], -nb[2], 0};
                    if ((double)norm3(diff) <= 0.043137254901960784) similar++;
                }
            if (similar < 6) continue;
            float n1 = iso_sample_normal(&seed), n2 = iso_sample_normal(&seed), n3 = iso_sample_normal(&seed);
            samples[ns++] = c + (float4){n1, n2, n3, 0} * P.noise;
        }
    }
#undef UNIT

    float4 *means = malloc(sizeof(float4) * K);
    iso_mat3 *covs = malloc(sizeof(iso_mat3) * K), *invs = malloc(sizeof(iso_mat3) * K);
    float *weights = malloc(sizeof(float) * K), *resp = malloc(sizeof(float) * (size_t)(K * (ns > 0 ? ns : 1)));
    iso_gmm(ns, K, P.steps, samples, means, covs, invs, weights, resp);
    free(samples); free(resp);

    // --- 4. Главный кластер и кластеры, связанные с ним ---
    int main = 0;
    for (int k = 1; k < K; k++) if (weights[k] > weights[main]) main = k;
    float *dist = malloc(sizeof(float) * K * K);
    for (int i = 0; i < K; i++)
        for (int j = 0; j < K; j++)
            dist[i * K + j] = iso_bhattacharyya(means[i], covs[i].c[0], covs[i].c[1], covs[i].c[2], means[j], covs[j].c[0], covs[j].c[1], covs[j].c[2]);
    float4 m = means[main], white = (float4)1.0f, black = 0;
    double toWhite = (double)norm3(m + (float4)-1.0f) * 0.19, toBlack = (double)norm3(m) * 0.19;
    int *inSet = calloc(K, sizeof(int)), *stack = malloc(sizeof(int) * (size_t)K * (size_t)K), sp = 0, *group = malloc(sizeof(int) * K), ng = 0;
    for (int i = 0; i < K; i++) {
        float4 mi = means[i];
        float4 p1 = iso_clamped_project(mi, m, white), p2 = iso_clamped_project(mi, m, black);
        int take = ((double)norm3(mi - p1) < 0.0196078431372549 && toWhite > (double)norm3(m - p1))
                || ((double)norm3(mi - p2) < 0.0196078431372549 && toBlack > (double)norm3(m - p2));
        if (take) { inSet[i] = 1; stack[sp++] = i; }
    }
    // поиск в глубину по близким (по расстоянию Бхаттачарьи) кластерам; inSet — множество уже взятых
    // (порядок: берём последний добавленный; новые соседи добавляются по возрастанию индекса)
    while (sp > 0) {
        int i = stack[--sp];
        group[ng++] = i;
        for (int j = 0; j < K; j++)
            if (!inSet[j] && !(dist[i * K + j] > P.groupThreshold)) { inSet[j] = 1; stack[sp++] = j; }
    }

    // --- 5. Вероятность «не фон» для каждого пикселя ---
    for (int p = 0; p < n; p++) {
        float4 c = (float4){(float)px[p * 4], (float)px[p * 4 + 1], (float)px[p * 4 + 2], 0} / (float4)255.0f;
        float prob = 1.0f;
        for (int g = 0; g < ng; g++) {
            int k = group[g];
            prob = prob * iso_chi2cdf3(iso_mahalanobis(c, means[k], invs[k].c[0], invs[k].c[1], invs[k].c[2]));
        }
        px[p * 4 + 3] = (uint8_t)(int)(prob * 255.0f);
    }

    // --- 6. Годится ли маска: у краёв должно быть больше «фона», чем «знака» ---
    int fg = 0, bgc = 0;
    int band[4][4] = {
        {0, w, margin, margin + bw},                        // верх
        {w - margin - bw, w - margin, 0, h},                // право
        {0, w, h - margin - bw, h - margin},                // низ
        {margin, margin + bw, 0, h},                        // лево
    };
    for (int b = 0; b < 4; b++)
        for (int x = band[b][0]; x < band[b][1]; x++)
            for (int y = band[b][2]; y < band[b][3]; y++) {
                int a = px[((size_t)y * w + x) * 4 + 3];
                if (P.boolThreshold < a) fg++; else bgc++;
            }
    free(means); free(covs); free(invs); free(weights); free(dist); free(inSet); free(stack); free(group);
    return fg <= bgc;
}
