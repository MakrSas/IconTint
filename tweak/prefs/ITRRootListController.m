// Экран настроек IconTint (Настройки → IconTint). Строки локализуются через Root.strings (en, ru).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Минимальное объявление PSListController: Preferences.framework приватный, поэтому линкуемся без него (dynamic_lookup).
@interface PSListController : UITableViewController {
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface ITRRootListController : PSListController
@end

@implementation ITRRootListController
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}
@end
