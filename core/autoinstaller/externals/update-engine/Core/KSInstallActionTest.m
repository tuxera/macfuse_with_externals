// Copyright 2008 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import <SenTestingKit/SenTestingKit.h>
#import "KSInstallAction.h"

#import "KSActionPipe.h"
#import "KSActionProcessor.h"
#import "KSCommandRunner.h"
#import "KSExistenceChecker.h"
#import "KSTicket.h"


@interface KSInstallActionTest : SenTestCase {
 @private
  NSString *successDMGPath_;
  NSString *failureDMGPath_;
  NSString *tryAgainDMGPath_;
  NSString *envVarDMGPath_;
}
@end


@interface KSInstallAction (Friend)
- (NSString *)mountPoint;
@end


// ----------------------------------------------------------------
// Implement KSDownloadActionDelegateMethods.  Keep track of progress.
@interface KSInstallProgressCounter : NSObject {
  NSMutableArray *progressArray_;
}
+ (id)counter;
- (NSArray *)progressArray;
@end

@implementation KSInstallProgressCounter

+ (id)counter {
  return [[[self alloc] init] autorelease];
}

- (id)init {
  if ((self = [super init])) {
    progressArray_ = [[NSMutableArray array] retain];
  }
  return self;
}

- (void)dealloc {
  [progressArray_ release];
  [super dealloc];
}

- (NSArray *)progressArray {
  return progressArray_;
}

- (void)installAction:(KSInstallAction *)action
             progress:(NSNumber *)progress {
  [progressArray_ addObject:progress];
}

@end

// -----------------------------------------------------

// !!!internal knowledge!!!
@interface KSInstallAction (PrivateMethods)
- (void)markProgress:(float)progress;
@end


@implementation KSInstallActionTest

- (void)setUp {
  NSBundle *mainBundle = [NSBundle bundleForClass:[self class]];

  successDMGPath_ = [[mainBundle pathForResource:@"Test-SUCCESS"
                                          ofType:@"dmg"] retain];

  failureDMGPath_ = [[mainBundle pathForResource:@"Test-FAILURE"
                                          ofType:@"dmg"] retain];

  tryAgainDMGPath_ = [[mainBundle pathForResource:@"Test-TRYAGAIN"
                                           ofType:@"dmg"] retain];

  envVarDMGPath_ = [[mainBundle pathForResource:@"Test-ENVVAR"
                                           ofType:@"dmg"] retain];

  STAssertNotNil(successDMGPath_, nil);
  STAssertNotNil(failureDMGPath_, nil);
  STAssertNotNil(tryAgainDMGPath_, nil);
  STAssertNotNil(envVarDMGPath_, nil);

  // Make sure we're always using the default script prefix
  [KSInstallAction setInstallScriptPrefix:nil];
}

- (void)tearDown {
  [successDMGPath_ release];
  [failureDMGPath_ release];
  [tryAgainDMGPath_ release];
}

- (void)testScriptPrefix {
  // Verify that setting a nil prefix falls back to the default
  [KSInstallAction setInstallScriptPrefix:nil];
  NSString *prefix = [KSInstallAction installScriptPrefix];
  STAssertNotNil(prefix, nil);
  STAssertEqualObjects(prefix, @".engine", nil);

  STAssertEqualObjects([KSInstallAction preinstallScriptName],
                       @".engine_preinstall", nil);
  STAssertEqualObjects([KSInstallAction installScriptName],
                       @".engine_install", nil);
  STAssertEqualObjects([KSInstallAction postinstallScriptName],
                       @".engine_postinstall", nil);


  // Now, verify that setting a different prefix works correctly
  [KSInstallAction setInstallScriptPrefix:@".foo"];
  prefix = [KSInstallAction installScriptPrefix];
  STAssertNotNil(prefix, nil);
  STAssertEqualObjects(prefix, @".foo", nil);

  STAssertEqualObjects([KSInstallAction preinstallScriptName],
                       @".foo_preinstall", nil);
  STAssertEqualObjects([KSInstallAction installScriptName],
                       @".foo_install", nil);
  STAssertEqualObjects([KSInstallAction postinstallScriptName],
                       @".foo_postinstall", nil);

  // Reset the class back to the default script prefix
  [KSInstallAction setInstallScriptPrefix:nil];
}

