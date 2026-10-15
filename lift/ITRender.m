// Рендер Dark / Tinted для одной иконки: сегментация iOS 18 (islift) + наша доводка.
// Повторяет lift/pipeline.py. Работает на Mac и на iOS 12 (только CoreGraphics + C).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "ITRender.h"
#import "islift.h"

int islift_mask(int w, int h, uint8_t *rgbaBuf, int strict);

#define SS 3   // суперсэмплинг

static void appleFallback(const uint8_t *px, int w, ITRenderResult *out);

static CGColorSpaceRef sRGB(void) {
    static CGColorSpaceRef cs; if (!cs) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); return cs;
}

// Рисует картинку в RGBA8 premultiplied заданного размера
static uint8_t *drawRGBA(CGImageRef img, int n) {
    uint8_t *px = calloc((size_t)n * n, 4);
    CGContextRef c = CGBitmapContextCreate(px, n, n, 8, n * 4, sRGB(), kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, n, n), img);
    CGContextRelease(c);
    return px;
}

// Плавное увеличение 8-битной маски (аналог бикубики PIL)
static float *upscaleMask(const uint8_t *m, int w, int n) {
    CGColorSpaceRef g = CGColorSpaceCreateDeviceGray();
    CGContextRef src = CGBitmapContextCreate((void *)m, w, w, 8, w, g, kCGImageAlphaNone);
    CGImageRef im = CGBitmapContextCreateImage(src);
    uint8_t *big = calloc((size_t)n * n, 1);
    CGContextRef dst = CGBitmapContextCreate(big, n, n, 8, n, g, kCGImageAlphaNone);
    CGContextSetInterpolationQuality(dst, kCGInterpolationHigh);
    CGContextDrawImage(dst, CGRectMake(0, 0, n, n), im);
    float *out = malloc(sizeof(float) * n * n);
    for (int i = 0; i < n * n; i++) out[i] = big[i] / 255.0f;
    CGContextRelease(src); CGContextRelease(dst); CGImageRelease(im); CGColorSpaceRelease(g); free(big);
    return out;
}

// Компоненты знака (4-связность). «Ободок» — компонента, которая почти целиком (≥90%) лежит в полосе 10% у края
// (светлая рамка новых иконок); такие считаются фоном. Широкие элементы у края (полоса «Заметок») остаются знаком.
static uint8_t *keepInnerComponents(const float *a, int n) {
    int *lab = calloc((size_t)n * n, sizeof(int)), *stack = malloc(sizeof(int) * n * n);
    uint8_t *rim = NULL; int nl = 0, cap = 0;
    int band = n / 10;
    for (int i = 0; i < n * n; i++) {
        if (a[i] < 0.5f || lab[i]) continue;
        nl++;
        if (nl >= cap) { cap = cap ? cap * 2 : 256; rim = realloc(rim, cap); }
        long inBand = 0, total = 0; int touches = 0;
        int sp = 0; stack[sp++] = i; lab[i] = nl;
        while (sp) {
            int p = stack[--sp], x = p % n, y = p / n;
            total++;
            if (x < band || y < band || x >= n - band || y >= n - band) inBand++;
            if (x == 0 || y == 0 || x == n - 1 || y == n - 1) touches = 1;
            int nb[4] = { x > 0 ? p - 1 : -1, x < n - 1 ? p + 1 : -1, y > 0 ? p - n : -1, y < n - 1 ? p + n : -1 };
            for (int k = 0; k < 4; k++) if (nb[k] >= 0 && !lab[nb[k]] && a[nb[k]] >= 0.5f) { lab[nb[k]] = nl; stack[sp++] = nb[k]; }
        }
        rim[nl] = touches && inBand * 10 >= total * 9;
    }
    uint8_t *keep = calloc((size_t)n * n, 1);
    for (int i = 0; i < n * n; i++) keep[i] = lab[i] && !rim[lab[i]];
    // расширение на 2*SS шагов крестом
    uint8_t *tmp = malloc((size_t)n * n);
    for (int it = 0; it < 2 * SS; it++) {
        memcpy(tmp, keep, (size_t)n * n);
        for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
            int p = y * n + x; if (tmp[p]) continue;
            if ((x > 0 && tmp[p - 1]) || (x < n - 1 && tmp[p + 1]) || (y > 0 && tmp[p - n]) || (y < n - 1 && tmp[p + n])) keep[p] = 1;
        }
    }
    free(tmp); free(lab); free(stack); free(rim);
    return keep;
}

