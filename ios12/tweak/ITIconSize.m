#import "ITIconSize.h"
#import "ITSettings.h"
#import "ITLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Во сколько раз крупнее иконки в режиме Large (iOS 18: около 1.2–1.3)
#define IT_LARGE_SCALE 1.2

@interface SBIconListView : UIView
@property (nonatomic) double iconContentScale;
- (void)setIconsNeedLayout;
- (void)layoutIconsNow;
@end
@interface SBIconView : UIView
- (void)_applyIconLabelAlpha:(double)alpha;
- (double)effectiveIconLabelAlpha;
@end

static BOOL gLarge;   // применённое состояние (его читают хуки)

// Вид относится к рабочему столу или доку (не к папке и не к Spotlight)
static BOOL isHomeListView(UIView *v) {
    return [v isKindOfClass:objc_getClass("SBRootIconListView")] || [v isKindOfClass:objc_getClass("SBDockIconListView")];
}
static BOOL isHomeIconView(UIView *iv) {
    for (UIView *v = iv.superview; v; v = v.superview) if ([v isKindOfClass:objc_getClass("SBIconListView")]) return isHomeListView(v);
    return NO;
}

// Увеличение: sublayerTransform вида иконки (не трогает transform, которым пользуется система при подъёме и перетаскивании)
static CATransform3D largeTransform(BOOL on) { return on ? CATransform3DMakeScale(IT_LARGE_SCALE, IT_LARGE_SCALE, 1) : CATransform3DIdentity; }
static IMP orig_didMoveToWindow;
static void hook_didMoveToWindow(SBIconView *self, SEL _cmd) {
    ((void (*)(id, SEL))orig_didMoveToWindow)(self, _cmd);
    if (self.window && isHomeIconView(self)) self.layer.sublayerTransform = largeTransform(gLarge);
}
static IMP orig_labelAlpha;
static double hook_labelAlpha(SBIconView *self, SEL _cmd) {
    double a = ((double (*)(id, SEL))orig_labelAlpha)(self, _cmd);
    return gLarge && isHomeIconView(self) ? 0 : a;
}

void ITIconSizeInstall(ITHookFn hook) {
    gLarge = [ITSettings shared].largeIcons;
    hook(objc_getClass("SBIconView"), @selector(didMoveToWindow), (IMP)hook_didMoveToWindow, &orig_didMoveToWindow);
    hook(objc_getClass("SBIconView"), @selector(effectiveIconLabelAlpha), (IMP)hook_labelAlpha, &orig_labelAlpha);
}

static void collect(UIView *v, Class c, NSMutableArray *out) {
    if ([v isKindOfClass:c]) { [out addObject:v]; return; }
    for (UIView *s in v.subviews) collect(s, c, out);
}

void ITApplyIconSize(BOOL animated) {
    BOOL want = [ITSettings shared].largeIcons;
    if (want == gLarge) return;
    gLarge = want;
    NSMutableArray *lists = [NSMutableArray array];
    for (UIWindow *w in [UIApplication sharedApplication].windows) collect(w, objc_getClass("SBIconListView"), lists);
    void (^change)(void) = ^{
        for (SBIconListView *lv in lists) {
            if (!isHomeListView(lv)) continue;
            NSMutableArray *ivs = [NSMutableArray array]; collect(lv, objc_getClass("SBIconView"), ivs);
            for (SBIconView *iv in ivs) @try {
                iv.layer.sublayerTransform = largeTransform(want);
                [iv _applyIconLabelAlpha:[iv effectiveIconLabelAlpha]];
            } @catch (NSException *e) {}
        }
    };
    if (animated) [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:change completion:nil];
    else change();
}
