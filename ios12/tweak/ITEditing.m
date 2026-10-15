#import "ITEditing.h"
#import "ITSettings.h"
#import "ITLog.h"
#import "ITCustomizeSheet.h"
#import <objc/runtime.h>
#import <notify.h>
#import <objc/message.h>

@interface SBIconController : UIViewController
+ (instancetype)sharedInstance;
- (BOOL)isEditing;
- (void)setIsEditing:(BOOL)editing;
@end
@interface SBRootFolderView : UIView
@property (retain, nonatomic) UIButton *doneButton;
- (UIScrollView *)scrollView;
@end

// Тексты iOS 18 (SpringBoardHome iOS 18): EDIT, DONE, EDIT_MENU_CUSTOMIZE
static BOOL isRussian(void) { return [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"]; }
static NSString *L_EDIT(void) { return isRussian() ? @"+" : @"Edit"; }
static NSString *L_DONE(void) { return isRussian() ? @"Готово" : @"Done"; }
static NSString *L_CUSTOMIZE(void) { return isRussian() ? @"Настроить" : @"Customize"; }

#pragma mark - Кнопка-«пилюля» (SBTitledHomeScreenButton iOS 18)

@interface ITPillButton : UIControl
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIVisualEffectView *blur;
@end
@implementation ITPillButton
- (instancetype)initWithTitle:(NSString *)title {
    if ((self = [super initWithFrame:CGRectZero])) {
        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleExtraLight]];
        _blur.userInteractionEnabled = NO;
        _blur.clipsToBounds = YES;
        _blur.contentView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
        [self addSubview:_blur];
        _label = [UILabel new];
        _label.text = title;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        _label.textColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        [self addSubview:_label];
    }
    return self;
}
- (CGSize)sizeThatFits:(CGSize)s {
    CGSize t = [_label sizeThatFits:CGSizeMake(200, 40)];
    return CGSizeMake(MAX(t.width + 32, 56), 28);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _blur.frame = self.bounds; _blur.layer.cornerRadius = self.bounds.size.height / 2;
    _label.frame = self.bounds;
}
- (void)setHighlighted:(BOOL)h { [super setHighlighted:h]; self.alpha = h ? 0.6 : 1; }
@end

#pragma mark - Меню «+» (контекстное меню iOS 18)