// Квадратичная поверхность фона по выбранным пикселям: B = c0 + c1 x + c2 y + c3 x² + c4 xy + c5 y²
static void fitBackground(const uint8_t *px, const uint8_t *sel, int n, double coef[3][6]) {
    double M[6][6] = {{0}}, R[3][6] = {{0}};
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        int p = y * n + x; if (!sel[p]) continue;
        double fx = (double)x / n - 0.5, fy = (double)y / n - 0.5, v[6] = {1, fx, fy, fx * fx, fx * fy, fy * fy};
        for (int i = 0; i < 6; i++) { for (int j = 0; j < 6; j++) M[i][j] += v[i] * v[j]; for (int c = 0; c < 3; c++) R[c][i] += v[i] * px[p * 4 + c]; }
    }
    // Гаусс с выбором ведущего элемента, три правые части
    double A[6][9];
    for (int i = 0; i < 6; i++) { for (int j = 0; j < 6; j++) A[i][j] = M[i][j]; for (int c = 0; c < 3; c++) A[i][6 + c] = R[c][i]; }
    for (int i = 0; i < 6; i++) {
        int piv = i; for (int r = i + 1; r < 6; r++) if (fabs(A[r][i]) > fabs(A[piv][i])) piv = r;
        for (int j = 0; j < 9; j++) { double t = A[i][j]; A[i][j] = A[piv][j]; A[piv][j] = t; }
        if (fabs(A[i][i]) < 1e-12) { A[i][i] = 1e-12; }
        for (int r = 0; r < 6; r++) if (r != i) { double f = A[r][i] / A[i][i]; for (int j = i; j < 9; j++) A[r][j] -= f * A[i][j]; }
    }
    for (int c = 0; c < 3; c++) for (int i = 0; i < 6; i++) coef[c][i] = A[i][6 + c] / A[i][i];
}

static void downscale(const float *src, int n, int comps, float *dst) {
    int w = n / SS;
    for (int y = 0; y < w; y++) for (int x = 0; x < w; x++) for (int c = 0; c < comps; c++) {
        float s = 0; for (int dy = 0; dy < SS; dy++) for (int dx = 0; dx < SS; dx++) s += src[((y * SS + dy) * n + x * SS + dx) * comps + c];
        dst[(y * w + x) * comps + c] = s / (SS * SS);
    }
}

