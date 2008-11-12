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

#import "ERSelfUpdateCommand.h"

#import "KSUpdateEngine.h"

// Some preprocessor magic to turn a command-line -DUPDATE_ENGINE_VERSION=R35
// into a string, and then into an NSString.  With -DBLAH=SNORK
// Doing TO_OBJC_STR(BLAH) will cause it to expand to TO_OBJC_STR2(SNORK).
// Then TO_BOJC2_STR will stringize SNORK and turn it into a quoted string.
#define TO_OBJC_STR2(x) @#x
#define TO_OBJC_STR(x) TO_OBJC_STR2(x)

static NSString *kSelfProductID = @"EngineRunner";
static NSString *kSelfUpdateURL = @"http://update-engine.googlecode.com/svn/site/enginerunner.plist";
static NSString *kSelfVersion = TO_OBJC_STR(UPDATE_ENGINE_VERSION);


@implementation ERSelfUpdateCommand

- (NSString *)name {
  return @"selfupdate";
}  // name


- (NSString *)blurb {
  return @"Update EngineRunner";
}  // blurb


- (NSDictionary *)optionalArguments {
  return [NSDictionary dictionaryWithObjectsAndKeys:
                       @"Version to claim that we are", @"version",
                       @"ProductID to claim that we are", @"productid",
                       @"Server URL", @"url",
                       nil];
}  // requiredArguments


- (BOOL)runWithArguments:(NSDictionary *)args {

  NSString *productID = [args valueForKey:@"productid"];
  NSString *version = [args valueForKey:@"version"];
  NSString *urlstring = [args valueForKey:@"url"];

  if (productID == nil) productID = kSelfProductID;
  if (version == nil) version = kSelfVersion;
  if (urlstring == nil) urlstring = kSelfUpdateURL;

  NSArray *argv = [[NSProcessInfo processInfo] arguments];
  NSString *me = [argv objectAtIndex:0];

  NSArray *arguments = [NSArray arrayWithObjects:
                                @"run",
                                @"-productid", productID,
                                @"-version", version,
                                @"-url", urlstring,
                                nil];

  NSTask *task = [NSTask launchedTaskWithLaunchPath:me
                                          arguments:arguments];
  [task waitUntilExit];

  if ([task terminationStatus] != 0) {
    return NO;
  } else {
    return YES;
  }

}  // runWithArguments

@end  // ERSelfUpdateCommand
