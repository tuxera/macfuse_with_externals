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

#import "GTResourceFork.h"

#if defined(__cplusplus)
	#include <stdlib>
	#include <string>
	using namespace std;
	extern "C" {
#else
	#include <stdlib.h>
	#include <string.h>
#endif
	
#pragma mark Threading and Memory
#if defined(MF_APPLICATION)
	/* mFurc wraps malloc, etc. in inlined functions for debugging purposes */
	#include <FurcKit/GTMemory.h>

	/* mFurc uses a different implementation for the GTMutexRef type/functions */
	#include <FurcKit/GTThreading.h>
#else /* defined(MF_APPLICATION) */
	/* you can substitute your own memory management functions if you want (e.g.
       NewPtrClear/DisposePtr, or NSZoneCalloc/NSZoneFree), but you must ensure
       the allocated memory is zeroed before the macro/function returns. */
	#define GTAllocate(SIZE) calloc(1, SIZE)
	#define GTFree(PTR) free(PTR)

	/* you can use some other implementation here too */
	typedef NSRecursiveLock *GTMutexRef;
	#define GTMutexCreate(RECURSIVE) ((RECURSIVE) ? [[NSRecursiveLock alloc] init] : [[NSLock alloc] init])
	#define GTMutexDestroy(MUTEX) [(MUTEX) release]
	#define GTMutexLock(MUTEX) ({ id __mutex = (MUTEX); [__mutex lock]; (__mutex != nil); })
	#define GTMutexTryLock(MUTEX) [(MUTEX) tryLock]
	#define GTMutexUnlock(MUTEX) ({ id __mutex = (MUTEX); [__mutex unlock]; (__mutex != nil); })
#endif /* defined(MF_APPLICATION) */

#pragma mark -
#pragma mark Global Variables
/* the global mutex for the Resource Manager */
static GTMutexRef resourcesMutex = (GTMutexRef)0;
/* This is a CFMutableDictionary instead of an NSMutableDictionary because we don't
   want to mess with the retain counts for values--if we do, we could end up unable to
   deallocate a resource fork because the table will always reference it. */
/* The reason we have this dictionary at all is so that two GTResourceFork objects aren't
   created that have the same reference number. If they were, and one is deallocated,
   it will close the reference number, leaving the other with an invalid reference
   number. Better to maintain only one GTResourceFork object per reference number. */
static CFMutableDictionaryRef activeResourceForks = NULL;
/* This is just a short function to get the key from a refnum (duh.) I use it instead of
   CFNumberCreate() for slightly shorter code (and so I don't have to worry about releasing
   the key and associated potential memory leaks.) I do not check that the result is
   non-NULL; This may potentially be an error condition. */
static inline __attribute__((__always_inline__)) CFNumberRef GTGetKeyForRefNum(ResFileRefNum num) {
	return (CFNumberRef)[NSNumber numberWithShort: (short int)num];
}

#pragma mark -
#pragma mark Resource Sections
/* Used when beginning and ending a "resource section", which locks access to the
   Resource Manager so one can send multiple GTResourceFork messages or call
   multiple Resource Manager functions. */
struct OpaqueGTResourceSectionStateStruct {
	ResFileRefNum lastRefNum;
	id unretainedOwner;
};

#pragma mark -
#pragma mark String Encodings
const NSStringEncoding GTResourceForkStringEncoding = NSMacOSRomanStringEncoding;
const CFStringEncoding kGTResourceForkCFStringEncoding = kCFStringEncodingMacRoman;

#pragma mark -
#pragma mark Private GTResourceFork Category Interfaces
@interface GTResourceFork (Styles)
- (NSAttributedString *)attributedStringFromString: (NSString *)str andStyleHandle: (Handle)hand;
- (NSColor *)colorForStyleEntry: (ScrpSTElement *)entry; 
- (NSFont *)fontForStyleEntry: (ScrpSTElement *)entry;
- (NSFontTraitMask)traitMaskForStyleEntry: (ScrpSTElement *)entry;
@end

@interface GTResourceFork (Cursors)
- (NSCursor *)cursorFromcrsrResource: (Handle)cursHand;
- (NSCursor *)cursorFromCURSResource: (Handle)cursHand;
- (NSImageRep *)imageRepWithBits16Data: (const Bits16)data andMask: (const Bits16)mask;
//- (NSImageRep *)imageRepWithColorCursor: (CCrsrPtr)cursor;
@end

#pragma mark -
#pragma mark GTResourceFork Implementation
@implementation GTResourceFork
+ (void)initialize {
	CFDictionaryValueCallBacks valueCallbacks;
	
	resourcesMutex = GTMutexCreate(YES);
	
	/* don't want to mess with the retain count of the values */
	valueCallbacks.version = 0;
	valueCallbacks.retain = NULL;
	valueCallbacks.release = NULL;
	valueCallbacks.copyDescription = NULL;
	valueCallbacks.equal = NULL;

	activeResourceForks = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &valueCallbacks);
}

+ (GTResourceFork *)systemResourceFork {
	static GTResourceFork *sysFork = nil;
	GTResourceSectionStateRef state;
	
	/* only create one resource fork object for the system resource fork */
	if (NULL != (state = [self beginGlobalResourceSection])) {
		if (!sysFork)
			sysFork = [[GTResourceFork alloc] initWithResourceManagerReferenceNumber: kSystemResFile error: NULL];
		[self endGlobalResourceSection: state];
	}
	
	return [[sysFork retain] autorelease];
}

- (id)init {
	return [self initWithData: nil];
}

- (id)initWithData: (NSData *)data {
	CFUUIDRef uuid;
	CFStringRef uuidString;
	NSString *tempPath;

	/* get the temporary path */
	tempPath = nil;
	uuid = CFUUIDCreate(NULL);
	if (uuid) {
		uuidString = CFUUIDCreateString(NULL, uuid);
		if (uuidString) {
			tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent: [NSString stringWithFormat: @"GTResourceFork-%@", uuidString]];
			CFRelease(uuidString);
		}
		CFRelease(uuid);
	}
	
	/* write the resource-fork-as-data to the temporary file */
	if (tempPath && data) {
		[data writeToFile: tempPath atomically: YES];
	}

	/* proceed as normal */
	self = [self initWithContentsOfFile: tempPath dataFork: YES];
	if (self)
		self->isTemporary = YES;
	
	return self;
}

- (id)initWithContentsOfFile: (NSString *)filename {
	return [self initWithContentsOfFile: filename dataFork: NO error: NULL];
}

- (id)initWithContentsOfFile: (NSString *)filename dataFork: (BOOL)df {
	return [self initWithContentsOfFile: filename dataFork: df error: NULL];
}

- (id)initWithContentsOfFile: (NSString *)filename dataFork: (BOOL)df error: (NSError **)outError {
	/* +fileURLWithPath: throws on nil */
	if (filename)
		return [self initWithContentsOfURL: [NSURL fileURLWithPath: filename] dataFork: df error: outError];
	else
		return [self initWithContentsOfURL: nil dataFork: df error: outError];
}

- (id)initWithContentsOfURL: (NSURL *)url {
	return [self initWithContentsOfURL: url dataFork: NO error: NULL];
}

- (id)initWithContentsOfURL: (NSURL *)url dataFork: (BOOL)df {
	return [self initWithContentsOfURL: url dataFork: df error: NULL];
}

- (id)initWithContentsOfURL: (NSURL *)url dataFork: (BOOL)df error: (NSError **)outError {
	FSRef ref;
	
	/* make sure the URL can be used with the resource manager and that the file exists, even if empty */
	if (url) {
		if ([url isFileURL] && ![[NSFileManager defaultManager] fileExistsAtPath: [url path]]) {
			if (![[NSData data] writeToFile: [url path] atomically: YES])
				url = nil;
		}
	}

	/* URL -> FSRef, create object */
	if (url && CFURLGetFSRef((CFURLRef)url, &ref)) {
		return [self initWithContentsOfFSRef: &ref dataFork: df error: outError];
	}
	
	/* some error above */
	return [self initWithContentsOfFSRef: NULL namedFork: NULL error: outError];
}

