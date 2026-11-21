// Developer-only semantic harness. Program-generated images only; no host media,
// private Swift ABI, filesystem path, deletion, or cache-index mutation.
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import "../ScaledRepresentationGeometry.h"

#import "../ScaledRepresentationRebuild.h"

@interface ScaledRepresentationRebuildTests : XCTestCase
@end
@implementation ScaledRepresentationRebuildTests
- (NSData *)axs_cachekeeper_original:(CGSize)size {
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;
    UIImage *image=[[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context){
        [UIColor.redColor setFill];[context fillRect:CGRectMake(0,0,size.width,size.height)];
        [UIColor.blueColor setFill];[context fillRect:CGRectMake(size.width/2,0,size.width/2,size.height)];
    }];return UIImagePNGRepresentation(image);
}
- (void)testSyntheticOriginalRebuildsDecodableRepresentationAndRemainsUnchanged {
    NSData *original=[self axs_cachekeeper_original:CGSizeMake(400,300)],*preserved=[original copy];
    NSDictionary *result=axs_cachekeeper_test_rebuild(original,YES,CGSizeMake(128,128),nil,NSProcessInfo.processInfo.systemUptime+5);
    XCTAssertEqualObjects(result[@"state"],@"rebuildVerified");XCTAssertEqualObjects(result[@"width"],@128);XCTAssertEqualObjects(result[@"height"],@96);
    XCTAssertNotNil([UIImage imageWithData:result[@"jpeg"]]);XCTAssertEqualObjects(original,preserved);
    XCTAssertEqualObjects(result[@"deletionAuthorization"],@"notGranted");
    UIImage *decoded=[UIImage imageWithData:result[@"jpeg"]];
    if(decoded.CGImage) {
        unsigned char pixels[128*96*4]={0};CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGContextRef bitmap=CGBitmapContextCreate(pixels,128,96,8,128*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(space);XCTAssertNotEqual(bitmap,NULL);
        if(bitmap){
            CGContextDrawImage(bitmap,CGRectMake(0,0,128,96),decoded.CGImage);CGContextRelease(bitmap);
            size_t left=(48*128+32)*4,right=(48*128+96)*4;
            XCTAssertGreaterThan(pixels[left],200);XCTAssertLessThan(pixels[left+2],45);
            XCTAssertGreaterThan(pixels[right+2],200);XCTAssertLessThan(pixels[right],45);
        }
    }
}
- (void)testSmallImageIsNotEnlargedAndInvalidInputsNeverProduceReplacement {
    NSData *original=[self axs_cachekeeper_original:CGSizeMake(32,16)];NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+5;
    NSDictionary *small=axs_cachekeeper_test_rebuild(original,YES,CGSizeMake(128,128),nil,deadline);
    XCTAssertEqualObjects(small[@"width"],@32);XCTAssertEqualObjects(small[@"height"],@16);
    XCTAssertEqualObjects(axs_cachekeeper_test_rebuild(original,NO,CGSizeMake(128,128),nil,deadline)[@"state"],@"incompleteOriginal");
    NSData *broken=[@"broken" dataUsingEncoding:NSUTF8StringEncoding],*preserved=[broken copy];
    NSDictionary *invalid=axs_cachekeeper_test_rebuild(broken,YES,CGSizeMake(128,128),nil,deadline);
    XCTAssertEqualObjects(invalid[@"state"],@"decoderFailed");XCTAssertNil(invalid[@"jpeg"]);XCTAssertEqualObjects(broken,preserved);
    XCTAssertEqualObjects(axs_cachekeeper_test_rebuild(original,YES,CGSizeMake(0,128),nil,deadline)[@"state"],@"invalidGeometry");
    XCTAssertEqualObjects(axs_cachekeeper_test_rebuild(original,YES,CGSizeMake(128,128),^BOOL{return YES;},deadline)[@"state"],@"cancelled");
    XCTAssertEqualObjects(axs_cachekeeper_test_rebuild(original,YES,CGSizeMake(128,128),nil,0)[@"state"],@"deadline");
}
- (void)testCancellationAtFinalPublicationKeepsOriginalAndReturnsNoReplacement {
    NSData *original=[self axs_cachekeeper_original:CGSizeMake(400,300)],*preserved=[original copy];
    __block NSUInteger checkpoints=0;
    NSDictionary *result=axs_cachekeeper_test_rebuild(original,YES,CGSizeMake(128,128),^BOOL{return ++checkpoints==5;},NSProcessInfo.processInfo.systemUptime+5);
    XCTAssertEqualObjects(result[@"state"],@"cancelled");XCTAssertNil(result[@"jpeg"]);XCTAssertEqualObjects(original,preserved);
}
- (void)testMultipleFramesRemainUnsupportedAndPreserveOriginal {
    UIImage *frame=[UIImage imageWithData:[self axs_cachekeeper_original:CGSizeMake(32,16)]];
    XCTAssertNotEqual(frame.CGImage,NULL);if(!frame.CGImage)return;
    NSMutableData *animation=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)animation,CFSTR("com.compuserve.gif"),2,NULL);
    XCTAssertNotEqual(destination,NULL);if(!destination)return;
    CGImageDestinationAddImage(destination,frame.CGImage,NULL);
    CGImageDestinationAddImage(destination,frame.CGImage,NULL);
    BOOL encoded=CGImageDestinationFinalize(destination);CFRelease(destination);
    XCTAssertTrue(encoded);if(!encoded)return;
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)animation,NULL);
    XCTAssertNotEqual(source,NULL);if(!source)return;
    XCTAssertEqual(CGImageSourceGetCount(source),2u);CFRelease(source);
    NSData *preserved=[animation copy];
    NSDictionary *result=axs_cachekeeper_test_rebuild(animation,YES,CGSizeMake(128,128),nil,NSProcessInfo.processInfo.systemUptime+5);
    XCTAssertEqualObjects(result[@"state"],@"unsupportedFrames");XCTAssertNil(result[@"jpeg"]);XCTAssertEqualObjects(animation,preserved);
}
@end
