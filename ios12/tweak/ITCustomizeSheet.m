#import "ITCustomizeSheet.h"
#import "ITSettings.h"

static BOOL ru(void) { return [[NSLocale preferredLanguages].firstObject hasPrefix:@"ru"]; }
// PosterUIFoundation / SpringBoardHome iOS 18 (ru/en)
static NSString *styleTitle(ITStyle s) {
    switch (s) {
        case ITStyleLight: return ru() ? @"Светлые" : @"Light";
        case ITStyleDark: return ru() ? @"Темные" : @"Dark";
        case ITStyleAutomatic: return ru() ? @"Автомати­чески" : @"Automatic";
        default: return ru() ? @"Выделе­ние цветом" : @"Tinted";
    }
}

// Шкала оттенка: 7 опорных цветов iOS 18
static NSArray *hueTrackColors(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i <= 12; i++) [a addObject:(id)[ITSettings tintColorForVariation:-1 + i / 6.0 luminanceValue:0.5 saturation:1].CGColor];
    return a;
}

#pragma mark - Ползунок с градиентной дорожкой (PUIStyleUICoordinatorImpl variationSlider)

@interface ITGradientSlider : UIControl
@property (nonatomic) double value;           // 0…1
@property (nonatomic, strong) CAGradientLayer *track;
@property (nonatomic, strong) UIView *thumb;
@property (nonatomic, strong) UIView *thumbFill;
@end
@implementation ITGradientSlider
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _track = [CAGradientLayer layer];
        _track.startPoint = CGPointMake(0, 0.5); _track.endPoint = CGPointMake(1, 0.5);
        [self.layer addSublayer:_track];
        _thumb = [UIView new];
        _thumb.backgroundColor = UIColor.whiteColor;
        _thumb.userInteractionEnabled = NO;
        _thumb.layer.shadowColor = UIColor.blackColor.CGColor; _thumb.layer.shadowOpacity = 0.2;
        _thumb.layer.shadowRadius = 4; _thumb.layer.shadowOffset = CGSizeMake(0, 1);
        _thumbFill = [UIView new]; _thumbFill.userInteractionEnabled = NO;
        [_thumb addSubview:_thumbFill];
        [self addSubview:_thumb];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    _track.frame = self.bounds; _track.cornerRadius = h / 2;
    CGFloat d = h + 2, x = h / 2 + _value * (self.bounds.size.width - h);
    _thumb.bounds = CGRectMake(0, 0, d, d); _thumb.center = CGPointMake(x, h / 2); _thumb.layer.cornerRadius = d / 2;
    _thumbFill.frame = CGRectInset(_thumb.bounds, 3, 3); _thumbFill.layer.cornerRadius = (d - 6) / 2;
}
- (void)setValue:(double)v { _value = fmin(fmax(v, 0), 1); [self setNeedsLayout]; }
- (void)track:(UITouch *)t {
    CGFloat h = self.bounds.size.height;
    self.value = ([t locationInView:self].x - h / 2) / (self.bounds.size.width - h);
    [self layoutIfNeeded];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (BOOL)beginTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { [self track:t]; return YES; }
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g { return NO; }   // чужие жесты над ползунком не начинаются
- (BOOL)continueTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { [self track:t]; return YES; }
- (void)endTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { [self sendActionsForControlEvents:UIControlEventEditingDidEnd]; }
@end

#pragma mark - Плитка стиля (PUIStylePickerHomeScreenItemView)

@interface ITStyleItem : UIControl
@property (nonatomic) ITStyle style;
@property (nonatomic, strong) UIImageView *tile;
@property (nonatomic, strong) UIView *ring;
@property (nonatomic, strong) UILabel *label;
@end
@implementation ITStyleItem
- (instancetype)initWithStyle:(ITStyle)s {
    if ((self = [super initWithFrame:CGRectZero])) {
        _style = s;
        _ring = [UIView new]; _ring.userInteractionEnabled = NO;
        _ring.layer.borderWidth = 3; _ring.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;
        [self addSubview:_ring];
        _tile = [UIImageView new]; _tile.userInteractionEnabled = NO;
        [self addSubview:_tile];
        _label = [UILabel new]; _label.text = styleTitle(s); _label.numberOfLines = 2; _label.textAlignment = NSTextAlignmentCenter;
        _label.font = [UIFont systemFontOfSize:15]; _label.adjustsFontSizeToFitWidth = YES; _label.minimumScaleFactor = 0.8;
        [self addSubview:_label];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, t = 60;
    _tile.frame = CGRectMake((w - t) / 2, 4, t, t); _tile.layer.cornerRadius = 14; _tile.clipsToBounds = YES;
    _ring.frame = CGRectInset(_tile.frame, -4, -4); _ring.layer.cornerRadius = 18;
    _label.frame = CGRectMake(0, CGRectGetMaxY(_tile.frame) + 8, w, 40);
    [_label sizeToFit]; _label.frame = CGRectMake(0, CGRectGetMaxY(_tile.frame) + 8, w, _label.frame.size.height);
}
- (void)setSelected:(BOOL)s {
    [super setSelected:s];
    _ring.hidden = !s;
    _label.textColor = s ? [UIColor colorWithWhite:0.1 alpha:0.9] : [UIColor colorWithWhite:0.1 alpha:0.45];
}
@end

#pragma mark - Лист

@interface ITCustomizeSheet () <UIGestureRecognizerDelegate>
@end

@implementation ITCustomizeSheet {
    UIView *_dim;
    UIVisualEffectView *_panel;
    UISegmentedControl *_size;
    NSArray<ITStyleItem *> *_items;
    ITGradientSlider *_hue, *_lum;
    UIButton *_dropper;
    void (^_onChange)(void);
    CGFloat _panelH;
    BOOL _dismissing;
}

+ (UIImage *)customizeMenuIcon {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(22, 22), NO, 0);
    [[UIColor blackColor] setStroke];
    UIBezierPath *phone = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(5, 2, 12, 18) cornerRadius:3]; phone.lineWidth = 1.5; [phone stroke];
    UIBezierPath *b = [UIBezierPath bezierPath]; [b moveToPoint:CGPointMake(8, 15)]; [b addLineToPoint:CGPointMake(14, 8)]; b.lineWidth = 2; b.lineCapStyle = kCGLineCapRound; [b stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext();
    return img;
}

extern UIImage *ITPreviewIcon(NSInteger style);

// Превью стиля на плитке: иконка «Погоды» (или App Store) в этом стиле; пока рендерится — нарисованная заглушка
- (UIImage *)previewFor:(ITStyle)s {
    UIImage *real = ITPreviewIcon(s);
    if (real) return real;
    CGSize sz = CGSizeMake(60, 60);
    UIGraphicsBeginImageContextWithOptions(sz, YES, 0);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    void (^grad)(UIColor *, UIColor *, CGRect) = ^(UIColor *top, UIColor *bot, CGRect r) {
        CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)@[(id)top.CGColor, (id)bot.CGColor], NULL);
        CGContextSaveGState(c); CGContextClipToRect(c, r);
        CGContextDrawLinearGradient(c, g, CGPointMake(0, r.origin.y), CGPointMake(0, CGRectGetMaxY(r)), 0);
        CGContextRestoreGState(c); CGGradientRelease(g);
    };
    UIColor *dTop = [UIColor colorWithWhite:0.1922 alpha:1], *dBot = [UIColor colorWithWhite:0.0784 alpha:1];
    UIColor *lTop = [UIColor colorWithRed:0.35 green:0.65 blue:1 alpha:1], *lBot = [UIColor colorWithRed:0.1 green:0.4 blue:0.95 alpha:1];
    CGRect all = CGRectMake(0, 0, 60, 60);
    UIBezierPath *glyph = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(19, 19, 22, 22)];
    if (s == ITStyleLight) { grad(lTop, lBot, all); [UIColor.whiteColor setFill]; [glyph fill]; }
    else if (s == ITStyleDark) { grad(dTop, dBot, all); [lTop setFill]; [glyph fill]; }
    else if (s == ITStyleTinted) { grad(dTop, dBot, all); [[ITSettings shared].tintColor setFill]; [glyph fill]; }
    else {
        grad(lTop, lBot, all);
        CGContextSaveGState(c);
        UIBezierPath *half = [UIBezierPath bezierPath]; [half moveToPoint:CGPointMake(60, 0)]; [half addLineToPoint:CGPointMake(60, 60)]; [half addLineToPoint:CGPointMake(0, 60)]; [half closePath];
        [half addClip]; grad(dTop, dBot, all);
        CGContextRestoreGState(c);
        [UIColor.whiteColor setFill]; [glyph fill];
    }
    CGColorSpaceRelease(cs);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext();
    return img;
}

