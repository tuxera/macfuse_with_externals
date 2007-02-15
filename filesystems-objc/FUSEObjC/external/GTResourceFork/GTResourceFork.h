/*
	Copyright (c) 2006 Jonathan Grynspan.

	Permission is hereby granted, free of charge, to any person obtaining a copy of
	this software and associated documentation files (the "Software"), to deal in
	the Software without restriction, including without limitation the rights to use,
	copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
	Software, and to permit persons to whom the Software is furnished to do so,
	subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
	INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
	PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
	HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
	CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
	OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

#import <Cocoa/Cocoa.h>
#include <Carbon/Carbon.h>
#include <stdlib.h>
#include <string.h>

#pragma mark Resource Sections
typedef struct OpaqueGTResourceSectionStateStruct *GTResourceSectionStateRef;

#pragma mark -
#pragma mark String Encodings
extern const NSStringEncoding kGTResourceForkStringEncoding; /* i.e. MacRoman */
extern const CFStringEncoding kGTResourceForkCFStringEncoding; /* i.e. MacRoman */

#pragma mark -
@interface GTResourceFork : NSObject <NSCopying> {
	@protected short int refNum;
	@protected BOOL isTemporary;
}

/* returns the resource fork for the system file */
+ (GTResourceFork *)systemResourceFork;

/* returns the resource fork for a temporary file in the system's or user's temporary
   directory; the file is deleted when this object is deallocated */
- (id)init;
- (id)initWithData: (NSData *)data;

/* will create the file if it doesn't exist */
- (id)initWithContentsOfFile: (NSString *)filename;
- (id)initWithContentsOfFile: (NSString *)filename dataFork: (BOOL)df;
- (id)initWithContentsOfFile: (NSString *)filename dataFork: (BOOL)df error: (NSError **)outError;

/* if the URL is a file URL, will create the file if it doesn't exist; other URL types may fail */
- (id)initWithContentsOfURL: (NSURL *)url;
- (id)initWithContentsOfURL: (NSURL *)url dataFork: (BOOL)df;
- (id)initWithContentsOfURL: (NSURL *)url dataFork: (BOOL)df error: (NSError **)outError;

- (id)initWithContentsOfFSRef: (const FSRef *)ref;
- (id)initWithContentsOfFSRef: (const FSRef *)ref dataFork: (BOOL)df;
- (id)initWithContentsOfFSRef: (const FSRef *)ref dataFork: (BOOL)df error: (NSError **)outError;

- (id)initWithContentsOfFSRef: (const FSRef *)ref namedFork: (ConstHFSUniStr255Param)frk;
- (id)initWithContentsOfFSRef: (const FSRef *)ref namedFork: (ConstHFSUniStr255Param)frk error: (NSError **)outError;

/* Takes ownership of the refNumber; the Resource Manager file represented by refNumber will be
   closed when this object is deallocated. May return an existing GTResourceFork object if it
   already owns refNumber. Returns nil if no Resource Manager file is open with that reference
   number. */
- (id)initWithResourceManagerReferenceNumber: (short int)refNumber;
- (id)initWithResourceManagerReferenceNumber: (short int)refNumber error: (NSError **)outError; /* designated initializer */

- (void)dealloc;

- (BOOL)isEqual: (id)anObject;
- (BOOL)isEqualToResourceFork: (GTResourceFork *)resourceFork;
- (int)hash;

- (id)copyWithZone: (NSZone *)zone;

- (NSURL *)URL; /* -URL will generally be valid, but may also be temporary */

- (NSData *)dataRepresentation;

- (BOOL)writeToFile: (NSString *)filename dataFork: (BOOL)df;
- (BOOL)writeToURL: (NSURL *)aURL dataFork: (BOOL)df;
- (BOOL)writeToResourceFork: (GTResourceFork *)fork; /* other -writeTo* methods call this */
- (BOOL)write; /* -writeToResourceFork: calls this to synchronize to disk */

