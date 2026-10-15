// IconTint: Dark / Tinted иконки iOS 18 в SpringBoard iOS 16 (rootless).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import "ITSettings.h"
#import "ITLog.h"
#import "ITIconStore.h"
#import "ITEditing.h"
#import "ITIconSize.h"
void ITDumpSizeMetrics(void);

// --- Substrate без линковки ---
static void (*pMSHookMessageEx)(Class, SEL, IMP, IMP *);
static void hook(Class c, SEL s, IMP imp, IMP *orig) {
    if (!c || !class_getInstanceMethod(c, s)) { NSLog(@"[IconTint] нет метода %@ %@", c, NSStringFromSelector(s)); return; }
    if (pMSHookMessageEx) pMSHookMessageEx(c, s, imp, orig);
    else { Method m = class_getInstanceMethod(c, s); *orig = method_getImplementation(m); method_setImplementation(m, imp); }
}

// --- Классы SpringBoard iOS 16 ---
typedef struct { CGSize size; CGFloat scale; CGFloat continuousCornerRadius; } SBIconImageInfo;
@interface SBIcon : NSObject
- (void)reloadIconImage;
- (UIImage *)unmaskedIconImageWithInfo:(SBIconImageInfo)info;
@end
@interface SBLeafIcon : SBIcon
@end
@interface SBApplicationIcon : SBLeafIcon
- (NSString *)applicationBundleID;
- (NSString *)leafIdentifier;
@end
@interface SBHIconImageCache : NSObject
- (void)purgeAllCachedImages;
@end
@interface SBIconModel : NSObject
- (NSSet *)leafIcons;
@end
@interface SBHIconManager : NSObject
- (void)setEditing:(BOOL)editing;
@property (nonatomic, readonly) SBHIconImageCache *iconImageCache;
@end
@interface SBIconImageView : UIView
- (void)clearCachedImages;
- (void)updateImageAnimated:(BOOL)animated;
@end
@interface SBIconController : UIViewController
+ (instancetype)sharedInstance;
@property (retain, nonatomic) SBIconModel *model;
@property (nonatomic, readonly) SBHIconManager *iconManager;
@end

static BOOL ITIsAppIcon(id i);
static NSString *ITBundleID(id i);
// Перерисовать иконки (все или одного приложения)
static void collectIconViews(UIView *v, NSMutableArray *out) {
    if ([v isKindOfClass:objc_getClass("SBIconView")]) [out addObject:v];
    for (UIView *s in v.subviews) collectIconViews(s, out);
}

void ITReloadIconsAnimated(NSString *onlyBundleID, BOOL animated) {
    SBIconController *ic = [objc_getClass("SBIconController") sharedInstance];
    // 1. сбрасываем кэши картинок иконок (рабочий стол, док, переключатель, уведомления, виджеты)
    NSMutableArray *caches = [NSMutableArray array];
    @try {
        id mgr = [ic valueForKey:@"iconManager"];
        for (NSString *k in @[@"_iconImageCache", @"_addWidgetSheetIconImageCache"]) { id c = [mgr valueForKey:k]; if (c) [caches addObject:c]; }
        for (NSString *k in @[@"_appSwitcherHeaderIconImageCache", @"_tableUIIconImageCache", @"_notificationIconImageCache"]) { id c = [ic valueForKey:k]; if (c) [caches addObject:c]; }
    } @catch (NSException *e) { NSLog(@"[IconTint] кэши: %@", e); }
    for (SBHIconImageCache *c in caches) [c purgeAllCachedImages];
    // 2. сообщаем иконкам об обновлении
    for (SBIcon *icon in [(SBIconModel *)ic.model leafIcons]) {
        if (!ITIsAppIcon(icon)) continue;
        if (onlyBundleID && ![ITBundleID(icon) isEqualToString:onlyBundleID]) continue;
        [icon reloadIconImage];
    }
    // 3. принудительно перерисовываем видимые иконки (без этого картинка остаётся прежней до респринга);
    //    старая картинка плавно растворяется поверх новой (как смена стиля в iOS 18)
    NSMutableArray *views = [NSMutableArray array];
    for (UIWindow *w in [UIApplication sharedApplication].windows) collectIconViews(w, views);
    for (UIView *iv in views) {
        @try {
            id icon = [iv valueForKey:@"icon"];
            if (!ITIsAppIcon(icon) && ![icon isKindOfClass:objc_getClass("SBFolderIcon")]) continue;
            if (onlyBundleID && ITIsAppIcon(icon) && ![ITBundleID(icon) isEqualToString:onlyBundleID]) continue;
            UIView *imageView = [iv valueForKey:@"_iconImageView"];
            UIView *snap = nil;
            if (animated && imageView.window && imageView.superview && !imageView.hidden && imageView.alpha > 0.01) {
                snap = [imageView snapshotViewAfterScreenUpdates:NO];
                snap.frame = imageView.frame; snap.transform = imageView.transform;
                [imageView.superview insertSubview:snap aboveSubview:imageView];
            }
            if ([imageView respondsToSelector:@selector(clearCachedImages)]) [(SBIconImageView *)imageView clearCachedImages];
            if ([imageView respondsToSelector:@selector(updateImageAnimated:)]) ((void (*)(id, SEL, BOOL))objc_msgSend)(imageView, @selector(updateImageAnimated:), NO);
            [imageView setNeedsDisplay];
            if (snap) [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction
                                       animations:^{ snap.alpha = 0; } completion:^(BOOL f) { [snap removeFromSuperview]; }];
        } @catch (NSException *e) {}
    }
}

