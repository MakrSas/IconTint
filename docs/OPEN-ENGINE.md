# Open segmentation engine / Открытый движок сегментации

> ⚠️ **Vibe-coded / Вайбкод.** This project was written almost entirely by an AI assistant (Claude) with a human only testing and steering it. It is not audited and may have bugs, including crashes of SpringBoard / Safe Mode. Use at your own risk and keep a way to remove the tweak (SSH / Safe Mode).
> Проект почти целиком написан ИИ-ассистентом (Claude), человек его только тестировал и направлял. Код не аудирован, возможны ошибки, в том числе вылеты SpringBoard и Safe Mode. Используйте на свой страх и риск и держите способ удалить твик (SSH / Safe Mode).

EN: `lift/isopen*.c` splits an app icon into glyph and background (Dark image + Tinted mask) with our own code. It was checked bit-for-bit against the system's own implementation on a corpus of real icons, on several thousand resized/recoloured variants and on synthetic icons; no differences were found. The reference code is not part of this repository.

RU: `lift/isopen*.c` отделяет знак от фона (картинка Dark и маска Tinted) нашим собственным кодом. Результат сверялся побитно с системной реализацией на корпусе настоящих иконок, на нескольких тысячах вариантов (другие размеры и цвета) и на синтетических иконках; расхождений не найдено. Эталонного кода в репозитории нет.

| Part | File |
| --- | --- |
| Colour math, contrast, lightening, dimming, gray weights, GMM, statistics | `lift/isopen_math.c` |
| Glyph mask | `lift/isopen_seg.c` |
| Pixel flags, sampling, DBSCAN, all segmentation branches | `lift/isopen_comp.c` |
| Glue (`islift_*` functions) | `lift/isopen.m` |

"Original iOS 18 rendering" uses the strict texture tolerance (`iso_set_texture_scale(1)`); the default rendering uses a relaxed one (16×).
