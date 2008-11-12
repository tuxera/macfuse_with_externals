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
#import "KSMultiUpdateAction.h"

#import "KSActionPipe.h"
#import "KSActionProcessor.h"
#import "KSMemoryTicketStore.h"
#import "KSTicketStore.h"
#import "KSUpdateAction.h"
#import "KSUpdateEngine.h"
#import "KSUpdateInfo.h"


@interface KSMultiUpdateActionTest : SenTestCase
@end


@interface Concrete : KSMultiUpdateAction {
  // Hang on to the avaialble updates array we get from Update Engine
  // to verify that the ticket info has been added.
  NSArray *availableUpdates_;
}

- (NSArray *)availableUpdates;
@end

@implementation Concrete

- (NSArray *)productsToUpdateFromAvailable:(NSArray *)availableUpdates {
  // Hang on to the updates so we can check their tickettude after
  // the update has run.
  availableUpdates_ = [availableUpdates retain];

  return [availableUpdates filteredArrayUsingPredicate:
          [NSPredicate predicateWithFormat:
           @"%K like 'allow*'", kServerProductID]];
}

- (void)dealloc {
  [availableUpdates_ release];
  [super dealloc];
}

- (NSArray *)availableUpdates {
  return availableUpdates_;
}

@end

static NSString *const kTicketStorePath = @"/tmp/KSMultiUpdateActionTest.ticketstore";

@implementation KSMultiUpdateActionTest

- (void)setUp {
  [@"" writeToFile:kTicketStorePath atomically:YES];
  [KSUpdateEngine setDefaultTicketStorePath:kTicketStorePath];
}

- (void)tearDown {
  [[NSFileManager defaultManager] removeFileAtPath:kTicketStorePath handler:nil];
  [KSUpdateEngine setDefaultTicketStorePath:nil];
}

// KSUpdateEngineDelegate protocol method
- (id<KSCommandRunner>)commandRunnerForEngine:(KSUpdateEngine *)engine {
  return nil;
}

- (void)loopUntilDone:(KSActionProcessor *)processor {
  int count = 10;
  while ([processor isProcessing] && (count > 0)) {
    NSDate *quick = [NSDate dateWithTimeIntervalSinceNow:0.2];
    [[NSRunLoop currentRunLoop] runUntilDate:quick];
    count--;
  }
  STAssertFalse([processor isProcessing], nil);
}

- (void)testCreation {
  Concrete *action = [Concrete actionWithEngine:nil];
  STAssertNil(action, nil);
  
  action = [[[Concrete alloc] init] autorelease];
  STAssertNil(action, nil);
  
  action = [[[Concrete alloc] initWithEngine:nil] autorelease];
  STAssertNil(action, nil);
  
  KSUpdateEngine *engine = [KSUpdateEngine engineWithDelegate:self];
  action = [Concrete actionWithEngine:engine];
  STAssertNotNil(action, nil);
  STAssertFalse([action isRunning], nil);

  // For the sake of code coverage, let's call this method even though we don't
  // really have a good way to test the functionality.
  [action terminateAction];
}


// Struct to hold the values used to create a ticket.
typedef struct RawTicketInfo {
  const char *productID;
  const char *version;
  const char *xcpath;
  const char *serverURL;
} RawTicketInfo;

static RawTicketInfo denyTix[] = {
  { "deny1", "123", "/blah", "http://google.com" },
  { "deny2", "234", "/blah", "http://google.com" },
};