int ITRenderIcon(CGImageRef icon, int w, ITRenderResult *out) {
    memset(out, 0, sizeof *out);
    int n = w * SS;
    // 1. Маска iOS 18 на родном размере
    uint8_t *px1 = drawRGBA(icon, w);
    uint8_t *mbuf = malloc((size_t)w * w * 4); memcpy(mbuf, px1, (size_t)w * w * 4);
    islift_mask(w, w, mbuf, 0);
    uint8_t *m1 = malloc((size_t)w * w);
    for (int i = 0; i < w * w; i++) m1[i] = mbuf[i * 4 + 3];
    free(mbuf); free(px1);
    // 2. Увеличение картинки и маски
    uint8_t *px = drawRGBA(icon, n);
    float *a = upscaleMask(m1, w, n); free(m1);
    uint8_t *keep = keepInnerComponents(a, n);
    long kept = 0, fgTotal = 0;
    for (int i = 0; i < n * n; i++) { kept += keep[i] && a[i] >= 0.5f; fgTotal += a[i] >= 0.5f; }
    if (kept < fgTotal / 20 || kept < (long)n * n / 200) memset(keep, 1, (size_t)n * n);   // всё «ободок» — значит, это не ободок
    int band = 3 * SS;
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        int p = y * n + x;
        if (!keep[p] || x < band || y < band || x >= n - band || y >= n - band) a[p] = 0;
    }
    free(keep);
    // Знака почти нет (вся иконка — рисунок, как «Заметки»): как iOS 18 — затемнение / серый×цвет
    double cover = 0; for (int i = 0; i < n * n; i++) cover += a[i];
    if (cover < 0.008 * n * n) {
        free(a); free(px);
        uint8_t *px1b = drawRGBA(icon, w);
        appleFallback(px1b, w, out);
        free(px1b);
        return 0;
    }
    // Мелкие «дырки» фона внутри знака (засечки Safari, ободок объектива) — часть знака:
    // компонента фона (a < 0.5) не касается края и меньше 3% окружающей её компоненты знака
    // (дырки в тонких буквах «Среда» не трогаем — они сравнимы с самой буквой).
    {
        int *fgLab = calloc((size_t)n * n, sizeof(int)), *st = malloc(sizeof(int) * n * n), *pix = malloc(sizeof(int) * n * n);
        long *fgArea = calloc(1, sizeof(long)); int nf = 0;
        for (int i = 0; i < n * n; i++) {
            if (a[i] < 0.5f || fgLab[i]) continue;
            nf++; fgArea = realloc(fgArea, sizeof(long) * (nf + 1)); fgArea[nf] = 0;
            int sp = 0; st[sp++] = i; fgLab[i] = nf;
            while (sp) {
                int p = st[--sp], x = p % n, y = p / n; fgArea[nf]++;
                int nb[4] = { x > 0 ? p - 1 : -1, x < n - 1 ? p + 1 : -1, y > 0 ? p - n : -1, y < n - 1 ? p + n : -1 };
                for (int k = 0; k < 4; k++) if (nb[k] >= 0 && !fgLab[nb[k]] && a[nb[k]] >= 0.5f) { fgLab[nb[k]] = nf; st[sp++] = nb[k]; }
            }
        }
        uint8_t *seen = calloc((size_t)n * n, 1);
        for (int i = 0; i < n * n; i++) {
            if (a[i] >= 0.5f || seen[i]) continue;
            int sp = 0, np = 0, touches = 0, around = 0; st[sp++] = i; seen[i] = 1;
            while (sp) {
                int p = st[--sp], x = p % n, y = p / n; pix[np++] = p;
                if (x == 0 || y == 0 || x == n - 1 || y == n - 1) touches = 1;
                int nb[4] = { x > 0 ? p - 1 : -1, x < n - 1 ? p + 1 : -1, y > 0 ? p - n : -1, y < n - 1 ? p + n : -1 };
                for (int k = 0; k < 4; k++) if (nb[k] >= 0) {
                    if (a[nb[k]] >= 0.5f) { if (!around) around = fgLab[nb[k]]; }
                    else if (!seen[nb[k]]) { seen[nb[k]] = 1; st[sp++] = nb[k]; }
                }
            }
            if (!touches && around && np * 33 < fgArea[around]) for (int k = 0; k < np; k++) a[pix[k]] = 1;
        }
        free(fgLab); free(st); free(pix); free(fgArea); free(seen);
    }
    // 3. Выравнивание фона
    uint8_t *bgsel = malloc((size_t)n * n);
    for (int i = 0; i < n * n; i++) bgsel[i] = a[i] < 0.03f;
    double coef[3][6]; fitBackground(px, bgsel, n, coef);
    double Bc[3] = {0}; long cnt = 0;
    float *B = malloc(sizeof(float) * n * n * 3);
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        int p = y * n + x; double fx = (double)x / n - 0.5, fy = (double)y / n - 0.5, v[6] = {1, fx, fy, fx * fx, fx * fy, fy * fy};
        for (int c = 0; c < 3; c++) { double s = 0; for (int i = 0; i < 6; i++) s += coef[c][i] * v[i]; B[p * 3 + c] = s; if (bgsel[p]) Bc[c] += s; }
        if (bgsel[p]) cnt++;
    }
    for (int c = 0; c < 3; c++) Bc[c] /= cnt ? cnt : 1;
    uint8_t *flat = malloc((size_t)n * n * 4);
    float *Pf = malloc(sizeof(float) * n * n * 3);
    for (int p = 0; p < n * n; p++) {
        for (int c = 0; c < 3; c++) {
            float v = bgsel[p] ? Bc[c] : px[p * 4 + c] + (1 - a[p]) * (Bc[c] - B[p * 3 + c]);
            Pf[p * 3 + c] = v;
            v = roundf(v); flat[p * 4 + c] = v < 0 ? 0 : v > 255 ? 255 : v;
        }
        flat[p * 4 + 3] = px[p * 4 + 3];
    }
    // Рисунок фона (дороги «Карт», сетка): остаток после вычитания плавной поверхности B.
    // Если он заметен — сохраняем его приглушённо (в iOS 18 такие фоны у iOS 18 тоже не пустые).
    float *detail = NULL;
    {
        double e = 0; long cntb = 0;
        float *dl = malloc(sizeof(float) * n * n);
        for (int p = 0; p < n * n; p++) {
            float lp = (0.2126f * px[p * 4] + 0.7152f * px[p * 4 + 1] + 0.0722f * px[p * 4 + 2]) / 255.0f;
            float lb = (0.2126f * B[p * 3] + 0.7152f * B[p * 3 + 1] + 0.0722f * B[p * 3 + 2]) / 255.0f;
            dl[p] = lp - lb;
            if (bgsel[p]) { e += fabsf(dl[p]); cntb++; }
        }
        e /= cntb ? cntb : 1;
        if (e > 0.025) detail = dl; else free(dl);
    }
    free(B); free(bgsel); free(px);
    // 4. Сегментация iOS 18 на выровненной картинке
    uint8_t *tint8 = calloc((size_t)n * n, 1), *dark8 = calloc((size_t)n * n, 4);
    out->tintSegmented = islift_compute(n, n, flat, tint8, NULL, 1, 1, 1, 1, NULL, 0) > 0;
    out->darkSegmented = islift_compute(n, n, flat, NULL, dark8, 1, 1, 1, 1, NULL, 0) > 0;
    free(flat);
    // 5. Запасная формула: распаковка цвета знака F из P' = aF + (1-a)Bc
    float *dark = malloc(sizeof(float) * n * n * 4), *tint = malloc(sizeof(float) * n * n);
    float Lmax = 1e-3f;
    float *F = malloc(sizeof(float) * n * n * 3);
    for (int p = 0; p < n * n; p++) {
        float A = a[p] > 1e-3f ? a[p] : 1e-3f;
        for (int c = 0; c < 3; c++) { float f = (Pf[p * 3 + c] / 255.0f - (1 - a[p]) * Bc[c] / 255.0f) / A; F[p * 3 + c] = f < 0 ? 0 : f > 1 ? 1 : f; }
        float L = 0.2126f * F[p * 3] + 0.7152f * F[p * 3 + 1] + 0.0722f * F[p * 3 + 2];
        if (a[p] > 0.5f && L > Lmax) Lmax = L;
    }
    // Края знака: цвет из деления на маленькую альфу подхватывает фон (белые точки у Safari).
    // Берём цвет ближайшего уверенного пикселя знака (a ≥ 0.6) — заливка от уверенных пикселей наружу.
    {
        int *q = malloc(sizeof(int) * n * n); uint8_t *done = calloc((size_t)n * n, 1); int qh = 0, qt = 0;
        for (int p = 0; p < n * n; p++) if (a[p] >= 0.6f) { done[p] = 1; q[qt++] = p; }
        while (qh < qt) {
            int p = q[qh++], x = p % n, y = p / n;
            int nb[4] = { x > 0 ? p - 1 : -1, x < n - 1 ? p + 1 : -1, y > 0 ? p - n : -1, y < n - 1 ? p + n : -1 };
            for (int k = 0; k < 4; k++) if (nb[k] >= 0 && !done[nb[k]]) {
                done[nb[k]] = 1; q[qt++] = nb[k];
                for (int c = 0; c < 3; c++) F[nb[k] * 3 + c] = F[p * 3 + c];
            }
        }
        free(q); free(done);
    }
    for (int p = 0; p < n * n; p++) {
        if (out->darkSegmented) for (int c = 0; c < 4; c++) dark[p * 4 + c] = dark8[p * 4 + c] / 255.0f;
        else {
            float col[4] = {F[p * 3], F[p * 3 + 1], F[p * 3 + 2], 1};
            float mx = fmaxf(col[0], fmaxf(col[1], col[2])), mn = fminf(col[0], fminf(col[1], col[2]));
            float sat = mx > 1e-4f ? (mx - mn) / mx : 0;
            if (a[p] > 0.02f && sat < 0.2f && mx < 0.5f) {
                // как в тёмных иконках iOS 18: чёрный/серый знак становится светлым (V' = 1 - V, оттенок сохраняется)
                float v2 = 1 - mx, k = mx > 1e-4f ? v2 / mx : 0;
                if (mx <= 1e-4f) col[0] = col[1] = col[2] = v2; else for (int c = 0; c < 3; c++) col[c] *= k;
            } else if (a[p] > 0.02f) islift_lighten(col);
            for (int c = 0; c < 3; c++) dark[p * 4 + c] = col[c] * a[p];
            dark[p * 4 + 3] = a[p];
        }
        if (out->tintSegmented) {
            tint[p] = tint8[p] / 255.0f;
            // чёрный/серый знак в Tinted светлый (как в Dark): яркость маски не ниже a·(1 − V)
            float mx = fmaxf(F[p * 3], fmaxf(F[p * 3 + 1], F[p * 3 + 2])), mn = fminf(F[p * 3], fminf(F[p * 3 + 1], F[p * 3 + 2]));
            float sat = mx > 1e-4f ? (mx - mn) / mx : 0;
            if (a[p] > 0.02f && sat < 0.2f && mx < 0.5f) tint[p] = fmaxf(tint[p], a[p] * (1 - mx));
        }
        else { float L = (0.2126f * F[p * 3] + 0.7152f * F[p * 3 + 1] + 0.0722f * F[p * 3 + 2]) / Lmax; tint[p] = a[p] * (L > 1 ? 1 : L); }
    }
    if (detail) {
        float mxd = 1e-3f;
        for (int p = 0; p < n * n; p++) if (a[p] < 0.5f && detail[p] > mxd) mxd = detail[p];
        for (int p = 0; p < n * n; p++) {
            float d = detail[p] > 0 ? detail[p] / mxd : 0, bgw = 1 - dark[p * 4 + 3];
            for (int c = 0; c < 3; c++) dark[p * 4 + c] += bgw * 0.22f * d;        // светлее фона Dark
            tint[p] += (1 - tint[p]) * (1 - a[p]) * 0.30f * d;                   // слабый оттенок
        }
        free(detail);
    }
    free(F); free(Pf); free(a); free(tint8); free(dark8);
    // 6. Уменьшение
    out->size = w;
    out->dark = malloc(sizeof(float) * w * w * 4); out->tint = malloc(sizeof(float) * w * w);
    downscale(dark, n, 4, out->dark); downscale(tint, n, 1, out->tint);
    free(dark); free(tint);
    return 0;
}

