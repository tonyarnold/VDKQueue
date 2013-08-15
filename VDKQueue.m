//	VDKQueue.m
//	Created by Bryan D K Jones on 28 March 2012
//	Copyright 2013 Bryan D K Jones
//
//  Based heavily on UKKQueue, which was created and copyrighted by Uli Kusterer on 21 Dec 2003.
//
//	This software is provided 'as-is', without any express or implied
//	warranty. In no event will the authors be held liable for any damages
//	arising from the use of this software.
//	Permission is granted to anyone to use this software for any purpose,
//	including commercial applications, and to alter it and redistribute it
//	freely, subject to the following restrictions:
//	   1. The origin of this software must not be misrepresented; you must not
//	   claim that you wrote the original software. If you use this software
//	   in a product, an acknowledgment in the product documentation would be
//	   appreciated but is not required.
//	   2. Altered source versions must be plainly marked as such, and must not be
//	   misrepresented as being the original software.
//	   3. This notice may not be removed or altered from any source
//	   distribution.

#import "VDKQueue.h"
#import <unistd.h>
#import <fcntl.h>
#include <sys/stat.h>



NSString * VDKQueueRenameNotification = @"VDKQueueFileRenamedNotification";
NSString * VDKQueueWriteNotification = @"VDKQueueFileWrittenToNotification";
NSString * VDKQueueDeleteNotification = @"VDKQueueFileDeletedNotification";
NSString * VDKQueueAttributeChangeNotification = @"VDKQueueFileAttributesChangedNotification";
NSString * VDKQueueSizeIncreaseNotification = @"VDKQueueFileSizeIncreasedNotification";
NSString * VDKQueueLinkCountChangeNotification = @"VDKQueueLinkCountChangedNotification";
NSString * VDKQueueAccessRevocationNotification = @"VDKQueueAccessWasRevokedNotification";



#pragma mark -
#pragma mark VDKQueuePathEntry
#pragma mark -
#pragma ------------------------------------------------------------------------------------------------------------------------------------------------------------

//  This is a simple model class used to hold info about each path we watch.
@interface VDKQueuePathEntry : NSObject
{
	NSString*		_path;
	int				_watchedFD;
	u_int			_subscriptionFlags;
	VDKPathBlock	_block;
}

- (id) initWithPath:(NSString*)inPath block:(VDKPathBlock)aBlock andSubscriptionFlags:(u_int)flags;

@property (atomic, copy) NSString *path;
@property (atomic, assign) int watchedFD;
@property (atomic, assign) u_int subscriptionFlags;
@property (strong)	VDKPathBlock	block;

@end

@implementation VDKQueuePathEntry
@synthesize path = _path;
@synthesize watchedFD = _watchedFD;
@synthesize subscriptionFlags = _subscriptionFlags;
@synthesize block = _block;


- (id) initWithPath:(NSString*)inPath block:(VDKPathBlock)aBlock andSubscriptionFlags:(u_int)flags;
{
    self = [super init];
	if (self)
	{
		_path = [inPath copy];
		_watchedFD = open([_path fileSystemRepresentation], O_EVTONLY, 0);
		if (_watchedFD < 0)
		{
			return nil;
		}
		_subscriptionFlags = flags;
		_block = aBlock;
	}
	return self;
}

-(void)	dealloc
{
	_path = nil;
	_block = nil;
    
	if (_watchedFD >= 0) close(_watchedFD);
	_watchedFD = -1;
	
}

@end



#pragma mark - VDKQueueProcessEntry -
#pragma -----------------------------------------------------------------------

@interface VDKQueueProcessEntry : NSObject

@property (strong)	NSString			*name;
@property (strong)	NSString			*bundleID;
@property (assign)	pid_t				processID;
@property (strong)	VDKProcessQuitBlock	block;

- (id)initWithBundleID:(NSString *)bundleIdentifier block:(VDKProcessQuitBlock)theBlock;
- (id)initWithProcessID:(pid_t)processIdentifier block:(VDKProcessQuitBlock)theBlock;

@end

@interface VDKQueueProcessEntry ()

- (id)initWithRunningApplication:(NSRunningApplication *)runningApp block:(VDKProcessQuitBlock)theBlock;

@end

@implementation VDKQueueProcessEntry

- (id)initWithRunningApplication:(NSRunningApplication *)runningApp block:(VDKProcessQuitBlock)theBlock {
	if (runningApp == nil) {
		return nil;
	}
	self = [super init];
	if (self) {
		self.name = runningApp.localizedName;
		self.bundleID = runningApp.bundleIdentifier;
		self.processID = runningApp.processIdentifier;
		self.block = theBlock;
	}
	return self;
}

