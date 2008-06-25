#import "AppController.h"
#import "Defines.h"

#import <Security/Security.h>
#import <QuartzCore/CoreAnimation.h>
#import "CocoaCryptoHashing.h"
#import "GrowlHub.h"

#import "iPodWatcher.h"
#import "BGTrackCollector.h"
#import "BGScrobbleDecisionManager.h"

#import "BGLastFmHandshaker.h"
#import "BGLastFmHandshakeResponse.h"
#import "BGLastFmScrobbler.h"
#import "BGLastFmScrobbleResponse.h"
#import "BGLastFmServiceWorker.h"

#import "BGMultipleSongPlayManager.h"

#import "NSCalendarDate+RelativeDateDescription.h"
#import "SFHFKeychainUtils.h"
#import "StatusItemView.h"

#include <ApplicationServices/ApplicationServices.h>

#import "NSString+UrlEncoding.h"

@implementation AppController

#pragma mark Application Starting/Quitting

-(void)setStatus {
	[statusIconButton setImage: [NSImage imageNamed: ( usingAutoDecide ? [NSString stringWithFormat:@"auto%d",[[BGScrobbleDecisionManager sharedManager] shouldScrobbleWhenUsingAutoDecide:usingAutoDecide withUserChosenStatus:userChosenStatus]] : [NSString stringWithFormat:@"%d",userChosenStatus] )]];
}

-(void)showStatusMenu:(id)sender {
	[statusItem popUpStatusItemMenu:statusMenu];
}

-(void)menuWillOpen:(NSMenu *)menu {
	[self setStatus];
	[[BGScrobbleDecisionManager sharedManager] resetRefreshTimer];
	[arrowWindow properClose];
}

-(void)awakeFromNib {

	[self setIsScrobbling:NO];
	[self setIsPostingNP:NO];
	
	usingAutoDecide = YES;
	userChosenStatus = YES;
	isLoadingCommonTags = NO;
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults registerDefaults: [NSDictionary dictionaryWithObjectsAndKeys:
		@"",BGPrefUserKey,
		[NSNumber numberWithBool:YES],BGPrefFirstRunKey,
		[[[NSCalendarDate calendarDate] dateByAddingYears:0 months:0 days:0 hours:0 minutes:-2 seconds:0] descriptionWithCalendarFormat:DATE_FORMAT_STRING],BGPrefLastScrobbled,
		[NSNumber numberWithBool:YES],BGPrefWantMultiPost,
		[NSNumber numberWithBool:NO],BGPrefShouldPlaySound,
		[NSNumber numberWithBool:NO],BGPrefShouldIgnoreComments,
		@"dontpost",BGPrefIgnoreCommentString,
		[NSNumber numberWithBool:YES],BGPrefShouldIgnoreShort,
		[NSNumber numberWithInt:30],BGPrefIgnoreShortLength,
		[NSNumber numberWithInt:3],BGPrefPodFreshnessInterval,
		[NSNumber numberWithBool:YES],BGPrefShouldIgnorePodcasts,
		[NSNumber numberWithBool:YES],BGPrefShouldIgnoreVideo,
		[NSNumber numberWithBool:YES],BGPrefWantNowPlaying,
		[NSNumber numberWithBool:YES],BGPrefWantStatusItem,
		[NSNumber numberWithBool:YES],BGPrefUsePodFreshnessInterval,
		[NSNumber numberWithInt:0],BGTracksScrobbledTotal,
		[NSNumber numberWithBool:YES],BGPref_Growl_SongChange,
		[NSNumber numberWithBool:YES],BGPref_Growl_ScrobbleFail,
		[NSNumber numberWithBool:YES],BGPref_Growl_ScrobbleDecisionChanged,
		[NSNumber numberWithBool:NO],BGPrefWantOldIcon,
		@"~/Music/iTunes/iTunes Music Library.xml",BGPrefXmlLocation,
nil] ];

	NSLog(@"Last iPod Sync Date: %@",[defaults objectForKey:BGLastSyncDate]);
	NSLog(@"Last Scrobbled: %@",[defaults objectForKey:BGPrefLastScrobbled]);

	statusItem = nil;
	if ([defaults boolForKey:BGPrefWantStatusItem])  {
		statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:23];//NSVariableStatusItemLength
		[statusItem setEnabled:YES];
