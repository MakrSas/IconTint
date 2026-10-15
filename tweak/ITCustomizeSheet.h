#pragma once
#import <UIKit/UIKit.h>

// Лист «Настройка» (Customize) как в iOS 18: Малые/Крупные, Светлые/Темные/Автоматически/Выделение цветом,
// для Tinted — ползунки оттенка и светлоты (PUIStylePickerHomeScreenComponentViewController).
@interface ITCustomizeSheet : UIView
+ (void)presentInView:(UIView *)host onChange:(void (^)(void))onChange;
+ (UIImage *)customizeMenuIcon;
+ (void)dismissAllInView:(UIView *)host;   // закрыть при выходе из правки
@end
