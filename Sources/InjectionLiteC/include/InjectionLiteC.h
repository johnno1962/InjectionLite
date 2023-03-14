//
//  InjectionLiteC.h
//
//  Created by John Holdsworth on 13/03/2023.
//

#import <Foundation/Foundation.h>

@interface NSObject(InjectionBoot)
+ (void)runXCTestCase:(Class)aTestCase;
@end
