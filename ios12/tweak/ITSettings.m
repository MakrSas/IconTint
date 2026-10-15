#import "ITSettings.h"
#import <notify.h>
#import "ITLog.h"

// 7 опорных цветов шкалы оттенка (+[PUIDiscreteGradientVariatedCustomStyle discreteGradientVariatedColors], iOS 18.6)
static const double kHueColors[7][3] = {
    {0.91765, 0.25882, 0.23137}, {0.96078, 0.88235, 0.33333}, {0.45882, 0.98431, 0.56863},
    {0.43529, 0.93725, 0.96863}, {0.03922, 0.54902, 0.96078}, {0.75686, 0.39216, 0.94510},
    {1.00000, 0.29804, 0.26275},
};

// +[PUIDiscreteGradientVariatedCustomStyle minLuminanceForStyle:] для variation = -1 + 2i/64 (снято в симуляторе iOS 18.6)
static const double kMinLuminance[65] = {
    0.574510, 0.580779, 0.587150, 0.593626, 0.600210, 0.606904, 0.613711, 0.620634, 0.627675, 0.634839,
    0.642128, 0.644414, 0.635114, 0.636697, 0.651125, 0.666283, 0.682226, 0.699017, 0.716726, 0.735430,
    0.747018, 0.727220, 0.719446, 0.716241, 0.713008, 0.709747, 0.706459, 0.703142, 0.699797, 0.696423,
    0.693019, 0.689586, 0.701961, 0.671334, 0.644386, 0.620491, 0.599158, 0.579995, 0.562689, 0.546981,
    0.532660, 0.519549, 0.507503, 0.504718, 0.520437, 0.538995, 0.561238, 0.588385, 0.622259, 0.665607,
    0.702767, 0.691919, 0.681608, 0.671794, 0.644070, 0.599891, 0.597936, 0.607286, 0.615481, 0.622723,
    0.629170, 0.634945, 0.640148, 0.643630, 0.575194,
};

static double hueOf(double r, double g, double b) {
    double mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b)), d = mx - mn, h;
    if (d < 1e-9) return 0;
    if (mx == r) h = fmod((g - b) / d, 6); else if (mx == g) h = (b - r) / d + 2; else h = (r - g) / d + 4;
    h /= 6; return h < 0 ? h + 1 : h;
}
static double hue2rgb(double p, double q, double t) {
    if (t < 0) t += 1; if (t > 1) t -= 1;
    if (t < 1.0 / 6) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3) return p + (q - p) * (2.0 / 3 - t) * 6;
    return p;
}

@implementation ITSettings

+ (instancetype)shared {
    static ITSettings *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ITSettings new]; [s load]; });
    return s;
}

// Настройки читаем и пишем через CFPreferences (cfprefsd): так значение из «Настроек» доступно сразу, без ожидания записи файла.
static id prefValue(NSString *key) {
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)IT_PREFS_DOMAIN));
    return v;
}

- (void)load {
    CFPreferencesAppSynchronize((__bridge CFStringRef)IT_PREFS_DOMAIN);
    _style = [prefValue(@"style") integerValue];
    id v;
    _variation = (v = prefValue(@"variation")) ? [v doubleValue] : -0.966387;   // как у iOS 18 для розового
    _luminanceValue = (v = prefValue(@"luminanceValue")) ? [v doubleValue] : 0.88;
    _saturation = (v = prefValue(@"saturation")) ? [v doubleValue] : 1.0;
    _largeIcons = [prefValue(@"largeIcons") boolValue];
    _originalRender = (v = prefValue(@"originalRender")) ? [v boolValue] : YES;   // по умолчанию — рендер как в iOS 18
#ifdef IT_TWO_ENGINES
    _engine = (v = prefValue(@"engine")) ? ([v integerValue] ? 1 : 0) : 1;
#else
    _engine = 0;
#endif
    _emptyAreaLongPress = (v = prefValue(@"emptyAreaLongPress")) ? [v boolValue] : YES;
}

- (void)save {
    NSDictionary *d = @{@"style": @(_style), @"variation": @(_variation), @"luminanceValue": @(_luminanceValue), @"saturation": @(_saturation), @"largeIcons": @(_largeIcons)};
    for (NSString *k in d) CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)d[k], (__bridge CFStringRef)IT_PREFS_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)IT_PREFS_DOMAIN);
}

- (ITStyle)effectiveStyle {
    if (_style != ITStyleAutomatic) return _style;
    NSInteger h = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
    return (h >= 19 || h < 7) ? ITStyleDark : ITStyleLight;
}

- (UIColor *)tintColor { return [ITSettings tintColorForVariation:_variation luminanceValue:_luminanceValue saturation:_saturation]; }

// accentColor = HSL(hue(variation), saturation, luminanceValue); hue — из RGB-смеси опорных цветов (проверено по таблице iOS 18.6)
+ (UIColor *)tintColorForVariation:(double)v luminanceValue:(double)L saturation:(double)S {
    double f = (fmin(fmax(v, -1), 1) + 1) * 3; int i = (int)floor(f); if (i >= 6) i = 5; double t = f - i;
    double r = kHueColors[i][0] + (kHueColors[i + 1][0] - kHueColors[i][0]) * t;
    double g = kHueColors[i][1] + (kHueColors[i + 1][1] - kHueColors[i][1]) * t;
    double b = kHueColors[i][2] + (kHueColors[i + 1][2] - kHueColors[i][2]) * t;
    double h = hueOf(r, g, b);
    double q = L < 0.5 ? L * (1 + S) : L + S - L * S, p = 2 * L - q;
    return [UIColor colorWithRed:hue2rgb(p, q, h + 1.0 / 3) green:hue2rgb(p, q, h) blue:hue2rgb(p, q, h - 1.0 / 3) alpha:1];
}

+ (double)minLuminanceForVariation:(double)v {
    double f = (fmin(fmax(v, -1), 1) + 1) * 32; int i = (int)floor(f); if (i >= 64) i = 63; double t = f - i;
    return kMinLuminance[i] + (kMinLuminance[i + 1] - kMinLuminance[i]) * t;
}

@end

#undef NSLog
void ITLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static dispatch_queue_t q; static NSDateFormatter *df; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.makr.icontint.log", DISPATCH_QUEUE_SERIAL); df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss.SSS"; });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], s];
    dispatch_async(q, ^{
        NSString *p = @"/var/mobile/Library/Caches/com.makr.icontint/log.txt";
        [[NSFileManager defaultManager] createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!h) { [line writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
        [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
    });
}