- (void)testCreation {
  KSInstallAction *action = nil;

  action = [[[KSInstallAction alloc] init] autorelease];
  STAssertNil(action, nil);

  action = [[[KSInstallAction alloc] initWithDMGPath:nil
                                              runner:nil
                                       userInitiated:NO
                                          updateInfo:nil] autorelease];
  STAssertNil(action, nil);

  action = [KSInstallAction actionWithDMGPath:nil runner:nil userInitiated:NO];
  STAssertNil(action, nil);

  action = [KSInstallAction actionWithDMGPath:@"blah"
                                       runner:@"foo"
                                userInitiated:NO];
  STAssertNotNil(action, nil);
  STAssertTrue([[action description] length] > 1, nil);

  STAssertEqualObjects([action dmgPath], @"blah", nil);
  STAssertEqualObjects([action runner], @"foo", nil);
  STAssertTrue([action userInitiated] == NO, nil);
}

- (void)testSuccess {
  id<KSCommandRunner> runner = [KSTaskCommandRunner commandRunner];
  STAssertNotNil(runner, nil);

  KSInstallAction *action = nil;
  action = [KSInstallAction actionWithDMGPath:successDMGPath_
                                       runner:runner
                                userInitiated:NO];
  STAssertNotNil(action, nil);

  // Create an action processor and run the action
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:action];
  [ap startProcessing];  // Runs the whole action because our action is sync.

  STAssertFalse([action isRunning], nil);
  STAssertEqualObjects([[action outPipe] contents],
                       [NSNumber numberWithInt:0],
                       nil);
}

- (void)testFailure {
  id<KSCommandRunner> runner = [KSTaskCommandRunner commandRunner];
  STAssertNotNil(runner, nil);

  KSInstallAction *action = nil;
  action = [KSInstallAction actionWithDMGPath:failureDMGPath_
                                       runner:runner
                                userInitiated:NO];
  STAssertNotNil(action, nil);

  // Create an action processor and run the action
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:action];
  [ap startProcessing];  // Runs the whole action because our action is sync.

  STAssertFalse([action isRunning], nil);

  // Make sure we get a script failure code (not zero) from the action.
  int rc = [[[action outPipe] contents] intValue];
  STAssertTrue(rc != 0, nil);
}

- (void)testTryAgain {
  id<KSCommandRunner> runner = [KSTaskCommandRunner commandRunner];
  STAssertNotNil(runner, nil);

  KSInstallAction *action = nil;
  action = [KSInstallAction actionWithDMGPath:tryAgainDMGPath_
                                       runner:runner
                                userInitiated:NO];
  STAssertNotNil(action, nil);

  // Create an action processor and run the action
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:action];
  [ap startProcessing];  // Runs the whole action because our action is sync.

  STAssertFalse([action isRunning], nil);
  STAssertEqualObjects([[action outPipe] contents],
                       [NSNumber numberWithInt:KS_INSTALL_TRY_AGAIN_LATER],
                       nil);
}

- (void)testBogusPath {
  id<KSCommandRunner> runner = [KSTaskCommandRunner commandRunner];
  STAssertNotNil(runner, nil);

  KSInstallAction *action = nil;

  // This should certainly fail since /etc/pass is clearly not a path to a DMG
  action = [KSInstallAction actionWithDMGPath:@"/etc/passwd"
                                       runner:runner
                                userInitiated:NO];
  STAssertNotNil(action, nil);

  // Create an action processor and run the action
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:action];
  [ap startProcessing];  // Runs the whole action because our action is sync.

  STAssertFalse([action isRunning], nil);
  // Make sure we get a script failure code (not zero) from the action.
  int rc = [[[action outPipe] contents] intValue];
  STAssertTrue(rc != 0, nil);
}