//		[statusItem setHighlightMode:YES];
//		[statusItem setMenu:statusMenu];
//		[statusItem setImage:nil];
//		[statusItem setToolTip:@"ScrobblePod"];
//		[statusItem setTarget:self];
//		[statusItem sendActionOn:NSLeftMouseDownMask];
//		[statusItem setAction:@selector(showStatusMenu:)];

		StatusItemView *tempView = [[StatusItemView alloc] initWithStatusItem:statusItem];
			[tempView setImage:[NSImage imageNamed:(![defaults boolForKey:BGPrefWantOldIcon] ? @"MenuNote" : @"old_menu_icon")]];
			[tempView setAlternateImage:(![defaults boolForKey:BGPrefWantOldIcon] ? [NSImage imageNamed:@"MenuNote_On"] : nil)];
			[tempView setTarget:self];
			[tempView setAction:@selector(showStatusMenu:)];

			[statusItem setView:tempView];
		[tempView release];
		[statusItem retain];
	}
	
	[currentSongMenuItem setView:containerView];
	[containerView addSubview:infoView];
	
//	[resizingMenuItem setView:[[[BGResizingMenuItemView alloc] initWithFrame:NSMakeRect(0,0,containerView.frame.size.width,20)] autorelease] ];
	
	NSString *storedDateString = [defaults valueForKey:BGPrefLastScrobbled];
	if ([NSCalendarDate dateWithString:storedDateString calendarFormat:DATE_FORMAT_STRING]==nil) {
		[defaults setValue:[[NSCalendarDate calendarDate] descriptionWithCalendarFormat:DATE_FORMAT_STRING] forKey:BGPrefLastScrobbled];
	}
	
	NSNotificationCenter *defaultNotificationCenter = [NSNotificationCenter defaultCenter];
	[defaultNotificationCenter addObserver:self selector:@selector(podWatcherMountedPod:) name:BGNotificationPodMounted object:nil];
	[defaultNotificationCenter addObserver:self selector:@selector(preferencesControllerUpdatedCredentials:) name:BGLoginChangedNotification object:nil];

	[[iTunesWatcher sharedManager] setDelegate:self];
	
	[[iPodWatcher alloc] init];
	
	NSNotificationCenter *workspaceNotificationCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    [workspaceNotificationCenter addObserver:self selector:@selector(workspaceDidLaunchApplication:) name:NSWorkspaceDidLaunchApplicationNotification object:nil];
    [workspaceNotificationCenter addObserver:self selector:@selector(workspaceDidTerminateApplication:) name:NSWorkspaceDidTerminateApplicationNotification object:nil];
}

-(void)menuDidClose:(NSMenu *)menu {
	[(StatusItemView *)statusItem.view setSelected:NO];
	[infoView stopScrollTimer];
	[infoView resetBlueToOffState];
}

-(void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

	prefController = [[PreferencesController alloc] init];

	if ([defaults boolForKey:BGPrefFirstRunKey]) [self doFirstRun];
	
	[self setAppropriateRoundedString];

	[[UKKQueue sharedFileWatcher] setDelegate:self];
	[self applyForXmlChangeNotification];
	
	// let the user know if scrobbling is enabled
	[self performSelector:@selector(podWatcherMountedPod:) withObject:nil afterDelay:10.0];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
	NSLog(@"Quit Decision - NP:%d\nSC:%d",isPostingNP,isScrobbling);
	return (!isPostingNP && !isScrobbling);
}

-(void)doFirstRun {
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

		NSString *overrideCalendarDate = [[[NSCalendarDate calendarDate] dateByAddingYears:0 months:0 days:0 hours:0 minutes:0 seconds:-60] descriptionWithCalendarFormat:DATE_FORMAT_STRING];
		[defaults setValue:overrideCalendarDate forKey:BGPrefLastScrobbled];

		[defaults setBool:FALSE forKey:BGPrefFirstRunKey];
}


-(IBAction)quit:(id)sender {
	[NSApp terminate:self];
}