- (id)initWithContentsOfFSRef: (const FSRef *)ref {
	return [self initWithContentsOfFSRef: ref dataFork: NO error: NULL];
}

- (id)initWithContentsOfFSRef: (const FSRef *)ref dataFork: (BOOL)df {
	return [self initWithContentsOfFSRef: ref dataFork: df error: NULL];
}

- (id)initWithContentsOfFSRef: (const FSRef *)ref dataFork: (BOOL)df error: (NSError **)outError {
	HFSUniStr255 forkName;
	OSErr error;
	
	if (ref) {
		/* get the name for the resource fork */
		if (df)
			error = FSGetDataForkName(&forkName);
		else
			error = FSGetResourceForkName(&forkName);
		
		/* proceed as normal */
		if (error == noErr) {
			return [self initWithContentsOfFSRef: ref namedFork: &forkName error: outError];
		}
	}
	
	/* some error above */
	return [self initWithContentsOfFSRef: NULL namedFork: NULL error: outError];
}

- (id)initWithContentsOfFSRef: (const FSRef *)ref namedFork: (ConstHFSUniStr255Param)frk {
	return [self initWithContentsOfFSRef: ref namedFork: frk error: NULL];
}

- (id)initWithContentsOfFSRef: (const FSRef *)ref namedFork: (ConstHFSUniStr255Param)forkName error: (NSError **)outError {
	GTResourceSectionStateRef state;
	OSErr error;
	ResFileRefNum refNumber;

	self = [super init];
	
	if (self) {
		/* if left unchanged, will cause self to be released/nilled on
		   call to -initWithResourceManagerReferenceNumber:error: */
		refNumber = -1;
		
		if (!ref || !forkName) {
			error = paramErr;
		} else {
			/* no error by default, natch */
			error = noErr;
			
			if (NULL != (state = [[self class] beginGlobalResourceSection])) {
				/* create the fork */
				if (error == noErr) {
					error = FSCreateResourceFork(ref, forkName->length, forkName->unicode, 0);
					if (error == errFSForkExists)
						error = noErr;
				}
				
				/* open the fork */
				if (error == noErr) {
					error = FSOpenResourceFile(ref, forkName->length, forkName->unicode, fsRdWrPerm, &refNumber);
					if (error != noErr)
						refNumber = -1;
				}
				
				/* exit resource section */
				[[self class] endGlobalResourceSection: state];
			} else {
				/* failed to enter resource section */
				error = notLockedErr;
			}
		}
		
		/* catch errors */
		self = [self initWithResourceManagerReferenceNumber: refNumber error: outError];
		if (error != noErr) {
			if (outError) {
				*outError = [NSError errorWithDomain: NSOSStatusErrorDomain code: (int)error userInfo: nil];
			}
		}
	}
	
	return self;
}

- (id)initWithResourceManagerReferenceNumber: (ResFileRefNum)refNumber {
	return [self initWithResourceManagerReferenceNumber: refNumber error: NULL];
}

- (id)initWithResourceManagerReferenceNumber: (ResFileRefNum)refNumber error: (NSError **)outError {
	GTResourceFork *otherFork;
	GTResourceSectionStateRef state;
	CFNumberRef key;
	OSErr error;
	
	self = [super init];

	if (self) {
		self->refNum = -1;
		error = noErr;

		if (refNumber >= 0) {
			if (NULL != (state = [[self class] beginGlobalResourceSection])) {
				/* check if the refNumber is in use */
				key = GTGetKeyForRefNum(refNumber);
				otherFork = (GTResourceFork *)CFDictionaryGetValue(activeResourceForks, key);
			
				if (otherFork) {
					/* is already open, so kill self and replace with otherFork */
					[self release];
					self = [otherFork retain];
				} else {
					/* isn't already open, so creating a new fork object */

					/* check if the refNumber is open by calling GetResFileAttrs and then checking ResError */
					(void)GetResFileAttrs(refNumber);
					error = ResError();
					
					if (error == noErr) {
						/* success, set fields */
						self->refNum = refNumber;
						self->isTemporary = NO;
						
						/* add to dictionary so it'll be used again */
						CFDictionarySetValue(activeResourceForks, key, self);
					}
				}
				
				/* exit section */
				[[self class] endGlobalResourceSection: state];
			} else {
				/* couldn't enter section, so fail */
				error = notLockedErr;
			}
		} else {
			/* refNumber is less than 0, so is invalid */
			error = paramErr;
		}
		
		if (error != noErr) {
			/* error occurred, free self */
			[self release];
			self = nil;

			if (outError)
				*outError = [NSError errorWithDomain: NSOSStatusErrorDomain code: (int)error userInfo: nil];
		}
	}
	
	return self;
}

- (id)retain {
	id result;
	GTResourceSectionStateRef state;
	
	/* the lock here is so that the call in -release to -retainCount is not interrupted
	   by this call to -retain; if it fails, still retain */
	state = [[self class] beginGlobalResourceSection];
	result = [super retain];
	[[self class] endGlobalResourceSection: state];
	
	return result;
}

- (void)release {
	GTResourceSectionStateRef state;

	/* have to do this in -release rather than in -dealloc because of the following possibility:
			Thread 0:						Thread 1:
			[aFork release];
											newFork = [[GTResourceFork alloc] initWithResourceManagerReferenceNumber: aFork's number];
			[aFork dealloc];
	*/
	state = [[self class] beginGlobalResourceSection];
	if ([self retainCount] == 1) {
		/* last release -- remove self from the table, so that
		   future resource forks on the same refNum will create
		   their own objects */
		CFDictionaryRemoveValue(activeResourceForks, GTGetKeyForRefNum(self->refNum));
		
		/* To ensure that another resource fork object does not attempt to reference
		   this one's refnum in its final moments, close the resource file here instead
		   of in -dealloc */
		if (self->refNum > 0) {
			/* let Resource Manager know we're done */
			CloseResFile(self->refNum);
			/* Ensure any possible future messages don't attempt to use our refnum */
			self->refNum = -1;
		}
	}
	[[self class] endGlobalResourceSection: state];
	
	[super release];
}

- (void)dealloc {
	NSURL *url;

	if (self->isTemporary) {
		/* delete file on disk */
		url = [self URL];
		if (url && [url isFileURL])
			[[NSFileManager defaultManager] removeFileAtPath: [url path] handler: nil];
	}
	
	/* CloseResFile() is called in -release */
	
	[super dealloc];
}


- (BOOL)isEqual: (id)anObject {
	if ([anObject isKindOfClass: [GTResourceFork class]]) {
		return [self isEqualToResourceFork: anObject];
	}
	
	return NO;
}

- (BOOL)isEqualToResourceFork: (GTResourceFork *)resourceFork {
	return [self resourceManagerReferenceNumber] == [resourceFork resourceManagerReferenceNumber];
}

- (unsigned int)hash {
	return (unsigned int)[self resourceManagerReferenceNumber];
}

- (id)copyWithZone: (NSZone *)zone {
	return [self retain];
}

- (void)copyResourcesToResourceFork: (GTResourceFork *)otherFork {
	NSEnumerator *e;
	NSString *type;
	GTResourceSectionStateRef state;
	
	if (!otherFork || otherFork == self)
		return;
	
	if (NULL != (state = [self beginResourceSection])) {
		e = [[self usedTypes] objectEnumerator];
		while ((type = [e nextObject]) != nil) {
			[self copyResourcesOfType: GTResTypeFromString(type) toResourceFork: otherFork];
		}
		
		[self endResourceSection: state];
	}
}

- (void)copyResourcesOfType: (ResType)type toResourceFork: (GTResourceFork *)otherFork {
	GTResourceSectionStateRef state;

	if (!otherFork || otherFork == self)
		return;

	if (NULL != (state = [self beginResourceSection])) {
		[self copyResources: [self usedResourcesOfType: type] ofType: type toResourceFork: otherFork];
		[self endResourceSection: state];
	}
}

