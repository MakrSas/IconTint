// Открытый движок: те же функции, что у islift.m, но без чужого кода (публичная сборка).
// СТАТУС: затемнение, веса серого и осветление цвета совпадают с эталоном побитно (проверка: test/unit.sh).
// Маска знака тоже совпадает с эталоном побитово (test/mask.sh). Dark/Tinted (islift_compute) пока заглушка. Цель — результат 1 в 1 с эталоном.
#import <Foundation/Foundation.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>
#import "islift.h"
#import "isopen_math.h"

int islift_init(const char *imagePath) { (void)imagePath; return 0; }

// Мягкая маска знака в альфа-канале rgbaBuf (isopen_seg.c, побитно как в эталоне на всех проверочных иконках).
int islift_mask(int w, int h, uint8_t *rgbaBuf, int strict) {
    return iso_foreground_mask(strict, w, h, rgbaBuf);
}

// Dark + маска Tinted: сначала строгий режим, потом мягкий (как у эталона). Возвращает 1 (строгий), 2 (мягкий) или 0 (отказ).
int islift_compute(int w, int h, const uint8_t *rgbaPremul, uint8_t *tintOut, uint8_t *darkOut,
                   int colorEnhancement, int recoloring, int allowStrict, int allowLoose, char *info, size_t infoLen) {
    if (info && infoLen) info[0] = 0;
    size_t len = (size_t)w * h * 4;
    uint8_t *buf = malloc(len);
    int result = 0;
    for (int strict = 1; strict >= 0 && !result; strict--) {
        if (strict ? !allowStrict : !allowLoose) continue;
        memcpy(buf, rgbaPremul, len);
        if (iso_segment(strict, w, h, buf, tintOut, darkOut, colorEnhancement, recoloring)) result = strict ? 1 : 2;
    }
    free(buf);
    return result;
}

// Осветление цвета знака для тёмного фона (isopen_math.c, побитно как в эталоне)
int islift_lighten(float rgba[4]) {
    float4 out, in = {rgba[0], rgba[1], rgba[2], rgba[3]};
    int ok = iso_lighten(in, &out);
    rgba[0] = out[0]; rgba[1] = out[1]; rgba[2] = out[2]; rgba[3] = out[3];
    return ok;
}

// Веса серого для запасного Tinted
int islift_gray_weights(int w, int h, const uint8_t *rgba, float out[3]) {
    float4 v = iso_gray_weights(w, h, rgba);
    out[0] = v[0]; out[1] = v[1]; out[2] = v[2];
    return 1;
}

// Затемнение иконки целиком (запасной Dark): параметры по умолчанию как в эталоне (пики 0.925, среднее 0.45, мин. коэффициент 0.65)
int islift_dim(int w, int h, const uint8_t *rgba, uint8_t *out) {
    return iso_dim(w, h, rgba, out, 0.925f, 0.45f, 0.65f);
}
