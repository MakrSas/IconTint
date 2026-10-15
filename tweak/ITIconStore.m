#import "ITIconStore.h"
#import "ITSettings.h"
#import "ITLog.h"
#import "ITRender.h"
#import "islift.h"
#ifdef IT_TWO_ENGINES
#import "isswitch.h"
#endif
#import <zlib.h>

#define IT_CACHE_DIR @"/var/mobile/Library/Caches/com.makr.icontint"
#define IT_CACHE_VERSION 4

// Результат рендера в памяти: 8-битные буферы (знак Dark — RGBA premultiplied, маска Tinted — 1 канал)
@interface ITRendered : NSObject
@property (nonatomic) int size;
@property (nonatomic, strong) NSData *dark;
@property (nonatomic, strong) NSData *tint;
@property (nonatomic) BOOL fallback;   // Tinted = цвет × серый, без тёмного фона (запасной путь iOS 18)
@end
@implementation ITRendered
@end

@implementation ITIconStore {
    dispatch_queue_t _queue;
    NSCache *_mem;
    NSCache *_last;   // последняя собранная картинка по bundle id и размеру — показывается, пока считается новый рендер
    NSMutableSet *_pending;
    NSInteger _readyEngine;   // движок, для которого выполнена инициализация (-1 — ни один)
}

+ (instancetype)shared {
    static ITIconStore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ITIconStore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.makr.icontint.render", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        _mem = [NSCache new];
        _mem.countLimit = 400;
        _last = [NSCache new]; _last.countLimit = 400;
        _pending = [NSMutableSet set];
        _readyEngine = -1;
        [[NSFileManager defaultManager] createDirectoryAtPath:IT_CACHE_DIR withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return self;
}

- (void)purgeMemory { [_mem removeAllObjects]; }

// Пиксели картинки как RGBA premultiplied n×n
static NSData *pixelsOf(UIImage *img, int n) {
    NSMutableData *d = [NSMutableData dataWithLength:(size_t)n * n * 4];
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(d.mutableBytes, n, n, 8, n * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, n, n), img.CGImage);
    CGContextRelease(c); CGColorSpaceRelease(cs);
    return d;
}

