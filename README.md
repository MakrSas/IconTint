# IconTint

> ⚠️ **Vibe-coded / Вайбкод.** This project was written almost entirely by an AI assistant (Claude) with a human only testing and steering it. It is not audited and may have bugs, including crashes of SpringBoard / Safe Mode. Use at your own risk and keep a way to remove the tweak (SSH / Safe Mode).
> Проект почти целиком написан ИИ-ассистентом (Claude), человек его только тестировал и направлял. Код не аудирован, возможны ошибки, в том числе вылеты SpringBoard и Safe Mode. Используйте на свой страх и риск и держите способ удалить твик (SSH / Safe Mode).

iOS 18-style **Dark** and **Tinted** app icons and the iOS 18 *Customize* sheet for jailbroken iOS 15–16 (rootless, tested on iPhone 8 / iOS 16.7, Dopamine; iOS 12 — see below).
Тёмные и тонированные иконки в стиле iOS 18 и лист «Настроить» для джейлбрейка iOS 15–16 (rootless).

- The home-screen "+" opens a two-item menu: Customize / Widgets.
- Light, Dark, Automatic, Tinted; tint colour and brightness; Small/Large icons; settings in Settings → IconTint (en, ru).
- Rendering: *Original iOS 18 rendering* (default) or our own rendering with extra clean-up.
- Segmentation (glyph vs. background) is done by our own open engine in `lift/isopen*.c`; no Apple code or data is included. See `docs/OPEN-ENGINE.md`.

## Install
Add the repo `https://makrsas.github.io/repo/` to Sileo and install **IconTint**.

## Build
Requires: Xcode (iPhoneOS SDK), `ldid`, `dpkg`.
```sh
scripts/build.sh public     # → packages/com.makr.icontint_<version>_iphoneos-arm64.deb
```

## iOS 12
`ios12/` builds the same tweak for iOS 12–14 (rootful, tested on iPhone 6 / iOS 12.5.7): `ios12/scripts/build.sh` → `com.makr.icontint_<version>_iphoneos-arm.deb`. It shares the render pipeline and the open engine in `lift/`.

## Layout
- `tweak/` — SpringBoard tweak, settings bundle, packaging
- `lift/` — render pipeline (`ITRender.m`) and open segmentation engine
- `assets/icon/` — tweak icon (light/dark)
