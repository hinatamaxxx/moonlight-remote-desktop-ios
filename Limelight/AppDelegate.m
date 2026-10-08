//
//  AppDelegate.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "AppDelegate.h"
#if !TARGET_OS_TV
#import "EmbeddedTailscale.h"
#import "Localization.h"
#import "SWRevealViewController.h"
#import "MainFrameViewController.h"
#import "SettingsViewController.h"

// The app's root: the standard tab bar (Liquid Glass on iOS 26+) with Home,
// Tailscale and Settings. Status bar and system gestures follow the screen
// shown in the selected tab, so the stream can hide the home indicator.
@interface MoonlightTabBarController : UITabBarController
@end

@implementation MoonlightTabBarController
- (UIViewController *)visibleContent {
    UIViewController *controller = self.selectedViewController;
    if ([controller isKindOfClass:[UINavigationController class]]) {
        controller = ((UINavigationController *)controller).topViewController;
    }
    return controller;
}
// Portrait shows the status bar (clock, battery); landscape stays full screen.
- (BOOL)prefersStatusBarHidden {
    return self.view.bounds.size.width > self.view.bounds.size.height;
}
- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}
- (UIViewController *)childViewControllerForStatusBarHidden {
    return nil;
}
- (UIViewController *)childViewControllerForStatusBarStyle {
    return nil;
}
- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden {
    return self.visibleContent;
}
- (UIViewController *)childViewControllerForScreenEdgesDeferringSystemGestures {
    return self.visibleContent;
}
- (UIViewController *)childViewControllerForPointerLock {
    return self.visibleContent;
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self setNeedsStatusBarAppearanceUpdate];
    } completion:nil];
}
@end

// Builds the tab bar from the storyboard's screens. The storyboard roots them
// in the old side-drawer controller; take Home and Settings out of it.
static UIViewController *MoonlightMakeRoot(UIViewController *storyboardRoot) {
    if (![storyboardRoot isKindOfClass:[SWRevealViewController class]]) {
        return storyboardRoot;
    }
    SWRevealViewController *reveal = (SWRevealViewController *)storyboardRoot;
    [reveal loadViewIfNeeded];
    UIViewController *home = reveal.frontViewController;
    UIViewController *settings = reveal.rearViewController;
    if (home == nil || settings == nil) {
        return storyboardRoot;
    }
    for (UIViewController *child in @[home, settings]) {
        [child willMoveToParentViewController:nil];
        [child.view removeFromSuperview];
        [child removeFromParentViewController];
    }

    home.tabBarItem = [[UITabBarItem alloc] initWithTitle:ML(@"Home") image:[UIImage systemImageNamed:@"house"] selectedImage:[UIImage systemImageNamed:@"house.fill"]];

    MainFrameViewController *mainFrame = nil;
    if ([home isKindOfClass:[UINavigationController class]]) {
        mainFrame = (MainFrameViewController *)((UINavigationController *)home).viewControllers.firstObject;
    }
    MoonlightTabBarController *tabs = [[MoonlightTabBarController alloc] init];
    __weak MoonlightTabBarController *weakTabs = tabs;
    __weak MainFrameViewController *weakMainFrame = mainFrame;
    UIViewController *tailscale = [EmbeddedTailscale tabControllerOnPeerSelected:^(NSString *address) {
        weakTabs.selectedIndex = 0;
        [weakMainFrame addHostWithAddress:address pair:YES];
    }];
    tailscale.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Tailscale" image:[EmbeddedTailscale logoImage] selectedImage:nil];

    MoonlightSettingsViewController *settingsList = [[MoonlightSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *settingsNavigation = [[UINavigationController alloc] initWithRootViewController:settingsList];
    settingsNavigation.tabBarItem = [[UITabBarItem alloc] initWithTitle:ML(@"Settings") image:[UIImage systemImageNamed:@"gearshape"] selectedImage:[UIImage systemImageNamed:@"gearshape.fill"]];

    tabs.viewControllers = @[home, tailscale, settingsNavigation];
    return tabs;
}

@interface MoonlightSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation MoonlightSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    AppDelegate *delegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
    delegate.window = self.window;
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.window.rootViewController = MoonlightMakeRoot(self.window.rootViewController);
}
// In case the storyboard's root arrives after willConnectToSession
- (void)sceneWillEnterForeground:(UIScene *)scene {
    if ([self.window.rootViewController isKindOfClass:[SWRevealViewController class]]) {
        self.window.rootViewController = MoonlightMakeRoot(self.window.rootViewController);
    }
}
- (void)sceneDidEnterBackground:(UIScene *)scene {
    [(AppDelegate *)UIApplication.sharedApplication.delegate saveContext];
}
- (void)windowScene:(UIWindowScene *)windowScene performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler {
    AppDelegate *delegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
    delegate.pcUuidToLoad = shortcutItem.userInfo[@"UUID"];
    delegate.shortcutCompletionHandler = completionHandler;
}
@end
#endif


@implementation AppDelegate

@synthesize managedObjectContext = _managedObjectContext;
@synthesize managedObjectModel = _managedObjectModel;
@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;

static NSOperationQueue* mainQueue;

#if TARGET_OS_TV
static NSString* DB_NAME = @"Moonlight_tvOS.bin";
#else
static NSString* DB_NAME = @"Limelight_iOS.sqlite";
#endif

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
#if !TARGET_OS_TV
    [EmbeddedTailscale restore];
    UIApplicationShortcutItem* shortcut = [launchOptions valueForKey:UIApplicationLaunchOptionsShortcutItemKey];
    if (shortcut != nil) {
        _pcUuidToLoad = (NSString*)[shortcut.userInfo objectForKey:@"UUID"];
    }
#endif
    return YES;
}