// Запасной путь iOS 18 (системный компонент / системный компонент при отказе сегментации)
static void appleFallback(const uint8_t *px, int w, ITRenderResult *out) {
    uint8_t *dim = malloc((size_t)w * w * 4);
    islift_dim(w, w, px, dim);
    float wt[3] = {0.299f, 0.587f, 0.114f};
    islift_gray_weights(w, w, px, wt);
    out->size = w; out->fallback = true; out->darkSegmented = out->tintSegmented = true;
    out->dark = malloc(sizeof(float) * w * w * 4); out->tint = malloc(sizeof(float) * w * w);
    for (int p = 0; p < w * w; p++) {
        for (int c = 0; c < 4; c++) out->dark[p * 4 + c] = dim[p * 4 + c] / 255.0f;
        float a = px[p * 4 + 3] / 255.0f, g = 0;
        if (a > 0) for (int c = 0; c < 3; c++) g += wt[c] * (px[p * 4 + c] / 255.0f / a);
        out->tint[p] = fminf(fmaxf(g, 0), 1) * a;
    }
    free(dim);
}

void iso_set_texture_scale(int scale);   // открытый движок: строгий допуск «текстуры»

int ITRenderIconOriginal(CGImageRef icon, int w, ITRenderResult *out) {
    memset(out, 0, sizeof *out);
    uint8_t *px = drawRGBA(icon, w);
    uint8_t *tint8 = calloc((size_t)w * w, 1), *dark8 = calloc((size_t)w * w, 4);
    iso_set_texture_scale(1);   // как в iOS 18, без нашего послабления
    BOOL tOK = islift_compute(w, w, px, tint8, NULL, 1, 1, 1, 1, NULL, 0) > 0;
    BOOL dOK = islift_compute(w, w, px, NULL, dark8, 1, 1, 1, 1, NULL, 0) > 0;
    iso_set_texture_scale(16);
    if (!tOK || !dOK) {
        ITRenderResult fb; appleFallback(px, w, &fb);
        *out = fb;
        // что удалось — берём от сегментации, остальное — запасной путь (как раздельные эффекты iOS 18)
        if (dOK) for (int i = 0; i < w * w * 4; i++) out->dark[i] = dark8[i] / 255.0f;
        if (tOK) { for (int i = 0; i < w * w; i++) out->tint[i] = tint8[i] / 255.0f; out->fallback = false; }
        out->darkSegmented = out->tintSegmented = true;
    } else {
        out->size = w; out->darkSegmented = out->tintSegmented = true;
        out->dark = malloc(sizeof(float) * w * w * 4); out->tint = malloc(sizeof(float) * w * w);
        for (int i = 0; i < w * w * 4; i++) out->dark[i] = dark8[i] / 255.0f;
        for (int i = 0; i < w * w; i++) out->tint[i] = tint8[i] / 255.0f;
    }
    free(px); free(tint8); free(dark8);
    return 0;
}

