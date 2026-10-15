#pragma once
#import <UIKit/UIKit.h>

// Кэш перекраски: по bundle id и размеру хранит результат ITRender (знак Dark и маску Tinted).
// Рендер идёт в фоне на одной очереди; когда готов — вызывается обработчик на главном потоке.
@interface ITIconStore : NSObject
+ (instancetype)shared;
// Иконка в текущем стиле, если результат уже есть; иначе nil и рендер ставится в очередь.
// masked — системная иконка (её альфа = форма иконки), unmasked — та же без маски.
- (UIImage *)styledImageForBundleID:(NSString *)bundleID masked:(UIImage *)masked unmasked:(UIImage *)unmasked;
@property (nonatomic, copy) void (^renderedHandler)(NSString *bundleID);
- (void)purgeMemory;
@end
