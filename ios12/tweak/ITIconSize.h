#pragma once
#import <UIKit/UIKit.h>
#import "ITEditing.h"

// Small / Large: крупные иконки без подписей (рабочий стол и док), как в iOS 18.
void ITIconSizeInstall(ITHookFn hook);
// Привести рабочий стол к ITSettings.largeIcons; при изменении — анимированный пересчёт.
void ITApplyIconSize(BOOL animated);
