// IconTint: Dark / Tinted иконки iOS 18 в SpringBoard iOS 12.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import "ITSettings.h"
#import "ITLog.h"
#import "ITIconStore.h"
#import "ITEditing.h"

// --- Substrate без линковки ---
static void (*pMSHookMessageEx)(Class, SEL, IMP, IMP *);
static void hook(Class c, SEL s, IMP imp, IMP *orig) {
    if (!c || !class_getInstanceMethod(c, s)) { NSLog(@"[IconTint] нет метода %@ %@", c, NSStringFromSelector(s)); return; }
    if (pMSHookMessageEx) pMSHookMessageEx(c, s, imp, orig);
    else { Method m = class_getInstanceMethod(c, s); *orig = method_getImplementation(m); method_setImplementation(m, imp); }
}

// --- Классы SpringBoard iOS 12 ---
@interface SBIcon : NSObject
- (void)reloadIconImagePurgingImageCache:(BOOL)purge;
@end
@interface SBLeafIcon : SBIcon
@end
@interface SBApplicationIcon : SBLeafIcon
- (NSString *)applicationBundleID;
- (UIImage *)getUnmaskedIconImage:(int)format;
@end
@interface SBIconModel : NSObject
- (NSSet *)leafIcons;
@end
@interface SBIconController : UIViewController
+ (instancetype)sharedInstance;
@property (retain, nonatomic) SBIconModel *model;
@end

// Перерисовать иконки (все или одного приложения)
void ITReloadIcons(NSString *onlyBundleID) {
    SBIconModel *model = (SBIconModel *)[(SBIconController *)[objc_getClass("SBIconController") sharedInstance] model];
    for (SBIcon *icon in [model leafIcons]) {
        if (![icon isKindOfClass:objc_getClass("SBApplicationIcon")]) continue;
        if (onlyBundleID && ![[(SBApplicationIcon *)icon applicationBundleID] isEqualToString:onlyBundleID]) continue;
        [icon reloadIconImagePurgingImageCache:YES];
    }
}

// -[SBApplicationIcon generateIconImage:]
static IMP orig_generateIconImage;
static UIImage *hook_generateIconImage(SBApplicationIcon *self, SEL _cmd, int format) {
    UIImage *img = ((UIImage *(*)(id, SEL, int))orig_generateIconImage)(self, _cmd, format);
    if (!img || [[ITSettings shared] effectiveStyle] == ITStyleLight) return img;
    @try {
        UIImage *unmasked = [self getUnmaskedIconImage:format];
        UIImage *styled = [[ITIconStore shared] styledImageForBundleID:[self applicationBundleID] masked:img unmasked:unmasked];
        if (styled) return styled;
    } @catch (NSException *e) {
        NSLog(@"[IconTint] %@", e);
    }
    return img;
}

static void dumpSources(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, NSDictionary *ui) {
    [@"1" writeToFile:@"/var/mobile/Library/Caches/com.makr.icontint/dumpsrc" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{ [[ITIconStore shared] purgeMemory]; ITReloadIcons(nil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Caches/com.makr.icontint/dumpsrc" error:nil]; });
    });
}

static void settingsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, NSDictionary *ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ITSettings shared] load];
        [[ITIconStore shared] purgeMemory];
        ITReloadIcons(nil);
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
    dispatch_async(dispatch_get_main_queue(), ^{ ((void (*)(id, SEL, BOOL))objc_msgSend)([objc_getClass("SBIconController") sharedInstance], @selector(setIsEditing:), on); });
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
        void *sub = dlopen("/usr/lib/libsubstrate.dylib", RTLD_LAZY);
        if (sub) pMSHookMessageEx = dlsym(sub, "MSHookMessageEx");
        hook(objc_getClass("SBApplicationIcon"), @selector(generateIconImage:), (IMP)hook_generateIconImage, &orig_generateIconImage);
        [ITIconStore shared].renderedHandler = ^(NSString *bundleID) { ITReloadIcons(bundleID); };
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)settingsChanged,
                                        CFSTR(IT_NOTIFY_RELOAD), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)takeScreenshot,
                                        CFSTR("com.makr.icontint/screenshot"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)dumpHierarchy,
                                        CFSTR("com.makr.icontint/views"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)dbgEdit, CFSTR("com.makr.icontint/edit"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)dbgEdit, CFSTR("com.makr.icontint/unedit"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)dumpSources, CFSTR("com.makr.icontint/dumpsrc"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *t) { automaticTick(); }];
        ITEditingInstall(hook);
        NSLog(@"[IconTint] загружен, стиль %ld", (long)[ITSettings shared].style);
    }
}