- (NSString *)cachePathFor:(NSString *)bundleID size:(int)n source:(NSData *)src {
    uLong crc = crc32(0, src.bytes, (uInt)src.length);
    BOOL orig = [ITSettings shared].originalRender;
    // суффикс «e» — результат открытого движка (без суффикса — iOS 18, как в прежних версиях)
    return [IT_CACHE_DIR stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%d_%08lx_v%d%@%@.bin", bundleID, n, crc, IT_CACHE_VERSION, orig ? @"o" : @"", [ITSettings shared].engine ? @"" : @"e"]];
}

- (ITRendered *)loadFile:(NSString *)path size:(int)n {
    NSData *d = [NSData dataWithContentsOfFile:path];
    size_t need = (size_t)n * n * 5 + 1;
    if (d.length != need) return nil;
    ITRendered *r = [ITRendered new]; r.size = n;
    r.dark = [d subdataWithRange:NSMakeRange(0, (size_t)n * n * 4)];
    r.tint = [d subdataWithRange:NSMakeRange((size_t)n * n * 4, (size_t)n * n)];
    r.fallback = ((const uint8_t *)d.bytes)[need - 1];
    return r;
}

- (ITRendered *)renderSource:(NSData *)src size:(int)n {
    NSInteger engine = [ITSettings shared].engine;
#ifdef IT_TWO_ENGINES
    islift_set_engine((int)engine);
#endif
    if (_readyEngine != engine) {
        int missing = islift_init(NULL);
        if (missing < 0) { NSLog(@"[IconTint] islift_init: %d", missing); return nil; }
        _readyEngine = engine;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef pr = CGDataProviderCreateWithCFData((__bridge CFDataRef)src);
    CGImageRef img = CGImageCreate(n, n, 8, 32, n * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast, pr, NULL, false, kCGRenderingIntentDefault);
    ITRenderResult res;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if ([ITSettings shared].originalRender) ITRenderIconOriginal(img, n, &res);
    else ITRenderIcon(img, n, &res);
    NSLog(@"[IconTint] render %dpx (engine %s): dark=%s tint=%s%s %.0f ms", n, engine ? "iOS 18" : "open", res.darkSegmented ? "segmented" : "own", res.tintSegmented ? "segmented" : "own", res.fallback ? " fallback" : "", (CFAbsoluteTimeGetCurrent() - t) * 1000);
    CGImageRelease(img); CGDataProviderRelease(pr); CGColorSpaceRelease(cs);
    NSMutableData *dark = [NSMutableData dataWithLength:(size_t)n * n * 4], *tint = [NSMutableData dataWithLength:(size_t)n * n];
    uint8_t *dp = dark.mutableBytes, *tp = tint.mutableBytes;
    for (int i = 0; i < n * n * 4; i++) dp[i] = (uint8_t)lroundf(fminf(fmaxf(res.dark[i], 0), 1) * 255);
    for (int i = 0; i < n * n; i++) tp[i] = (uint8_t)lroundf(fminf(fmaxf(res.tint[i], 0), 1) * 255);
    ITRenderResultFree(&res);
    ITRendered *r = [ITRendered new]; r.size = n; r.dark = dark; r.tint = tint; r.fallback = res.fallback;
    return r;
}

// Сборка итоговой иконки: фон Dark (градиент системный компонент) + знак, затем форма системной иконки
- (UIImage *)compose:(ITRendered *)r style:(ITStyle)style masked:(UIImage *)masked scale:(CGFloat)refScale {
    int n = r.size;
    float *bg = malloc(sizeof(float) * n);
    double scale = refScale > 0 ? refScale : 2;
    ITDarkBackground(n, scale, bg);
    CGFloat tr = 0, tg = 0, tb = 0, ta;
    if (style == ITStyleTinted) [[ITSettings shared].tintColor getRed:&tr green:&tg blue:&tb alpha:&ta];
    NSData *shape = masked ? pixelsOf(masked, n) : nil;   // masked == nil: квадратная иконка без маски (для анимации открытия)
    NSMutableData *opaque = nil;
    if (!shape) { opaque = [NSMutableData dataWithLength:(size_t)n * n * 4]; memset(opaque.mutableBytes, 255, opaque.length); shape = opaque; }
    const uint8_t *sp = shape.bytes, *dp = r.dark.bytes, *tp = r.tint.bytes;
    NSMutableData *out = [NSMutableData dataWithLength:(size_t)n * n * 4];
    uint8_t *op = out.mutableBytes;
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        int p = y * n + x; float g = bg[y], rgb[3];
        if (style == ITStyleTinted && r.fallback) {
            float t = tp[p] / 255.0f;   // системный компонент × цвет (CIMultiplyCompositing)
            rgb[0] = tr * t; rgb[1] = tg * t; rgb[2] = tb * t;
        } else if (style == ITStyleTinted) {
            float t = tp[p] / 255.0f;
            rgb[0] = g * (1 - t) + tr * t; rgb[1] = g * (1 - t) + tg * t; rgb[2] = g * (1 - t) + tb * t;
        } else {
            float a = dp[p * 4 + 3] / 255.0f;
            for (int c = 0; c < 3; c++) rgb[c] = dp[p * 4 + c] / 255.0f + g * (1 - a);
        }
        float shapeA = sp[p * 4 + 3] / 255.0f;   // форма системной иконки (premultiplied)
        for (int c = 0; c < 3; c++) op[p * 4 + c] = (uint8_t)lroundf(fminf(rgb[c], 1) * shapeA * 255);
        op[p * 4 + 3] = sp[p * 4 + 3];
    }
    free(bg);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef pr = CGDataProviderCreateWithCFData((__bridge CFDataRef)out);
    CGImageRef img = CGImageCreate(n, n, 8, 32, n * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast, pr, NULL, false, kCGRenderingIntentDefault);
    UIImage *u = [UIImage imageWithCGImage:img scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(img); CGDataProviderRelease(pr); CGColorSpaceRelease(cs);
    return u;
}

- (UIImage *)styledImageForBundleID:(NSString *)bundleID masked:(UIImage *)masked unmasked:(UIImage *)unmasked {
    return [self styledImageForBundleID:bundleID masked:masked unmasked:unmasked style:[[ITSettings shared] effectiveStyle]];
}

- (UIImage *)styledImageForBundleID:(NSString *)bundleID masked:(UIImage *)masked unmasked:(UIImage *)unmasked style:(ITStyle)style {
    if (style == ITStyleLight || style == ITStyleAutomatic || !bundleID || !unmasked) return nil;
    UIImage *ref = masked ?: unmasked;
    int n = (int)lround(ref.size.width * ref.scale);
    if (n < 16 || n > 512) return nil;
    NSString *key = [NSString stringWithFormat:@"%@_%d_%d_%ld", bundleID, n, [ITSettings shared].originalRender, (long)[ITSettings shared].engine];
    ITRendered *r = [_mem objectForKey:key];
    if (!r) {
        NSData *src = pixelsOf(unmasked, n);
        // отладка: выгрузка исходника, если есть файл-флаг dumpsrc
        NSString *dumpDir = [IT_CACHE_DIR stringByAppendingPathComponent:@"src"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:[IT_CACHE_DIR stringByAppendingPathComponent:@"dumpsrc"]]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:dumpDir withIntermediateDirectories:YES attributes:nil error:nil];
            int32_t hdr[2] = {n, n}; NSMutableData *f = [NSMutableData dataWithBytes:hdr length:8]; [f appendData:src];
            [f writeToFile:[dumpDir stringByAppendingPathComponent:[bundleID stringByAppendingString:@".rgba"]] atomically:YES];
        }
        NSString *path = [self cachePathFor:bundleID size:n source:src];
        r = [self loadFile:path size:n];
        if (r) [_mem setObject:r forKey:key];
        else {
            UIImage *prev = [_last objectForKey:[NSString stringWithFormat:@"%@_%d_%d", bundleID, n, masked ? 1 : 0]];
            @synchronized (_pending) { if ([_pending containsObject:key]) return prev; [_pending addObject:key]; }
            dispatch_async(_queue, ^{
                ITRendered *nr = [self renderSource:src size:n];
                if (nr) {
                    NSMutableData *file = [nr.dark mutableCopy]; [file appendData:nr.tint];
                    uint8_t flag = nr.fallback; [file appendBytes:&flag length:1];
                    [file writeToFile:path atomically:YES];
                    [self->_mem setObject:nr forKey:key];
                }
                @synchronized (self->_pending) { [self->_pending removeObject:key]; }
                dispatch_async(dispatch_get_main_queue(), ^{ if (nr && self.renderedHandler) self.renderedHandler(bundleID); });
            });
            return prev;
        }
    }
    UIImage *out = [self compose:r style:style masked:masked scale:ref.scale];
    if (out) [_last setObject:out forKey:[NSString stringWithFormat:@"%@_%d_%d", bundleID, n, masked ? 1 : 0]];
    return out;
}

@end
