#import "ITIconSize.h"
#import "ITSettings.h"
#import "ITLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

// Во сколько раз крупнее иконки в режиме Large (iOS 18: около 1.2–1.3)
#define IT_LARGE_SCALE 1.2

typedef struct { CGSize size; CGFloat scale; CGFloat continuousCornerRadius; } SBIconImageInfo;

@interface SBIconListView : UIView
- (NSString *)iconLocation;
- (void)setIconsNeedLayout;
- (void)layoutIconsNow;
- (CGSize)iconSpacing;
- (void)setIconSpacing:(CGSize)s;
- (UIEdgeInsets)layoutInsetsForOrientation:(NSInteger)o;
- (NSInteger)orientation;
- (CGSize)effectiveIconSpacing;
- (UIEdgeInsets)additionalLayoutInsets;
@end
@interface SBIconView : UIView
- (NSString *)location;
- (void)_updateLabel;
- (CGSize)iconViewSizeForIconImageSize:(CGSize)s;
@end

static BOOL gLarge;                       // применённое состояние (его читают хуки)
static const void *kTagKey = &kTagKey;    // раскладка помечена: рабочий стол / док

static BOOL isHomeLocation(NSString *loc) {
    return [loc isKindOfClass:NSString.class] && ([loc hasPrefix:@"SBIconLocationRoot"] || [loc isEqualToString:@"SBIconLocationDock"]);
}

