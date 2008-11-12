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

#import "KSTicket.h"
#import "KSExistenceChecker.h"


@implementation KSTicket

+ (id)ticketWithProductID:(NSString *)productid
                  version:(NSString *)version
         existenceChecker:(KSExistenceChecker *)xc
                serverURL:(NSURL *)serverURL {

  return [[[self alloc] initWithProductID:productid
                                  version:version
                         existenceChecker:xc
                                serverURL:serverURL
                       trustedTesterToken:nil] autorelease];
}

+ (id)ticketWithProductID:(NSString *)productid
                  version:(NSString *)version
         existenceChecker:(KSExistenceChecker *)xc
                serverURL:(NSURL *)serverURL
       trustedTesterToken:(NSString *)trustedTesterToken {

  return [[[self alloc] initWithProductID:productid
                                  version:version
                         existenceChecker:xc
                                serverURL:serverURL
                       trustedTesterToken:trustedTesterToken] autorelease];
}

- (id)init {
  return [self initWithProductID:nil
                    version:nil
           existenceChecker:nil
                  serverURL:nil];
}

- (id)initWithProductID:(NSString *)productid
                version:(NSString *)version
       existenceChecker:(KSExistenceChecker *)xc
              serverURL:(NSURL *)serverURL {

  return [self initWithProductID:productid
                         version:version
                existenceChecker:xc
                       serverURL:serverURL
              trustedTesterToken:nil];
}

- (id)initWithProductID:(NSString *)productid
                version:(NSString *)version
       existenceChecker:(KSExistenceChecker *)xc
              serverURL:(NSURL *)serverURL
     trustedTesterToken:(NSString *)trustedTesterToken {

  if ((self = [super init])) {
    productID_ = [productid copy];
    version_ = [version copy];
    existenceChecker_ = [xc retain];
    serverURL_ = [serverURL retain];
    creationDate_ = [[NSDate alloc] init];
    trustedTesterToken_ = [trustedTesterToken retain];

    // ensure that no ivars (other than trustedTesterToken_) are nil
    if (productID_ == nil || version_ == nil ||
        existenceChecker_ == nil || serverURL == nil) {
      [self release];
      return nil;
    }
  }
  return self;
}

- (id)initWithCoder:(NSCoder *)coder {
  if ((self = [super init])) {
    productID_ = [[coder decodeObjectForKey:@"product_id"] retain];
    version_ = [[coder decodeObjectForKey:@"version"] retain];
    existenceChecker_ = [[coder decodeObjectForKey:@"existence_checker"] retain];
    serverURL_ = [[coder decodeObjectForKey:@"server_url"] retain];
    creationDate_ = [[coder decodeObjectForKey:@"creation_date"] retain];
    if ([coder containsValueForKey:@"trusted_tester_token"]) {
      trustedTesterToken_ = [[coder decodeObjectForKey:@"trusted_tester_token"] retain];
    }
  }
  return self;
}

- (void)dealloc {
  [productID_ release];
  [version_ release];
  [existenceChecker_ release];
  [serverURL_ release];
  [creationDate_ release];
  [super dealloc];
}

- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeObject:productID_ forKey:@"product_id"];
  [coder encodeObject:version_ forKey:@"version"];
  [coder encodeObject:existenceChecker_ forKey:@"existence_checker"];
  [coder encodeObject:serverURL_ forKey:@"server_url"];
  [coder encodeObject:creationDate_ forKey:@"creation_date"];
  if (trustedTesterToken_)
    [coder encodeObject:trustedTesterToken_ forKey:@"trusted_tester_token"];
}

// trustedTesterToken_ intentionally excluded from hash
- (unsigned)hash {
  return [productID_ hash] + [version_ hash] + [existenceChecker_ hash]
       + [serverURL_ hash] + [creationDate_ hash];
}

- (BOOL)isEqual:(id)other {
  if (other == self)
    return YES;
  if (!other || ![other isKindOfClass:[self class]])
    return NO;
  return [self isEqualToTicket:other];
}

- (BOOL)isEqualToTicket:(KSTicket *)ticket {
  if (ticket == self)
    return YES;
  if (![productID_ isEqualToString:[ticket productID]])
    return NO;
  if (![version_ isEqualToString:[ticket version]])
    return NO;
  if (![existenceChecker_ isEqual:[ticket existenceChecker]])
    return NO;
  if (![serverURL_ isEqual:[ticket serverURL]])
    return NO;
  if (![creationDate_ isEqual:[ticket creationDate]])
    return NO;
  if (trustedTesterToken_ &&
      ![trustedTesterToken_ isEqual:[ticket trustedTesterToken]])
    return NO;
  return YES;
}

- (NSString *)description {
  NSString *tttokenString = @"";
  if (trustedTesterToken_) {
    tttokenString = [NSString stringWithFormat:@"\n\ttrustedTesterToken=%@",
                              trustedTesterToken_];
  }

  return [NSString stringWithFormat:
                   @"<%@:%p\n\tproductID=%@\n\tversion=%@\n\t"
                   @"xc=%@\n\turl=%@\n\tcreationDate=%@%@\n>",
                   [self class], self, productID_,
                   version_, existenceChecker_, serverURL_, creationDate_,
                   tttokenString];
}

- (NSString *)productID {
  return productID_;
}

- (NSString *)version {
  return version_;
}

- (KSExistenceChecker *)existenceChecker {
  return existenceChecker_;
}

- (NSURL *)serverURL {
  return serverURL_;
}

- (NSDate *)creationDate {
  return creationDate_;
}

- (NSString *)trustedTesterToken {
  return trustedTesterToken_;
}

@end