- (void)copyResources: (NSArray *)resIDs ofType: (ResType)type toResourceFork: (GTResourceFork *)otherFork {
	NSEnumerator *e;
	NSNumber *resIDNumber;
	GTResourceSectionStateRef state;
	NSData *resData;
	ResID resID;

	if (!otherFork || otherFork == self)
		return;
	else if (!resIDs || [resIDs count] < 1)
		return;
	
	/* global resource section so we can deal with multiple forks at a time */
	if (NULL != (state = [[self class] beginGlobalResourceSection])) {
		e = [resIDs objectEnumerator];
		while ((resIDNumber = [e nextObject]) != nil) {
			/* get the resource ID number */
			resID = (ResID)[resIDNumber shortValue];
			/* get the resource data */
			resData = [self dataForResource: resID ofType: type];
			/* set it on the other fork */
			[otherFork setData: resData forResource: resID withName: [self nameOfResource: resID ofType: type] ofType: type];
		}
		
		[[self class] endGlobalResourceSection: state];
	}	
}

- (NSURL *)URL {
	NSURL *result;
	FSRef fsRef;
	
	result = nil;
	if (FSGetForkCBInfo([self resourceManagerReferenceNumber], 0, NULL, NULL, NULL, &fsRef, NULL) == noErr) {
		result = (NSURL *)CFURLCreateFromFSRef(NULL, &fsRef);
		result = [result autorelease];
	}
	
	return result;
}

- (NSData *)dataRepresentation {
	NSData *result;
	NSMutableData *mutResult;
	GTResourceSectionStateRef state;
	char buffer[512];
	SInt64 offset;
	ByteCount got;
	OSErr error;
	ResFileRefNum myRefNum;
	
	/* iterates through the resource fork as a byte stream, reading it in
	   512 bytes at a time, outputting to mutResult, and returning an
	   immutable copy thereof */
	
	mutResult = nil;
	if (NULL != (state = [self beginResourceSection])) {
		/* make sure changes are synchronized */
		[self write];
		
		/* capacity of 16KB by default */
		mutResult = [[NSMutableData alloc] initWithCapacity: 16384];
		offset = S64SetU(0);
		got = 0;
		myRefNum = [self resourceManagerReferenceNumber];
		
		do {
			/* read a chunk of data from the fork */
			error = FSReadFork(myRefNum, fsFromStart, offset, (ByteCount)sizeof(buffer), buffer, &got);
			if (error != noErr && error != eofErr)
				break;
			
			/* write that chunk to the result object */
			[mutResult appendBytes: buffer length: (unsigned int)got];
			
			/* update the offset */
			offset = S64Add(offset, S64SetU(got));
		} while (got > 0);
		
		[self endResourceSection: state];
	}
	
	result = [[mutResult copy] autorelease];
	[mutResult release];
	return result;
}

- (NSString *)description {
	return [NSString stringWithFormat: @"%@ { ResFileRefNum: %i }", [super description], (int)[self resourceManagerReferenceNumber]];
}

- (BOOL)writeToFile: (NSString *)filename dataFork: (BOOL)df {
	if (filename)
		return [self writeToURL: [NSURL fileURLWithPath: filename] dataFork: df];
	else
		return NO;
}

- (BOOL)writeToURL: (NSURL *)aURL dataFork: (BOOL)df {
	GTResourceFork *tempFork;
	BOOL result;
	
	if ([aURL isEqual: [self URL]]) {
		/* don't need to create a temp object */
		result = [self write];
	} else {
		/* fail by default */
		result = NO;
		/* create a temp object attached to the passed URL, then write *that* object */
		tempFork = [[GTResourceFork alloc] initWithContentsOfURL: aURL dataFork: df];
		if (tempFork) {
			/* write self to temp */
			result = [self writeToResourceFork: tempFork];
			/* sync */
			[tempFork write];
			/* free mem */
			[tempFork release];
		}	
	}
	
	return result;
}

- (BOOL)writeToResourceFork: (GTResourceFork *)fork {
	NSAutoreleasePool *pool;
	NSData *data;
	GTResourceSectionStateRef state;
	ByteCount written;
	ResFileRefNum forkRefNum;
	BOOL success;
	
	pool = [[NSAutoreleasePool alloc] init];
	fork = [[fork retain] autorelease];
	success = NO;

	if (fork) {
		data = [self dataRepresentation];
		
		if (NULL != (state = [fork beginResourceSection])) {
			forkRefNum = [fork resourceManagerReferenceNumber];
			written = 0;
			
			/* first, set the fork size to the size of the outgoing data; this will prevent extraneous
			   data trailing at the end of the file */
			success = (noErr == FSSetForkSize(forkRefNum, fsFromStart, S64SetU([data length])));
			if (success) {
				/* now, write the data to the fork */
				success = (noErr == FSWriteFork(forkRefNum, fsFromStart, S64SetU(0), (ByteCount)[data length], [data bytes], &written));
				if (success) {
					/* write that fork to disk */
					success = [fork write];
				}
			}
			[fork endResourceSection: state];
		}
	}
	
	[pool release];
	return success;
}

- (BOOL)write {
	GTResourceSectionStateRef state;
	BOOL result;
	
	result = NO;
	if (NULL != (state = [self beginResourceSection])) {
		/* the Resource Manager function for this */
		UpdateResFile([self resourceManagerReferenceNumber]);
		/* if there was a problem writing, ResError() is set */
		result = (ResError() == noErr);
		[self endResourceSection: state];
	}
	
	return result;
}

- (void)flushChanges {
	NSLog(@"calling deprecated method -[GTResourceFork flushChanges]; use -write instead");
	(void)[self write];
}

- (ResFileRefNum)resourceManagerReferenceNumber {
	/* If in a multithreaded environment, be sure to call -beginResourceSection
	   first and -endResourceSection: after! This class doesn't always obey this
	   rule, but when it breaks it it's for good reason (e.g. deallocating self.) */

	return self->refNum;
}

- (NSData *)dataForResource: (ResID)resID ofType: (ResType)type {
	Handle hand;

	hand = [self handleForResource: resID ofType: type];
	if (hand && *hand) {
		return [NSData dataWithBytes: *hand length: GTUnsignedIntFromSize(GetHandleSize(hand))];
	} else {
		return nil;
	}
}

- (NSData *)dataForNamedResource: (NSString *)name ofType: (ResType)type {
	Handle hand;

	hand = [self handleForNamedResource: name ofType: type];
	if (hand && *hand) {
		return [NSData dataWithBytes: *hand length: GTUnsignedIntFromSize(GetHandleSize(hand))];
	} else {
		return nil;
	}
}

- (void)setData: (NSData *)data forResource: (ResID)resID ofType: (ResType)type {
	[self setData: data forResource: resID withName: nil ofType: type];
}

- (void)setData: (NSData *)data forNamedResource: (NSString *)name ofType: (ResType)type {
	GTResourceSectionStateRef state;
	ResID resID;
	
	if (NULL != (state = [self beginResourceSection])) {
		if ([self getUniqueID: &resID forType: type]) {
			[self setData: data forResource: resID withName: name ofType: type];
		}
		[self endResourceSection: state];
	}
}

- (void)setData: (NSData *)data forResource: (ResID)resID withName: (NSString *)name ofType: (ResType)type {
	ConstStringPtr pascStr;
	GTResourceSectionStateRef state;
	Handle hand;
	
	if (NULL != (state = [self beginResourceSection])) {
		[self removeDataForNamedResource: name ofType: type];
	
		if (!name)
			name = @"";
		pascStr = GTStringGetPascalString(name);

		if (data && pascStr) {
			hand = NULL;
			if (noErr == PtrToHand([data bytes], &hand, GTSizeFromUnsignedInt([data length]))) {
				/* got ID, yay */
				AddResource(hand, type, resID, pascStr);
				if (noErr == ResError()) {
					/* success adding resource */
					ChangedResource(hand);
				} else {
					/* failure */
					DisposeHandle(hand);
				}
			}
		}

		[self endResourceSection: state];
	}
}

- (void)removeDataForResource: (ResID)resID ofType: (ResType)type {
	GTResourceSectionStateRef state;
	Handle hand;
	
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForResource: resID ofType: type];
		if (hand) {
			RemoveResource(hand);
			/* the handle is orphaned by RemoveResource() */
			DisposeHandle(hand);
		}
		[self endResourceSection: state];
	}
}

