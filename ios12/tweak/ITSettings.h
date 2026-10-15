#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Стили как в листе Customize iOS 18 (порядок кнопок: Light, Dark, Automatic, Tinted)
typedef NS_ENUM(NSInteger, ITStyle) {
    ITStyleLight = 0,      // обычные иконки
    ITStyleDark = 1,
    ITStyleAutomatic = 2,  // днём Light, ночью Dark
    ITStyleTinted = 3,
};

#define IT_PREFS_DOMAIN @"com.makr.icontint"
#define IT_PREFS_PATH @"/var/mobile/Library/Preferences/com.makr.icontint.plist"
#define IT_NOTIFY_RELOAD "com.makr.icontint/reload"

@interface ITSettings : NSObject
+ (instancetype)shared;
@property (nonatomic) ITStyle style;
@property (nonatomic) double variation;       // оттенок, -1…1 (PUIDiscreteGradientVariatedCustomStyle)
@property (nonatomic) double luminanceValue;  // светлота HSL, minLuminance(variation)…1
@property (nonatomic) double saturation;      // 0…1, в листе iOS 18 всегда 1
@property (nonatomic) BOOL largeIcons;        // Small/Large (рабочий стол и док: ITIconSize.m)
@property (nonatomic) NSInteger engine;       // движок сегментации: 0 — открытый (свой код), 1 — iOS 18 (только в приватной сборке IT_TWO_ENGINES)
@property (nonatomic) BOOL originalRender;    // «оригинальный рендер iOS 18» (без нашей доводки)
@property (nonatomic) BOOL emptyAreaLongPress; // долгое нажатие на пустое место — режим правки
- (void)load;
- (void)save;
// Итоговый стиль с учётом Automatic (день/ночь)
- (ITStyle)effectiveStyle;
- (UIColor *)tintColor;
+ (UIColor *)tintColorForVariation:(double)variation luminanceValue:(double)lv saturation:(double)s;
+ (double)minLuminanceForVariation:(double)variation;
@end