#if !TARGET_OS_TV
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (options.shortcutItem != nil) {
        self.pcUuidToLoad = options.shortcutItem.userInfo[@"UUID"];
    }
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Moonlight" sessionRole:session.role];
    configuration.delegateClass = MoonlightSceneDelegate.class;
    NSString *storyboardName = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone";
    configuration.storyboard = [UIStoryboard storyboardWithName:storyboardName bundle:nil];
    return configuration;
}

- (void)application:(UIApplication *)application performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL succeeded))completionHandler {
    _pcUuidToLoad = (NSString*)[shortcutItem.userInfo objectForKey:@"UUID"];
    _shortcutCompletionHandler = completionHandler;
}

// Takes precedence over the Info.plist orientations, which packaging may
// replace with the original landscape-only list.
- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    if (_orientationLock != 0) {
        return _orientationLock;
    }
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)setOrientationLock:(UIInterfaceOrientationMask)orientationLock {
    _orientationLock = orientationLock;
    if (@available(iOS 16.0, *)) {
        UIViewController *controller = self.window.rootViewController;
        while (controller != nil) {
            [controller setNeedsUpdateOfSupportedInterfaceOrientations];
            controller = controller.presentedViewController;
        }
    }
    else {
        [UIViewController attemptRotationToDeviceOrientation];
    }
}

- (void)rotateToOrientations:(UIInterfaceOrientationMask)mask {
    UIWindow *window = self.window;
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *preferences = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
        [window.windowScene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
            Log(LOG_W, @"Rotation request failed: %@", error);
        }];
    }
    else {
        UIInterfaceOrientation target = (mask & UIInterfaceOrientationMaskPortrait) ? UIInterfaceOrientationPortrait :
            (mask & UIInterfaceOrientationMaskLandscapeLeft) ? UIInterfaceOrientationLandscapeLeft : UIInterfaceOrientationLandscapeRight;
        [UIDevice.currentDevice setValue:@(target) forKey:@"orientation"];
        [UIViewController attemptRotationToDeviceOrientation];
    }
}
#endif

- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Saves changes in the application's managed object context before the application terminates.
    [self saveContext];
}

