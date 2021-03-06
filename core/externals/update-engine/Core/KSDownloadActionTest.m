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
#import "KSDownloadAction.h"
#import "KSActionProcessor.h"
#import "KSActionPipe.h"
#import "NSData+Hash.h"
#import "GTMBase64.h"
#import <unistd.h>
#import <sys/utsname.h>


@interface KSDownloadActionTest : SenTestCase {
 @private
  NSString *tempName_;
}
@end


// !!!internal knowledge!!!
@interface KSDownloadAction (PrivateMethods)
- (NSString *)ksurlDirectoryName;
- (NSString *)ksurlValidatedDirectory;
- (NSString *)ksurlPath;
- (void)markProgress:(float)progress;
@end

// ----------------------------------------------------------------
// Implement KSDownloadActionDelegateMethods.  Keep track of progress.
@interface KSDownloadProgressCounter : NSObject {
  NSMutableArray *progressArray_;
}
+ (id)counter;
- (NSArray *)progressArray;
@end

@implementation KSDownloadProgressCounter

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

- (void)processor:(KSActionProcessor *)processor
    runningAction:(KSAction *)action
         progress:(float)progress {
  [progressArray_ addObject:[NSNumber numberWithFloat:progress]];
}

@end

// ----------------------------------------------------------------
// Just like a KSDownloadAction but lets us specify the directory
// where ksurl will be created.
@interface KSDownloadActionWithDirectory : KSDownloadAction {
  NSString *directory_;
}
- (id)initWithURL:(NSURL *)url
             size:(unsigned long long)size
             hash:(NSString *)hash
             path:(NSString *)path
      ksdirectory:(NSString *)directory;
- (NSString *)ksurlDirectoryName;
@end

@implementation KSDownloadActionWithDirectory

- (id)initWithURL:(NSURL *)url
             size:(unsigned long long)size
             hash:(NSString *)hash
             path:(NSString *)path
      ksdirectory:(NSString *)directory {
  if ((self = [super initWithURL:url size:size hash:hash path:path])) {
    directory_ = [directory copy];
  }
  return self;
}

- (void)dealloc {
  [directory_ release];
  [super dealloc];
}

- (NSString *)ksurlDirectoryName {
  return directory_;
}

@end

// ----------------------------------------------------------------

//
// In this file we use file:// URLs for testing so that we don't have any
// network dependencies for this unit test.
//

@implementation KSDownloadActionTest

- (void)setUp {
  tempName_ = [[NSString alloc] initWithFormat:
               @"/tmp/KSDownloadActionUnitTest-%x", geteuid()];
  [[NSFileManager defaultManager] removeFileAtPath:tempName_ handler:nil];
}

- (void)tearDown {
  [[NSFileManager defaultManager] removeFileAtPath:tempName_ handler:nil];
}

- (void)loopUntilDone:(KSAction *)action seconds:(int)seconds {
  int count = seconds * 5;
  while ([action isRunning] && (count > 0)) {
    NSDate *quick = [NSDate dateWithTimeIntervalSinceNow:0.2];
    [[NSRunLoop currentRunLoop] runUntilDate:quick];
    count--;
  }
  STAssertFalse([action isRunning], nil);
}

- (void)loopUntilDone:(KSAction *)action {
  [self loopUntilDone:action seconds:2];
}

- (void)testCreation {
  KSDownloadAction *download = nil;

  download = [[KSDownloadAction alloc] init];
  STAssertNil(download, nil);

  download = [[KSDownloadAction alloc] initWithURL:nil
                                              size:nil
                                              hash:nil
                                              path:nil];
  STAssertNil(download, nil);

  NSURL *url = [NSURL URLWithString:@"http://www.google.com"];
  download = [[KSDownloadAction alloc] initWithURL:url
                                              size:1
                                              hash:@"not nil"
                                              path:@"/tmp/Google"];
  STAssertNotNil(download, nil);
  STAssertTrue([[download description] length] > 1, nil);
  [download release];

  // Make sure this convenience method works and that it gives us a nice
  // default download directory (since we didn't specify one).
  download = [KSDownloadAction actionWithURL:url
                                        size:1
                                        hash:@"not nil"
                                        name:@"Google"];
  STAssertNotNil(download, nil);

  NSString *cachePath = [@"~/Library/Caches/com.google.UpdateEngine.Framework."
                         stringByExpandingTildeInPath];
  // We do a range check instead of a prefix check because home directories that
  // are symlinked to other weird places (e.g., /Volumes/Users) may not resolve
  // correctly.
  NSRange range = [[download path] rangeOfString:cachePath];
  STAssertTrue(range.location != NSNotFound, nil);
}