@interface ITMenuView : UIView
@property (nonatomic, copy) void (^onCustomize)(void);
@end
@implementation ITMenuView {
    UIVisualEffectView *_blur;
    UIControl *_row;
}
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.18; self.layer.shadowRadius = 24; self.layer.shadowOffset = CGSizeMake(0, 8);
        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleExtraLight]];
        _blur.layer.cornerRadius = 13; _blur.clipsToBounds = YES;
        _blur.contentView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.5];
        [self addSubview:_blur];
        _row = [UIControl new];
        [_row addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
        [_row addTarget:self action:@selector(down) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [_row addTarget:self action:@selector(up) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
        UILabel *l = [UILabel new]; l.tag = 1; l.text = L_CUSTOMIZE(); l.font = [UIFont systemFontOfSize:17]; l.textColor = UIColor.blackColor;
        [_row addSubview:l];
        UIImageView *icon = [[UIImageView alloc] initWithImage:[ITCustomizeSheet customizeMenuIcon]]; icon.tag = 2;
        [_row addSubview:icon];
        [_blur.contentView addSubview:_row];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _blur.frame = self.bounds; _row.frame = self.bounds;
    [_row viewWithTag:1].frame = CGRectMake(16, 0, self.bounds.size.width - 60, self.bounds.size.height);
    [_row viewWithTag:2].frame = CGRectMake(self.bounds.size.width - 16 - 22, (self.bounds.size.height - 22) / 2, 22, 22);
}
- (void)down { _row.backgroundColor = [UIColor colorWithWhite:0 alpha:0.08]; }
- (void)up { _row.backgroundColor = nil; }
- (void)tap { [self up]; if (self.onCustomize) self.onCustomize(); }
@end

#pragma mark - Управление кнопками на корневой папке

static const void *kEditKey = &kEditKey, *kDoneKey = &kDoneKey, *kMenuKey = &kMenuKey, *kDimKey = &kDimKey, *kLPKey = &kLPKey;

static void hideMenu(UIView *root, BOOL animated) {
    UIView *menu = objc_getAssociatedObject(root, kMenuKey), *dim = objc_getAssociatedObject(root, kDimKey);
    if (!menu) return;
    objc_setAssociatedObject(root, kMenuKey, nil, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(root, kDimKey, nil, OBJC_ASSOCIATION_RETAIN);
    [UIView animateWithDuration:animated ? 0.2 : 0 animations:^{ menu.alpha = 0; menu.transform = CGAffineTransformMakeScale(0.9, 0.9); }
                     completion:^(BOOL f) { [menu removeFromSuperview]; [dim removeFromSuperview]; }];
}

@interface ITEditingTarget : NSObject
+ (instancetype)shared;
@property (nonatomic, weak) SBRootFolderView *root;
@end
@implementation ITEditingTarget
+ (instancetype)shared { static ITEditingTarget *t; static dispatch_once_t o; dispatch_once(&o, ^{ t = [ITEditingTarget new]; }); return t; }
- (void)editTapped:(UIView *)button {
    SBRootFolderView *root = self.root; if (!root) return;
    if (objc_getAssociatedObject(root, kMenuKey)) { hideMenu(root, YES); return; }
    UIControl *dim = [[UIControl alloc] initWithFrame:root.bounds];
    [dim addTarget:self action:@selector(dimTapped) forControlEvents:UIControlEventTouchDown];
    [root addSubview:dim];
    CGRect bf = [button convertRect:button.bounds toView:root];
    ITMenuView *menu = [[ITMenuView alloc] initWithFrame:CGRectMake(MAX(8, bf.origin.x - 8), CGRectGetMaxY(bf) + 8, 250, 44)];
    __weak ITEditingTarget *ws = self;
    menu.onCustomize = ^{ [ws openCustomize]; };
    menu.layer.anchorPoint = CGPointMake(0.1, 0); menu.frame = CGRectMake(MAX(8, bf.origin.x - 8), CGRectGetMaxY(bf) + 8, 250, 44);
    menu.alpha = 0; menu.transform = CGAffineTransformMakeScale(0.6, 0.6);
    [root addSubview:menu];
    objc_setAssociatedObject(root, kMenuKey, menu, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(root, kDimKey, dim, OBJC_ASSOCIATION_RETAIN);
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0 options:0
                     animations:^{ menu.alpha = 1; menu.transform = CGAffineTransformIdentity; } completion:nil];
}
- (void)dimTapped { if (self.root) hideMenu(self.root, YES); }
- (void)doneTapped {
    if (self.root) hideMenu(self.root, NO);
    [[objc_getClass("SBIconController") sharedInstance] setIsEditing:NO];
}
- (void)openCustomize {
    SBRootFolderView *root = self.root; if (!root) return;
    hideMenu(root, YES);
    UIView *host = root.window ?: root;
    [ITCustomizeSheet presentInView:host onChange:^{
        [[ITSettings shared] save];
        notify_post(IT_NOTIFY_RELOAD);
    }];
}
- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || ![ITSettings shared].emptyAreaLongPress) return;
    SBIconController *ic = [objc_getClass("SBIconController") sharedInstance];
    if ([ic isEditing]) return;
    // только по пустому месту: под пальцем не должно быть иконки
    UIView *hit = [g.view hitTest:[g locationInView:g.view] withEvent:nil];
    for (UIView *v = hit; v; v = v.superview) if ([v isKindOfClass:objc_getClass("SBIconView")]) return;
    [ic setIsEditing:YES];
}
@end

// Видна ли родная кнопка Done (на iPhone X / с HomeGesture)
static BOOL nativeDoneVisible(SBRootFolderView *root) {
    UIButton *d = [root respondsToSelector:@selector(doneButton)] ? root.doneButton : nil;
    return d && d.superview && !d.hidden && d.alpha > 0.01;
}

static id gStatusBarAssertion;
static void setStatusBarHidden(BOOL hidden) {
    if (hidden == (gStatusBarAssertion != nil)) return;
    if (!hidden) {
        ((void (*)(id, SEL))objc_msgSend)(gStatusBarAssertion, sel_registerName("invalidate"));
        gStatusBarAssertion = nil;
        return;
    }
    Class A = objc_getClass("SBAppStatusBarSettingsAssertion");
    if (!A) return;
    gStatusBarAssertion = ((id (*)(id, SEL, BOOL, unsigned long long, id))objc_msgSend)([A alloc], sel_registerName("initWithStatusBarHidden:atLevel:reason:"), YES, 0, @"IconTint editing");
    ((void (*)(id, SEL))objc_msgSend)(gStatusBarAssertion, sel_registerName("acquire"));
}

static void updateButtons(SBRootFolderView *root) {
    [ITEditingTarget shared].root = root;
    BOOL editing = [[objc_getClass("SBIconController") sharedInstance] isEditing];
    ITPillButton *edit = objc_getAssociatedObject(root, kEditKey), *done = objc_getAssociatedObject(root, kDoneKey);
    if (editing && !edit) {
        edit = [[ITPillButton alloc] initWithTitle:L_EDIT()];
        [edit addTarget:[ITEditingTarget shared] action:@selector(editTapped:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(root, kEditKey, edit, OBJC_ASSOCIATION_RETAIN);
        done = [[ITPillButton alloc] initWithTitle:L_DONE()];
        [done addTarget:[ITEditingTarget shared] action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(root, kDoneKey, done, OBJC_ASSOCIATION_RETAIN);
        edit.alpha = done.alpha = 0;
        [root addSubview:edit]; [root addSubview:done];
    }
    if (!edit) return;
    CGFloat W = root.bounds.size.width;
    CGSize es = [edit sizeThatFits:CGSizeZero], ds = [done sizeThatFits:CGSizeZero];
    BOOL native = nativeDoneVisible(root);
    if (native) {
        CGRect nf = [root.doneButton.superview convertRect:root.doneButton.frame toView:root];   // наша «+» — зеркально родной кнопке
        edit.frame = CGRectMake(W - CGRectGetMaxX(nf), nf.origin.y + (nf.size.height - es.height) / 2, es.width, es.height);
    } else {
        CGFloat y = 2;  // на месте строки состояния (iOS 18 прячет её в режиме правки)
        edit.frame = CGRectMake(16, y, es.width, es.height);
        done.frame = CGRectMake(W - 16 - ds.width, y, ds.width, ds.height);
    }
    [root bringSubviewToFront:edit]; [root bringSubviewToFront:done];

    // Сетку иконок опускаем, чтобы кнопки её не перекрывали (только в режиме правки, dock не трогаем)
    UIScrollView *sv = [root respondsToSelector:@selector(scrollView)] ? [root scrollView] : nil;
    CGFloat shift = 0;
    if (editing && sv) {
        CGFloat buttonsBottom = CGRectGetMaxY(edit.frame) + 6, iconsTop = CGFLOAT_MAX;
        // верх первой иконки на текущей странице (без текущего сдвига)
        CGAffineTransform saved = sv.transform; sv.transform = CGAffineTransformIdentity;
        for (UIView *list in sv.subviews) for (UIView *iv in list.subviews) {
            if (![iv isKindOfClass:objc_getClass("SBIconView")]) continue;
            CGRect r = [iv convertRect:iv.bounds toView:root];
            if (r.origin.x < -1 || r.origin.x > root.bounds.size.width) continue;
            iconsTop = MIN(iconsTop, r.origin.y);
        }
        sv.transform = saved;
        if (iconsTop == CGFLOAT_MAX) iconsTop = 30;
        shift = MAX(12, buttonsBottom - iconsTop + 8);   // немного вниз всегда + место под кружки «удалить»
    }
    if (sv && fabs(sv.transform.ty - shift) > 0.5)
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ sv.transform = CGAffineTransformMakeTranslation(0, shift); } completion:nil];
    // Видимость всегда из текущего состояния (не из прошлого)
    CGFloat editTarget = editing ? 1 : 0, doneTarget = (editing && !native) ? 1 : 0;
    if (fabs(edit.alpha - editTarget) > 0.01 || fabs(done.alpha - doneTarget) > 0.01)
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ edit.alpha = editTarget; done.alpha = doneTarget; } completion:nil];
    // Строка состояния: прячем, пока на её месте наши кнопки (SBAppStatusBarSettingsAssertion, уровень homescreen)
    setStatusBarHidden(editing && !native);
    if (!editing) { hideMenu(root, NO); if (root.window) [ITCustomizeSheet dismissAllInView:root.window]; }
    edit.userInteractionEnabled = editing; done.userInteractionEnabled = editing && !native;
}