- (id)initWithBundleID:(NSString *)bundleIdentifier block:(VDKProcessQuitBlock)theBlock {
	return [self initWithRunningApplication:[[NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier] lastObject] block:theBlock];
}

- (id)initWithProcessID:(pid_t)processIdentifier block:(VDKProcessQuitBlock)theBlock {
	return [self initWithRunningApplication:[NSRunningApplication runningApplicationWithProcessIdentifier:processIdentifier] block:theBlock];
}

@end







#pragma mark -
#pragma mark VDKQueue
#pragma mark -
#pragma ------------------------------------------------------------------------------------------------------------------------------------------------------------

@interface VDKQueue ()
@property (strong)	NSMutableArray		*watchedProcessEntries;
@property (strong)	dispatch_queue_t	modifyEventQueue;
- (void) watcherThread:(id)sender;
@end



@implementation VDKQueue
@synthesize delegate = _delegate;
@synthesize alwaysPostNotifications = _alwaysPostNotifications;



#pragma mark -
#pragma mark INIT/DEALLOC

- (id) init
{
	self = [super init];
	if (self)
	{
		_coreQueueFD = kqueue();
		if (_coreQueueFD == -1)
		{
			return nil;
		}
		
        _alwaysPostNotifications = NO;
		_watchedPathEntries = [[NSMutableDictionary alloc] init];
		self.watchedProcessEntries = [[NSMutableArray alloc] init];
		self.modifyEventQueue = dispatch_queue_create("VDKQueue.modifyEventQueue", 0);
	}
	return self;
}


- (void) dealloc
{
    // Shut down the thread that's scanning for kQueue events
    _keepWatcherThreadRunning = NO;
    
    // Do this to close all the open file descriptors for files we're watching
    [self removeAllPaths];
    
    _watchedPathEntries = nil;
    
}





#pragma mark -
#pragma mark PRIVATE METHODS

- (VDKQueuePathEntry *)	addPathToQueue:(NSString *)path block:(VDKPathBlock)aBlock notifyingAbout:(u_int)flags
{
	@synchronized(self)
	{
        // Are we already watching this path?
		VDKQueuePathEntry *pathEntry = [_watchedPathEntries objectForKey:path];
		
        if (pathEntry)
		{
            // All flags already set?
			if(([pathEntry subscriptionFlags] & flags) == flags) 
            {
				return pathEntry; 
            }
			
			flags |= [pathEntry subscriptionFlags];
		}
		
		struct timespec		nullts = { 0, 0 };
		struct kevent		ev;
		
		if (!pathEntry)
        {
            pathEntry = [[VDKQueuePathEntry alloc] initWithPath:path block:aBlock andSubscriptionFlags:flags];
        }
        
		if (pathEntry)
		{
			EV_SET(&ev, [pathEntry watchedFD], EVFILT_VNODE, EV_ADD | EV_ENABLE | EV_CLEAR, flags, 0, (__bridge void *)(pathEntry));
			
			[pathEntry setSubscriptionFlags:flags];
            
            [_watchedPathEntries setObject:pathEntry forKey:path];
            kevent(_coreQueueFD, &ev, 1, NULL, 0, &nullts);
            
			// Start the thread that fetches and processes our events if it's not already running.
			if(!_keepWatcherThreadRunning)
			{
				_keepWatcherThreadRunning = YES;
				[NSThread detachNewThreadSelector:@selector(watcherThread:) toTarget:self withObject:nil];
			}
        }
        
        return pathEntry;
    }
    
    return nil;
}


