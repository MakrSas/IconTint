#import "ITEditing.h"
#import "ITSettings.h"
#import "ITLog.h"
#import "ITCustomizeSheet.h"
#import <objc/runtime.h>
#import <notify.h>
#import <objc/message.h>

@interface SBRootFolderView : UIView
@property (retain, nonatomic) UIButton *widgetButton;
- (void)widgetButtonTriggered:(id)sender;
- (BOOL)isEditing;
@end

// Тексты: на iOS 18 это пункты меню «+» (EDIT_MENU_CUSTOMIZE и виджеты)
static BOOL isRussian(void) { return [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"]; }
static NSString *L_CUSTOMIZE(void) { return isRussian() ? @"Настроить" : @"Customize"; }
static NSString *L_WIDGETS(void) { return isRussian() ? @"Виджеты" : @"Widgets"; }

#pragma mark - Оригинальные символы iOS 18

// Символы SF из iOS 18.6 (в iOS 16 их нет), отрисованы в симуляторе: tools/symbols. Чёрные, @3x, красятся как template.
static UIImage *ITSymbol(NSString *name) {
    NSString *path = [NSString stringWithFormat:@"/var/jb/Library/Application Support/IconTint/%@@3x.png", name];
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    if (!raw.CGImage) return nil;
    return [[UIImage imageWithCGImage:raw.CGImage scale:3 orientation:UIImageOrientationUp] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

#pragma mark - Меню «+» (контекстное меню iOS 18, два пункта)

@interface ITMenuRow : UIControl
@end
@implementation ITMenuRow
- (void)setHighlighted:(BOOL)h { [super setHighlighted:h]; self.backgroundColor = h ? [UIColor colorWithWhite:0 alpha:0.08] : nil; }
@end

@interface ITMenuView : UIView
@property (nonatomic, copy) void (^onCustomize)(void);
@property (nonatomic, copy) void (^onWidgets)(void);
@end
@implementation ITMenuView {
    UIVisualEffectView *_blur;
    NSArray<ITMenuRow *> *_rows;
    UIView *_sep;
}
- (ITMenuRow *)rowWithTitle:(NSString *)title image:(UIImage *)image action:(SEL)sel {
    ITMenuRow *row = [ITMenuRow new];
    [row addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    UILabel *l = [UILabel new]; l.tag = 1; l.text = title; l.font = [UIFont systemFontOfSize:17]; l.textColor = UIColor.blackColor;
    [row addSubview:l];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    icon.tag = 2; icon.tintColor = UIColor.blackColor; icon.contentMode = UIViewContentModeScaleAspectFit;
    [row addSubview:icon];
    return row;
}
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.18; self.layer.shadowRadius = 24; self.layer.shadowOffset = CGSizeMake(0, 8);
        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleExtraLight]];
        _blur.layer.cornerRadius = 13; _blur.clipsToBounds = YES;
        _blur.contentView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.5];
        [self addSubview:_blur];
        UIImage *widgetIcon = ITSymbol(@"widgets") ?: [UIImage systemImageNamed:@"square.grid.2x2"];
        UIImage *customizeIcon = ITSymbol(@"customize") ?: [ITCustomizeSheet customizeMenuIcon];
        ITMenuRow *r1 = [self rowWithTitle:L_CUSTOMIZE() image:customizeIcon action:@selector(tapCustomize)];
        ITMenuRow *r2 = [self rowWithTitle:L_WIDGETS() image:widgetIcon action:@selector(tapWidgets)];
        _rows = @[r1, r2];
        _sep = [UIView new]; _sep.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12];
        for (UIView *v in @[r1, r2, _sep]) [_blur.contentView addSubview:v];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _blur.frame = self.bounds;
    CGFloat w = self.bounds.size.width, rh = self.bounds.size.height / _rows.count;
    for (NSUInteger i = 0; i < _rows.count; i++) {
        ITMenuRow *row = _rows[i];
        row.frame = CGRectMake(0, i * rh, w, rh);
        [row viewWithTag:1].frame = CGRectMake(16, 0, w - 60, rh);
        UIImageView *iv = (UIImageView *)[row viewWithTag:2];
        CGSize is = iv.image.size; CGFloat k = MIN(1, 24 / MAX(is.width, is.height));
        iv.frame = CGRectMake(w - 16 - is.width * k, (rh - is.height * k) / 2, is.width * k, is.height * k);
    }
    _sep.frame = CGRectMake(0, rh - 0.25, w, 0.5);
}
- (void)tapCustomize { if (self.onCustomize) self.onCustomize(); }
- (void)tapWidgets { if (self.onWidgets) self.onWidgets(); }
@end

#pragma mark - Управление меню

static IMP orig_widgetTriggered;
static const void *kMenuKey = &kMenuKey, *kDimKey = &kDimKey;
static const CGFloat kMenuRowHeight = 44;