- (KSTicketStore *)ticketStoreFromRawInfo:(RawTicketInfo *)rawBits
                                   length:(int)length {
  KSTicketStore *ticketStore = [[[KSMemoryTicketStore alloc] init] autorelease];
  RawTicketInfo *scan, *stop;
  scan = rawBits;
  stop = scan + length;
  while (scan < stop) {
    NSString *productID = [NSString stringWithUTF8String:scan->productID];
    NSString *version = [NSString stringWithUTF8String:scan->version];
    KSExistenceChecker *xc = [KSPathExistenceChecker checkerWithPath:
        [NSString stringWithUTF8String:scan->xcpath]];
    NSURL *serverURL =
      [NSURL URLWithString:[NSString stringWithUTF8String:scan->serverURL]];
    KSTicket *ticket =
      [KSTicket ticketWithProductID:productID
                            version:version
                   existenceChecker:xc
                          serverURL:serverURL];
    [ticketStore storeTicket:ticket];
    scan++;
  }
  return ticketStore;
}

- (void)testNegativeFiltering {
  KSTicketStore *store =
    [self ticketStoreFromRawInfo:denyTix
                          length:sizeof(denyTix) / sizeof(*denyTix)];
  KSUpdateEngine *engine =
    [KSUpdateEngine engineWithTicketStore:store delegate:self];
  STAssertNotNil(engine, nil);
  
  Concrete *action = [Concrete actionWithEngine:engine];
  STAssertNotNil(action, nil);
  
  NSArray *availableProducts =
  [[NSArray alloc] initWithObjects:
   [NSDictionary dictionaryWithObjectsAndKeys:
    @"deny1", kServerProductID,
    [NSURL URLWithString:@"a://b"], kServerCodebaseURL,
    [NSNumber numberWithInt:1], kServerCodeSize,
    @"vvv", kServerCodeHash,
    @"a://b", kServerMoreInfoURLString,
    nil],
   [NSDictionary dictionaryWithObjectsAndKeys:
    @"deny2", kServerProductID,
    [NSURL URLWithString:@"a://b"], kServerCodebaseURL,
    [NSNumber numberWithInt:2], kServerCodeSize,
    @"qqq", kServerCodeHash,
    @"a://b", kServerMoreInfoURLString,
    nil],
   nil];
  
  KSActionPipe *pipe = [KSActionPipe pipe];
  [pipe setContents:availableProducts];
  [action setInPipe:pipe];
  
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  [ap enqueueAction:action];
  
  STAssertEqualsWithAccuracy([ap progress], 0.0f, 0.01, nil);
  [ap startProcessing];
  [self loopUntilDone:ap];
  STAssertFalse([ap isProcessing], nil);
  STAssertEqualsWithAccuracy([ap progress], 1.0f, 0.01, nil);

  // Make sure the ticket made it to the update infos.
  NSEnumerator *updateEnumerator = [[action availableUpdates] objectEnumerator];
  KSUpdateInfo *info = nil;
  while ((info = [updateEnumerator nextObject])) {
    KSTicket *ticket = [info ticket];
    STAssertNotNil(ticket, nil);

    // Sanity check the ticket.
    NSString *ticketProductID = [ticket productID];
    NSString *infoProductID = [info productID];
    STAssertEqualObjects(ticketProductID, infoProductID, nil);
  }
  
  STAssertEquals([action subActionsProcessed], 0, nil);
}

- (void)testNoUpdates {
  KSUpdateEngine *engine = [KSUpdateEngine engineWithDelegate:self];
  STAssertNotNil(engine, nil);
  
  Concrete *action = [Concrete actionWithEngine:engine];
  STAssertNotNil(action, nil);
  
  KSActionPipe *pipe = [KSActionPipe pipe];
  [action setInPipe:pipe];  // This pipe is empty
  
  KSActionProcessor *ap = [[[KSActionProcessor alloc] init] autorelease];
  [ap enqueueAction:action];
  
  STAssertEqualsWithAccuracy([ap progress], 0.0f, 0.01, nil);
  [ap startProcessing];
  [self loopUntilDone:ap];
  STAssertFalse([ap isProcessing], nil);
  STAssertEqualsWithAccuracy([ap progress], 1.0f, 0.01, nil);
  
  STAssertEqualObjects([[action outPipe] contents], nil, nil);
}

@end