+ (void)presentInView:(UIView *)host onChange:(void (^)(void))onChange {
    ITCustomizeSheet *s = [[ITCustomizeSheet alloc] initWithFrame:host.bounds];
    s->_onChange = [onChange copy];
    [host addSubview:s];
    [s show];
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _dim = [[UIView alloc] initWithFrame:self.bounds];
        _dim.autoresizingMask = self.autoresizingMask;
        [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)]];
        [self addSubview:_dim];

        _panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleExtraLight]];
        _panel.contentView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
        _panel.layer.cornerRadius = 16; _panel.clipsToBounds = YES;
        if (@available(iOS 11.0, *)) _panel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        [self addSubview:_panel];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        pan.delegate = self;
        [_panel addGestureRecognizer:pan];

        _size = [[UISegmentedControl alloc] initWithItems:@[ru() ? @"Малые" : @"Small", ru() ? @"Крупные" : @"Large"]];
        _size.selectedSegmentIndex = [ITSettings shared].largeIcons ? 1 : 0;
        _size.tintColor = [UIColor colorWithWhite:0.15 alpha:0.9];
        [_size addTarget:self action:@selector(sizeChanged) forControlEvents:UIControlEventValueChanged];
        [_panel.contentView addSubview:_size];

        _dropper = [UIButton buttonWithType:UIButtonTypeSystem];
        [_dropper setTitle:@"◉" forState:UIControlStateNormal];
        _dropper.tintColor = [UIColor colorWithWhite:0.15 alpha:0.8];
        _dropper.titleLabel.font = [UIFont systemFontOfSize:20];
        [_dropper addTarget:self action:@selector(pickFromWallpaper) forControlEvents:UIControlEventTouchUpInside];
        [_panel.contentView addSubview:_dropper];

        NSMutableArray *items = [NSMutableArray array];
        for (ITStyle st = ITStyleLight; st <= ITStyleTinted; st++) {
            ITStyleItem *it = [[ITStyleItem alloc] initWithStyle:st];
            [it addTarget:self action:@selector(styleTapped:) forControlEvents:UIControlEventTouchUpInside];
            [_panel.contentView addSubview:it]; [items addObject:it];
        }
        _items = items;

        _hue = [ITGradientSlider new];
        _hue.track.colors = hueTrackColors();
        [_hue addTarget:self action:@selector(slidersChanged) forControlEvents:UIControlEventValueChanged];
        [_hue addTarget:self action:@selector(slidersEnded) forControlEvents:UIControlEventEditingDidEnd];
        _lum = [ITGradientSlider new];
        [_lum addTarget:self action:@selector(slidersChanged) forControlEvents:UIControlEventValueChanged];
        [_lum addTarget:self action:@selector(slidersEnded) forControlEvents:UIControlEventEditingDidEnd];
        [_panel.contentView addSubview:_hue]; [_panel.contentView addSubview:_lum];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(iconRendered) name:@"ITIconRendered" object:nil];
        [self syncFromSettings];
    }
    return self;
}

