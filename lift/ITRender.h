#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

typedef struct {
    int size;          // сторона в пикселях
    float *dark;       // size*size*4, RGBA premultiplied 0..1: знак для Dark (без фона)
    float *tint;       // size*size, 0..1: маска для Tinted
    bool darkSegmented;  // Dark сделан кодом iOS 18 (иначе — наша запасная формула)
    bool tintSegmented;
    bool fallback;     // знак не отделяется: dark = затемнённая иконка (системный компонент),
                       // tint = серый по весам iOS 18, итог Tinted = цвет × серый (без тёмного фона)
} ITRenderResult;

// Иконка без маски (квадрат) -> Dark/Tinted размером w×w. Нужен islift_init().
int ITRenderIcon(CGImageRef icon, int w, ITRenderResult *out);
// «Оригинальный рендер iOS 18»: сегментация iOS 18 на родном размере без нашей доводки, при отказе — запасной путь iOS 18.
int ITRenderIconOriginal(CGImageRef icon, int w, ITRenderResult *out);
void ITRenderResultFree(ITRenderResult *r);

// Фон Dark: h строк сверху вниз, серый 0..1. scale — масштаб экрана (пиксели на точку).
void ITDarkBackground(int h, double scale, float *rowsTopToBottom);