void ITReloadIcons(NSString *onlyBundleID) { ITReloadIconsAnimated(onlyBundleID, YES); }

// -[SBLeafIcon generateIconImageWithInfo:] и -[SBIcon unmaskedIconImageWithInfo:]
// Анимация открытия/закрытия приложения берёт немаскированную (квадратную) иконку — её тоже перекрашиваем.
static IMP orig_generateIconImage, orig_unmaskedIcon;
static SBIconImageInfo gHomeInfo;          // последний размер иконки рабочего стола (для превью в листе)
static __thread int gInOwnCall;            // свои вызовы оригиналов не перехватываем

// Иконка приложения: SBApplicationIcon и SBHCalendarApplicationIcon (у календаря свой класс и свои методы генерации)
static BOOL ITIsAppIcon(id i) { Class c = objc_getClass("SBHApplicationIcon"); return c && [i isKindOfClass:c]; }
static NSString *ITBundleID(id i) {
    if ([i respondsToSelector:@selector(applicationBundleID)]) return [i applicationBundleID];
    if ([i respondsToSelector:@selector(leafIdentifier)]) return [i leafIdentifier];
    return nil;
}

static UIImage *styleGenerate(id self, SEL _cmd, SBIconImageInfo info, IMP origGen, IMP origUnm) {
    UIImage *img = ((UIImage *(*)(id, SEL, SBIconImageInfo))origGen)(self, _cmd, info);
    if (!img || !ITIsAppIcon(self) || [[ITSettings shared] effectiveStyle] == ITStyleLight) return img;
    if (info.size.width >= 50 && info.size.width <= 66) gHomeInfo = info;
    @try {
        gInOwnCall++;
        UIImage *unmasked = ((UIImage *(*)(id, SEL, SBIconImageInfo))origUnm)(self, @selector(unmaskedIconImageWithInfo:), info);
        gInOwnCall--;
        UIImage *styled = [[ITIconStore shared] styledImageForBundleID:ITBundleID(self) masked:img unmasked:unmasked];
        if (styled) return styled;
    } @catch (NSException *e) {
        gInOwnCall = 0;
        NSLog(@"[IconTint] %@", e);
    }
    return img;
}

static UIImage *styleUnmasked(id self, SEL _cmd, SBIconImageInfo info, IMP origUnm) {
    UIImage *img = ((UIImage *(*)(id, SEL, SBIconImageInfo))origUnm)(self, _cmd, info);
    if (gInOwnCall || !img || !ITIsAppIcon(self) || [[ITSettings shared] effectiveStyle] == ITStyleLight) return img;
    @try {
        UIImage *styled = [[ITIconStore shared] styledImageForBundleID:ITBundleID(self) masked:nil unmasked:img];
        if (styled) return styled;
    } @catch (NSException *e) { NSLog(@"[IconTint] %@", e); }
    return img;
}

static IMP orig_generateCal, orig_unmaskedCal;
static UIImage *hook_generateIconImage(id self, SEL _cmd, SBIconImageInfo info) { return styleGenerate(self, _cmd, info, orig_generateIconImage, orig_unmaskedIcon); }
static UIImage *hook_unmaskedIcon(id self, SEL _cmd, SBIconImageInfo info) { return styleUnmasked(self, _cmd, info, orig_unmaskedIcon); }
static UIImage *hook_generateCal(id self, SEL _cmd, SBIconImageInfo info) { return styleGenerate(self, _cmd, info, orig_generateCal, orig_unmaskedCal); }
static UIImage *hook_unmaskedCal(id self, SEL _cmd, SBIconImageInfo info) { return styleUnmasked(self, _cmd, info, orig_unmaskedCal); }