// Смахивание листа: только вертикальное и не с ползунков/переключателя (иначе ползунок нельзя тянуть)
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    for (UIView *v = t.view; v && v != _panel; v = v.superview)
        if ([v isKindOfClass:[ITGradientSlider class]] || [v isKindOfClass:[UISegmentedControl class]]) return NO;
    return YES;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (![g isKindOfClass:[UIPanGestureRecognizer class]]) return YES;
    CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:self];
    return fabs(v.y) > fabs(v.x);
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)iconRendered { [self syncFromSettings]; }

- (BOOL)tinted { return [ITSettings shared].style == ITStyleTinted; }

- (void)syncFromSettings {
    ITSettings *st = [ITSettings shared];
    for (ITStyleItem *it in _items) { it.selected = it.style == st.style; it.tile.image = [self previewFor:it.style]; }
    _hue.value = (st.variation + 1) / 2;
    double mn = [ITSettings minLuminanceForVariation:st.variation];
    _lum.value = (st.luminanceValue - mn) / (1 - mn);
    // дорожка светлоты: от насыщенного цвета (min) к белому (1)
    _lum.track.colors = @[(id)[ITSettings tintColorForVariation:st.variation luminanceValue:mn saturation:st.saturation].CGColor,
                          (id)[ITSettings tintColorForVariation:st.variation luminanceValue:1 saturation:st.saturation].CGColor];
    _hue.thumbFill.backgroundColor = [ITSettings tintColorForVariation:st.variation luminanceValue:0.5 saturation:1];
    _lum.thumbFill.backgroundColor = st.tintColor;
    BOOL t = [self tinted];
    _hue.hidden = _lum.hidden = _dropper.hidden = !t;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, bottomInset = 0;
    if (@available(iOS 11.0, *)) bottomInset = self.safeAreaInsets.bottom;
    _panelH = ([self tinted] ? 300 : 186) + bottomInset;
    // bounds+center, а не frame: у панели во время показа/закрытия есть transform
    _panel.bounds = CGRectMake(0, 0, W, _panelH + 40);
    _panel.center = CGPointMake(W / 2, self.bounds.size.height - _panelH + (_panelH + 40) / 2);
    _size.frame = CGRectMake((W - 170) / 2, 16, 170, 30);
    _dropper.frame = CGRectMake(W - 52, 14, 36, 34);
    CGFloat itemW = (W - 16) / 4;
    for (NSUInteger i = 0; i < _items.count; i++) _items[i].frame = CGRectMake(8 + i * itemW, 62, itemW, 120);
    _hue.frame = CGRectMake(30, 196, W - 60, 32);
    _lum.frame = CGRectMake(30, 250, W - 60, 32);
}

