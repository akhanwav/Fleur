//
//  XCTestErrorObservationWorkaround.m
//  RivuletTests
//
//  XCTest wraps every test method in +[XCTSwiftErrorObservation
//  observeErrorsInBlock:], which binds a Swift task-local on the main thread
//  for the length of the test. The app's classes are main-actor by default,
//  so their deinit takes the runtime's isolated-deinit path, and freeing one
//  on the main thread outside a task while that binding is live crashes the
//  test host: "pointer being freed was not allocated" in
//  TaskLocal::StopLookupScope (Xcode 26.3, tvOS 26.2 simulator). UIKit frees
//  objects late from the run loop, so the crash hit whichever test was
//  running, not the one that made the object.
//
//  The app never binds a task-local, so this is test-only. Running the block
//  directly removes the binding. A thrown error still fails its test; the
//  failure just no longer names the line that threw.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface RivuletXCTestErrorObservationWorkaround : NSObject
@end

@implementation RivuletXCTestErrorObservationWorkaround

+ (void)load {
    Class cls = NSClassFromString(@"XCTSwiftErrorObservation");
    Method method = cls ? class_getClassMethod(cls, NSSelectorFromString(@"observeErrorsInBlock:")) : NULL;
    if (!method) return;
    IMP passthrough = imp_implementationWithBlock(^id(id _self, void (^block)(void)) {
        block();
        return nil;
    });
    method_setImplementation(method, passthrough);
}

@end