- (void)flushChanges; /* DEPRECATED: alias of -write */

/* wrap this in calls to -beginResourceSection and -endResourceSection: to ensure thread-safety
   on custom resource fork calls */
- (short int)resourceManagerReferenceNumber;

- (NSData *)dataForResource: (short int)ID ofType: (ResType)type;
- (NSData *)dataForNamedResource: (NSString *)name ofType: (ResType)type;

- (void)setData: (NSData *)data forResource: (short int)ID ofType: (ResType)type;
- (void)setData: (NSData *)data forNamedResource: (NSString *)name ofType: (ResType)type;

- (void)removeDataForResource: (short int)ID ofType: (ResType)type;
- (void)removeDataForNamedResource: (NSString *)name ofType: (ResType)type;
- (void)removeAllResourcesOfType: (ResType)type;

- (BOOL)hasResource: (short int)ID ofType: (ResType)type;
- (BOOL)hasNamedResource: (NSString *)name ofType: (ResType)type;

- (unsigned int)sizeOfResource: (short int)ID ofType: (ResType)type;
- (unsigned int)sizeOfNamedResource: (NSString *)name ofType: (ResType)type;

/* returns (SHRT_MAX + 1) on fail, SHRT_MIN-SHRT_MAX inclusive on success */
- (int)IDOfNamedResource: (NSString *)name ofType: (ResType)type;
- (NSString *)nameOfResource: (short int)ID ofType: (ResType)type;

- (void)setID: (short int)ID ofNamedResource: (NSString *)name ofType: (ResType)type;
/* Unlike SetResInfo(), passing an empty string for the name will actually set the
   name. However, doing so will invalidate the existing Handle for the represented
   resource. */
- (void)setName: (NSString *)name ofResource: (short int)ID ofType: (ResType)type;
@end

@interface GTResourceFork (ThreadSafety)
/* Use global resource sections when dealing with the Resource Manager in general, or when
   dealing with GTResourceFork's support structures/system. Use instance resource sections
   when dealing with a specific resource fork. */

/* if this method returns NULL, it is not safe to continue with resource operations; unlike
   -beginResourceSection, this method does not set the current resource fork */
+ (GTResourceSectionStateRef)beginGlobalResourceSection;
/* pass to this method the value returned by the previous call to -beginGlobalResourceSection */
+ (void)endGlobalResourceSection: (GTResourceSectionStateRef)state;

/* if this method returns NULL, it is not safe to continue with resource operations */
- (GTResourceSectionStateRef)beginResourceSection;
/* pass to this method the value returned by the previous call to -beginResourceSection */
- (void)endResourceSection: (GTResourceSectionStateRef)state;
@end

@interface GTResourceFork (Handles)
/* Returns an existing resource fork if available, or creates a new one if not; in any event, the returned
   object owns the Resource Manager reference number of the file that owns aResource, and will close it
   when it is deallocated. aResource is not explicitly disposed or released by this method, though the
   Resource Manager may do so upon or after the resultant object's deallocation. This method returns
   nil if aResource is not a Resource Manager handle. */
+ (GTResourceFork *)resourceForkOwningHandle: (Handle)aResource;

/* you can pass NULL for any out parameters you're not interested in; the method returns YES if
   data was got (even if all the out parameters are NULL), NO otherwise */
+ (BOOL)getInfoForHandle: (Handle)aResource type: (ResType *)outType name: (NSString * *)outName ID: (short int *)outID;

/* The resultant handles should only be considered valid for the lifetime of the receiver. Avoid
   releasing or disposing of these handles; due to limitations of the Resource Manager, there is
   no way to know if other parts of the software use the handle. You can override these methods
   to provide custom results, but know that any handles you create (e.g. with NewHandle(),
   NewHandleClear(), PtrToHand(), etc.) need to be disposed upon or after the receiver's deallocation. */