- (void)show {
    [self layoutIfNeeded];
    _panel.transform = CGAffineTransformMakeTranslation(0, _panelH + 40);
    _dim.backgroundColor = UIColor.clearColor;
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0 options:0 animations:^{
        self->_panel.transform = CGAffineTransformIdentity;
        self->_dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.08];
    } completion:nil];
}

- (void)dismiss {
    if (_dismissing) return;
    _dismissing = YES;
    self.userInteractionEnabled = NO;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn animations:^{
        self->_panel.transform = CGAffineTransformMakeTranslation(0, self->_panelH + 40);
        self->_dim.backgroundColor = UIColor.clearColor;
    } completion:^(BOOL f) { [self removeFromSuperview]; }];
}

+ (void)dismissAllInView:(UIView *)host {
    for (UIView *v in [host.subviews copy]) if ([v isKindOfClass:self]) [(ITCustomizeSheet *)v dismiss];
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGFloat dy = MAX(0, [g translationInView:self].y);
    if (g.state == UIGestureRecognizerStateChanged) _panel.transform = CGAffineTransformMakeTranslation(0, dy);
    else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (dy > 80 || [g velocityInView:self].y > 600) [self dismiss];
        else [UIView animateWithDuration:0.25 animations:^{ self->_panel.transform = CGAffineTransformIdentity; }];
    }
}

- (void)changed { if (_onChange) _onChange(); }

- (void)sizeChanged { [ITSettings shared].largeIcons = _size.selectedSegmentIndex == 1; [self changed]; }

- (void)styleTapped:(ITStyleItem *)it {
    BOOL wasTinted = [self tinted];
    [ITSettings shared].style = it.style;
    [self syncFromSettings];
    if (wasTinted != [self tinted])
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:0 animations:^{ [self layoutIfNeeded]; [self setNeedsLayout]; [self layoutIfNeeded]; } completion:nil];
    [self changed];
}

- (void)slidersChanged {
    ITSettings *st = [ITSettings shared];
    st.variation = _hue.value * 2 - 1;
    double mn = [ITSettings minLuminanceForVariation:st.variation];
    st.luminanceValue = mn + _lum.value * (1 - mn);
    [self syncFromSettings];
    // во время движения перерисовываем не чаще ~12 раз в секунду
    static CFAbsoluteTime last;
    if (CFAbsoluteTimeGetCurrent() - last > 0.08) { last = CFAbsoluteTimeGetCurrent(); [self changed]; }
}
- (void)slidersEnded { [self changed]; }

// Пипетка iOS 18 берёт цвет с обоев; здесь — оттенок из среднего цвета обоев домашнего экрана
- (void)pickFromWallpaper {
    UIView *host = self.superview;
    if (!host) return;
    self.hidden = YES;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(8, 8), YES, 1);
    CGContextScaleCTM(UIGraphicsGetCurrentContext(), 8 / host.bounds.size.width, 8 / host.bounds.size.height);
    [host drawViewHierarchyInRect:host.bounds afterScreenUpdates:NO];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext();
    self.hidden = NO;
    CGFloat r = 0, g = 0, b = 0; uint8_t px[8 * 8 * 4];
    CGContextRef c = CGBitmapContextCreate(px, 8, 8, 8, 32, CGColorSpaceCreateDeviceRGB(), (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(c, CGRectMake(0, 0, 8, 8), img.CGImage); CGContextRelease(c);
    for (int i = 0; i < 64; i++) { r += px[i * 4]; g += px[i * 4 + 1]; b += px[i * 4 + 2]; }
    double hue = 0, s, v; [[UIColor colorWithRed:r / 64 / 255 green:g / 64 / 255 blue:b / 64 / 255 alpha:1] getHue:(CGFloat *)&hue saturation:(CGFloat *)&s brightness:(CGFloat *)&v alpha:NULL];
    // variationForHue: — ближайшая точка шкалы по оттенку
    double best = 0, bestD = 9;
    for (int i = 0; i <= 200; i++) {
        double var = -1 + i / 100.0; CGFloat h2;
        [[ITSettings tintColorForVariation:var luminanceValue:0.5 saturation:1] getHue:&h2 saturation:NULL brightness:NULL alpha:NULL];
        double d = fabs(h2 - hue); d = fmin(d, 1 - d);
        if (d < bestD) { bestD = d; best = var; }
    }
    [ITSettings shared].variation = best;
    [self syncFromSettings];
    [self changed];
}

@end
