# Releases and packaging / Выпуск и упаковка

> ⚠️ **Vibe-coded / Вайбкод.** This project was written almost entirely by an AI assistant (Claude) with a human only testing and steering it. It is not audited and may have bugs, including crashes of SpringBoard / Safe Mode. Use at your own risk and keep a way to remove the tweak (SSH / Safe Mode).
> Проект почти целиком написан ИИ-ассистентом (Claude), человек его только тестировал и направлял. Код не аудирован, возможны ошибки, в том числе вылеты SpringBoard и Safe Mode. Используйте на свой страх и риск и держите способ удалить твик (SSH / Safe Mode).

- `com.makr.icontint` is published in the Sileo repo (https://makrsas.github.io/repo/) in two architecture variants / пакет выходит в двух вариантах:
  - `iphoneos-arm64` — rootless, iOS 15+ (build: `scripts/build.sh public`, version 1.0);
  - `iphoneos-arm` — rootful, iOS 12–14 (build: `ios12/scripts/build.sh`, version 1.1, `firmware (<< 15.0)`).
  Sileo picks the variant by device architecture, so the two do not affect each other / Sileo выбирает вариант по архитектуре устройства, они не влияют друг на друга.
- Both share `lift/` (render pipeline and open engine). After any change there, rebuild and republish **both** / после правок в `lift/` пересобирайте и выкладывайте оба.
- Publishing: copy the `.deb` to `debs/` of the repo, run `./update.sh`, commit, push. Replace the old `.deb` of the same architecture.
- Public sources contain no Apple code or data: before pushing, comments are neutralised (no internal class names, no vendor mentions) and reference-dependent tools (loader, disassembly, tests that run the reference) are left out.
- The Sileo repo no longer lists FakeSIM (hidden at the owner's request; sources are kept locally).
