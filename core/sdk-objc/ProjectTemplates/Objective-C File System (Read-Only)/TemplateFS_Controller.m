//
//  �PROJECTNAMEASIDENTIFIER�_Controller.m
//  �PROJECTNAME�
//
//  Created by �FULLUSERNAME� on �DATE�.
//  Copyright �YEAR� �ORGANIZATIONNAME�. All rights reserved.
//
#import "�PROJECTNAMEASIDENTIFIER�_Controller.h"
#import "�PROJECTNAMEASIDENTIFIER�_Filesystem.h"
#import <MacFUSE/MacFUSE.h>

@implementation �PROJECTNAMEASIDENTIFIER�_Controller

- (void)mountFailed:(NSNotification *)notification {
  NSDictionary* userInfo = [notification userInfo];
  NSError* error = [userInfo objectForKey:kGMUserFileSystemErrorKey];
  NSLog(@"kGMUserFileSystem Error: %@, userInfo=%@", error, [error userInfo]);  
  NSRunAlertPanel(@"Mount Failed", [error localizedDescription], nil, nil, nil);
  [[NSApplication sharedApplication] terminate:nil];
}

- (void)didMount:(NSNotification *)notification {
  NSDictionary* userInfo = [notification userInfo];
  NSString* mountPath = [userInfo objectForKey:kGMUserFileSystemMountPathKey];
  NSString* parentPath = [mountPath stringByDeletingLastPathComponent];
  [[NSWorkspace sharedWorkspace] selectFile:mountPath
                   inFileViewerRootedAtPath:parentPath];
}

- (void)didUnmount:(NSNotification*)notification {
  [[NSApplication sharedApplication] terminate:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  [center addObserver:self selector:@selector(mountFailed:)
                 name:kGMUserFileSystemMountFailed object:nil];
  [center addObserver:self selector:@selector(didMount:)
                 name:kGMUserFileSystemDidMount object:nil];
  [center addObserver:self selector:@selector(didUnmount:)
                 name:kGMUserFileSystemDidUnmount object:nil];
  
  NSString* mountPath = @"/Volumes/�PROJECTNAME�";
  fs_delegate_ = [[�PROJECTNAMEASIDENTIFIER�_Filesystem alloc] init];
  fs_ = [[GMUserFileSystem alloc] initWithDelegate:fs_delegate_ isThreadSafe:NO];

  NSMutableArray* options = [NSMutableArray array];
  NSString* volArg = 
    [NSString stringWithFormat:@"volicon=%@", 
     [[NSBundle mainBundle] pathForResource:@"�PROJECTNAME�" ofType:@"icns"]];
  [options addObject:volArg];
  [options addObject:@"volname=�PROJECTNAME�"];
  [options addObject:@"rdonly"];
  [fs_ mountAtPath:mountPath withOptions:options];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [fs_ unmount];
  [fs_ release];
  [fs_delegate_ release];
  return NSTerminateNow;
}

@end