- (void)removeDataForNamedResource: (NSString *)name ofType: (ResType)type {
	GTResourceSectionStateRef state;
	Handle hand;
	
	if (!name)
		return;
	
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForNamedResource: name ofType: type];
		if (hand) {
			RemoveResource(hand);
			/* the handle is orphaned by RemoveResource() */
			DisposeHandle(hand);
		}
		[self endResourceSection: state];
	}
}

- (void)removeAllResourcesOfType: (ResType)type {
	GTResourceSectionStateRef state;
	Handle hand;
	unsigned int resCount;
	
	if (NULL != (state = [self beginResourceSection])) {
		resCount = [self countOfResourcesOfType: type];
		unsigned int i = 0; for (; i < resCount; i++) {
			hand = Get1IndResource(type, i + 1);
			if (hand) {
				RemoveResource(hand);
				/* the handle is orphaned by RemoveResource() */
				DisposeHandle(hand);
			}
		}
		[self endResourceSection: state];
	}
}

- (BOOL)hasResource: (ResID)resID ofType: (ResType)type {
	/* no Resource Manager function to specifically check for the existence of a resource, so must load it */
	return [self handleForResource: resID ofType: type] ? YES : NO;
}

- (BOOL)hasNamedResource: (NSString *)name ofType: (ResType)type {
	/* no Resource Manager function to specifically check for the existence of a resource, so must load it */
	return [self handleForNamedResource: name ofType: type] ? YES : NO;
}

- (unsigned int)sizeOfResource: (ResID)resID ofType: (ResType)type {
	GTResourceSectionStateRef state;
	Handle hand;
	unsigned int result;
	
	result = 0;
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForResource: resID ofType: type];
		if (hand && *hand)
			result = GTUnsignedIntFromSize(GetHandleSize(hand));
		[self endResourceSection: state];
	}
	
	return result;	
}

- (unsigned int)sizeOfNamedResource: (NSString *)name ofType: (ResType)type {
	GTResourceSectionStateRef state;
	Handle hand;
	unsigned int result;
	
	result = 0;
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForNamedResource: name ofType: type];
		if (hand && *hand)
			result = GTUnsignedIntFromSize(GetHandleSize(hand));
		[self endResourceSection: state];
	}
	
	return result;
}

- (BOOL)getID: (ResID *)outID ofNamedResource: (NSString *)name ofType: (ResType)type {
	Handle hand;
	GTResourceSectionStateRef state;
	ResID theID;
	BOOL gotIt;
	
	theID = 0;
	gotIt = NO;
	
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForNamedResource: name ofType: type];
		if (hand) {
			if ([[self class] getInfoForHandle: hand type: NULL name: NULL ID: &theID]) {
				gotIt = YES;
			}
		}
		
		[self endResourceSection: state];
	}
	
	if (gotIt) {
		if (outID)
			*outID = theID;
	}
	return gotIt;
}

- (NSString *)nameOfResource: (ResID)resID ofType: (ResType)type {
	NSString *result;
	Handle hand;
	GTResourceSectionStateRef state;
	
	result = nil;
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForResource: resID ofType: type];
		if (hand) {
			if (![[self class] getInfoForHandle: hand type: NULL name: &result ID: NULL]) {
				result = nil;
			}
		}
		
		[self endResourceSection: state];
	}
	
	return result;
}

- (void)setID: (ResID)resID ofNamedResource: (NSString *)name ofType: (ResType)type {
	Handle hand;
	GTResourceSectionStateRef state;
	
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForNamedResource: name ofType: type];
		if (hand) {
			/* Passing an empty Pascal string as the name does not change
			   it, so there's no need to call GTStringGetPascalString() here. */
			SetResInfo(hand, resID, "\p");
		}
		[self endResourceSection: state];
	}
}

- (void)setName: (NSString *)name ofResource: (ResID)resID ofType: (ResType)type {
	NSData *data;
	Handle hand;
	GTResourceSectionStateRef state;
	
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForResource: resID ofType: type];
		if (hand) {
			if (!name || [name length] < 1) {
				/* SetResInfo() won't change the name if the passed string is
				   empty, so have to go about it a different way. Delete the existing
				   resource, then add a new one with the same ID and no name. */
				data = [NSData dataWithBytes: *hand length: GTUnsignedIntFromSize(GetHandleSize(hand))];
				[self removeDataForResource: resID ofType: type];
				[self setData: data forResource: resID ofType: type];
			} else {
				/* Can do it the normal way. */
				SetResInfo(hand, resID, GTStringGetPascalString(name));
			}
		}
		[self endResourceSection: state];
	}
}
@end

@implementation GTResourceFork (ThreadSafety)
+ (GTResourceSectionStateRef)beginGlobalResourceSection {
	struct OpaqueGTResourceSectionStateStruct *result;
	
	/* Creates a pointer to a state structure, locks the resource mutex, fills the
	   state with the currently-selected resource file refnum, returns pointer to state. */

	result = GTAllocate(sizeof(struct OpaqueGTResourceSectionStateStruct));
	if (result) {
		if (GTMutexLock(resourcesMutex)) {
			result->lastRefNum = CurResFile();
			result->unretainedOwner = self;
		} else {
			/* couldn't obtain lock, must release memory to avoid leak */
			GTFree(result);
			result = NULL;
		}
	}
	
	return result;
}

+ (void)endGlobalResourceSection: (GTResourceSectionStateRef)state {
	/* Restores the currently-used resource file to its old refnum, unlocks the
	   resource mutex, and frees the allocated memory. */
	
	if (state) {
		UseResFile(state->lastRefNum);
		GTMutexUnlock(resourcesMutex);
		GTFree(state);
	}
}

- (GTResourceSectionStateRef)beginResourceSection {
	struct OpaqueGTResourceSectionStateStruct *result;
	
	result = [[self class] beginGlobalResourceSection];
	if (result) {
		result->unretainedOwner = self;
		UseResFile([self resourceManagerReferenceNumber]);
	}
	
	return result;
}

- (void)endResourceSection: (GTResourceSectionStateRef)state {
	/* don't rely on this behaviour being identical in the future */
	[[self class] endGlobalResourceSection: state];
}

+ (id)ownerOfResourceSectionState: (GTResourceSectionStateRef)state {
	if (state) {
		return [[state->unretainedOwner retain] autorelease];
	}
	
	return nil;
}
@end

@implementation GTResourceFork (Handles)
+ (GTResourceFork *)resourceForkOwningHandle: (Handle)aResource {
	return [self resourceForkOwningHandle: aResource createIfNotFound: YES];
}

+ (GTResourceFork *)resourceForkOwningHandle: (Handle)aResource createIfNotFound: (BOOL)create {
	GTResourceSectionStateRef state;
	GTResourceFork *result;
	ResFileRefNum refNum;

	result = nil;
	if (NULL != (state = [self beginGlobalResourceSection])) {
		refNum = HomeResFile(aResource);
		if (ResError() == noErr) {
			/* fork exists! */
			if (refNum == 0) {
				/* system resource fork */
				result = [self systemResourceFork];
			} else if (refNum > 0) {
				/* see if a fork exists and use it if it does */
				result = (GTResourceFork *)CFDictionaryGetValue(activeResourceForks, GTGetKeyForRefNum(refNum));
				if (result) {
					/* existing GTResourceFork object */
					result = [[result retain] autorelease];
				} else if (create) {
					/* user wants to create a new fork object where none yet exists */
					result = [[[self alloc] initWithResourceManagerReferenceNumber: refNum error: NULL] autorelease];
				}
			}
		}
		[self endGlobalResourceSection: state];
	}
	
	return result;
}

+ (BOOL)getInfoForHandle: (Handle)aResource type: (ResType *)outType name: (NSString * *)outName ID: (ResID *)outID {
	GTResourceSectionStateRef state;
	Str255 pascStr;
	ResType type;
	ResID resID;
	BOOL result;

	result = NO;
	if (NULL != (state = [self beginGlobalResourceSection])) {
		GetResInfo(aResource, &resID, &type, pascStr);
		if (ResError() == noErr) {
			/* get the type */
			if (outType) {
				*outType = type;
			}
			
			/* get the ID */
			if (outID) {
				*outID = resID;
			}
			
			/* get the name */
			if (outName) {
				*outName = GTPascalStringGetString((ConstStringPtr)pascStr);
			}

			result = YES;
		}
		
		[self endGlobalResourceSection: state];
	}
	
	return result;
}