static void hideMenu(UIView *host, BOOL animated) {
    UIView *menu = objc_getAssociatedObject(host, kMenuKey), *dim = objc_getAssociatedObject(host, kDimKey);
    if (!menu) return;
    objc_setAssociatedObject(host, kMenuKey, nil, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(host, kDimKey, nil, OBJC_ASSOCIATION_RETAIN);
    [UIView animateWithDuration:animated ? 0.2 : 0 animations:^{ menu.alpha = 0; menu.transform = CGAffineTransformMakeScale(0.9, 0.9); }
                     completion:^(BOOL f) { [menu removeFromSuperview]; [dim removeFromSuperview]; }];
}

@interface ITEditingTarget : NSObject
+ (instancetype)shared;
@property (nonatomic, weak) SBRootFolderView *root;
@end
@implementation ITEditingTarget
+ (instancetype)shared { static ITEditingTarget *t; static dispatch_once_t o; dispatch_once(&o, ^{ t = [ITEditingTarget new]; }); return t; }
- (UIView *)host { return self.root.window ?: self.root; }
- (void)showMenuFromButton:(UIView *)button {
    UIView *host = [self host]; if (!host) return;
    if (objc_getAssociatedObject(host, kMenuKey)) { hideMenu(host, YES); return; }
    UIControl *dim = [[UIControl alloc] initWithFrame:host.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addTarget:self action:@selector(dimTapped) forControlEvents:UIControlEventTouchDown];
    [host addSubview:dim];
    CGRect bf = [button convertRect:button.bounds toView:host];
    // Меню выравниваем по краю кнопки «+» (справа на iPhone 8, слева на iPhone X и новее) и не даём выйти за экран
    CGFloat menuW = 250, W = host.bounds.size.width;
    BOOL buttonOnRight = CGRectGetMidX(bf) > W / 2;
    CGFloat x = buttonOnRight ? CGRectGetMaxX(bf) + 8 - menuW : bf.origin.x - 8;
    x = MIN(MAX(x, 8), W - 8 - menuW);
    CGRect frame = CGRectMake(x, CGRectGetMaxY(bf) + 8, menuW, kMenuRowHeight * 2);
    ITMenuView *menu = [[ITMenuView alloc] initWithFrame:CGRectZero];
    __weak ITEditingTarget *ws = self;
    menu.onCustomize = ^{ [ws openCustomize]; };
    menu.onWidgets = ^{ [ws openWidgets]; };
    menu.layer.anchorPoint = CGPointMake(buttonOnRight ? 0.9 : 0.1, 0);
    menu.frame = frame;
    menu.alpha = 0; menu.transform = CGAffineTransformMakeScale(0.6, 0.6);
    [host addSubview:menu];
    objc_setAssociatedObject(host, kMenuKey, menu, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(host, kDimKey, dim, OBJC_ASSOCIATION_RETAIN);
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0 options:0
                     animations:^{ menu.alpha = 1; menu.transform = CGAffineTransformIdentity; } completion:nil];
}
- (void)dimTapped { UIView *h = [self host]; if (h) hideMenu(h, YES); }
- (void)openCustomize {
    UIView *host = [self host]; if (!host) return;
    hideMenu(host, YES);
    [ITCustomizeSheet presentInView:host onChange:^{
        [[ITSettings shared] save];
        notify_post(IT_NOTIFY_RELOAD);
    }];
}
- (void)openWidgets {
    SBRootFolderView *root = self.root; if (!root) return;
    UIView *host = [self host];
    if (host) hideMenu(host, NO);
    // родное действие кнопки «+» (панель виджетов iOS 16)
    ((void (*)(id, SEL, id))orig_widgetTriggered)(root, @selector(widgetButtonTriggered:), root.widgetButton);
}
@end

#pragma mark - Хуки

// Нажатие на родной «+»: вместо панели виджетов показываем меню из двух пунктов.
static void hook_widgetButtonTriggered(SBRootFolderView *self, SEL _cmd, id sender) {
    [ITEditingTarget shared].root = self;
    [[ITEditingTarget shared] showMenuFromButton:[sender isKindOfClass:UIView.class] ? sender : self.widgetButton];
}

// Выход из режима правки закрывает меню и лист.
static IMP orig_updateEditing;
static void hook_updateEditing(SBRootFolderView *self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))orig_updateEditing)(self, _cmd, animated);
    [ITEditingTarget shared].root = self;
    if (![(id)self respondsToSelector:@selector(isEditing)] || ![(SBRootFolderView *)self isEditing]) {
        UIView *host = self.window ?: self;
        hideMenu(host, NO);
        if (self.window) [ITCustomizeSheet dismissAllInView:self.window];
    }
}

void ITEditingInstall(ITHookFn hook) {
    Class rfv = objc_getClass("SBRootFolderView");
    hook(rfv, @selector(widgetButtonTriggered:), (IMP)hook_widgetButtonTriggered, &orig_widgetTriggered);
    hook(rfv, @selector(_updateEditingStateAnimated:), (IMP)hook_updateEditing, &orig_updateEditing);
}

void ITDebugPlus(void) {
    SBRootFolderView *root = [ITEditingTarget shared].root;
    if (!root) { NSLog(@"[IconTint] ITDebugPlus: нет root"); return; }
    hook_widgetButtonTriggered(root, @selector(widgetButtonTriggered:), root.widgetButton);
}