- (Handle)handleForResource: (short int)ID ofType: (ResType)type;
- (Handle)handleForNamedResource: (NSString *)name ofType: (ResType)type;

/* Does not take ownership of the handle. If the handle or its master pointer is NULL, returns NO;
   if the handle is not a resource handle, returns NO; if the handle is a valid resource handle,
   returns YES. */
- (BOOL)isOwnerOfHandle: (Handle)aHandle;
@end

@interface GTResourceFork (Enumeration)
- (unsigned int)countOfResources;
- (unsigned int)countOfTypes;
- (unsigned int)countOfResourcesOfType: (ResType)type;

/* returns 0 on fail, 128-SHRT_MAX inclusive on success */
- (short int)uniqueIDForType: (ResType)type;

/* returns an array of NSString objects, each holding a string representation of
   a ResType value. Each type in the array corresponds to a type in the fork for
   which there is at least one resource. */
- (NSArray *)usedTypes;

/* returns an array of NSNumber objects--each one has a shortValue corresponding
   to the resource ID of an existing resource of type 'type'. */
- (NSArray *)usedResourcesOfType: (ResType)type;

/* same idea as -usedResourcesOfType:, but NSStrings/names instead of NSNumbers/IDs */
- (NSArray *)usedResourceNamesOfType: (ResType)type;
@end

@interface GTResourceFork (Attributes)
- (short int)forkAttributes;
- (void)setForkAttributes: (short int)attrs;

- (short int)attributesForResource: (short int)ID ofType: (ResType)type;
- (short int)attributesForNamedResource: (NSString *)name ofType: (ResType)type;

- (void)setAttributes: (short int)attrs forResource: (short int)ID ofType: (ResType)type;
- (void)setAttributes: (short int)attrs forNamedResource: (NSString *)name ofType: (ResType)type;
@end

@interface GTResourceFork (SpecificTypes)
/* ===== 'TEXT', fallback to 'STR ' ===== */
- (NSString *)stringResource: (short int)ID;
- (NSString *)namedStringResource: (NSString *)name;

/* ===== 'STR#' -- note: arrays are 0-based, but GetIndString is 1-based ===== */
- (NSArray *)stringTableResource: (short int)ID;
- (NSArray *)namedStringTableResource: (NSString *)name;

/* ===== 'styl'/'TEXT' combo ===== */
- (NSAttributedString *)attributedStringResource: (short int)ID;
- (NSAttributedString *)namedAttributedStringResource: (NSString *)name;
- (NSAttributedString *)attributedStringResource: (short int)ID styleResource: (short int)styleID;
- (NSAttributedString *)namedAttributedStringResource: (NSString *)name styleResource: (NSString *)styleName;

/* ===== 'PICT' ===== */
- (NSImage *)imageResource: (short int)ID;
- (NSImage *)namedImageResource: (NSString *)name;

/* ===== 'snd ' ===== */
- (void)playSoundResource: (short int)ID;
- (void)playNamedSoundResource: (NSString *)name;

/* ===== 'crsr', fallback to 'CURS' -- only black & white right now ===== */
- (NSCursor *)cursorResource: (short int)ID;
- (NSCursor *)namedCursorResource: (NSString *)name;
@end

#pragma mark -
#pragma mark Support Functions
extern NSString *GTStringFromResType(ResType type); /* returns nil on fail */
extern ResType GTResTypeFromString(NSString *string); /* returns kUnknownType on fail */

/* The returned Pascal string is only valid until the end of the current autorelease pool;
   to extend its lifetime, you'll have to copy it (and use the copy, of course.) */
extern ConstStringPtr GTStringGetPascalString(NSString *aString); /* may return NULL */
extern NSString *GTPascalStringGetString(ConstStringPtr aString); /* may return nil */

extern unsigned int GTUnsignedIntFromSize(Size sz); /* used with GetHandleSize() and NSData creation */
extern Size GTSizeFromUnsignedInt(unsigned int ui); /* used with SetHandleSize() and Handle creation */