// --- Раскладки: помечаем те, что относятся к рабочему столу и доку ---
static IMP orig_layoutDefault, orig_layoutAdjustable;
static id tagLayout(id layout, NSString *loc) {
    if (layout && isHomeLocation(loc)) objc_setAssociatedObject(layout, kTagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return layout;
}
static id hook_layoutDefault(id self, SEL _cmd, NSString *loc) { return tagLayout(((id (*)(id, SEL, id))orig_layoutDefault)(self, _cmd, loc), loc); }
static id hook_layoutAdjustable(id self, SEL _cmd, NSString *loc) { return tagLayout(((id (*)(id, SEL, id))orig_layoutAdjustable)(self, _cmd, loc), loc); }

// --- Размер картинки иконки ---
static IMP orig_infoForClass, orig_info;
static SBIconImageInfo scaled(SBIconImageInfo i) {
    i.size = CGSizeMake(round(i.size.width * IT_LARGE_SCALE), round(i.size.height * IT_LARGE_SCALE));
    i.continuousCornerRadius *= IT_LARGE_SCALE;
    return i;
}
static BOOL layoutIsHome(id layout) { return [objc_getAssociatedObject(layout, kTagKey) boolValue]; }
static SBIconImageInfo hook_info(id self, SEL _cmd) {
    SBIconImageInfo i = ((SBIconImageInfo (*)(id, SEL))orig_info)(self, _cmd);
    return gLarge && layoutIsHome(self) ? scaled(i) : i;
}
static SBIconImageInfo hook_infoForClass(id self, SEL _cmd, NSUInteger cls) {
    SBIconImageInfo i = ((SBIconImageInfo (*)(id, SEL, NSUInteger))orig_infoForClass)(self, _cmd, cls);
    if (!gLarge || !layoutIsHome(self)) return i;
    // увеличиваем только обычную иконку (её размер совпадает с iconImageInfo), не виджеты
    SBIconImageInfo base = ((SBIconImageInfo (*)(id, SEL))orig_info)(self, @selector(iconImageInfo));
    return i.size.width == base.size.width && i.size.height == base.size.height ? scaled(i) : i;
}

// --- Подписи ---
static IMP orig_shouldShowLabel;
static BOOL hook_shouldShowLabel(SBIconView *self, SEL _cmd) {
    BOOL r = ((BOOL (*)(id, SEL))orig_shouldShowLabel)(self, _cmd);
    return r && !(gLarge && isHomeLocation([self location]));
}

void ITIconSizeInstall(ITHookFn hook) {
    gLarge = [ITSettings shared].largeIcons;
    hook(objc_getClass("SBHDefaultIconListLayoutProvider"), @selector(layoutForIconLocation:), (IMP)hook_layoutDefault, &orig_layoutDefault);
    hook(objc_getClass("SBHAdjustableRootIconListLayoutProvider"), @selector(layoutForIconLocation:), (IMP)hook_layoutAdjustable, &orig_layoutAdjustable);
    hook(objc_getClass("SBIconListGridLayout"), @selector(iconImageInfo), (IMP)hook_info, &orig_info);
    hook(objc_getClass("SBIconListGridLayout"), @selector(iconImageInfoForGridSizeClass:), (IMP)hook_infoForClass, &orig_infoForClass);
    hook(objc_getClass("SBIconView"), NSSelectorFromString(@"_shouldShowLabel"), (IMP)hook_shouldShowLabel, &orig_shouldShowLabel);
}

// --- Применение ---
static void collect(UIView *v, Class c, NSMutableArray *out) {
    if ([v isKindOfClass:c]) { [out addObject:v]; return; }
    for (UIView *s in v.subviews) collect(s, c, out);
}

static NSArray *homeListViews(void) {
    NSMutableArray *all = [NSMutableArray array], *out = [NSMutableArray array];
    for (UIWindow *w in [UIApplication sharedApplication].windows) collect(w, objc_getClass("SBIconListView"), all);
    for (SBIconListView *lv in all) if (isHomeLocation([lv iconLocation])) [out addObject:lv];
    return out;
}

static void collectIconViews(UIView *v, NSMutableArray *out) {
    if ([v isKindOfClass:objc_getClass("SBIconView")]) { [out addObject:v]; return; }
    for (UIView *s in v.subviews) collectIconViews(s, out);
}
static NSArray *iconViewsOf(SBIconListView *lv) { NSMutableArray *a = [NSMutableArray array]; collectIconViews(lv, a); return a; }

void ITApplyIconSize(BOOL animated) {
    BOOL want = [ITSettings shared].largeIcons;
    if (want == gLarge) return;
    gLarge = want;
    NSArray *lists = homeListViews();
    NSMutableArray *allViews = [NSMutableArray array], *oldImgs = [NSMutableArray array];
    for (SBIconListView *lv in lists) {
        CGFloat oldImg = 0;
        @try { oldImg = [[[lv valueForKey:@"layoutMetrics"] valueForKey:@"iconImageSize"] CGSizeValue].width; } @catch (NSException *e) {}
        [oldImgs addObject:@(oldImg)];
        @try { [lv setValue:nil forKey:@"_cachedMetrics"]; } @catch (NSException *e) { NSLog(@"[IconTint] _cachedMetrics: %@", e); }
        // Док: интервал задан снаружи (не «автоматический») и сам не пересчитывается — подгоняем под новый размер
        if (![[lv valueForKey:@"automaticallyAdjustsLayoutMetricsToFit"] boolValue]) @try {
            id m = [lv valueForKey:@"layoutMetrics"];
            NSUInteger cols = [[m valueForKey:@"columns"] unsignedIntegerValue];
            CGFloat img = [[m valueForKey:@"iconImageSize"] CGSizeValue].width;
            UIEdgeInsets in = [lv layoutInsetsForOrientation:[lv orientation]];
            if (cols > 1 && img > 0) {
                CGFloat sp = floor((lv.bounds.size.width - in.left - in.right - cols * img) / (cols - 1));
                if (sp > 0) [lv setIconSpacing:CGSizeMake(sp, sp)];
                [lv setValue:nil forKey:@"_cachedMetrics"];
            }
        } @catch (NSException *e) { NSLog(@"[IconTint] spacing: %@", e); }
        NSArray *ivs = iconViewsOf(lv);
        [allViews addObjectsFromArray:ivs];
        if (!want) for (SBIconView *iv in ivs) {   // Small: подпись возвращается и проявляется
            @try { [iv _updateLabel]; UIView *l = [iv valueForKey:@"labelView"]; l.alpha = 0; } @catch (NSException *e) {}
        }
    }
    void (^change)(void) = ^{
        for (NSUInteger k = 0; k < lists.count; k++) {
            SBIconListView *lv = lists[k];
            @try {
                // Размер самой иконки (вида) меняется вместе с картинкой; виджеты (другой размер) не трогаем
                CGFloat oldImg = [oldImgs[k] doubleValue];
                CGFloat newImg = [[[lv valueForKey:@"layoutMetrics"] valueForKey:@"iconImageSize"] CGSizeValue].width;
                for (SBIconView *iv in iconViewsOf(lv)) {
                    CGSize cur = iv.bounds.size;
                    if (oldImg > 0 && fabs(cur.width - oldImg) < 1.5) {
                        CGSize ns = [iv iconViewSizeForIconImageSize:CGSizeMake(newImg, newImg)];
                        iv.bounds = CGRectMake(0, 0, ns.width, ns.height);
                        [iv setNeedsLayout];
                    }
                }
                [lv setIconsNeedLayout]; [lv layoutIconsNow];
            } @catch (NSException *e) { NSLog(@"[IconTint] layout: %@", e); }
        }
        for (SBIconView *iv in allViews) {
            @try { UIView *l = [iv valueForKey:@"labelView"]; l.alpha = want ? 0 : 1; } @catch (NSException *e) {}
        }
        for (UIView *lv in lists) { [lv.superview setNeedsLayout]; [lv.superview layoutIfNeeded]; }
    };
    void (^done)(BOOL) = ^(BOOL f) {
        for (SBIconListView *lv in lists) { @try { [lv setIconsNeedLayout]; [lv layoutIconsNow]; } @catch (NSException *e) {} }   // догоняем док: размер ячеек
        if (!want) return;
        for (SBIconView *iv in allViews) { @try { [iv _updateLabel]; } @catch (NSException *e) {} }
    };
    if (animated)
        [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:change completion:done];
    else { change(); done(YES); }
}

// Отладка: метрики сетки в лог (ntfy com.makr.icontint/sizedump)
void ITDumpSizeMetrics(void) {
    for (SBIconListView *lv in homeListViews()) {
        id m = nil; @try { m = [lv valueForKey:@"layoutMetrics"]; } @catch (NSException *e) {}
        NSArray *ivs = iconViewsOf(lv);
        UIView *first = ivs.firstObject;
        for (NSUInteger k = 0; k < MIN(ivs.count, 5); k++) {
            SBIconView *iv = ivs[k]; UIView *img = nil, *lab = nil;
            @try { img = [iv valueForKey:@"_iconImageView"]; lab = [iv valueForKey:@"labelView"]; } @catch (NSException *e) {}
            NSLog(@"[IconTint]   iv%lu %@ frame=%@ img=%@ label=%@ a=%.2f", (unsigned long)k, NSStringFromClass([[iv valueForKey:@"icon"] class]), NSStringFromCGRect(iv.frame), NSStringFromCGRect(img.frame), lab ? NSStringFromCGRect(lab.frame) : @"-", lab.alpha);
        }
        NSLog(@"[IconTint] spacing=%@ eff=%@ addl=%@ auto=%@", NSStringFromCGSize([lv iconSpacing]), NSStringFromCGSize([lv effectiveIconSpacing]), NSStringFromUIEdgeInsets([lv additionalLayoutInsets]), [lv valueForKey:@"automaticallyAdjustsLayoutMetricsToFit"]);
        NSLog(@"[IconTint] size %@ large=%d frame=%@ ivs=%lu first=%@ metrics=%@", [lv iconLocation], gLarge, NSStringFromCGRect(lv.frame), (unsigned long)ivs.count, first ? NSStringFromCGRect(first.frame) : @"-", m);
    }
}