//
//  WARNING: This thread has no active autorelease pool, so if you make changes, you must manually manage 
//           memory without relying on autorelease. Otherwise, you will leak!
//
- (void) watcherThread:(id)sender
{
    int					n;
    struct kevent		ev;
    struct timespec     timeout = { 1, 0 };     // 1 second timeout. Should be longer, but we need this thread to exit when a kqueue is dealloced, so 1 second timeout is quite a while to wait.
	int					theFD = _coreQueueFD;	// So we don't have to risk accessing iVars when the thread is terminated.
    
    NSMutableArray      *notesToPost = [[NSMutableArray alloc] initWithCapacity:5];
    
#if DEBUG_LOG_THREAD_LIFETIME
	NSLog(@"watcherThread started.");
#endif
	
    while(_keepWatcherThreadRunning)
    {
        @try 
        {
            n = kevent(theFD, NULL, 0, &ev, 1, &timeout);
            if (n > 0)
            {
                //NSLog( @"KEVENT returned %d", n );
                if (ev.filter == EVFILT_VNODE)
                {
                    //NSLog( @"KEVENT filter is EVFILT_VNODE" );
                    if (ev.fflags)
                    {
                        //NSLog( @"KEVENT flags are set" );
                        
                        //
                        //  Note: VDKQueue gets tested by thousands of CodeKit users who each watch several thousand files at once.
                        //        I was receiving about 3 EXC_BAD_ACCESS (SIGSEGV) crash reports a month that listed the 'path' objc_msgSend
                        //        as the culprit. That suggests the KEVENT is being sent back to us with a udata value that is NOT what we assigned
                        //        to the queue, though I don't know why and I don't know why it's intermittent. Regardless, I've added an extra
                        //        check here to try to eliminate this (infrequent) problem. In theory, a KEVENT that does not have a VDKQueuePathEntry
                        //        object attached as the udata parameter is not an event we registered for, so we should not be "missing" any events. In theory.
                        //
                        id pe = (__bridge id)(ev.udata);
                        if (pe && [pe respondsToSelector:@selector(path)])
                        {
							VDKQueuePathEntry	*pathEntry = (VDKQueuePathEntry *)pe;
                            NSString *fpath = pathEntry.path;
                            if (!fpath) continue;
							if (![_watchedPathEntries valueForKey:fpath]) continue;
                            
                            [[NSWorkspace sharedWorkspace] noteFileSystemChanged:fpath];
                            
                            // Clear any old notifications
                            [notesToPost removeAllObjects];
                            
                            // Figure out which notifications we need to issue
                            if ((ev.fflags & NOTE_RENAME) == NOTE_RENAME)
                            {
                                [notesToPost addObject:VDKQueueRenameNotification];
                            }
                            if ((ev.fflags & NOTE_WRITE) == NOTE_WRITE)
                            {
                                [notesToPost addObject:VDKQueueWriteNotification];
                            }
                            if ((ev.fflags & NOTE_DELETE) == NOTE_DELETE)
                            {
                                [notesToPost addObject:VDKQueueDeleteNotification];
                            }
                            if ((ev.fflags & NOTE_ATTRIB) == NOTE_ATTRIB)
                            {
                                [notesToPost addObject:VDKQueueAttributeChangeNotification];
                            }
                            if ((ev.fflags & NOTE_EXTEND) == NOTE_EXTEND)
                            {
                                [notesToPost addObject:VDKQueueSizeIncreaseNotification];
                            }
                            if ((ev.fflags & NOTE_LINK) == NOTE_LINK)
                            {
                                [notesToPost addObject:VDKQueueLinkCountChangeNotification];
                            }
                            if ((ev.fflags & NOTE_REVOKE) == NOTE_REVOKE)
                            {
                                [notesToPost addObject:VDKQueueAccessRevocationNotification];
                            }
                            
                            
                            NSArray *notes = [[NSArray alloc] initWithArray:notesToPost];   // notesToPost will be changed in the next loop iteration, which will likely occur before the block below runs.
							
                            // Post the notifications (or call the delegate method) on the main thread.
                            dispatch_async(dispatch_get_main_queue(),
								   ^{
									   for (NSString *note in notes)
									   {
										   [_delegate VDKQueue:self receivedNotification:note forPath:fpath];
										   
										   if (pathEntry.block) {
											   pathEntry.block(self, note, pathEntry.path);
										   }
										   
										   if ((!_delegate && !pathEntry.block) || _alwaysPostNotifications)
										   {
											   NSDictionary *userInfoDict = [[NSDictionary alloc] initWithObjectsAndKeys:fpath, @"path", nil];
											   [[[NSWorkspace sharedWorkspace] notificationCenter] postNotificationName:note object:self userInfo:userInfoDict];
										   }
									   }
									   
								   });
                        }
                    }
                }
				else if (ev.filter == EVFILT_PROC) {
					id pe = (__bridge id)(ev.udata);
					if (pe && [pe respondsToSelector:@selector(bundleID)]) {
						VDKQueueProcessEntry	*processEntry = (VDKQueueProcessEntry *)pe;
						if (processEntry.block) {
							dispatch_async(dispatch_get_main_queue(), ^{
								processEntry.block(self, processEntry.name, processEntry.bundleID, processEntry.processID);
							});
						}
						
						dispatch_async(self.modifyEventQueue, ^{
							//	Remove the event from the queue
							//	Remove the kevent for this path
							struct timespec		nullts = { 0, 0 };
							struct kevent		removeEvent;
							
							EV_SET(&removeEvent, processEntry.processID, EVFILT_PROC, EV_DELETE, NOTE_EXIT, 0, NULL);
							kevent(_coreQueueFD, &removeEvent, 1, NULL, 0, &nullts);
							
							//	Remove the entry from our list
							[self.watchedProcessEntries removeObject:processEntry];
						});
					}
				}
            }
        }
        
        @catch (NSException *localException) 
        {
            NSLog(@"Error in VDKQueue watcherThread: %@", localException);
        }
    }
    
	// Close our kqueue's file descriptor
	if(close(theFD) == -1) {
       NSLog(@"VDKQueue watcherThread: Couldn't close main kqueue (%d)", errno); 
    }
    
#if DEBUG_LOG_THREAD_LIFETIME
	NSLog(@"watcherThread finished.");
#endif

}



