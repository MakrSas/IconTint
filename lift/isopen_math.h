// Открытый движок: цветовая математика (RGB/HSV/XYZ/Lab, контраст). Написано по описанию поведения, проверяется побитно сверкой с эталоном.
#pragma once
#include <arm_neon.h>
typedef float float4 __attribute__((ext_vector_type(4)));

float iso_luma(float4 rgb);
float iso_relative_luminance(float4 rgb);
float iso_contrast_ratio(float4 a, float4 b);
float4 iso_rgb2hsv(float4 rgb);
float4 iso_hsv2rgb(float4 hsv);
float4 iso_rgb2xyz(float4 rgb);
float4 iso_xyz2lab(float4 xyz);
float4 iso_rgb2lab(float4 rgb);
float4 iso_lab2xyz(float4 lab);
float4 iso_xyz2rgb(float4 xyz);
float4 iso_lab2rgb(float4 lab);
float iso_chi2cdf3(float x);

// Осветляет цвет знака, чтобы он читался на тёмном фоне 0.0784 (контраст 4.5 по яркости, затем по насыщенности до 3.0).
// Возвращает 1 при успехе (out — результат), 0 при отказе (out — исходный цвет).
int iso_lighten(float4 color, float4 *out);

// Веса серого (системный компонент): по выборке цветов подбирает оттенок, чьи веса лучше всего разделяют цвета выборки.
float4 iso_gray_weights_samples(int n, const float4 *samples);
// То же по картинке RGBA8 (2000 случайных пикселей, seed 10).
float4 iso_gray_weights(int w, int h, const uint8_t *rgba);

// Затемнение иконки целиком (системный компонент; запасной Dark, когда знак не отделяется).
// rgba — RGBA8 premultiplied w×h. Возвращает 1 и пишет результат в out, либо 0 (иконка не требует затемнения, out = копия входа).
int iso_dim(int w, int h, const uint8_t *rgba, uint8_t *out, float targetHighlight, float targetMean, float minMeanAdjust);

// Матрица 3×3 как три столбца float4 (lane 3 не используется)
typedef struct { float4 c[3]; } iso_mat3;

// Смесь гауссиан (EM) по n цветам. Результат: средние, ковариации, обратные ковариации, веса кластеров.
// resp — рабочий буфер K*n float. Генератор случайных чисел — rand_r с seed 10 (как в эталоне).
void iso_gmm(int n, int K, int steps, const float4 *X, float4 *means, iso_mat3 *covs, iso_mat3 *invcovs, float *weights, float *resp);

iso_mat3 iso_outer(float4 a, float4 b);
float4 iso_clamped_project(float4 p, float4 a, float4 b);
float iso_mahalanobis(float4 x, float4 mean, float4 c0, float4 c1, float4 c2);
float iso_bhattacharyya(float4 m1, float4 a0, float4 a1, float4 a2, float4 m2, float4 b0, float4 b1, float4 b2);
float iso_sample_normal(unsigned *seed);
float4 iso_mean(int n, const float4 *x);
iso_mat3 iso_covariance(int n, const float4 *x, float4 mean);

// Мягкая маска знака (фон иконки → альфа 0, знак → 255). Результат пишется в альфа-канал px (RGBA8, w×h).
// strict=1 — «строгий» режим (узкий порог, подходит для плоских фонов), 0 — «мягкий». Возвращает 1, если маска годится, иначе 0.
int iso_foreground_mask(int strict, int w, int h, uint8_t *px);

// ---- Сегментация (Dark + маска Tinted) ----
// Флаги пикселя: бит0 — знак; бит1 — «внутренний» (все соседи 3×3 того же класса); бит4 — пригоден для выборки цвета.
enum { ISO_FG = 1, ISO_INTERIOR = 2, ISO_USABLE = 0x10 };
// Первые три стадии разметки: по альфе маски (px, w×h RGBA8) строит массив флагов (w*h байт).
void iso_stage_flags(int strict, int w, int h, const uint8_t *px, uint8_t *F);

