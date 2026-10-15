#pragma once
#import <Foundation/Foundation.h>
// Лог в файл /var/mobile/Library/Caches/com.makr.icontint/log.txt (NSLog на iOS 12 по SSH не прочитать)
void ITLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
#define NSLog ITLog
