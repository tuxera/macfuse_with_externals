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

#import "KSCheckAction.h"
#import "KSTicket.h"
#import "KSUpdateCheckAction.h"
#import "KSPlistServer.h"
#import "KSActionPipe.h"
#import "KSActionProcessor.h"
#import "KSTicketStore.h"
#import "KSFrameworkStats.h"


// The KSServer class used by this action is configurable. This variable holds
// the objc Class representing the KSServer subclass to use. This variable
// should not be directly accessed. Instead, the +serverClass class method
// should be used. That class method will return a default KSServer class if one
// is not set.
static Class gServerClass;  // Weak


@implementation KSCheckAction

+ (id)actionWithTickets:(NSArray *)tickets params:(NSDictionary *)params {
  return [[[self alloc] initWithTickets:tickets params:params] autorelease];
}

+ (id)actionWithTickets:(NSArray *)tickets {
  return [[[self alloc] initWithTickets:tickets] autorelease];
}

- (id)initWithTickets:(NSArray *)tickets params:(NSDictionary *)params {
  if ((self = [super init])) {
    tickets_ = [tickets copy];
    params_ = [params retain];
  }
  return self;
}

- (id)initWithTickets:(NSArray *)tickets {
  return [self initWithTickets:tickets params:nil];
}

- (void)dealloc {
  [params_ release];
  [tickets_ release];
  [super dealloc];
}

- (void)performAction {
  NSDictionary *tixMap = [tickets_ ticketsByURL];
  if (tixMap == nil) {
    GTMLoggerInfo(@"no tickets to check on.");
    [[self outPipe] setContents:nil];
    [[self processor] finishedProcessing:self successfully:YES];
    return;
  }
  
  NSURL *url = nil;
  NSEnumerator *tixMapEnumerator = [tixMap keyEnumerator];
  
  while ((url = [tixMapEnumerator nextObject])) {
    NSArray *tickets = [tixMap objectForKey:url];
    [[KSFrameworkStats sharedStats] incrementStat:kStatTickets
                                               by:[tickets count]];
    
    // We don't want to check for products that are currently not installed, so 
    // we need to filter the array of tickets to only those ticktes whose 
    // existence checker indicates that they are currently installed.
    // NSPredicate makes this very easy.
    NSArray *filteredTickets =
      [tickets filteredArrayUsingPredicate:
       [NSPredicate predicateWithFormat:@"existenceChecker.exists == YES"]];
    
    if ([filteredTickets count] == 0)
      continue;
    
    GTMLoggerInfo(@"filteredTickets = %@", filteredTickets);
    [[KSFrameworkStats sharedStats] incrementStat:kStatValidTickets
                                               by:[filteredTickets count]];
    
    Class serverClass = [[self class] serverClass];
    // Creates a concrete KSServer instance using the designated initializer
    // declared on KSServer.
    KSServer *server = [[[serverClass alloc] initWithURL:url
                                                  params:params_] autorelease];
    KSAction *checker = [KSUpdateCheckAction checkerWithServer:server
                                                       tickets:filteredTickets];
    [[self subProcessor] enqueueAction:checker];
  }

  if ([[[self subProcessor] actions] count] == 0) {
    GTMLoggerInfo(@"No checkers created.");
    [[self processor] finishedProcessing:self successfully:YES];
    return;
  }
  
  // Our output needs to be the aggregate of all our sub-action checkers' output
  // For now, we'll just set our output to a mutable array, that we'll append to
  // as each sub-action checker finishs.
  [[self outPipe] setContents:[NSMutableArray array]];
  
  [[self subProcessor] startProcessing];
}

// KSActionProcessor callback method that will be called by our subProcessor
- (void)processor:(KSActionProcessor *)processor
   finishedAction:(KSAction *)action
     successfully:(BOOL)wasOK {
  [[KSFrameworkStats sharedStats] incrementStat:kStatChecks];
  if (wasOK) {
    // Get the checker's output contents and append it to our own output.
    NSArray *checkerOutput = [[action outPipe] contents];
    [[[self outPipe] contents] addObjectsFromArray:checkerOutput];
    // See header comments about why this gets set to YES here.
    wasSuccessful_ = YES;
  } else {
    [[KSFrameworkStats sharedStats] incrementStat:kStatFailedChecks];
  }
}

// Overridden from KSMultiAction. Called by our subProcessor when it finishes.
// We tell our parent processor that we succeeded if *any* of our subactions
// succeeded.
- (void)processingDone:(KSActionProcessor *)processor {
  [[self processor] finishedProcessing:self successfully:wasSuccessful_];
}

@end


@implementation KSCheckAction (Configuration)

+ (Class)serverClass {
  return gServerClass ? gServerClass : [KSPlistServer class];
}

+ (void)setServerClass:(Class)serverClass {
  if (serverClass != Nil && ![serverClass isSubclassOfClass:[KSServer class]])
    return;
  gServerClass = serverClass;
}

@end