- (void)testAccessors {
  NSURL *url = [NSURL URLWithString:@"http://www.google.com"];
  KSDownloadAction *download = nil;
  download = [[KSDownloadAction alloc] initWithURL:url
                                              size:1
                                              hash:@"not nil"
                                              path:@"/tmp/Google"];
  [download autorelease];
  STAssertNotNil(download, nil);

  STAssertEqualObjects(url, [download url], nil);
  STAssertEqualObjects(@"not nil", [download hash], nil);
  STAssertEqualObjects(@"/tmp/Google", [download path], nil);
  STAssertEquals(1ULL, [download size], nil);

  // The download path should be nil until a successful download
  STAssertNil([[download outPipe] contents], nil);
}

- (void)testDownloadWithBadHash {
  // To avoid network issues screwing up the tests, we'll use file: URLs
  NSURL *url = [NSURL URLWithString:@"file:///etc/passwd"];

  KSDownloadAction *download = [[[KSDownloadAction alloc] initWithURL:url
                                                                 size:1
                                                                 hash:@"bad hash value"
                                                                 path:tempName_] autorelease];
  STAssertNotNil(download, nil);
  STAssertNil([[download outPipe] contents], nil);

  // Create an action processor and process the download
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:download];
  [ap startProcessing];  // Starts action

  [self loopUntilDone:download];

  // We didn't provide a valid hash value, so the path should still be nil.
  STAssertTrue([download isRunning] == NO, nil);  // make sure we're done
  STAssertNil([[download outPipe] contents], nil);
}

// Return a good file URL download with good hash, size
- (KSDownloadAction *)goodDownloadActionWithFile:(NSString *)file {
  NSURL *url = [NSURL fileURLWithPath:file];
  NSData *data = [NSData dataWithContentsOfFile:file];
  NSData *dhash = [data SHA1Hash];
  NSString *hash = [GTMBase64 stringByEncodingData:dhash];

  unsigned long long realSize =
  [[[NSFileManager defaultManager] fileAttributesAtPath:file
                                           traverseLink:NO] fileSize];

  KSDownloadAction *download = [[[KSDownloadAction alloc] initWithURL:url
                                                                 size:realSize
                                                                 hash:hash
                                                                 path:tempName_] autorelease];
  STAssertNotNil(download, nil);
  STAssertNil([[download outPipe] contents], nil);
  return download;
}

- (void)testDownloadWithGoodHash {
  // To avoid network issues screwing up the tests, we'll use file: URLs
  KSDownloadAction *download = [self goodDownloadActionWithFile:@"/etc/passwd"];

  // Create an action processor and process the download
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:download];
  [ap startProcessing];  // Starts action

  [self loopUntilDone:download];

  STAssertTrue([download isRunning] == NO, nil);  // make sure we're done
  STAssertNotNil([[download outPipe] contents], nil);
}

- (void)testDownloadWithBadURL {
  // To avoid network issues screwing up the tests, we'll use file: URLs
  NSURL *url = [NSURL URLWithString:@"file:///path/to/fake/file"];

  KSDownloadAction *download = [[[KSDownloadAction alloc] initWithURL:url
                                                                 size:1
                                                                 hash:@"bad hash value"
                                                                 path:tempName_] autorelease];
  STAssertNotNil(download, nil);
  STAssertNil([[download outPipe] contents], nil);

  // Create an action processor and process the download
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:download];
  [ap startProcessing];  // Starts action

  [self loopUntilDone:download];

  // We didn't provide a valid hash value, so the path should still be nil.
  STAssertTrue([download isRunning] == NO, nil);  // make sure we're done
  STAssertNil([[download outPipe] contents], nil);
}

