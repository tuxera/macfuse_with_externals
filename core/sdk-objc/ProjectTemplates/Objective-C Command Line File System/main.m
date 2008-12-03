//
//  main.m
//  �PROJECTNAME�
//
//  Created by �FULLUSERNAME� on �DATE�.
//  Copyright �YEAR� �ORGANIZATIONNAME�. All rights reserved.
//
// Compile on the command line as follows:
//  gcc -o "�PROJECTNAME�" �PROJECTNAMEASIDENTIFIER�_Filesystem.m main.m 
//      -framework MacFUSE -framework Foundation
//
#import <Foundation/Foundation.h>
#import <MacFUSE/GMUserFileSystem.h>
#import "�PROJECTNAMEASIDENTIFIER�_Filesystem.h"

int main(int argc, char* argv[]) {
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
  
  NSUserDefaults *args = [NSUserDefaults standardUserDefaults];
  NSString* mountPath = [args stringForKey:@"mountPath"];
  if (!mountPath || [mountPath isEqualToString:@""]) {
    printf("\nUsage: %s -mountPath <path>\n", argv[0]);
    printf("  -mountPath: Mount point to use.\n");
    printf("Ex: %s -mountPath /Volumes/�PROJECTNAME�\n\n", argv[0]);
    return 0;
  }
  
  �PROJECTNAMEASIDENTIFIER�_Filesystem* fs = 
  [[�PROJECTNAMEASIDENTIFIER�_Filesystem alloc] init];
  GMUserFileSystem* userFS = [[GMUserFileSystem alloc] initWithDelegate:fs 
                                                           isThreadSafe:NO];
  
  NSMutableArray* options = [NSMutableArray array];
  // [options addObject:@"rdonly"];  <-- Uncomment to mount read-only.
  
  [userFS mountAtPath:mountPath 
          withOptions:options 
     shouldForeground:YES 
      detachNewThread:NO];
  
  [userFS release];
  [fs release];
  
  [pool release];
  return 0;
}
