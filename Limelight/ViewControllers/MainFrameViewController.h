//
//  MainFrameViewController.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "DiscoveryManager.h"
#import "PairManager.h"
#import "StreamConfiguration.h"
#import "UIComputerView.h"
#import "UIAppView.h"
#import "AppAssetManager.h"
#import "SWRevealViewController.h"

@interface MainFrameViewController : UICollectionViewController <DiscoveryCallback, PairCallback, HostCallback, AppCallback, AppAssetCallback, NSURLConnectionDelegate, SWRevealViewControllerDelegate>

@property (weak, nonatomic) IBOutlet UIBarButtonItem *settingsButton;
#if !TARGET_OS_TV
@property (weak, nonatomic) IBOutlet UIBarButtonItem *upButton;
#endif

// Adds a PC by address; with pair set it is opened right away to pair.
- (void) addHostWithAddress:(NSString*)hostAddress pair:(BOOL)pair;
@end
