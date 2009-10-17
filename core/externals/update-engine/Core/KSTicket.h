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

#import <Foundation/Foundation.h>

@class KSExistenceChecker;

// POD object that encapsulates information that an application provides when
// "registering" with UpdateEngine. Tickets are a central part of UpdateEngine.
// UpdateEngine maintains one ticket for each registered application. Tickets
// are how UpdateEngine knows what's installed.
//
// The creation date simply records the date the ticket was created. If a ticket
// is unarchived (from a KSTicketStore), the creationDate_ will be the date the
// ticket was originally created, not the date it was unarchived.  You can use
// the creation date to see how long the ticket has been registered.  You should
// preserve the creation date when you update a ticket.
//
@interface KSTicket : NSObject <NSCoding> {
 @private
  NSString *productID_;  // guid or bundleID
  NSString *version_;
  KSExistenceChecker *existenceChecker_;
  NSURL *serverURL_;
  NSDate *creationDate_;
  NSString *trustedTesterToken_;
  NSString *tag_;
}

// Returns an autoreleased KSTicket instance initialized with the specified
// arguments. All arguments are required; if any are nil, then nil is returned.
+ (id)ticketWithProductID:(NSString *)productid
                  version:(NSString *)version
         existenceChecker:(KSExistenceChecker *)xc
                serverURL:(NSURL *)serverURL;

// Returns an autoreleased KSTicket instance initialized with the
// specified arguments, also allowing a trusted tester token to be
// specified.  All arguments other than the trusted tester token are
// required; if any others are nil, then nil is returned.
+ (id)ticketWithProductID:(NSString *)productid
                  version:(NSString *)version
         existenceChecker:(KSExistenceChecker *)xc
                serverURL:(NSURL *)serverURL
       trustedTesterToken:(NSString *)trustedTesterToken;

// Returns an autoreleased KSTicket instance initialized with the
// specified arguments, also allowing a trusted tester token and a
// creation date to be specified.  All arguments other than the
// trusted tester token and creation date are required; if any others
// are nil, then nil is returned.
+ (id)ticketWithProductID:(NSString *)productid
                  version:(NSString *)version
         existenceChecker:(KSExistenceChecker *)xc
                serverURL:(NSURL *)serverURL
       trustedTesterToken:(NSString *)trustedTesterToken
             creationDate:(NSDate *)creationDate;

// Returns an autoreleased KSTicket instance initialized with the
// specified arguments, also allowing a trusted tester token, a
// creation date, and a tag to be specified.  All arguments other than
// the trusted tester token, creation date, and tag are required; if
// any others are nil, then nil is returned.
// TODO(mdalrymple): There's too damn many of these initializers.
//    Pare it down to the Big Four (prodID, version, xc, url), and then
//    another one with all the args - either as individual arguments, or
//    a dict/struct packed with the extra values.
+ (id)ticketWithProductID:(NSString *)productid
                  version:(NSString *)version
         existenceChecker:(KSExistenceChecker *)xc
                serverURL:(NSURL *)serverURL
       trustedTesterToken:(NSString *)trustedTesterToken
             creationDate:(NSDate *)creationDate
                      tag:(NSString *)tag;

// Returns a KSTicket initialized with the specified arguments. All
// arguments are required; if any are nil, then nil is returned.
- (id)initWithProductID:(NSString *)productid
                version:(NSString *)version
       existenceChecker:(KSExistenceChecker *)xc
              serverURL:(NSURL *)serverURL;

// Returns a KSTicket initialized with the specified arguments, also
// allowing a trusted tester token.  All arguments other than the
// trusted tester token are required; if any are nil, then nil is
// returned.
- (id)initWithProductID:(NSString *)productid
                version:(NSString *)version
       existenceChecker:(KSExistenceChecker *)xc
              serverURL:(NSURL *)serverURL
     trustedTesterToken:(NSString *)trustedTesterToken;

// Returns a KSTicket initialized with the specified arguments, also
// allowing a trusted tester token and a creation date.  All arguments
// other than the trusted tester token and creation date are required;
// if any are nil, then nil is returned. If no creation date is
// supplied, the current date and time is used.
- (id)initWithProductID:(NSString *)productid
                version:(NSString *)version
       existenceChecker:(KSExistenceChecker *)xc
              serverURL:(NSURL *)serverURL
     trustedTesterToken:(NSString *)trustedTesterToken
           creationDate:(NSDate *)creationDate;

// Designated initializer. Returns a KSTicket initialized with the
// specified arguments, also allowing a trusted tester token,
// a creation date, and a tag.  All arguments other than the trusted tester
// token, creation date, and tag are required; if any are nil, then nil is
// returned.  If no creation date is supplied, the current date and
// time is used.
- (id)initWithProductID:(NSString *)productid
                version:(NSString *)version
       existenceChecker:(KSExistenceChecker *)xc
              serverURL:(NSURL *)serverURL
     trustedTesterToken:(NSString *)trustedTesterToken
           creationDate:(NSDate *)creationDate
                    tag:(NSString *)tag;

// Returns YES if ticket is equal to the ticket identified by self.
- (BOOL)isEqualToTicket:(KSTicket *)ticket;

// Returns the productID for this ticket.
// We don't know or care if it's a GUID or BundleID
- (NSString *)productID;

// Returns the version for this ticket.
- (NSString *)version;

// Returns the existence checker object for this ticket. This object can be used
// to determine if the application represented by this ticket is still
// installed.
- (KSExistenceChecker *)existenceChecker;

// Returns the server URL to check for updates to the application represented by
// this ticket.
- (NSURL *)serverURL;

// Returns the date this ticket was created.
- (NSDate *)creationDate;

// Returns the trusted tester token, or nil if the ticket does not have one.
- (NSString *)trustedTesterToken;

// Returns the tag, or nil if the ticket does not have one.
- (NSString *)tag;

@end