// Превью стиля для плитки листа: иконка «Погоды» (в оригинальном рендере iOS 18 — App Store, у Погоды там просто затемнение) в нужном стиле (nil — ещё рендерится / не найдена).
UIImage *ITPreviewIcon(NSInteger styleValue) {
    ITStyle style = (ITStyle)styleValue;
    NSString *previewID = [ITSettings shared].originalRender ? @"com.apple.AppStore" : @"com.apple.weather";
    SBIconController *ic = [objc_getClass("SBIconController") sharedInstance];
    SBApplicationIcon *icon = nil;
    for (SBIcon *i in [(SBIconModel *)ic.model leafIcons])
        if (ITIsAppIcon(i) && [ITBundleID(i) isEqualToString:previewID]) { icon = (SBApplicationIcon *)i; break; }
    if (!icon || !orig_generateIconImage || !orig_unmaskedIcon) return nil;
    SBIconImageInfo info = gHomeInfo.size.width > 0 ? gHomeInfo : (SBIconImageInfo){CGSizeMake(60, 60), UIScreen.mainScreen.scale, 13.5};
    gInOwnCall++;
    UIImage *masked = ((UIImage *(*)(id, SEL, SBIconImageInfo))orig_generateIconImage)(icon, @selector(generateIconImageWithInfo:), info);
    UIImage *unmasked = ((UIImage *(*)(id, SEL, SBIconImageInfo))orig_unmaskedIcon)(icon, @selector(unmaskedIconImageWithInfo:), info);
    gInOwnCall--;
    if (!masked || !unmasked) return nil;
    if (style == ITStyleLight) return masked;
    ITStyle real = style == ITStyleAutomatic ? ITStyleDark : style;
    UIImage *styled = [[ITIconStore shared] styledImageForBundleID:previewID masked:masked unmasked:unmasked style:real];
    if (!styled) return nil;
    if (style != ITStyleAutomatic) return styled;
    // Автоматически: диагональ — светлая слева сверху, тёмная справа снизу
    CGSize sz = masked.size;
    UIGraphicsBeginImageContextWithOptions(sz, NO, masked.scale);
    [masked drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSaveGState(c);
    CGContextMoveToPoint(c, sz.width, 0); CGContextAddLineToPoint(c, sz.width, sz.height); CGContextAddLineToPoint(c, 0, sz.height); CGContextClosePath(c); CGContextClip(c);
    [styled drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    CGContextRestoreGState(c);
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext();
    return out;
}

static void dumpSources(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, NSDictionary *ui) {
    [@"1" writeToFile:@"/var/mobile/Library/Caches/com.makr.icontint/dumpsrc" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{ [[ITIconStore shared] purgeMemory]; ITReloadIcons(nil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Caches/com.makr.icontint/dumpsrc" error:nil]; });
    });
}

static void dbgSize(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, NSDictionary *ui) {
    dispatch_async(dispatch_get_main_queue(), ^{ ITDumpSizeMetrics(); });
}

// Отладка: нажать «+» (itctl plus / ntfy com.makr.icontint/plus)
static void dbgPlus(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, NSDictionary *ui) {
    dispatch_async(dispatch_get_main_queue(), ^{ ITDebugPlus(); });
}

static NSString *lastStyleSig;
static void settingsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, NSDictionary *ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ITSettings *st = [ITSettings shared];
        [st load];
        NSString *sig = [NSString stringWithFormat:@"%ld|%.4f|%.4f|%.4f|%d|%ld", (long)st.style, st.variation, st.luminanceValue, st.saturation, st.originalRender, (long)st.engine];
        BOOL styleChanged = !lastStyleSig || ![sig isEqualToString:lastStyleSig];
        lastStyleSig = sig;
        ITApplyIconSize(YES);   // Small/Large: анимированный пересчёт сетки
        if (styleChanged) {
            [[ITIconStore shared] purgeMemory];
            ITReloadIcons(nil);
        }
    });
}