- (void)testShortCircuitDownload {

  //
  // 1. Predownload the file so that it will be cached and the short circuit
  //    will work below.
  //

  // To avoid network issues screwing up the tests, we'll use file: URLs
  NSURL *url = [NSURL URLWithString:@"file:///etc/passwd"];
  NSData *data = [NSData dataWithContentsOfFile:@"/etc/passwd"];
  NSData *dhash = [data SHA1Hash];
  NSString *hash = [GTMBase64 stringByEncodingData:dhash];
  unsigned long long realSize =
    [[[NSFileManager defaultManager] fileAttributesAtPath:@"/etc/passwd"
                                             traverseLink:NO] fileSize];
  STAssertTrue(realSize > 0, nil);

  // download file must not already exist so that we can ensure that we're not
  // short circuited on the first run.
  [[NSFileManager defaultManager] removeFileAtPath:tempName_
                                           handler:nil];

  KSDownloadAction *download = [[[KSDownloadAction alloc] initWithURL:url
                                                                 size:realSize
                                                                 hash:hash
                                                                 path:tempName_] autorelease];
  STAssertNotNil(download, nil);
  STAssertNil([[download outPipe] contents], nil);

  // Create an action processor and process the download
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:download];
  [ap startProcessing];  // Starts action
  STAssertNil([[download outPipe] contents], nil);

  [self loopUntilDone:download];

  STAssertTrue([download isRunning] == NO, nil);  // make sure we're done
  STAssertNotNil([[download outPipe] contents], nil);
  STAssertTrue([[[download outPipe] contents] isEqual:tempName_], nil);

  //
  // 2. Now that we know the file is already downloaded, let's make sure our
  //    short circuit download works by starting the download but not spinning
  //    the runloop.
  //

  download = [[[KSDownloadAction alloc] initWithURL:url
                                               size:realSize
                                               hash:hash
                                               path:tempName_] autorelease];
  STAssertNotNil(download, nil);
  STAssertNil([[download outPipe] contents], nil);

  // Create an action processor and process the download
  ap = [[[KSActionProcessor alloc] init] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:download];
  [ap startProcessing];  // Starts action

  // Short-circuit download should be done already (w/o a runloop spin)

  STAssertTrue([download isRunning] == NO, nil);  // make sure we're done
  STAssertNotNil([[download outPipe] contents], nil);
  STAssertTrue([[[download outPipe] contents] isEqual:tempName_], nil);
}

// Return a basic KSDownloadAction for whatever.
- (KSDownloadAction *)basicDownload {
  NSURL *url = [NSURL URLWithString:@"file:///etc/passwd"];
  KSDownloadAction *download = [[[KSDownloadAction alloc] initWithURL:url
                                                                 size:1
                                                                 hash:@"bad hash value"
                                                                 path:tempName_] autorelease];
  STAssertNotNil(download, nil);
  return download;
}

- (void)testKsurlName {
  KSDownloadAction *download = [self basicDownload];
  NSString *dirname = [download ksurlDirectoryName];

  // Sanity check path
  STAssertTrue([dirname length] > 1, nil);
  NSString *topDirectory = [[dirname pathComponents] objectAtIndex:0];
  BOOL isDir = NO;
  STAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:topDirectory
                                                    isDirectory:&isDir], nil);
  STAssertTrue(isDir, nil);
}

// Return a basic KSDownloadActionWithDirectory for whatever.
- (KSDownloadAction *)basicDownloadWithDirectory:(NSString *)dir {
  NSURL *url = [NSURL URLWithString:@"file:///etc/passwd"];
  KSDownloadAction *download = [[[KSDownloadActionWithDirectory alloc]
                                  initWithURL:url
                                         size:1
                                         hash:@"bad hash value"
                                         path:tempName_
                                  ksdirectory:dir] autorelease];
  STAssertNotNil(download, nil);
  return download;
}

// Helper to confirm the parent directory of ksurl is valid.
- (void)confirmValidatedDirectory:(KSDownloadAction *)download {
  NSNumber *properPermission = [NSNumber numberWithUnsignedLong:0755];
  NSDictionary *attr = nil;

  STAssertNotNil(download, nil);
  NSString *dir = [[download ksurlPath] stringByDeletingLastPathComponent];
  STAssertNotNil(dir, nil);

  attr = [[NSFileManager defaultManager] fileAttributesAtPath:dir
                                                 traverseLink:NO];
  STAssertTrue([[attr objectForKey:NSFileOwnerAccountID]
                   isEqual:[NSNumber numberWithUnsignedLong:(long)geteuid()]],
               nil);
  STAssertTrue([[attr objectForKey:NSFilePosixPermissions]
                   isEqual:properPermission], nil);
}