#pragma mark - Хуки

static IMP orig_updateEditing, orig_layout, orig_setIsEditing;
static void hook_updateEditing(SBRootFolderView *self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))orig_updateEditing)(self, _cmd, animated);
    updateButtons(self);
}
static void hook_layout(SBRootFolderView *self, SEL _cmd) {
    ((void (*)(id, SEL))orig_layout)(self, _cmd);
    updateButtons(self);
    if (!objc_getAssociatedObject(self, kLPKey)) {
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[ITEditingTarget shared] action:@selector(longPress:)];
        lp.minimumPressDuration = 0.6;
        lp.cancelsTouchesInView = NO;
        UIView *target = [self respondsToSelector:@selector(scrollView)] ? [self scrollView] : self;
        [target addGestureRecognizer:lp];
        objc_setAssociatedObject(self, kLPKey, lp, OBJC_ASSOCIATION_RETAIN);
    }
}
static IMP orig_setIsEditingFB;
static void hook_setIsEditing(id self, SEL _cmd, BOOL editing) {
    ((void (*)(id, SEL, BOOL))orig_setIsEditing)(self, _cmd, editing);
    SBRootFolderView *root = [ITEditingTarget shared].root;
    if (root) updateButtons(root);
}
static void hook_setIsEditingFB(id self, SEL _cmd, BOOL editing, id fb) {
    ((void (*)(id, SEL, BOOL, id))orig_setIsEditingFB)(self, _cmd, editing, fb);
    SBRootFolderView *root = [ITEditingTarget shared].root;
    if (root) updateButtons(root);
}

void ITEditingInstall(ITHookFn hook) {
    Class rfv = objc_getClass("SBRootFolderView");
    hook(rfv, @selector(_updateEditingStateAnimated:), (IMP)hook_updateEditing, &orig_updateEditing);
    hook(rfv, @selector(layoutSubviews), (IMP)hook_layout, &orig_layout);
    hook(objc_getClass("SBIconController"), @selector(setIsEditing:), (IMP)hook_setIsEditing, &orig_setIsEditing);
    hook(objc_getClass("SBIconController"), sel_registerName("setIsEditing:withFeedbackBehavior:"), (IMP)hook_setIsEditingFB, &orig_setIsEditingFB);
}