-(void)applicationWillTerminate:(NSNotification *)aNotification {
	if (statusItem) [[NSStatusBar systemStatusBar] removeStatusItem:statusItem];

	[[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void) dealloc {
	[statusItem release];

	[scrobbleSound release];
	[prefController release];
	
	[currentSessionKey release];
	[currentPostUrl release];
	[currentNowPlayingUrl release];
	
	[nowPlayingDelay invalidate];
	[nowPlayingDelay release];
	
	[tagAutocompleteList release];
		
	[super dealloc];
}

#pragma mark Delegate Method

-(void)podWatcherMountedPod:(NSNotification *)notification {
	[[BGScrobbleDecisionManager sharedManager] refreshDecisionWithAutoDecide:usingAutoDecide userChosenStatus:userChosenStatus notifyingIfChanged:YES];
}

-(void)preferencesControllerUpdatedCredentials:(NSNotification *)notification {
	if (currentSessionKey) [currentSessionKey release];
}

-(void)workspaceDidLaunchApplication:(NSNotification *)notification {
    if ([[[notification userInfo] objectForKey:@"NSApplicationName"] isEqualToString:@"iTunes"]) {
		[self setAppropriateRoundedString];
    }
}

-(void)workspaceDidTerminateApplication:(NSNotification *)notification {
    if ([[[notification userInfo] objectForKey:@"NSApplicationName"] isEqualToString:@"iTunes"]) {
		[self setAppropriateRoundedString];
    }
}

-(void)iTunesWatcherDidDetectStartOfNewSongWithName:(NSString *)aName artist:(NSString *)anArtist artwork:(NSImage *)anArtwork {
	NSImage *growlImage;
	if (anArtwork) {
		growlImage = anArtwork;
	} else {
		growlImage = [NSImage imageNamed:@"iTunesSmall"];
	}
	
	[[GrowlHub sharedManager] postGrowlNotificationWithName:SP_Growl_TrackChanged andTitle:aName andDescription:anArtist andImage:[NSData dataWithData:[growlImage TIFFRepresentation]] andIdentifier:@"SP_Track"];

	NSString *songTitleString = [NSString stringWithFormat:@"%@: %@ ",anArtist,aName];
	[infoView setStringValue:songTitleString isActive:YES];

	[self startNowPlayingTimer];
	
	if ([arrowWindow isVisible]) [self updateTagLabel:self];
}

-(void)iTunesWatcherDidDetectSongStopped {
	[self setAppropriateRoundedString];
	if ([arrowWindow isVisible]) [arrowWindow close];
/*	if (nowPlayingDelay!=nil) {
		[nowPlayingDelay invalidate];
		[nowPlayingDelay release];
	}*/
}

-(void)applyForXmlChangeNotification {
	[[UKKQueue sharedFileWatcher] addPathToQueue:[self fullXmlPath] notifyingAbout:UKKQueueNotifyAboutDelete];
}

-(void)watcher:(id<UKFileWatcher>)watcher receivedNotification:(NSString *)notification forPath:(NSString *)path {
	[self detachScrobbleThreadWithoutConsideration:NO];
	[[UKKQueue sharedFileWatcher] removePathFromQueue:[self fullXmlPath]];
	[self applyForXmlChangeNotification];
}

-(NSString *)fullXmlPath {
	return [[[NSUserDefaults standardUserDefaults] stringForKey:BGPrefXmlLocation] stringByExpandingTildeInPath];
}

-(IBAction)updateTagLabel:(id)sender {
	NSString *properString;
	BGLastFmSong *currentSong = [[iTunesWatcher sharedManager] currentSong];
	if (currentSong) {
		if (!isLoadingCommonTags) {
			[arrowWindow setShouldClose:NO];
			int selectedTag = [tagTypeChooser selectedSegment];
			if (selectedTag==0) {
				properString = currentSong.title;
			} else if (selectedTag==1) {
				properString = currentSong.artist;
			} else if (selectedTag==2) {
				properString = currentSong.album;
			}
			tagLabel.stringValue = [NSString stringWithFormat:@"Tags for: \"%@\"",properString];
			
			[NSThread detachNewThreadSelector:@selector(populateCommonTags) toTarget:self withObject:nil];
			[arrowWindow setShouldClose:YES];
		}
	} else {
		[arrowWindow close];
	}
}

-(NSArray *)tokenField:(NSTokenField *)tokenField completionsForSubstring:(NSString *)substring indexOfToken:(int)tokenIndex indexOfSelectedItem:(int *)selectedIndex {
	NSMutableArray *matchingTags = [NSMutableArray array];
	NSString *substringLower = [substring lowercaseString];
	NSString *currentTag;
	for (currentTag in tagAutocompleteList) {
		if ([currentTag.lowercaseString rangeOfString:substringLower].location == 0) [matchingTags addObject:currentTag];
	}

	return matchingTags;
}

@synthesize tagAutocompleteList;

-(void)populateCommonTags {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	isLoadingCommonTags = YES;
	[commonTagsField setObjectValue:[NSArray array]];
	[commonTagsLoadingView setHidden:NO];
	[commonTagsLoadingIndicator startAnimation:self];
	BGLastFmServiceWorker *serviceWorker = [[BGLastFmServiceWorker alloc] init];
		NSArray *tagList = [serviceWorker tagsForSong:nil forType: tagTypeChooser.selectedSegment];
		if (tagList.count > 0) {
			self.tagAutocompleteList = tagList;
		} else {
			self.tagAutocompleteList = [NSArray arrayWithObjects:@"Tags", @"Could", @"Not", @"Be", @"Loaded",nil];
		}
		[commonTagsField setObjectValue:tagAutocompleteList];
	[serviceWorker release];
	[commonTagsLoadingIndicator stopAnimation:self];
	[commonTagsLoadingView setHidden:YES];
	isLoadingCommonTags = NO;
	[pool release];
}

#pragma mark Scrobbling Status Methods

-(void)setAppropriateRoundedString {
	iTunesWatcher *tunesWatcher = [iTunesWatcher sharedManager];
	if ([tunesWatcher itunesIsRunning]) {
		if (![tunesWatcher iTunesIsPlaying]) {
			[infoView setStringValue:@"iTunes is not playing" isActive:NO];
		} else {
			[infoView setActive:YES];
		}
	} else {
		[infoView setStringValue:@"iTunes is not running" isActive:NO];
	}
}

-(void)setIsScrobblingWithNumber:(NSNumber *)aNumber {
	[self setIsScrobbling: [aNumber boolValue] ];
}

-(void)setIsScrobbling:(BOOL)aBool {
	isScrobbling = aBool;
}

-(void)setIsPostingNP:(BOOL)aBool {
	isPostingNP = aBool;
}

-(IBAction)switchStatus:(id)sender {		
	
	// FUNCTION DESCRIPTION:
	// This function changes the shiny circle icon at the top of the ScrobblePod menu.
	// If the current status is chosen automatically, then the opposite of that is shown
	// when the icon is first clicked.
	//
	// For example, if the icon is a "blue/green" combination, then the next shown colour will
	// be "red". However, if the icon is a "blue/red" icon, then the next shown colour will be
	// "green". This functionality is in place so that the behaviour is as intuitive as possible.
	
	BOOL scrobbleAuto = [[BGScrobbleDecisionManager sharedManager] shouldScrobbleAuto];
	if (usingAutoDecide) { //Changing from auto to manual
		usingAutoDecide = NO;
		userChosenStatus = !scrobbleAuto;
	} else {
		// If you want to see the logic that thse 2 lines replace, email me. Basically, they replace
		// an inefficient "if" selector, saving 10-15 lines of code.
		userChosenStatus = !userChosenStatus;
		usingAutoDecide  = scrobbleAuto ^ userChosenStatus; //XOR
	}	
	[self setStatus]; //Display the changes just made
}

#pragma mark Last.fm API Interaction

-(IBAction)loveSong:(id)sender {		
	[self startTasteCommand:ServiceWorker_LoveCommand];
}

-(IBAction)banSong:(id)sender {
	[self startTasteCommand:ServiceWorker_BanCommand];
}

-(IBAction)tagSong:(id)sender {
	[tagEntryField setObjectValue:[NSArray array]];
	[self showArrowWindowForView:tagEntryView];
	[self updateTagLabel:self];
	[arrowWindow makeFirstResponder:tagEntryField];
}

-(IBAction)performTagSong:(id)sender {
	[arrowWindow setShouldClose:NO];
	BGLastFmServiceWorker *serviceWorker = [[BGLastFmServiceWorker alloc] init];
		[serviceWorker acquireCredentials];
		[serviceWorker tagWithType:[tagTypeChooser selectedSegment] forTags:[tagEntryField objectValue]];
	[serviceWorker release];
	[arrowWindow setShouldClose:YES];
}

-(IBAction)recommendSong:(id)sender {
	[self showArrowWindowForView:recommendationEntryView];
//	[self updateTagLabel:self];
	[self updateFriendsList];
	[arrowWindow makeFirstResponder:tagEntryField];
}

-(IBAction)performRecommendSong:(id)sender {
	[arrowWindow setShouldClose:NO];
	BGLastFmServiceWorker *serviceWorker = [[BGLastFmServiceWorker alloc] init];
		[serviceWorker acquireCredentials];
		[serviceWorker recommendWithType:[recommendTypeChooser selectedSegment] forFriendUsernames:friendsController.selectedObjects];
	[serviceWorker release];
	[arrowWindow setShouldClose:YES];
}

-(void)updateFriendsList {
	BGLastFmServiceWorker *friendFinder = [[BGLastFmServiceWorker alloc] init];
		NSArray *friendsList = [friendFinder friendsForUser:[[NSUserDefaults standardUserDefaults] stringForKey:BGPrefUserKey]];
	[friendFinder release];
	[friendsController removeObjects: friendsController.arrangedObjects];
	[friendsController addObjects:friendsList];
	NSLog(@"%@",friendsList);
}

-(void)showArrowWindowForView:(NSView *)theView {
	float xVal, yVal;
	NSPoint statusItemLocation = [[[statusItem view] window] frame].origin;
	xVal = statusItemLocation.x;
	yVal = statusItemLocation.y;
	[NSApp activateIgnoringOtherApps:YES];
	[statusMenu cancelTracking];
	[arrowWindow setFrame:theView.frame display:YES];
	[arrowWindow setContentView:theView];
	[arrowWindow positionAtMenuBarForHorizontalValue:xVal-(theView.frame.size.width/2)+(statusItem.view.frame.size.width/2) andVerticalValue:yVal-theView.frame.size.height+2];
	[arrowWindow setInitialFirstResponder:tagEntryField];
	[self performSelector:@selector(showArrowWindow) withObject:nil afterDelay:0.15];
}

-(void)showArrowWindow {
	arrowWindow.alphaValue = 0.0;
	[arrowWindow makeKeyAndOrderFront:self];
	[arrowWindow makeMainWindow];
	[NSAnimationContext beginGrouping];
		[[NSAnimationContext currentContext] setDuration:0.1];
		[arrowWindow.animator setAlphaValue:1.0f];
	[NSAnimationContext endGrouping];
}

-(void)startTasteCommand:(NSString *)tasteCommand {
//	[infoView setStringValue:@"Loving song..." isActive:YES];
	BGLastFmServiceWorker *serviceWorker = [[BGLastFmServiceWorker alloc] init];
	[serviceWorker acquireCredentials];
	[serviceWorker submitTasteCommand:tasteCommand];
	[serviceWorker release];
}

#pragma mark Preferences

-(IBAction)showAboutPanel:(id)sender {
	[NSApp activateIgnoringOtherApps:YES];
	[NSApp orderFrontStandardAboutPanel:self];
}

-(IBAction)raiseLoginPanel:(id)sender {
	if (!prefController) {
		prefController = [[PreferencesController alloc] init];
	}
	[prefController showWindow:self];
}

#pragma mark Main Scrobbling Methods

-(void)detachScrobbleThreadWithoutConsideration:(BOOL)passThrough {
	if (!isScrobbling) {
		BOOL shouldContinue = passThrough;
		if (!passThrough) shouldContinue = [[BGScrobbleDecisionManager sharedManager] shouldScrobbleWhenUsingAutoDecide:usingAutoDecide withUserChosenStatus:userChosenStatus];
		if (shouldContinue) [NSThread detachNewThreadSelector:@selector(postScrobble) toTarget:self withObject:nil];
	}
}

-(IBAction)goToUserProfilePage:(id)sender {
	[statusMenu cancelTracking];
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://www.last.fm/user/%@",[[NSUserDefaults standardUserDefaults] stringForKey:BGPrefUserKey] ] ]];
}

-(IBAction)manualScrobble:(id)sender {
	NSCalendarDate *lastScrobbled = [NSCalendarDate dateWithString:[[NSUserDefaults standardUserDefaults] valueForKey:BGPrefLastScrobbled] calendarFormat:DATE_FORMAT_STRING];
	[NSApp activateIgnoringOtherApps:YES];
	int shouldForceScrobble = NSRunAlertPanel(@"Scrobble songs before syncing your iPod?", @"Songs played on your iPod after %@ will not be scrobbled when the iPod is next connected." , @"Scrobble Anyway", @"Cancel", nil,[lastScrobbled relativeDateDescription], nil);
	if (shouldForceScrobble == NSAlertDefaultReturn) [self detachScrobbleThreadWithoutConsideration:YES];
}

-(void)postScrobble {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	[self performSelectorOnMainThread:@selector(setIsScrobblingWithNumber:) withObject:[NSNumber numberWithBool:YES] waitUntilDone:YES];// setIsScrobbling:YES];

	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

	NSString *lastScrobbleDateString = 	[defaults valueForKey:BGPrefLastScrobbled];
	NSCalendarDate *applescriptInputDateString = [NSCalendarDate dateWithString:lastScrobbleDateString calendarFormat:DATE_FORMAT_STRING];// descriptionWithCalendarFormat:DATE_FORMAT_STRING];
	
	BGTrackCollector *trackCollector = [[BGTrackCollector alloc] init];
		NSArray *recentTracksSimple = [trackCollector collectTracksFromXMLFile:self.fullXmlPath withCutoffDate:applescriptInputDateString includingPodcasts:(![defaults boolForKey:BGPrefShouldIgnorePodcasts]) includingVideo:(![defaults boolForKey:BGPrefShouldIgnoreVideo]) ignoringComment:[defaults stringForKey:BGPrefIgnoreCommentString] withMinimumDuration:[defaults integerForKey:BGPrefIgnoreShortLength]];//![defaults boolForKey:BGPrefShouldIgnorePodcasts]
	[trackCollector release];
	
	// Calculate extra plays, and insert them into recent songs array
	BGMultipleSongPlayManager *multiPlayManager = [[BGMultipleSongPlayManager alloc] init];
		NSArray *allRecentTracks = [multiPlayManager completeSongListForRecentTracks:recentTracksSimple sinceDate:applescriptInputDateString];
	[multiPlayManager release];
	
	[recentTracksSimple release];
	
	NSLog(@"GOT ALL RECENT TRACKS:\n%@",allRecentTracks);
	
	int recentTracksCount = allRecentTracks.count;
	
	if (recentTracksCount > 0) {
	
		if (recentTracksCount > 1) 	[[GrowlHub sharedManager] postGrowlNotificationWithName:SP_Growl_StartedScrobbling andTitle:SP_Growl_StartedScrobbling andDescription:[NSString stringWithFormat:@"Scrobbling %d track%@ to Last.fm", recentTracksCount, ( recentTracksCount == 1 ? @"" : @"s" )] andImage:nil andIdentifier:SP_Growl_StartedScrobbling];

		BOOL startFromHandshake = YES;
		BOOL forceHandshake = NO;
		int scrobbleAttempts = 0;
		while (startFromHandshake && scrobbleAttempts < 2) {
		
			if ((!currentSessionKey || !currentPostUrl) || forceHandshake) {
				
				if (currentSessionKey) [currentSessionKey release];
				if (currentPostUrl) [currentPostUrl release];
				
				SecKeychainItemRef itemRef;
				NSString *currentUsername = [defaults stringForKey:BGPrefUserKey];
				NSString *currentPassword = [SFHFKeychainUtils getWebPasswordForUser:currentUsername URL:[NSURL URLWithString:@"http://www.last.fm/"] domain:@"Last.FM Login" itemReference:&itemRef];

				
				BGLastFmHandshaker *theHandshaker = [[BGLastFmHandshaker alloc] init];
				BGLastFmHandshakeResponse *handshakeResponse = [theHandshaker performHandshakeWithUsername:currentUsername andPassword:currentPassword];
				
				if (!handshakeResponse.didFail && handshakeResponse.sessionKey!=nil) {
					currentSessionKey = [handshakeResponse.sessionKey retain];
					currentPostUrl = [handshakeResponse.postURL retain];
				}
				
				[handshakeResponse release];
				[theHandshaker release];
			}
			
			if (currentSessionKey && currentPostUrl) {
								
				BGLastFmScrobbler *theScrobbler = [[BGLastFmScrobbler alloc] init];
				BGLastFmScrobbleResponse *scrobbleResponse = [theScrobbler performScrobbleWithSongs:allRecentTracks andSessionKey:currentSessionKey toURL:currentPostUrl];

				if (!scrobbleResponse.wasSuccessful) {
					if (scrobbleResponse.responseType==2) {
						forceHandshake = YES;
						startFromHandshake = YES;
					} else if (scrobbleResponse.responseType==3) {
						[[GrowlHub sharedManager] postGrowlNotificationWithName:SP_Growl_FailedScrobbling andTitle:@"Tracks could not be scrobbled" andDescription:[NSString stringWithFormat:@"Server said \"%@\"",[scrobbleResponse failureReason]] andImage:nil andIdentifier:SP_Growl_StartedScrobbling];
						[prefController addHistoryWithSuccess:NO andDate:[NSDate date] andDescription:[NSString stringWithFormat:@"Scrobble failed: ",[scrobbleResponse failureReason]]];
						startFromHandshake = YES;
					} else {
						if (scrobbleAttempts==1) {
							[[GrowlHub sharedManager] postGrowlNotificationWithName:SP_Growl_FailedScrobbling andTitle:@"Tracks could not be scrobbled" andDescription:@"Posting most likely timed out" andImage:nil andIdentifier:SP_Growl_StartedScrobbling];
							[prefController addHistoryWithSuccess:NO andDate:[NSDate date] andDescription:@"Scrobble failed likely due to timeout"];
						}
						startFromHandshake = YES;
					}
				} else {
					[prefController addHistoryWithSuccess:YES andDate:[NSDate date] andDescription:[NSString stringWithFormat:@"Scrobbled %d tracks",recentTracksCount]];
					startFromHandshake = NO;
					NSCalendarDate *returnedDate = [scrobbleResponse lastScrobbleDate];
					//[self addActivityHistoryEntryWithStatus:NO andDescription:@"Successful"];
					if (returnedDate!=nil) {
						[defaults setValue:[returnedDate descriptionWithCalendarFormat:DATE_FORMAT_STRING] forKey:BGPrefLastScrobbled];
						[defaults synchronize];
					}
					[defaults setObject: [NSNumber numberWithInt: [[NSUserDefaults standardUserDefaults] integerForKey:BGTracksScrobbledTotal]+recentTracksCount ]
										forKey:BGTracksScrobbledTotal];
					if (recentTracksCount>1) [[GrowlHub sharedManager] postGrowlNotificationWithName:SP_Growl_FinishedScrobbling andTitle:@"Finished Scrobbling" andDescription:[NSString stringWithFormat:@"%d track%@ successfully scrobbled to Last.fm",recentTracksCount,( recentTracksCount == 1 ? @"" : @"s" )] andImage:nil andIdentifier:SP_Growl_StartedScrobbling];

					if ([defaults boolForKey:BGPrefShouldPlaySound]) {
						[self playScrobblingSound];
					}

				}
				
				[scrobbleResponse release];
				[theScrobbler release];

			} else {
				[prefController addHistoryWithSuccess:NO andDate:[NSDate date] andDescription:@"Handshake Failed"];
				startFromHandshake = YES;
			}//end if handshake worked
			scrobbleAttempts++;
		} //end while around handshake&scrobble processes
		
	}
	
	[self performSelectorOnMainThread:@selector(setIsScrobblingWithNumber:) withObject:[NSNumber numberWithBool:NO] waitUntilDone:YES];// setIsScrobbling:NO];
	
	[pool release];
}

-(void)playScrobblingSound {
	if (!scrobbleSound) {
		NSString *soundPath = [[NSBundle mainBundle] pathForResource:@"bubbles" ofType:@"aif"];
		scrobbleSound = [[NSSound alloc] initWithContentsOfFile:soundPath byReference:NO];
	}
	[scrobbleSound play];
}

-(void)startNowPlayingTimer {
	if (nowPlayingDelay!=nil) {
		[nowPlayingDelay invalidate];
		[nowPlayingDelay release];
	}
	nowPlayingDelay = [NSTimer scheduledTimerWithTimeInterval:15.0 target:self selector:@selector(detachNowPlayingThread:) userInfo:nil repeats:NO];
	[nowPlayingDelay retain];
}

-(void)detachNowPlayingThread:(NSTimer *)fromTimer {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	if (!isPostingNP && [defaults boolForKey:BGPrefWantNowPlaying]) {
		BGLastFmSong *currentPlayingSong = [iTunesWatcher sharedManager].currentSong;
		[NSThread detachNewThreadSelector:@selector(postNowPlayingNotificationForSong:) toTarget:self withObject:currentPlayingSong];
	}
}

-(void)postNowPlayingNotificationForSong:(BGLastFmSong *)nowPlayingSong {
	NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];

	//////////////////////////////////////////////////////////
	
	[self setIsPostingNP:YES];

	if (nowPlayingSong) {
		
		BOOL startFromHandshake = YES;
		BOOL forceHandshake = NO;
		int notifyAttempts = 0;
		while (startFromHandshake && notifyAttempts < 2) {
			
			if ((!currentSessionKey || !currentNowPlayingUrl) || forceHandshake) {
				
				if (currentSessionKey) [currentSessionKey release];
				if (currentNowPlayingUrl) [currentNowPlayingUrl release];
				
				SecKeychainItemRef itemRef;
				NSString *currentUsername = [[NSUserDefaults standardUserDefaults] stringForKey:BGPrefUserKey];
				NSString *currentPassword = [SFHFKeychainUtils getWebPasswordForUser:currentUsername  URL:[NSURL URLWithString:@"http://www.last.fm/"] domain:@"Last.FM Login" itemReference:&itemRef];

				
				BGLastFmHandshaker *theHandshaker = [[BGLastFmHandshaker alloc] init];
				BGLastFmHandshakeResponse *handshakeResponse = [theHandshaker performHandshakeWithUsername:currentUsername andPassword:currentPassword];
				
				if (!handshakeResponse.didFail && handshakeResponse.sessionKey!=nil) {
					currentSessionKey = [handshakeResponse.sessionKey retain];
					currentNowPlayingUrl = [handshakeResponse.nowPlayingURL retain];
				}
				
				[handshakeResponse release];
				[theHandshaker release];
			}// end if need to handshake
			
			if (currentSessionKey && currentNowPlayingUrl) {
				NSLog(@"Song length: %d seconds",nowPlayingSong.length);
				NSString *npPostString = [NSString stringWithFormat:@"s=%@&a=%@&t=%@&b=%@&l=%d&n=&m=",currentSessionKey,nowPlayingSong.artist.urlEncodedString,nowPlayingSong.title.urlEncodedString,nowPlayingSong.album.urlEncodedString,nowPlayingSong.length];
				NSData *postData = [npPostString dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
				NSString *postLength = [NSString stringWithFormat:@"%d", postData.length];
		
				NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
				[request setURL:currentNowPlayingUrl];
				[request setHTTPMethod:@"POST"];
				[request setValue:postLength forHTTPHeaderField:@"Content-Length"];
				[request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
				[request setTimeoutInterval:20.0];// timeout scrobble posting after 20 seconds
				[request setHTTPBody:postData];

				NSError *postingError;
				NSData *npResponseData = [NSURLConnection sendSynchronousRequest:request returningResponse:nil error:&postingError];
				
				[request release];
						
				if (npResponseData!=nil && postingError==nil) {
					NSString *npResponseString = [[NSString alloc] initWithData:npResponseData encoding:NSUTF8StringEncoding];
					if ([npResponseString rangeOfString:@"BADSESSION"].length>0) {
						forceHandshake = YES;
						startFromHandshake = YES;
					} else if ([npResponseString rangeOfString:@"OK"].length>0) {
						startFromHandshake = NO;
					} else {
					}
					[npResponseString release];
				}
								
			} else {
				startFromHandshake = YES;
			}//end if handshake worked
	
			notifyAttempts++;
		} //end while around handshake&notifying processes		
	}
	
	//////////////////////////////////////////////////////////
	
	[self setIsPostingNP:NO];
	[pool release];
}

@end