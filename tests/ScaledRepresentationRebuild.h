#pragma once
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import "ScaledRepresentationGeometry.h"

static NSDictionary *axs_cachekeeper_test_rebuild(NSData *original,BOOL complete,CGSize target,
        BOOL (^cancelled)(void),NSTimeInterval deadline) {
    NSString *(^stop)(void)=^NSString *{
        if (cancelled && cancelled()) return @"cancelled";
        return NSProcessInfo.processInfo.systemUptime>=deadline ? @"deadline" : nil;
    };
    NSString *stopped=stop();if(stopped)return @{@"state":stopped};
    if(!complete)return @{@"state":@"incompleteOriginal"};
    if(!original.length||original.length>16*1024*1024)return @{@"state":@"originalUnavailable"};
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)original,NULL);
    if(!source)return @{@"state":@"decoderFailed"};
    NSDictionary *metadata=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
    size_t count=CGImageSourceGetCount(source);CFRelease(source);
    if(count!=1)return @{@"state":@"unsupportedFrames"};
    NSNumber *orientation=metadata[(__bridge NSString *)kCGImagePropertyOrientation];
    if(orientation && orientation.integerValue!=1)return @{@"state":@"unsupportedOrientation"};
    AxsCacheKeeperTestSize size;
    if(!axs_cachekeeper_test_scaled_geometry((AxsCacheKeeperTestSize){[metadata[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue],
        [metadata[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue]},(AxsCacheKeeperTestSize){target.width,target.height},&size))
        return @{@"state":@"invalidGeometry"};
    stopped=stop();if(stopped)return @{@"state":stopped};
    UIImage *image=[UIImage imageWithData:original scale:1];
    if(!image.CGImage||image.imageOrientation!=UIImageOrientationUp)return @{@"state":@"decoderFailed"};
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;format.opaque=NO;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size.width,size.height) format:format];
    UIImage *rendered=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){
        CGContextSetBlendMode(context.CGContext,kCGBlendModeCopy);
        [image drawInRect:CGRectMake(0,0,size.width,size.height) blendMode:kCGBlendModeCopy alpha:1];
    }];
    stopped=stop();if(stopped)return @{@"state":stopped};
    NSMutableData *output=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)output,CFSTR("public.jpeg"),1,NULL);
    if(!destination||!rendered.CGImage){if(destination)CFRelease(destination);return @{@"state":@"encoderFailed"};}
    CGImageDestinationAddImage(destination,rendered.CGImage,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality:@0.5});
    BOOL encoded=CGImageDestinationFinalize(destination);CFRelease(destination);
    if(!encoded)return @{@"state":@"encoderFailed"};
    stopped=stop();if(stopped)return @{@"state":stopped};
    CGImageSourceRef verification=CGImageSourceCreateWithData((__bridge CFDataRef)output,NULL);
    CGImageRef decoded=verification?CGImageSourceCreateImageAtIndex(verification,0,NULL):NULL;
    BOOL valid=decoded&&CGImageGetWidth(decoded)==(size_t)size.width&&CGImageGetHeight(decoded)==(size_t)size.height;
    if(decoded)CGImageRelease(decoded);if(verification)CFRelease(verification);
    if(!valid)return @{@"state":@"verificationFailed"};
    stopped=stop();if(stopped)return @{@"state":stopped};
    return @{@"state":@"rebuildVerified",@"width":@(size.width),@"height":@(size.height),@"jpeg":output,
        @"scope":@"syntheticAspectFitUpOnly",@"deletionAuthorization":@"notGranted"};
}
