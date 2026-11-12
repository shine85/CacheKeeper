#pragma once
#import <Foundation/Foundation.h>
#include <notify.h>

static inline NSString *axs_cachekeeper_probe_name(NSString *bundle, BOOL response) {
    return [NSString stringWithFormat:@"dev.local.cachekeeper.probe.%@.%@",bundle,response ? @"response" : @"request"];
}
static inline uint64_t axs_cachekeeper_probe_request(uint32_t nonce, NSTimeInterval now) {
    return ((uint64_t)nonce<<32)|(uint32_t)now;
}
static inline BOOL axs_cachekeeper_probe_fresh(uint64_t request, NSTimeInterval now) {
    uint32_t when=(uint32_t)request;
    return (request>>32)!=0 && now>=when && now-when<=300;
}
static inline uint32_t axs_cachekeeper_probe_result(uint16_t stage, uint16_t code) { return ((uint32_t)stage<<16)|code; }
static inline NSString *axs_cachekeeper_probe_description(uint32_t result) {
    unsigned stage=result>>16,code=result&0xffff;
    switch(stage) {
        case 1: return [NSString stringWithFormat:@"已收到 APP 注入响应；libSandy 授权失败（返回 %u：1=服务通信失败，2=profile 未获准）。检查 RootHide 版 libSandy 安装与服务。",code];
        case 2: return [NSString stringWithFormat:@"已收到 APP 注入响应；配置读取失败（Cocoa 错误 %u）。需检查配置路径和沙盒授权；未限制网络缓存。",code];
        case 3: return @"已收到 APP 注入响应；此 APP 总开关未开启，没有限制网络缓存。";
        case 4: return @"已收到 APP 注入响应；当前模式或网络选项未请求禁止磁盘缓存。";
        case 5: return @"已收到 APP 注入响应；已核对标准 NSURLCache 磁盘容量为 0，文件回执也已保存。";
        case 6: return @"已收到 APP 注入响应；NSURLCache 容量设置未生效。";
        case 7: return @"已收到 APP 注入响应；NSURLCache 磁盘容量已为 0，但共享目录中的文件回执写入失败。";
        case 8: return @"已收到 APP 注入响应；此进程没有标准 APP 数据容器，未应用网络限制。";
        case 9: return @"已收到 APP 注入响应；当前未请求网络限制，但恢复 APP 原磁盘容量尚未成功。可重新启动 APP 恢复。";
        default: return @"收到无法识别的诊断状态，未确认限制生效。";
    }
}
