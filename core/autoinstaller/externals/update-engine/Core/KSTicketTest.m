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
#import "KSTicket.h"
#import "KSExistenceChecker.h"


@interface KSTicketTest : SenTestCase
@end


@implementation KSTicketTest

- (void)testTicket {
  KSTicket *t = nil;
  
  t = [[KSTicket alloc] init];
  STAssertNil(t, nil);
  
  KSExistenceChecker *xc = [KSExistenceChecker falseChecker];
  NSURL *url = [NSURL URLWithString:@"http://www.google.com"];

  t = [KSTicket ticketWithProductID:@"{GUID}"
                       version:@"1.1"
              existenceChecker:xc
                     serverURL:url];
  STAssertNotNil(t, nil);

  STAssertEqualObjects([t productID], @"{GUID}", nil);
  STAssertEqualObjects([t version], @"1.1", nil);
  STAssertEqualObjects([t existenceChecker], xc, nil);
  STAssertEqualObjects([t serverURL], url, nil);
  STAssertTrue([[t creationDate] timeIntervalSinceNow] < 0, nil);
  STAssertTrue(-[[t creationDate] timeIntervalSinceNow] < 0.5, nil);
  STAssertTrue([[t description] length] > 1, nil);
}

- (void)testTicketEquality {
  KSTicket *t1 = nil;
  KSExistenceChecker *xc = [KSExistenceChecker falseChecker];
  NSURL *url = [NSURL URLWithString:@"http://www.google.com"];
  t1 = [KSTicket ticketWithProductID:@"{GUID}"
                       version:@"1.1"
              existenceChecker:xc
                     serverURL:url];
  STAssertNotNil(t1, nil);
  STAssertTrue([t1 isEqual:t1], nil);
  STAssertTrue([t1 isEqualToTicket:t1], nil);
  STAssertFalse([t1 isEqual:@"blah"], nil);
  
  // "copy" t1 by archiving it then unarchiving it. This simulates adding the 
  // ticket to the ticket store, then retrieving it.
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:t1];
  KSTicket *t2 = [NSKeyedUnarchiver unarchiveObjectWithData:data];
  STAssertNotNil(t2, nil);
  
  STAssertTrue(t1 != t2, nil);
  STAssertTrue([t1 isEqual:t2], nil);
  STAssertTrue([t1 isEqualToTicket:t2], nil);
  STAssertEqualObjects(t1, t2, nil);
  STAssertEquals([t1 hash], [t2 hash], nil);
  
  t2 = [KSTicket ticketWithProductID:@"{GUID}"
                        version:@"1.1"
               existenceChecker:xc
                      serverURL:url];
  STAssertNotNil(t2, nil);
  STAssertFalse([t1 isEqual:t2], nil);

  KSTicket *t3 = nil;
  t3 = [KSTicket ticketWithProductID:@"{GUID}!"
                        version:@"1.1"
               existenceChecker:xc
                      serverURL:url];
  STAssertFalse([t1 isEqual:t3], nil);

  t3 = [KSTicket ticketWithProductID:@"{GUID}"
                        version:@"1.1!"
               existenceChecker:xc
                      serverURL:url];
  STAssertFalse([t1 isEqual:t3], nil);

  t3 = [KSTicket ticketWithProductID:@"{GUID}"
                        version:@"1.1"
               existenceChecker:xc
                      serverURL:[NSURL URLWithString:@"http://unixjunkie.net"]];
  STAssertFalse([t1 isEqual:t3], nil);

  KSExistenceChecker *xchecker = [KSPathExistenceChecker checkerWithPath:@"/tmp"];
  t3 = [KSTicket ticketWithProductID:@"{GUID}"
                        version:@"1.1"
               existenceChecker:xchecker
                      serverURL:url];
  STAssertFalse([t1 isEqual:t3], nil);
}

- (void)testNilArgs {
  KSTicket *t = nil;

  t = [KSTicket ticketWithProductID:nil version:nil
              existenceChecker:nil serverURL:nil];
  STAssertNil(t, nil);

  t = [KSTicket ticketWithProductID:@"hi" version:nil
              existenceChecker:nil serverURL:nil];
  STAssertNil(t, nil);

  t = [KSTicket ticketWithProductID:nil  version:nil
              existenceChecker:nil serverURL:nil];
  STAssertNil(t, nil);

  t = [KSTicket ticketWithProductID:nil version:@"hi"
              existenceChecker:nil serverURL:nil];
  STAssertNil(t, nil);

  KSExistenceChecker *xc = [KSExistenceChecker falseChecker];
  t = [KSTicket ticketWithProductID:nil version:nil
              existenceChecker:xc serverURL:nil];
  STAssertNil(t, nil);

  NSURL *url = [NSURL URLWithString:@"http://www.google.com"];
  t = [KSTicket ticketWithProductID:nil version:nil
              existenceChecker:nil serverURL:url];
  STAssertNil(t, nil);

  t = [KSTicket ticketWithProductID:@"hi" version:@"hi"
              existenceChecker:xc serverURL:url];
  STAssertNotNil(t, nil);
}

@end