- (void)testKsurlValidatedDirectory {
  NSString *tempdir = [NSString stringWithFormat:@"/tmp/ksda-%d", geteuid()];
  KSDownloadAction *download = nil;

  // test 1: doesn't exist yet.
  [[NSFileManager defaultManager] removeFileAtPath:tempdir handler:nil];
  download = [self basicDownloadWithDirectory:tempdir];
  [self confirmValidatedDirectory:download];

  // test 2: already exists, correct permission
  download = [self basicDownloadWithDirectory:tempdir];
  [self confirmValidatedDirectory:download];

  // test 3: already exists, wrong permission
  [[NSFileManager defaultManager] removeFileAtPath:tempdir handler:nil];
  NSNumber *wrongPermission = [NSNumber numberWithUnsignedLong:0777];
  NSDictionary *attr = [NSDictionary dictionaryWithObject:wrongPermission
                                                   forKey:NSFilePosixPermissions];
  [[NSFileManager defaultManager] createDirectoryAtPath:tempdir
                                             attributes:attr];
  download = [self basicDownloadWithDirectory:tempdir];
  [self confirmValidatedDirectory:download];

  // prevent Alex from getting mad
  [[NSFileManager defaultManager] removeFileAtPath:tempdir handler:nil];
}

- (void)testKsurlPath {
  KSDownloadAction *download = [self basicDownload];
  NSString *ksurl = [download ksurlPath];

  STAssertTrue([[NSFileManager defaultManager] isExecutableFileAtPath:ksurl], nil);
  NSDictionary *attr = [[NSFileManager defaultManager] fileAttributesAtPath:ksurl
                                                               traverseLink:NO];
  STAssertNotNil(ksurl, nil);
  NSNumber *uidNumber = [attr objectForKey:NSFileOwnerAccountID];
  STAssertNotNil(uidNumber, nil);
  STAssertTrue([uidNumber isEqual:[NSNumber numberWithUnsignedLong:(long)geteuid()]], nil);

  NSNumber *properPermission = [NSNumber numberWithUnsignedLong:0755];
  NSNumber *currentPermission = [attr objectForKey:NSFilePosixPermissions];
  STAssertTrue([properPermission isEqual:currentPermission], nil);
}

- (void)testBasicProgress {
  KSDownloadAction *download = [self basicDownload];
  KSDownloadProgressCounter *progressCounter = [KSDownloadProgressCounter counter];

  // We need to put the download action on a processor because the progress
  // is relayed via the processor
  KSActionProcessor *processor = [[[KSActionProcessor alloc ]
                                   initWithDelegate:progressCounter] autorelease];
  [processor enqueueAction:download];
  STAssertEqualsWithAccuracy([processor progress], 0.0f, 0.01, nil);

  STAssertTrue([[progressCounter progressArray] count] == 0, nil);
  [download markProgress:0.0];
  [download markProgress:0.7];
  [download markProgress:1.0];
  STAssertTrue([[progressCounter progressArray] count] == 3, nil);

  STAssertEqualsWithAccuracy([processor progress], 1.0f, 0.01, nil);
}

- (void)testProgress {
  // To avoid network issues screwing up the tests, we'll use file: URLs.
  // Find a file we know we can read without issue.  Some continuous build
  // systems throw errors when trying to read from system files.
  NSBundle *me = [NSBundle bundleForClass:[self class]];
  NSString *file = [me executablePath];
  KSDownloadAction *download = [self goodDownloadActionWithFile:file];

  // keep track of status
  KSDownloadProgressCounter *progressCounter = [KSDownloadProgressCounter counter];

  STAssertTrue([[progressCounter progressArray] count] == 0, nil);

  // Create an action processor and process the download
  KSActionProcessor *ap = [[[KSActionProcessor alloc]
                            initWithDelegate:progressCounter] autorelease];
  STAssertNotNil(ap, nil);

  [ap enqueueAction:download];
  [ap startProcessing];  // Starts action

  [self loopUntilDone:download seconds:10];
  STAssertTrue([download isRunning] == NO, nil);  // make sure we're done

  // Want more than nothing...
  STAssertTrue([[progressCounter progressArray] count] >= 1, nil);

  // confirm we got some good lookin' status (10.5 only)
  // No incremental progress on 10.4 for file:// URLs :-(
  // 10.4.11: relase is 8.11; 10.5.3: release is 9.3
  struct utsname name;
  if ((uname(&name) == 0) &&
      (name.release[0] != '8')) {
    STAssertTrue([[progressCounter progressArray] count] > 8, nil);
  }

  NSNumber *num;
  NSEnumerator *penum = [[progressCounter progressArray] objectEnumerator];
  float last = 0.0;
  while ((num = [penum nextObject])) {
    STAssertTrue([num floatValue] >= last, nil);
    last = [num floatValue];
  }
  STAssertTrue(last <= 1.0, nil);
}


@end