- (Handle)handleForResource: (ResID)resID ofType: (ResType)type {
	GTResourceSectionStateRef state;
	Handle hand;

	hand = NULL;
	if (NULL != (state = [self beginResourceSection])) {
		hand = Get1Resource(type, resID);
		[self endResourceSection: state];
	}
	
	return hand;
}

- (Handle)handleForNamedResource: (NSString *)name ofType: (ResType)type {
	ConstStringPtr pascStr;
	GTResourceSectionStateRef state;
	Handle hand;

	/* result pointer */
	hand = NULL;
	
	pascStr = GTStringGetPascalString(name);
	if (pascStr) {
		if (NULL != (state = [self beginResourceSection])) {
			hand = Get1NamedResource(type, pascStr);
			[self endResourceSection: state];
		}
	}
	
	return hand;
}

- (Handle)copyHandleForResource: (ResID)resID ofType: (ResType)type {
	return GTCopyHandle([self handleForResource: resID ofType: type]);
}

- (Handle)copyHandleForNamedResource: (NSString *)name ofType: (ResType)type {
	return GTCopyHandle([self handleForNamedResource: name ofType: type]);
}

- (BOOL)isOwnerOfHandle: (Handle)aHandle {
	GTResourceSectionStateRef state;
	ResFileRefNum ownerRefNum;
	BOOL result;
	
	result = NO;
	if (NULL != (state = [self beginResourceSection])) {
		
		if (aHandle && *aHandle) {
			ownerRefNum = HomeResFile(aHandle);
			if (ResError() == noErr)
				result = ([self resourceManagerReferenceNumber] == ownerRefNum);
		}
		
		[self endResourceSection: state];
	}
	
	return result;
}
@end

@implementation GTResourceFork (Enumeration)
- (unsigned int)countOfResources {
	GTResourceSectionStateRef state;
	uintmax_t result;
	ResType type;
	unsigned int typeCount;
	
	result = 0;
	if (NULL != (state = [self beginResourceSection])) {
		typeCount = [self countOfTypes];
		
		unsigned int i = 1; for (; i <= typeCount; i++) {
			Get1IndType(&type, i);
			result += [self countOfResourcesOfType: type];
		}
		
		[self endResourceSection: state];
	}
	
	if (result > UINT_MAX)
		result = UINT_MAX;
	
	return result;
}

- (unsigned int)countOfTypes {
	GTResourceSectionStateRef state;
	unsigned int result;
	
	result = 0;
	if (NULL != (state = [self beginResourceSection])) {
		result = (unsigned int)Count1Types();
		[self endResourceSection: state];
	}
	
	return result;
}

- (unsigned int)countOfResourcesOfType: (ResType)type {
	GTResourceSectionStateRef state;
	unsigned int result;
	
	result = 0;
	if (NULL != (state = [self beginResourceSection])) {
		result = (unsigned int)Count1Resources(type);
		[self endResourceSection: state];
	}
	
	return result;
}

- (BOOL)getUniqueID: (ResID *)outID forType: (ResType)type {
	GTResourceSectionStateRef state;
	ResID result;
	BOOL gotIt;
	
	result = 0;
	gotIt = NO;
	
	if (NULL != (state = [self beginResourceSection])) {
		/* System 7 has a bug in this function requiring a while
		   loop, but this is Mac OS X! */
		result = Unique1ID(type);
		gotIt = (ResError() == noErr);
		[self endResourceSection: state];
	}
	
	if (gotIt) {
		if (outID)
			*outID = result;
	}
	return gotIt;
}

- (NSArray *)usedTypes {
	NSMutableArray *result;
	GTResourceSectionStateRef state;
	ResType type;
	unsigned int typeCount;
	
	result = nil;
	if (NULL != (state = [self beginResourceSection])) {
		result = [NSMutableArray array];		
		typeCount = [self countOfTypes];

		unsigned int i = 1; for (; i <= typeCount; i++) {
			Get1IndType(&type, i);
			[result addObject: GTStringFromResType(type)];
		}
		
		[self endResourceSection: state];
	}
	
	return [[result copy] autorelease];
}

- (NSArray *)usedResourcesOfType: (ResType)type {
	NSMutableArray *result;
	GTResourceSectionStateRef state;
	Handle hand;
	unsigned int resCount;
	ResID resID;

	result = nil;
	if (NULL != (state = [self beginResourceSection])) {
		result = [NSMutableArray array];
		resCount = [self countOfResourcesOfType: type];
		
		unsigned int i = 1; for (; i <= resCount; i++) {
			hand = Get1IndResource(type, i);
			if (hand) {
				/* find out the ID number */
				if ([[self class] getInfoForHandle: hand type: NULL name: NULL ID: &resID]) {
					if (sizeof(ResID) == sizeof(short int))
						[result addObject: [NSNumber numberWithShort: resID]];
					else
						[result addObject: [NSNumber numberWithLongLong: (long long int)resID]];
				}
			}
		}
		
		[self endResourceSection: state];
	}
	
	return [[result copy] autorelease];
}

- (NSArray *)usedResourceNamesOfType: (ResType)type {
	NSMutableArray *result;
	NSString *name;
	GTResourceSectionStateRef state;
	Handle hand;
	unsigned int resCount;
	
	result = nil;
	if (NULL != (state = [self beginResourceSection])) {
		result = [NSMutableArray array];
		resCount = [self countOfResourcesOfType: type];
		
		unsigned int i = 1; for (; i <= resCount; i++) {
			hand = Get1IndResource(type, i);
			if ([[self class] getInfoForHandle: hand type: NULL name: &name ID: NULL]) {
				[result addObject: name];
			}
		}
		
		[self endResourceSection: state];
	}
	
	return [[result copy] autorelease];
}
@end

#pragma mark -
#pragma mark GTResourceFork Attributes
@implementation GTResourceFork (Attributes)
- (ResFileAttributes)forkAttributes {
	GTResourceSectionStateRef state;
	ResFileAttributes result;

	result = 0;
	if (NULL != (state = [self beginResourceSection])) {
		result = GetResFileAttrs([self resourceManagerReferenceNumber]);
		if (ResError() != noErr)
			result = 0;
		[self endResourceSection: state];
	}
	
	return result;
}

- (void)setForkAttributes: (ResFileAttributes)attrs {
	GTResourceSectionStateRef state;

	/* will change */
	if ([self respondsToSelector: @selector(willChangeValueForKey:)])
		objc_msgSend(self, @selector(willChangeValueForKey:), @"forkAttributes");

	if (NULL != (state = [self beginResourceSection])) {
		SetResFileAttrs([self resourceManagerReferenceNumber], attrs);
		[self endResourceSection: state];
	}
	
	/* did change */
	if ([self respondsToSelector: @selector(didChangeValueForKey:)])
		objc_msgSend(self, @selector(didChangeValueForKey:), @"forkAttributes");
}

- (ResAttributes)attributesForResource: (ResID)resID ofType: (ResType)type {
	GTResourceSectionStateRef state;
	Handle hand;
	ResAttributes result;
	
	result = 0;
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForResource: resID ofType: type];
		if (hand) {
			result = GetResAttrs(hand);
			if (ResError() != noErr)
				result = 0;
		}
		[self endResourceSection: state];
	}
	
	return result;
}

- (ResAttributes)attributesForNamedResource: (NSString *)name ofType: (ResType)type {
	GTResourceSectionStateRef state;
	Handle hand;
	ResAttributes result;
	
	if (!name)
		return 0;
	
	result = 0;
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForNamedResource: name ofType: type];
		if (hand) {
			result = GetResAttrs(hand);
			if (ResError() != noErr)
				result = 0;
		}
		[self endResourceSection: state];
	}
	
	return result;
}

- (void)setAttributes: (ResAttributes)attrs forResource: (ResID)resID ofType: (ResType)type {
	GTResourceSectionStateRef state;
	Handle hand;
	
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForResource: resID ofType: type];
		if (hand) {
			SetResAttrs(hand, attrs);
			if (ResError() != noErr)
				ChangedResource(hand);
		}
		[self endResourceSection: state];
	}
}