- (void)watchForExitOfProcessEntry:(VDKQueueProcessEntry *)processEntry {
	
	if (processEntry == nil) {
		return;
	}
	
	dispatch_async(self.modifyEventQueue, ^{
		//	Add the kevent for this process
		struct timespec		nullts = { 0, 0 };
		struct kevent		ev;
		
		EV_SET(&ev, processEntry.processID, EVFILT_PROC, EV_ADD, NOTE_EXIT, 0, (__bridge void *)processEntry);
		if (kevent(_coreQueueFD, &ev, 1, NULL, 0, &nullts) != -1) {
			[self.watchedProcessEntries addObject:processEntry];
		}
	});
	
}




#pragma mark -
#pragma mark PUBLIC METHODS
#pragma -----------------------------------------------------------------------------------------------------------------------------------------------------


- (void)executeBlock:(VDKProcessQuitBlock)processBlock forProcessIDOnExit:(pid_t)processID {
	[self watchForExitOfProcessEntry:[[VDKQueueProcessEntry alloc] initWithProcessID:processID block:processBlock]];
}

- (void)executeBlock:(VDKProcessQuitBlock)processBlock forBundleIDOnExit:(NSString *)bundleID {
	[self watchForExitOfProcessEntry:[[VDKQueueProcessEntry alloc] initWithBundleID:bundleID block:processBlock]];
}


- (void) addPath:(NSString *)aPath
{
    if (!aPath) return;
	[self addPath:aPath withBlock:nil notifyingAbout:VDKQueueNotifyDefault];
    
}


- (void) addPath:(NSString *)aPath notifyingAbout:(u_int)flags
{
    if (!aPath) return;
	[self addPath:aPath withBlock:nil notifyingAbout:flags];
    
}

- (void)addPath:(NSString *)aPath withBlock:(VDKPathBlock)aBlock notifyingAbout:(u_int)flags;
{
    if (!aPath) return;
    
    @synchronized(self)
    {
        VDKQueuePathEntry *entry = [_watchedPathEntries objectForKey:aPath];
        
        // Only add this path if we don't already have it.
        if (!entry)
        {
            entry = [self addPathToQueue:aPath block:aBlock notifyingAbout:flags];
            if (!entry) {
                NSLog(@"VDKQueue tried to add the path %@ to watchedPathEntries, but the VDKQueuePathEntry was nil. \nIt's possible that the host process has hit its max open file descriptors limit.", aPath);
            }
        }
    }
    
}

- (void)removePath:(NSString *)aPath
{
    if (!aPath) return;
    
    @synchronized(self)
	{
		VDKQueuePathEntry *pathEntry = [_watchedPathEntries objectForKey:aPath];
        
        // Remove it only if we're watching it.
        if (pathEntry) {
			//	Remove the kevent for this path
			struct timespec		nullts = { 0, 0 };
			struct kevent		ev;
			
			EV_SET(&ev, pathEntry.watchedFD, EVFILT_VNODE, EV_DELETE, pathEntry.subscriptionFlags, 0, NULL);
            kevent(_coreQueueFD, &ev, 1, NULL, 0, &nullts);

			//	Remove from our list
			[_watchedPathEntries removeObjectForKey:aPath];
			
		}
	}
    
}


- (void) removeAllPaths
{
    @synchronized(self)
    {

        for (id pathKey in [_watchedPathEntries allKeys]) {

			VDKQueuePathEntry *pathEntry = [_watchedPathEntries objectForKey:pathKey];
			//	Remove the kevent for this path
			struct timespec		nullts = { 0, 0 };
			struct kevent		ev;
			
			EV_SET(&ev, pathEntry.watchedFD, EVFILT_VNODE, EV_DELETE, pathEntry.subscriptionFlags, 0, NULL);
			kevent(_coreQueueFD, &ev, 1, NULL, 0, &nullts);
			
		}
		
		[_watchedPathEntries removeAllObjects];
    }
}


- (NSUInteger) numberOfWatchedPaths
{
    NSUInteger count;
    
    @synchronized(self)
    {
        count = [_watchedPathEntries count];
    }
    
    return count;
}




@end

