#pragma once
#import <UIKit/UIKit.h>

typedef void (*ITHookFn)(Class, SEL, IMP, IMP *);
// Кнопки «+» / «Готово» в режиме правки, меню «Настроить», лист «Настройка», долгое нажатие на пустое место.
void ITEditingInstall(ITHookFn hook);
void ITReloadIcons(NSString *onlyBundleID);