- (void)testWithNonExistantPath {
  id<KSCommandRunner> runner = [KSTaskCommandRunner commandRunner];
  STAssertNotNil(runner, nil);

  KSInstallAction *action = nil;

  // This should certainly fail since /etc/pass is clearly not a path to a DMG
  action = [KSInstallAction actionWithDMGPath:@"/path/to/fake/file"
                                       runner:runner
                                userInitiated:NO];
  STAssertNotNil(action, nil);

  // Create an action processor and run the action
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:action];
  [ap startProcessing];  // Runs the whole action because our action is sync.

  STAssertFalse([action isRunning], nil);

  // Make sure we get a script failure code (not zero) from the action.
  int rc = [[[action outPipe] contents] intValue];
  STAssertTrue(rc != 0, nil);
}

- (void)testEnvironmentVariables {
  id<KSCommandRunner> runner = [KSTaskCommandRunner commandRunner];
  STAssertNotNil(runner, nil);

  // Construct a ticket and update info, and then check the values
  // in the three scripts on the disk image.
  // It's the scripts on the disk image which check the values and in
  // the case of error will complain to standard out (which will then
  // get printed by KSInstallAction) and return a non-zero value from
  // the script.
  KSTicket *ticket =
      [KSTicket ticketWithProductID:@"com.google.hasselhoff"
                            version:@"3.14.15.9"
                   existenceChecker:[KSPathExistenceChecker 
                                      checkerWithPath:@"/oombly/foombly"]
                          serverURL:[NSURL URLWithString:@"http://google.com"]];

  KSUpdateInfo *info;
  info = [NSDictionary dictionaryWithObjectsAndKeys:
            @"com.google.hasselhoff", kServerProductID,
            [NSURL URLWithString:@"a://a"], kServerCodebaseURL,
            [NSNumber numberWithInt:2], kServerCodeSize,
            @"zzz", kServerCodeHash,
            @"a://b", kServerMoreInfoURLString,
            [NSNumber numberWithBool:YES], kServerPromptUser,
            [NSNumber numberWithBool:YES], kServerRequireReboot,
            @"/Hassel/Hoff", kServerLocalizationBundle,
            @"1.3.2 (with pudding)", kServerDisplayVersion,
            ticket, kTicket,
            nil];

  KSInstallAction *action = nil;
  action = [KSInstallAction actionWithDMGPath:envVarDMGPath_
                                       runner:runner
                                userInitiated:NO
                                   updateInfo:info];
  STAssertNotNil(action, nil);

  // Create an action processor and run the action
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:action];
  [ap startProcessing];  // Runs the whole action because our action is sync.

  STAssertFalse([action isRunning], nil);
  STAssertEqualObjects([[action outPipe] contents], [NSNumber numberWithInt:0],
                       nil);
}

- (void)testMountPointGeneration {
  id<KSCommandRunner> runner = [KSTaskCommandRunner commandRunner];
  STAssertNotNil(runner, nil);
  
  NSDictionary *fakeUpdateInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                  @"product", @"kServerProductID",
                                  @"hash", @"kServerCodeHash", nil];
  
  KSInstallAction *action = nil;
  action = [KSInstallAction actionWithDMGPath:successDMGPath_
                                       runner:runner
                                userInitiated:NO
                                   updateInfo:fakeUpdateInfo];
  STAssertEqualObjects([action mountPoint], @"/Volumes/product-hash", nil);
  
  
  // Now try the test w/ a huge product ID and it should be truncated to 50 cols
  fakeUpdateInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                    @"12345678901234567890123456789012345678901234567890"  // 50
                    @"ABCDEFG...", @"kServerProductID",
                    @"hash", @"kServerCodeHash", nil];
  action = [KSInstallAction actionWithDMGPath:successDMGPath_
                                       runner:runner
                                userInitiated:NO
                                   updateInfo:fakeUpdateInfo];
  STAssertEqualObjects([action mountPoint], @"/Volumes/"
                       @"12345678901234567890123456789012345678901234567890"  // 50
                       @"-hash", nil);
}

@end