- (void)setAttributes: (ResAttributes)attrs forNamedResource: (NSString *)name ofType: (ResType)type {
	GTResourceSectionStateRef state;
	Handle hand;
	
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForNamedResource: name ofType: type];
		if (hand) {
			SetResAttrs(hand, attrs);
			if (ResError() != noErr)
				ChangedResource(hand);
		}
		[self endResourceSection: state];
	}
}
@end

#pragma mark -
#pragma mark GTResourceFork Specific Types
@implementation GTResourceFork (SpecificTypes)
- (NSString *)stringResource: (ResID)resID {
	NSString *result;
	NSAutoreleasePool *pool;
	GTResourceSectionStateRef state;
	Handle hand;
	
	result = nil;
	pool = [[NSAutoreleasePool alloc] init];
	
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForResource: resID ofType: 'TEXT'];
		if (hand) {
			result = (NSString *)CFStringCreateWithCString(NULL, *hand, kGTResourceForkCFStringEncoding);
		} else {
			hand = [self handleForResource: resID ofType: 'STR '];
			if (hand) {
				result = GTPascalStringGetString((ConstStringPtr)(*hand));
				result = [result retain];
			}
		}

		[self endResourceSection: state];
	}
	
	[pool release];
	return [result autorelease];
}

- (NSString *)namedStringResource: (NSString *)name {
	NSString *result;
	NSAutoreleasePool *pool;
	GTResourceSectionStateRef state;
	Handle hand;
	
	result = nil;
	pool = [[NSAutoreleasePool alloc] init];

	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForNamedResource: name ofType: 'TEXT'];
		if (hand) {
			result = (NSString *)CFStringCreateWithCString(NULL, *hand, kGTResourceForkCFStringEncoding);
		} else {
			hand = [self handleForNamedResource: name ofType: 'STR '];
			if (hand) {
				result = GTPascalStringGetString((ConstStringPtr)(*hand));
				result = [result retain];
			}
		}
		[self endResourceSection: state];
	}
	
	[pool release];
	return [result autorelease];
}

- (NSArray *)stringTableResource: (ResID)resID {
	NSMutableArray *result;
	NSString *string;
	Handle hand;
	const void *str;
	const void *str_end;
	unsigned int strCount;
	
	result = nil;
	hand = [self handleForResource: resID ofType: 'STR#'];
	if (hand && *hand) {
		str = *hand;
		str_end = str + GTUnsignedIntFromSize(GetHandleSize(hand));
		
		if (str) {
			/* get the number of strings -- this is auto-swapped on Intel, apparently */
			strCount = (unsigned int)(*(uint16_t *)str);
			str += sizeof(uint16_t);
			
			/* fill the result array */
			result = [NSMutableArray arrayWithCapacity: strCount];
			unsigned int i = 0; for (; i < strCount; i++) {
				if (str >= str_end)
					break;
				else if (str + StrLength((ConstStringPtr)str) >= str_end)
					break;

				/* add the string as object to the resulting array */
				string = GTPascalStringGetString((ConstStringPtr)str);
				if (!string)
					string = @"";
				[result addObject: string];
				
				/* advance pointer */
				str += StrLength((ConstStringPtr)str) + 1;
			}
		}
	}
	
	return result;
}

- (NSArray *)namedStringTableResource: (NSString *)name {
	NSArray *result;
	GTResourceSectionStateRef state;
	ResID resID;
	
	result = nil;

	if (NULL != (state = [self beginResourceSection])) {
		if ([self getID: &resID ofNamedResource: name ofType: 'STR#'])
			result = [self stringTableResource: resID];
		[self endResourceSection: state];
	}
	
	return result;
}

- (NSAttributedString *)attributedStringResource: (ResID)resID {
	return [self attributedStringResource: resID styleResource: resID];
}

- (NSAttributedString *)namedAttributedStringResource: (NSString *)name {
	return [self namedAttributedStringResource: name styleResource: name];
}

- (NSAttributedString *)attributedStringResource: (ResID)stringID styleResource: (ResID)styleID {
	NSAttributedString *result;
	NSAutoreleasePool *pool;
	NSString *string;
	GTResourceSectionStateRef state;
	Handle strHand;
	Handle styleHand;
	
	result = nil;
	string = nil;
	pool = [[NSAutoreleasePool alloc] init];
	
	if (NULL != (state = [self beginResourceSection])) {
		strHand = [self handleForResource: stringID ofType: 'TEXT'];
		if (strHand) {
			string = (NSString *)CFStringCreateWithCString(NULL, *strHand, kGTResourceForkCFStringEncoding);
			string = [string autorelease];
		}
		
		if (strHand) {
			styleHand = [self handleForResource: styleID ofType: 'styl'];
			if (styleHand) {
				result = [[self attributedStringFromString: string andStyleHandle: styleHand] retain];
			} else {
				result = [[NSAttributedString alloc] initWithString: string];
			}
		}
		[self endResourceSection: state];
	}
	
	[pool release];
	return [result autorelease];
}

- (NSAttributedString *)namedAttributedStringResource: (NSString *)name styleResource: (NSString *)styleName {
	id result;
	GTResourceSectionStateRef state;
	Handle strHand;
	ResID stringID;
	ResID styleID;
	
	result = nil;

	if (NULL != (state = [self beginResourceSection])) {
		if ([self getID: &stringID ofNamedResource: name ofType: 'TEXT']) {
			if ([self getID: &styleID ofNamedResource: styleName ofType: 'styl']) {
				result = [self attributedStringResource: stringID styleResource: styleID];
			} else {
				strHand = [self handleForResource: stringID ofType: 'TEXT'];
				if (strHand) {
					result = (NSString *)CFStringCreateWithCString(NULL, *strHand, kGTResourceForkCFStringEncoding);
					result = [result autorelease];
					result = [[[NSAttributedString alloc] initWithString: result] autorelease];
				}
			}
		}
		[self endResourceSection: state];
	}
	
	return result;
}

- (NSImage *)imageResource: (ResID)resID {
	NSImage *result;
	NSAutoreleasePool *pool;
	NSData *data;
	NSPICTImageRep *pict;
	
	result = nil;
	pool = [[NSAutoreleasePool alloc] init];
	
	data = [self dataForResource: resID ofType: 'PICT'];
	if (data) {
		pict = [[NSPICTImageRep alloc] initWithData: data];
		if (pict) {
			result = [[NSImage alloc] initWithSize: [pict size]];
			[result addRepresentation: pict];
			[pict release];
		}
	}
	
	[pool release];
	return [result autorelease];
}

- (NSImage *)namedImageResource: (NSString *)name {
	NSImage *result;
	GTResourceSectionStateRef state;
	ResID resID;
	
	result = nil;

	if (NULL != (state = [self beginResourceSection])) {
		if ([self getID: &resID ofNamedResource: name ofType: 'PICT'])
			result = [self imageResource: resID];
		[self endResourceSection: state];
	}
	
	return result;
}

- (void)playSoundResource: (ResID)resID {
	NSAutoreleasePool *pool;
	Handle hand;
	
	pool = [[NSAutoreleasePool alloc] init];
	
	hand = [self handleForResource: resID ofType: 'snd '];
	if (hand) {
#if defined(__SOUND__)
		SndPlay(NULL, (SndListHandle)hand, FALSE);
#else
		NSLog(@"*** couldn't play sound %i in %@: not linked with Sound Manager", (int)ID, self);
#endif /* defined(__SOUND__) */
	}
	
	[pool release];
}

- (void)playNamedSoundResource: (NSString *)name {
	GTResourceSectionStateRef state;
	ResID resID;
	
	if (NULL != (state = [self beginResourceSection])) {
		if ([self getID: &resID ofNamedResource: name ofType: 'snd '])
			[self playSoundResource: resID];
		[self endResourceSection: state];
	}
}

