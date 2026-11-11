#pragma once
#import <objc/runtime.h>

// macOS 使用真实 Objective-C runtime 替换方法，以测试缓存策略；不验证 iOS Substrate 注入。
static inline void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method=class_getInstanceMethod(cls,selector);
    if (!method) { *original=NULL; return; }
    *original=method_getImplementation(method);
    class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));
}
