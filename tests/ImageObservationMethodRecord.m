// This fixture is compiled without ARC: Class metadata must reach the gate
// without Foundation retaining it and triggering +initialize during preparation.
#import "ImageObservationMethodRecord.h"

@interface AxsCacheKeeperObservationMethodDictionary : NSDictionary {
    Class _owner;
    NSDictionary *_metadata;
}
- (instancetype)initWithOwner:(Class)owner selector:(SEL)selector implementation:(IMP)implementation;
@end

@implementation AxsCacheKeeperObservationMethodDictionary
- (instancetype)initWithOwner:(Class)owner selector:(SEL)selector implementation:(IMP)implementation {
    id objects[]={owner,NSStringFromSelector(selector),[NSValue valueWithPointer:(const void *)implementation]};
    id keys[]={@"class",@"selector",@"implementation"};
    return [self initWithObjects:objects forKeys:keys count:3];
}
- (instancetype)init {return [self initWithObjects:NULL forKeys:NULL count:0];}
- (instancetype)initWithObjects:(const id [])objects forKeys:(const id<NSCopying> [])keys count:(NSUInteger)count {
    // A class-cluster subclass owns its storage; the superclass initializer
    // would route through a Foundation store that retains Class values.
    NSMutableDictionary *metadata=[[NSMutableDictionary alloc] init];
    for (NSUInteger i=0;i<count;i++) {
        if ([(id)keys[i] isEqual:@"class"]) _owner=objects[i];
        else [metadata setObject:objects[i] forKey:keys[i]];
    }
    _metadata=metadata;
    return self;
}
- (NSUInteger)count {return _metadata.count+(_owner ? 1 : 0);}
- (NSEnumerator *)keyEnumerator {return [(_owner ? [_metadata.allKeys arrayByAddingObject:@"class"] : _metadata.allKeys) objectEnumerator];}
- (id)objectForKey:(id)key {return [key isEqual:@"class"] ? _owner : [_metadata objectForKey:key];}
- (id)objectForKeyedSubscript:(id)key {return [self objectForKey:key];}
- (void)dealloc {[_metadata release];[super dealloc];}
@end

NSDictionary *AxsCacheKeeperObservationMethodRecord(Class owner,SEL selector,IMP expected) {
    return [[[AxsCacheKeeperObservationMethodDictionary alloc] initWithOwner:owner selector:selector implementation:expected] autorelease];
}