// Отладка: снимок экрана по уведомлению (ssh: notifyutil -p com.makr.icontint/screenshot)
UIImage *_UICreateScreenUIImage(void);
static void takeScreenshot(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, NSDictionary *ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImage *img = _UICreateScreenUIImage();
        [UIImagePNGRepresentation(img) writeToFile:@"/var/mobile/Library/Caches/com.makr.icontint/screen.png" atomically:YES];
        NSLog(@"[IconTint] скриншот %.0fx%.0f", img.size.width * img.scale, img.size.height * img.scale);
    });
}

// Отладка: дерево окон/видов (классы и рамки) в лог
static void dumpViews(UIView *v, int depth, NSMutableString *out) {
    if (depth > 9) return;
    [out appendFormat:@"%*s%@ %@ a=%.2f h=%d\n", depth * 2, "", NSStringFromClass(v.class), NSStringFromCGRect(v.frame), v.alpha, v.hidden];
    for (UIView *s in v.subviews) dumpViews(s, depth + 1, out);
}
static void dumpHierarchy(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, NSDictionary *ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableString *out = [NSMutableString string];
        for (UIWindow *w in [UIApplication sharedApplication].windows) if (!w.hidden) { [out appendFormat:@"WINDOW %@ level=%.0f\n", NSStringFromClass(w.class), w.windowLevel]; dumpViews(w, 1, out); }
        [out writeToFile:@"/var/mobile/Library/Caches/com.makr.icontint/views.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}

// Отладка: войти/выйти из режима правки (itctl edit / itctl unedit)
static void dbgEdit(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, NSDictionary *ui) {
    BOOL on = CFStringHasSuffix(n, CFSTR("/edit"));
    dispatch_async(dispatch_get_main_queue(), ^{ ((void (*)(id, SEL, BOOL))objc_msgSend)([(SBIconController *)[objc_getClass("SBIconController") sharedInstance] iconManager], @selector(setEditing:), on); });
}

// Automatic: проверка смены дня/ночи раз в минуту
static ITStyle lastEffective = -1;
static void automaticTick(void) {
    ITStyle e = [[ITSettings shared] effectiveStyle];
    if ((NSInteger)lastEffective != -1 && e != lastEffective) ITReloadIcons(nil);
    lastEffective = e;
}

__attribute__((constructor)) static void IconTintInit(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        void *sub = dlopen("/var/jb/usr/lib/libsubstrate.dylib", RTLD_LAZY) ?: dlopen("/usr/lib/libsubstrate.dylib", RTLD_LAZY);
        if (sub) pMSHookMessageEx = dlsym(sub, "MSHookMessageEx");
        hook(objc_getClass("SBLeafIcon"), @selector(generateIconImageWithInfo:), (IMP)hook_generateIconImage, &orig_generateIconImage);
        hook(objc_getClass("SBLeafIcon"), @selector(unmaskedIconImageWithInfo:), (IMP)hook_unmaskedIcon, &orig_unmaskedIcon);
        hook(objc_getClass("SBHCalendarApplicationIcon"), @selector(generateIconImageWithInfo:), (IMP)hook_generateCal, &orig_generateCal);
        hook(objc_getClass("SBHCalendarApplicationIcon"), @selector(unmaskedIconImageWithInfo:), (IMP)hook_unmaskedCal, &orig_unmaskedCal);
        [ITIconStore shared].renderedHandler = ^(NSString *bundleID) {
            ITReloadIcons(bundleID);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ITIconRendered" object:nil];   // лист обновит превью
        };
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)settingsChanged,
                                        CFSTR(IT_NOTIFY_RELOAD), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)takeScreenshot,
                                        CFSTR("com.makr.icontint/screenshot"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)dumpHierarchy,
                                        CFSTR("com.makr.icontint/views"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)dbgEdit, CFSTR("com.makr.icontint/edit"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)dbgEdit, CFSTR("com.makr.icontint/unedit"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)dbgPlus, CFSTR("com.makr.icontint/plus"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)dumpSources, CFSTR("com.makr.icontint/dumpsrc"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *t) { automaticTick(); }];
        ITIconSizeInstall(hook);
        {   ITSettings *st = [ITSettings shared];
            lastStyleSig = [NSString stringWithFormat:@"%ld|%.4f|%.4f|%.4f|%d|%ld", (long)st.style, st.variation, st.luminanceValue, st.saturation, st.originalRender, (long)st.engine]; }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)dbgSize, CFSTR("com.makr.icontint/sizedump"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
#ifdef IT_EDITING
        ITEditingInstall(hook);
#endif
        NSLog(@"[IconTint] загружен, стиль %ld", (long)[ITSettings shared].style);
    }
}