// Проверка «полос»: узор знак/фон не должен быть строго полосатым (иначе иконку не режем). 1 — ок, 0 — отказ.
int iso_stripe_check(int w, int h, const uint8_t *F);
// Выборка цветов: знак — в начало массива, фон — в конец (индекс N-1 и ниже). Возвращает 1, если набрано достаточно.
int iso_stage_samples(int w, int h, const uint8_t *px, const uint8_t *F, int N, float4 *samples, int *nfg, int *nbg);

// Один цвет знака на фоне-градиенте: знак = «похож на цвет fg» (маска Tinted), Dark = знак, залитый градиентом фона между четырьмя углами.
// scale — расстояние, на котором сходство с fg пропадает. tint (w*h байт) и dark (w*h*4, premultiplied) могут быть NULL.
void iso_mask_single_on_gradient(int w, int h, const uint8_t *px, uint8_t *tint, uint8_t *dark, float4 fg, float scale);

// Осветление цвета для тёмного фона и решение «делать ли Dark» для однотонных знака и фона.
int iso_should_generate_dark(int enhance, float4 *out, float4 fg, float4 bg);
// Дополнительные признаки флагов (радиус 1 и 2 вокруг «внутренних» пикселей).
void iso_flag_more_confidence(int w, int h, uint8_t *F);    // бит 0x4: все соседи 3×3 внутренние
void iso_flag_extra_confidence(int w, int h, uint8_t *F);   // бит 0x8: вся окрестность радиуса 2 (ромб) внутренняя

// Разделение иконки. px — RGBA8 premultiplied w×h; в альфа-канале должна быть маска знака (её строит iso_foreground_mask внутри).
// tint (w*h) и dark (w*h*4) — выходы, любой из них может быть NULL. Возвращает 1 при успехе.
int iso_segment(int strict, int w, int h, uint8_t *px, uint8_t *tint, uint8_t *dark, int colorEnhancement, int recoloring);

// Кластеризация DBSCAN по цветам. labels[i]: номер кластера или -1 (шум). Возвращает число кластеров.
int iso_dbscan(int n, int minPts, const float4 *pts, int *labels, float eps);

// Разложение вектора a по двум направлениям (b — к фону, c — второй цвет) относительно опорного цвета: доля и тон.
void iso_ratio_alpha(float4 a, float4 b, float4 c, float *ratio, float *alpha);
// Помечает (бит 0x80) пиксели фона на границе иконки.
void iso_connected_background(int w, int h, uint8_t *F);
// Признак «глаз»: белое пятно со зрачком и цветной радужкой в одной строке. 1 — найден.
int iso_test_eye(int w, int h, int x, int y, const uint8_t *px, const uint8_t *F);
// Несколько цветов знака на однотонном фоне: tint и dark (любой может быть NULL). ovr — цвет, которым заливается Dark (или NULL).
int iso_fg_multi(int w, int h, int K, const float4 *fg, float4 gw, float4 bg, const uint8_t *px, uint8_t *F, uint8_t *tint, const float4 *ovr, uint8_t *dark);
// Дополнительные флаги для знака-градиента (см. iso_fg_gradient)
void iso_flag_additional_gradient(int w, int h, int grad, const uint8_t *px, const uint8_t *F, uint8_t *out);
// Знак-градиент на однотонном фоне: tint и dark (любой может быть NULL). Возвращает 1 при успехе.
int iso_fg_gradient(int w, int h, float4 gw, float4 bg, int grad, float4 shade, const uint8_t *px, uint8_t *F, const uint8_t *buf, uint8_t *tint, uint8_t *dark);
// Допуск «текстуры» знака (16 — по умолчанию, 1 — строго как в iOS 18, режим «оригинальный рендер»).
void iso_set_texture_scale(int scale);