- (NSCursor *)cursorResource: (ResID)resID {
	NSCursor *result;
	GTResourceSectionStateRef state;
	Handle hand;
	
	result = nil;
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForResource: resID ofType: 'crsr'];
		if (hand)
			result = [self cursorFromcrsrResource: hand];
		
		if (!result) {
			/* fallback to CURS resource */
			hand = [self handleForResource: resID ofType: 'CURS'];
			if (hand)
				result = [self cursorFromCURSResource: hand];
		}
		[self endResourceSection: state];
	}
	
	return result;
}

- (NSCursor *)namedCursorResource: (NSString *)name {
	NSCursor *result;
	GTResourceSectionStateRef state;
	Handle hand;
	
	result = nil;
	
	if (NULL != (state = [self beginResourceSection])) {
		hand = [self handleForNamedResource: name ofType: 'crsr'];
		if (hand)
			result = [self cursorFromcrsrResource: hand];
		
		if (!result) {
			/* fallback to CURS resource */
			hand = [self handleForNamedResource: name ofType: 'CURS'];
			if (hand)
				result = [self cursorFromCURSResource: hand];
		}
		[self endResourceSection: state];
	}
	
	return result;
}
@end

@implementation GTResourceFork (GTResourceFork_Deprecated)
- (int)IDOfNamedResource: (NSString *)name ofType: (ResType)type {
	ResID result;
	
	NSLog(@"warning: -[GTResourceFork IDOfNamedResource:ofType:] is deprecated; use -[GTResourceFork getID:ofNamedResource:ofType:] instead");
	
	if ([self getID: &result ofNamedResource: name ofType: type]) {
		return (int)(result);
	} else {
		return (int)(SHRT_MAX + 1);
	}
}

- (ResID)uniqueIDForType: (ResType)type {
	ResID result;
	
	NSLog(@"warning: -[GTResourceFork uniqueIDForType:] is deprecated; use -[GTResourceFork getUniqueID:forType:] instead");

	if ([self getUniqueID: &result forType: type]) {
		return result;
	} else {
		return 0;
	}
}
@end

#pragma mark -
#pragma mark Private GTResourceFork Category Implementations
@implementation GTResourceFork (Styles)
- (NSAttributedString *)attributedStringFromString: (NSString *)str andStyleHandle: (Handle)hand {
	NSMutableAttributedString *result;
	NSColor *color;
	id obj;
	StScrpPtr scrap;
	ScrpSTElement entry;
	NSRange entryRange;
	unsigned int numStyles;

	if (!str)
		return nil;
	
	result = [[[NSMutableAttributedString alloc] initWithString: str] autorelease];

	if (!hand || !*hand)
		return result;

	/* 'styl' resources are auto-swapped by Resource Manager */
	scrap = (StScrpPtr)(*hand);
	if (scrap) {
		numStyles = (unsigned int)(scrap->scrpNStyles);
		unsigned int i = 0; for (; i < numStyles; i++) {
			entry = scrap->scrpStyleTab[i];
			entryRange.location = entry.scrpStartChar;
#if defined(MF_APPLICATION)
			/* mFurc uses its own Max macro that's side-effect-aware */
			if (i + 1 < numStyles)
				entryRange.length = MMax(0, scrap->scrpStyleTab[i + 1].scrpStartChar - entry.scrpStartChar);
			else
				entryRange.length = MMax(0, (long int)[str length] - entry.scrpStartChar);
#else /* defined(MF_APPLICATION) */
			if (i + 1 < numStyles)
				entryRange.length = MAX(0, scrap->scrpStyleTab[i + 1].scrpStartChar - entry.scrpStartChar);
			else
				entryRange.length = MAX(0, (long int)[str length] - entry.scrpStartChar);
#endif /* defined(MF_APPLICATION) */

			/* color */
			color = [self colorForStyleEntry: &entry];
			if (color) {
				[result
					addAttribute:	NSForegroundColorAttributeName
					value:			color
					range:			entryRange];
			}
			
			/* font */
			obj = [self fontForStyleEntry: &entry];
			if (obj) {
				[result
					addAttribute:	NSFontAttributeName
					value:			obj
					range:			entryRange];
			}
			
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_3
			/* shadow */
			if (entry.scrpFace & shadow) {
				obj = [[[NSShadow alloc] init] autorelease];
				if (obj) {
					if (color)
						[obj setShadowColor: color];
					[obj setShadowOffset: NSMakeSize(0.0f, -2.0f)];
					[obj setShadowBlurRadius: 2.0f];
					[result addAttribute: NSShadowAttributeName value: obj range: entryRange];
				}
			}
			
			/* outline */
			if (entry.scrpFace & outline) {
				obj = [NSNumber numberWithFloat: 5.0f];
				if (obj) {
					[result addAttribute: NSStrokeWidthAttributeName value: obj range: entryRange];
				}
			}
#endif /* MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_3 */

			/* underline */
			if (entry.scrpFace & underline) {
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_3
				obj = [NSNumber numberWithInt: NSUnderlineStyleSingle | NSUnderlinePatternSolid];
#else /* MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_3 */
				obj = [NSNumber numberWithInt: NSSingleUnderlineStyle];
#endif /* MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_3 */

				if (obj) {
					[result addAttribute: NSUnderlineStyleAttributeName value: obj range: entryRange];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_3
					if (color)
						[result addAttribute: NSUnderlineColorAttributeName value: color range: entryRange];
#endif /* MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_3 */
				}
			}
		}
	}
	
	return [[result copy] autorelease];
}

- (NSColor *)colorForStyleEntry: (ScrpSTElement *)entry {
	NSColor *result;

	result = nil;
	if (entry) {
		if (entry->scrpColor.red != 0 || entry->scrpColor.green != 0 || entry->scrpColor.blue != 0) {
			result = [NSColor
				colorWithDeviceRed:		(float)entry->scrpColor.red / (float)USHRT_MAX
				green:					(float)entry->scrpColor.green / (float)USHRT_MAX
				blue:					(float)entry->scrpColor.blue / (float)USHRT_MAX
				alpha:					1.0f];
		}
	}
	
	return result;
}

- (NSFont *)fontForStyleEntry: (ScrpSTElement *)entry {
	NSFont *result;
	NSString *psName;
	
	result = nil;
	psName = nil;

	if (entry) {
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_4
		/* targetting Mac OS X 10.4 or newer -- GetFontName and FMGetFontFamilyName deprecated */
		CGFontRef cgFont;
		FMFontStyle ignored;

		cgFont = NULL;
		if (noErr == FMFontGetCGFontRefFromFontFamilyInstance(entry->scrpFont, 0, &cgFont, &ignored)) {
			if (cgFont) {
				/* get the name of the font */
				psName = (NSString *)CGFontCopyPostScriptName(cgFont);
				psName = [psName autorelease];
				
				CFRelease(cgFont);
			}
		}
#else /* MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_4 */
		/* targetting Mac OS X 10.3 or older, FMFontGetCGFontRefFromFontFamilyInstance unavailable */
		Str255 oldFontName;
		
		/* GetFontName and FMGetFontFamilyName don't cover the same fonts, so need to try both */
		if (noErr != FMGetFontFamilyName((FMFontFamily)(entry->scrpFont), oldFontName))
			GetFontName(entry->scrpFont, oldFontName);
		psName = GTPascalStringGetString(oldFontName, kGTResourceForkStringEncoding);
#endif /* MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_4 */
		
		/* got the name, now get font */
		if (psName && [psName length] > 0) {
			result = [NSFont fontWithName: psName size: 0.0f];
		}
		
		/* make sure even the default font is the correct size, if possible */
		if (entry->scrpSize > 0) {
			result = [[NSFontManager sharedFontManager] convertFont: result toSize: (float)(entry->scrpSize)];
		}
	}

	/* fallback to default font */
	if (!result)
		result = [NSFont userFontOfSize: 0.0f];
	
	/* apply any font traits */
	return [[NSFontManager sharedFontManager] convertFont: result toHaveTrait: [self traitMaskForStyleEntry: entry]];
}

- (NSFontTraitMask)traitMaskForStyleEntry: (ScrpSTElement *)entry {
	NSFontTraitMask result;
	StyleField style;
	
	result = 0;
	
	if (entry) {
		style = entry->scrpFace;
		
		if (style & bold)
			result |= NSBoldFontMask;
		if (style & italic)
			result |= NSItalicFontMask;
		if (style & condense)
			result |= NSCondensedFontMask;
		else if (style & extend)
			result |= NSExpandedFontMask;
	}
	
	return result;
}
@end