- (void)saveContext
{
    NSManagedObjectContext *managedObjectContext = [self managedObjectContext];
    if (managedObjectContext != nil) {
        [managedObjectContext performBlock:^{
            if (![managedObjectContext hasChanges]) {
                return;
            }
            NSError *error = nil;
            if (![managedObjectContext save:&error]) {
                Log(LOG_E, @"Critical database error: %@, %@", error, [error userInfo]);
            }
            
#if TARGET_OS_TV
            NSData* dbData = [NSData dataWithContentsOfURL:[[[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject] URLByAppendingPathComponent:DB_NAME]];
            [[NSUserDefaults standardUserDefaults] setObject:dbData forKey:DB_NAME];
#endif
        }];
    }
}

#pragma mark - Core Data stack

// Returns the managed object context for the application.
// If the context doesn't already exist, it is created and bound to the persistent store coordinator for the application.
- (NSManagedObjectContext *)managedObjectContext
{
    if (_managedObjectContext != nil) {
        return _managedObjectContext;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (coordinator != nil) {
        _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [_managedObjectContext setPersistentStoreCoordinator:coordinator];
    }
    return _managedObjectContext;
}

// Returns the managed object model for the application.
// If the model doesn't already exist, it is created from the application's model.
- (NSManagedObjectModel *)managedObjectModel
{
    if (_managedObjectModel != nil) {
        return _managedObjectModel;
    }
    _managedObjectModel = [NSManagedObjectModel mergedModelFromBundles:nil];
    return _managedObjectModel;
}

// Returns the persistent store coordinator for the application.
// If the coordinator doesn't already exist, it is created and the application's store added to it.
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator != nil) {
        return _persistentStoreCoordinator;
    }
    
    NSError *error = nil;
    _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             [NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption,
                             [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption, nil];
    NSString* storeType;
    
#if TARGET_OS_TV
    // Use a binary store for tvOS since we will need exclusive access to the file
    // to serialize into NSUserDefaults.
    storeType = NSBinaryStoreType;
#else
    storeType = NSSQLiteStoreType;
#endif
    
    // We must ensure the persistent store is ready to opened
    [self preparePersistentStore];
    
    if (![_persistentStoreCoordinator addPersistentStoreWithType:storeType configuration:nil URL:[self getStoreURL] options:options error:&error]) {
        // Log the error
        Log(LOG_E, @"Critical database error: %@, %@", error, [error userInfo]);
        
        // Drop the database
        [self dropDatabase];
        
        // Try again
        return [self persistentStoreCoordinator];
    }
    
    return _persistentStoreCoordinator;
}

#pragma mark - Application's Documents directory

// Returns the URL to the application's Documents directory.
- (NSURL *)applicationDocumentsDirectory
{
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
}

- (void) dropDatabase
{
    // Delete the file on disk
    [[NSFileManager defaultManager] removeItemAtURL:[self getStoreURL] error:nil];
    
#if TARGET_OS_TV
    // Also delete the copy in the NSUserDefaults on tvOS
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:DB_NAME];
#endif
}

- (void) preparePersistentStore
{
#if TARGET_OS_TV
    // On tvOS, we may need to inflate the DB from NSUserDefaults
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheDirectory = [paths objectAtIndex:0];
    NSString *dbPath = [cacheDirectory stringByAppendingPathComponent:DB_NAME];
    
    // Always prefer the on disk version
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) {
        // If that is unavailable, inflate it from NSUserDefaults
        NSData* data = [[NSUserDefaults standardUserDefaults] dataForKey:DB_NAME];
        if (data != nil) {
            Log(LOG_I, @"Inflating database from NSUserDefaults");
            [data writeToFile:dbPath atomically:YES];
        }
        else {
            Log(LOG_I, @"No database on disk or in NSUserDefaults");
        }
    }
    else {
        Log(LOG_I, @"Using cached database");
    }
#endif
}

- (NSURL*) getStoreURL {
#if TARGET_OS_TV
    // We use the cache folder to store our database on tvOS
    return [[[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject] URLByAppendingPathComponent:DB_NAME];
#else
    return [[self applicationDocumentsDirectory] URLByAppendingPathComponent:DB_NAME];
#endif
}

@end
