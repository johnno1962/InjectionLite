//
//  InjectionBoot.m
//
//  This has to be in Objective-C. Creates an
//  instance of InjectionLite which is enough
//  to start a file watcher to inject files.
// 
//  Created by John Holdsworth on 25/02/2023.
//

#import <Foundation/Foundation.h>

@interface InjectionLite: NSObject
@end

@implementation NSObject(InjectionBoot)

+ (void)load {
    static InjectionLite *singleton;
    singleton = [[InjectionLite alloc] init];
}

@end