void ITRenderResultFree(ITRenderResult *r) { free(r->dark); free(r->tint); memset(r, 0, sizeof *r); }

// Фон Dark (системный компонент): серый 0.0784 снизу → 0.1922 сверху по кривой (0.221, 0.0051, 0.8045, 1)
static double bezierY(double x) {
    const double p1x = 0.22102037072181702, p1y = 0.005102040711790323, p2x = 0.8044896721839905, p2y = 1.0;
    double lo = 0, hi = 1, t = 0.5;
    for (int i = 0; i < 60; i++) {
        t = (lo + hi) / 2;
        double bx = 3 * (1 - t) * (1 - t) * t * p1x + 3 * (1 - t) * t * t * p2x + t * t * t;
        if (bx < x) lo = t; else hi = t;
    }
    t = (lo + hi) / 2;
    return 3 * (1 - t) * (1 - t) * t * p1y + 3 * (1 - t) * t * t * p2y + t * t * t;
}
void ITDarkBackground(int h, double scale, float *rowsTopToBottom) {
    int stops = (int)(5 * h / scale);
    for (int y = 0; y < h; y++) {
        double pos = (h - 1 - y + 0.5) / h;            // снизу вверх, центр пикселя
        double fi = pos * stops; int i = (int)floor(fi);
        double l0 = (double)i / stops, l1 = (double)(i + 1) / stops;
        double v0 = 0.0784 + (0.1922 - 0.0784) * bezierY(i < stops ? l0 : 1);
        double v1 = 0.0784 + (0.1922 - 0.0784) * bezierY(i + 1 < stops ? l1 : (double)(stops - 1) / stops);
        if (i + 1 >= stops) { rowsTopToBottom[y] = v0; continue; }
        double f = (pos - l0) / (l1 - l0);
        rowsTopToBottom[y] = v0 + (v1 - v0) * f;
    }
}
