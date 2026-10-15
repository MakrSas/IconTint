#pragma once
#include <stdint.h>
#include <stddef.h>

// Загружает arm64-образ системная библиотека iOS 18.6. Возвращает число неразрешённых символов (>=0) или <0 при ошибке.
int islift_init(const char *imagePath);

// Сегментация iOS 18. rgbaPremul: w*h*4 (RGBA8 premultiplied). tintOut: w*h, darkOut: w*h*4.
// Возвращает 1 — strict удалась, 2 — loose удалась, 0 — iOS 18 отказалась.
int islift_compute(int w, int h, const uint8_t *rgbaPremul, uint8_t *tintOut, uint8_t *darkOut,
                   int colorEnhancement, int recoloring, int allowStrict, int allowLoose, char *info, size_t infoLen);
int islift_lighten(float rgba[4]);
int islift_gray_weights(int w, int h, const uint8_t *rgba, float out[3]);
int islift_dim(int w, int h, const uint8_t *rgba, uint8_t *out);