@implementation GTResourceFork (Cursors)
- (NSCursor *)cursorFromcrsrResource: (Handle)cursHand {
	NSImage *image;
	CCrsrPtr carbCursor;
	
	if (cursHand) {
		carbCursor = *((CCrsrHandle)cursHand);
		
		if (carbCursor) {
			image = [[[NSImage alloc] initWithSize: NSMakeSize(16.0f, 16.0f)] autorelease];

			/* 1-bit version */
			[image addRepresentation: [self imageRepWithBits16Data: carbCursor->crsr1Data andMask: carbCursor->crsrMask]];		

			/* NOT SUPPORTED YET */
//			if (CFSwapInt16BigToHost((uint16_t)carbCursor->crsrType) == 0x8001) {
//				/* 256-color version */
//				[image addRepresentation: [self imageRepWithColorCursor: carbCursor]];
//			}
			
			return [[[NSCursor alloc]
					initWithImage:	image
					hotSpot:		NSZeroPoint] autorelease];
		}
	}
	
	return nil;
}

- (NSCursor *)cursorFromCURSResource: (Handle)cursHand {
	NSImage *image;
	CursPtr carbCursor;

	if (cursHand) {
		carbCursor = *((CursHandle)cursHand);
		
		image = [[[NSImage alloc] initWithSize: NSMakeSize(16.0f, 16.0f)] autorelease];
		[image addRepresentation: [self imageRepWithBits16Data: carbCursor->data andMask: carbCursor->mask]];
		return [[[NSCursor alloc]
				initWithImage:	image
				hotSpot:		NSMakePoint(carbCursor->hotSpot.h, 16 - carbCursor->hotSpot.v)] autorelease];
	}
	
	return nil;
}

- (NSImageRep *)imageRepWithBits16Data: (const Bits16)data andMask: (const Bits16)mask {
	NSBitmapImageRep *result;
	unsigned char *bmData;
	int x;
	int y;
	uint16_t row;
	uint16_t rowMask;

	if (data && mask) {
		result = [[NSBitmapImageRep alloc]
			initWithBitmapDataPlanes:	NULL
			pixelsWide:					16
			pixelsHigh:					16
			bitsPerSample:				8
			samplesPerPixel:			2
			hasAlpha:					YES
			isPlanar:					NO
			colorSpaceName:				NSDeviceBlackColorSpace
			bytesPerRow:				32
			bitsPerPixel:				16];
		bmData = [result bitmapData];
		for (y = 0; y < 16; y++) {
			row = CFSwapInt16BigToHost(data[y]);
			rowMask = CFSwapInt16BigToHost(mask[y]);
			for (x = 0; x < 16; x++) {
				bmData[0] = (row & (1 << (15 - x))) ? 0xFF : 0x00;
				bmData[1] = (rowMask & (1 << (15 - x))) ? 0xFF : 0x00;
				bmData += 2;
			}
		}
		return [result autorelease];
	}
	
	return nil;
}

//- (NSImageRep *)imageRepWithColorCursor: (CCrsrPtr)cursor {
//	void *data;
//	
//	if (cursor && CFSwapInt16BigToHost((uint16_t)cursor->crsrType) == 0x8001) {
//		data = ((void *)cursor) + CFSwapInt32BigToHost((uint32_t)cursor->crsrData);
//	}
//	
//	return nil;
//}
@end

#pragma mark -
#pragma mark Support Functions
NSString *GTStringFromResType(ResType type) {
	char buff[5];
	
	/* this is endian-safe, works on Intel and PPC */
	
	buff[0] = (type & 0xFF000000) >> 24;
	buff[1] = (type & 0x00FF0000) >> 16;
	buff[2] = (type & 0x0000FF00) >> 8;
	buff[3] = (type & 0x000000FF) >> 0;
	buff[4] = 0;
	
	return [(NSString *)CFStringCreateWithCString(NULL, buff, kGTResourceForkCFStringEncoding) autorelease];
}

ResType GTResTypeFromString(NSString *string) {
	char buff[5];
	
	/* this is endian-safe, works on Intel and PPC */
	
	if (string && CFStringGetCString((CFStringRef)string, buff, sizeof(buff), kGTResourceForkCFStringEncoding)) {
		return (buff[0] << 24) | (buff[1] << 16) | (buff[2] << 8) | (buff[3] << 0);
	} else {
		return kUnknownType;
	}
}

ConstStringPtr GTStringGetPascalString(NSString *aString) {
	ConstStringPtr localStrPtr;
	Str255 localStrFull;
	
	/* fail immediately if aString is nil */
	if (!aString)
		return (ConstStringPtr)NULL;
	
	/* try the quick fetch first -- one less memcpy to worry about */
	localStrPtr = CFStringGetPascalStringPtr((CFStringRef)aString, kGTResourceForkCFStringEncoding);
	if (!localStrPtr) {
		/* quick fetch failed, try slow fetch */
		if (CFStringGetPascalString((CFStringRef)aString, (StringPtr)localStrFull, (CFIndex)sizeof(localStrFull), kGTResourceForkCFStringEncoding))
			localStrPtr = (ConstStringPtr)localStrFull;
	}
	
	if (localStrPtr) {
		/* worked, so put it in a place where it will be valid outside the function, and also freed when
		   the autorelease pool ends: i.e., an NSData object */
		return (ConstStringPtr)[[NSData dataWithBytes: localStrPtr length: StrLength(localStrPtr) + 1] bytes];
	}
	
	/* failed */
	return (ConstStringPtr)NULL;
}

NSString *GTPascalStringGetString(ConstStringPtr aString) {
	id result;
	
	if (aString) {
		/* create the string */
		result = (id)CFStringCreateWithPascalString(NULL, (ConstStr255Param)aString, kGTResourceForkCFStringEncoding);
		return [result autorelease];
	} else {
		return nil;
	}
}

unsigned int GTUnsignedIntFromSize(Size sz) {
	unsigned int len;
	
	/* Upper-bounds checking isn't strictly necessary on 32-bit Mac OS X, since on such
	   systems Size and unsigned int are both 32 bits width (Size is a signed long integer.)
	   By the nature of binary math, max(signed-type) will always be less than
	   max(unsigned-type) if both types are the same width. */
	
	/* However, on 64-bit Mac OS X, long ints are 64-bits, so sz *can* be larger than
	   UINT_MAX. With virtual memory and multi-gigabyte real memory on the latest Macs,
	   it's necessary to check the upper bounds to make sure the size fits within an
	   unsigned integer. */
	
	/* I shouldn't have to explain why I'm checking a signed type to make sure it's >= 0
	   before returning it cast to an unsigned type. ;) */
	
	/* The logic of this function will likely change to use NSUInteger when Leopard is released.
	   Because NSUInteger is always the same size as a long integer on Mac OS X, the upper-bounds
	   checking will be unneeded. */
	
	if (sz > UINT_MAX)
		len = UINT_MAX;
	else if (sz < 0)
		len = 0;
	else
		len = (unsigned int)sz;
	
	return len;
}

Size GTSizeFromUnsignedInt(unsigned int ui) {
	Size sz;
	
	/* Reverse of GTUnsignedIntFromSize(). The only bounds issue going from unsigned to signed
	   is an overflow, in which case we just truncate to the maximum value a Size can represent. */
	
	if (ui > LONG_MAX)
		sz = LONG_MAX;
	else
		sz = (Size)ui;
	
	return sz;
}

unsigned int GTUnsignedIntFromSizeT(size_t sz) {
	unsigned int len;
	
	if (sz > UINT_MAX)
		len = UINT_MAX;
	else
		len = (unsigned int)sz;
	
	return len;
}

size_t GTSizeTFromUnsignedInt(unsigned int ui) {
	size_t sz;
	
	if (ui > SIZE_MAX)
		sz = SIZE_MAX;
	else
		sz = (size_t)ui;
	
	return sz;
}

Handle GTCopyHandle(Handle hand) {
	return ((noErr == HandToHand(&hand)) ? hand : NULL);
}

#if defined(__cplusplus)
	}
#endif
