//  MainFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import ImageIO;

#import "MainFrameViewController.h"
#import <Network/Network.h>
#import "Localization.h"
#if !TARGET_OS_TV
#import "EmbeddedTailscale.h"
#endif

#import "CryptoManager.h"
#import "HttpManager.h"
#import "Connection.h"
#import "StreamManager.h"
#import "Utils.h"
#import "UIComputerView.h"
#import "UIAppView.h"
#import "DataManager.h"
#import "TemporarySettings.h"
#import "WakeOnLanManager.h"
#import "AppListResponse.h"
#import "ServerInfoResponse.h"
#import "StreamFrameViewController.h"
#import "LoadingFrameViewController.h"
#import "ComputerScrollView.h"
#import "TemporaryApp.h"
#import "IdManager.h"
#import "ConnectionHelper.h"

#if !TARGET_OS_TV
#import "SettingsViewController.h"
#else
#import <sys/utsname.h>
#endif

#import <VideoToolbox/VideoToolbox.h>

#include <Limelight.h>

#if !TARGET_OS_TV
@interface MainFrameViewController () <UIAdaptivePresentationControllerDelegate>
- (void) connectToHost:(TemporaryHost*)host view:(UIView*)view;
- (void) wakeHost:(TemporaryHost*)host;
- (void) showSettingsForHost:(TemporaryHost*)host;
- (void) testNetwork;
- (void) confirmRemoveHost:(TemporaryHost*)host view:(UIView*)view;
- (void) showTailscaleSetup;
- (void) showTailscalePeerPicker;
@end

@interface HostCardView : UIControl
@property (nonatomic, copy) void (^onTap)(HostCardView* card);
@property (nonatomic, copy) void (^onLongPress)(HostCardView* card);
@property (nonatomic, copy) void (^onPower)(HostCardView* card);
@property (nonatomic, copy) void (^onSettings)(HostCardView* card);
- (instancetype)initWithHost:(TemporaryHost*)host;
@end

// One PC on Home: tap to connect; power (Wake-on-LAN), connect and settings
// buttons; long press for every action.
@implementation HostCardView

- (instancetype)initWithHost:(TemporaryHost*)host {
    self = [super initWithFrame:CGRectZero];
    self.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.layer.cornerRadius = 20;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    BOOL online = host.state == StateOnline;
    BOOL paired = host.pairState == PairStatePaired;
    UIColor* accent = online ? (paired ? UIColor.systemGreenColor : UIColor.systemOrangeColor) : UIColor.systemGrayColor;

    UIView* iconBackground = [[UIView alloc] init];
    iconBackground.backgroundColor = [accent colorWithAlphaComponent:0.18];
    iconBackground.layer.cornerRadius = 12;
    iconBackground.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageView* icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"desktopcomputer"]];
    icon.tintColor = accent;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];

    UILabel* name = [[UILabel alloc] init];
    name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    name.text = host.name;

    UILabel* status = [[UILabel alloc] init];
    status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    status.textColor = UIColor.secondaryLabelColor;
    NSString* state;
    switch (host.state) {
        case StateOnline:
            state = paired ? ML(@"Online") : ML(@"Online · Tap to pair");
            break;
        case StateOffline:
            state = ML(@"Offline");
            break;
        default:
            state = ML(@"Checking…");
            break;
    }
    NSString* route = host.activeAddress == nil ? nil : [EmbeddedTailscale matchesAddress:host.activeAddress] ? @"Tailscale" : @"LAN";
    status.text = route != nil && host.state != StateOffline ? [NSString stringWithFormat:@"%@ · %@", state, route] : state;

    UIView* indicator;
    if (host.state == StateUnknown) {
        UIActivityIndicatorView* spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        indicator = spinner;
    }
    else {
        UIView* dot = [[UIView alloc] init];
        dot.backgroundColor = accent;
        dot.layer.cornerRadius = 5;
        [dot.widthAnchor constraintEqualToConstant:10].active = YES;
        [dot.heightAnchor constraintEqualToConstant:10].active = YES;
        indicator = dot;
    }

    UIStackView* text = [[UIStackView alloc] initWithArrangedSubviews:@[name, status]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;

    // Power, connect and settings
    UIButton* (^action)(NSString*, NSString*, UIColor*, SEL) = ^UIButton*(NSString* title, NSString* symbol, UIColor* color, SEL selector) {
        UIButtonConfiguration* config = [UIButtonConfiguration grayButtonConfiguration];
        config.image = [UIImage systemImageNamed:symbol];
        config.title = title;
        config.imagePadding = 5;
        config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
        config.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id>*(NSDictionary<NSAttributedStringKey, id>* attributes) {
            NSMutableDictionary* updated = [attributes mutableCopy];
            updated[NSFontAttributeName] = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            return updated;
        };
        if (color != nil) {
            config.baseForegroundColor = color;
        }
        UIButton* button = [UIButton buttonWithConfiguration:config primaryAction:nil];
        [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
        return button;
    };
    UIButton* power = action(ML(@"Wake"), @"power", nil, @selector(powerTapped));
    UIButton* connect = action(ML(@"Connect"), @"play.fill", UIColor.systemGreenColor, @selector(tapped));
    UIButton* settings = action(ML(@"Settings"), @"gearshape", nil, @selector(settingsTapped));
    connect.enabled = host.state != StateOffline;
    UIStackView* actions = [[UIStackView alloc] initWithArrangedSubviews:@[settings, power, connect]];
    actions.spacing = 8;
    actions.distribution = UIStackViewDistributionFillEqually;

    for (UIView* view in @[iconBackground, icon, text, indicator, actions]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        view.userInteractionEnabled = view == actions;
        [self addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [iconBackground.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [iconBackground.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
        [iconBackground.widthAnchor constraintEqualToConstant:46],
        [iconBackground.heightAnchor constraintEqualToConstant:46],
        [icon.centerXAnchor constraintEqualToAnchor:iconBackground.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconBackground.centerYAnchor],
        [text.leadingAnchor constraintEqualToAnchor:iconBackground.trailingAnchor constant:14],
        [text.centerYAnchor constraintEqualToAnchor:iconBackground.centerYAnchor],
        [text.trailingAnchor constraintLessThanOrEqualToAnchor:indicator.leadingAnchor constant:-10],
        [indicator.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
        [indicator.centerYAnchor constraintEqualToAnchor:iconBackground.centerYAnchor],
        [actions.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [actions.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
        [actions.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-14],
        [actions.heightAnchor constraintEqualToConstant:36],
    ]];

    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", name.text, status.text];
    [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [self addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)]];
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.15 animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.98, 0.98) : CGAffineTransformIdentity;
    }];
}

- (void)tapped {
    if (self.onTap) self.onTap(self);
}

- (void)powerTapped {
    if (self.onPower) self.onPower(self);
}

- (void)settingsTapped {
    if (self.onSettings) self.onSettings(self);
}

- (void)longPressed:(UILongPressGestureRecognizer*)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan && self.onLongPress) {
        self.onLongPress(self);
    }
}

@end

// Settings for one PC: status, how it is reached (local IP, Tailscale,
// route choice) and its actions.
@interface HostSettingsViewController : UITableViewController
@property (nonatomic, strong) TemporaryHost* host;
@property (nonatomic, weak) MainFrameViewController* owner;
@end

@implementation HostSettingsViewController {
    NSArray<NSDictionary*>* _sections; // title, footer, rows: {title, detail, symbol, destructive, action}
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.host.name;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuild];
}

- (void)close {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

// Runs an owner action after the sheet is gone (for screens on Home)
- (void)closeThen:(void (^)(void))block {
    [self.navigationController dismissViewControllerAnimated:YES completion:block];
}

- (NSString*)routeName:(NSInteger)preference {
    switch (preference) {
        case 1: return ML(@"Local network only");
        case 2: return ML(@"Tailscale only");
        default: return ML(@"Automatic (local network first)");
    }
}

- (void)rebuild {
    TemporaryHost* host = self.host;
    __weak typeof(self) weakSelf = self;
    BOOL tailscale = [EmbeddedTailscale matchesAddress:host.address];
    NSString* state = host.state == StateOnline ? ML(@"Online") : host.state == StateOffline ? ML(@"Offline") : ML(@"Checking…");
    NSString* route = @"—";
    if (host.activeAddress != nil && host.state == StateOnline) {
        route = [NSString stringWithFormat:@"%@（%@）", [EmbeddedTailscale matchesAddress:host.activeAddress] ? @"Tailscale" : @"LAN", host.activeAddress];
    }

    NSMutableArray* connection = [NSMutableArray array];
    if (tailscale) {
        [connection addObject:@{@"title": ML(@"Route"), @"menu": @YES}];
    }
    [connection addObject:@{@"title": ML(@"Local IP address"), @"detail": host.localAddress ?: @"—",
                            @"action": ^{ [weakSelf editLocalAddress]; }}];
    [connection addObject:@{@"title": @"Tailscale", @"detail": tailscale ? host.address : ML(@"Not used")}];
    [connection addObject:@{@"title": ML(@"External IP address"), @"detail": host.externalAddress ?: @"—"}];
    [connection addObject:@{@"title": ML(@"MAC address"), @"detail": host.mac ?: @"—"}];

    NSMutableArray* actions = [NSMutableArray arrayWithArray:@[
        @{@"title": ML(@"Connect"), @"symbol": @"play.fill", @"action": ^{ [weakSelf closeThen:^{ [weakSelf.owner connectToHost:weakSelf.host view:nil]; }]; }},
        @{@"title": ML(@"Wake PC"), @"symbol": @"power", @"action": ^{ [weakSelf.owner wakeHost:weakSelf.host]; }},
    ]];
    [actions addObject:@{@"title": ML(@"Test Network"), @"symbol": @"network", @"action": ^{ [weakSelf.owner testNetwork]; }}];

    _sections = @[
        @{@"title": ML(@"Status"), @"rows": @[
            @{@"title": ML(@"Status"), @"detail": state},
            @{@"title": ML(@"Pairing"), @"detail": host.pairState == PairStatePaired ? ML(@"Paired") : ML(@"Not paired")},
            @{@"title": ML(@"Current route"), @"detail": route},
        ]},
        @{@"title": ML(@"Connection"), @"footer": tailscale ? ML(@"Automatic uses the local network when the PC answers there, and Tailscale otherwise.") : @"", @"rows": connection},
        @{@"title": @"", @"rows": actions},
        @{@"title": @"", @"rows": @[@{@"title": ML(@"Remove Host"), @"symbol": @"trash", @"destructive": @YES,
                                      @"action": ^{ [weakSelf.owner confirmRemoveHost:weakSelf.host view:weakSelf.view]; }}]},
    ];
    [self.tableView reloadData];
}

- (void)editLocalAddress {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:ML(@"Local IP address") message:ML(@"The PC's address on your home network, for example 192.168.1.10.") preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.text = self.host.localAddress;
        field.placeholder = @"192.168.1.10";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:ML(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ML(@"Save") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        NSString* value = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        self.host.localAddress = value.length ? value : nil;
        [[[DataManager alloc] init] updateHost:self.host];
        [self rebuild];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return _sections.count;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return [_sections[section][@"rows"] count];
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    NSString* title = _sections[section][@"title"];
    return title.length ? title : nil;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    NSString* footer = _sections[section][@"footer"];
    return footer.length ? footer : nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* row = _sections[indexPath.section][@"rows"][indexPath.row];
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"detail"];
    cell.detailTextLabel.numberOfLines = 2;
    if ([row[@"menu"] boolValue]) {
        // Pull-down menu next to the row, like other iOS settings
        NSInteger current = [EmbeddedTailscale routePreferenceForHost:self.host];
        NSMutableArray* choices = [NSMutableArray array];
        for (NSInteger preference = 0; preference < 3; preference++) {
            UIAction* choice = [UIAction actionWithTitle:[self routeName:preference] image:nil identifier:nil handler:^(__kindof UIAction* action) {
                [EmbeddedTailscale setRoutePreference:preference forHost:self.host];
                [self rebuild];
            }];
            choice.state = preference == current ? UIMenuElementStateOn : UIMenuElementStateOff;
            [choices addObject:choice];
        }
        UIButtonConfiguration* config = [UIButtonConfiguration plainButtonConfiguration];
        config.title = [self routeName:current];
        config.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"];
        config.imagePlacement = NSDirectionalRectEdgeTrailing;
        config.imagePadding = 4;
        config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
        config.baseForegroundColor = UIColor.secondaryLabelColor;
        config.contentInsets = NSDirectionalEdgeInsetsZero;
        UIButton* button = [UIButton buttonWithConfiguration:config primaryAction:nil];
        button.menu = [UIMenu menuWithChildren:choices];
        button.showsMenuAsPrimaryAction = YES;
        [button sizeToFit];
        cell.accessoryView = button;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    BOOL actionable = row[@"action"] != nil;
    BOOL destructive = [row[@"destructive"] boolValue];
    if (row[@"symbol"] != nil) {
        cell.imageView.image = [UIImage systemImageNamed:row[@"symbol"]];
        cell.imageView.tintColor = destructive ? UIColor.systemRedColor : self.view.tintColor;
        cell.textLabel.textColor = destructive ? UIColor.systemRedColor : self.view.tintColor;
    }
    else if (actionable) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.selectionStyle = actionable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    void (^action)(void) = _sections[indexPath.section][@"rows"][indexPath.row][@"action"];
    if (action) {
        action();
    }
}

@end
#endif

@implementation MainFrameViewController {
    NSOperationQueue* _opQueue;
    TemporaryHost* _selectedHost;
    BOOL _showHiddenApps;
    NSString* _uniqueId;
    NSData* _clientCert;
    DiscoveryManager* _discMan;
    AppAssetManager* _appManager;
    StreamConfiguration* _streamConfig;
    UIAlertController* _pairAlert;
    LoadingFrameViewController* _loadingFrame;
    UIScrollView* hostScrollView;
    FrontViewPosition currentPosition;
    NSArray* _sortedAppList;
    NSCache* _boxArtCache;
    bool _background;
#if TARGET_OS_TV
    UITapGestureRecognizer* _menuRecognizer;
#else
    // Tapping a PC on Home streams right away; afterwards Home shows the PCs again
    TemporaryHost* _directLaunchHost;
    // Tells the Tailscale sheet whether pairing the PC it chose succeeded
    void (^_pairingFinished)(BOOL paired);
    // Wi-Fi / cellular changes: recheck every PC right away so Home shows the
    // route (LAN or Tailscale) that works now
    nw_path_monitor_t _pathMonitor;
    NSString* _networkKind;
    BOOL _returnToListAfterStream;
    UIBarButtonItem* _addButton;
    // Settings or Tailscale screen shown in place of Home while its tab is selected
    UIViewController* _tabContent;
    NSString* _hostSignature;
    NSTimer* _hostRefreshTimer;
    UINavigationController* _settingsNavigation;
    SettingsViewController* _settingsController;
#endif
    CGSize _hostLayoutSize;
    // Open the only saved PC once discovery confirms it is reachable, instead
    // of blocking launch with a spinner.
    BOOL _autoOpenPending;
}
static NSMutableSet* hostList;

- (void)startPairing:(NSString *)PIN {
    // Needs to be synchronous to ensure the alert is shown before any potential
    // failure callback could be invoked.
    dispatch_sync(dispatch_get_main_queue(), ^{
        self->_pairAlert = [UIAlertController alertControllerWithTitle:ML(@"Pairing")
                                                               message:[NSString stringWithFormat:ML(@"Enter the following PIN on the host machine: %@\n\nIf your host PC is running Sunshine, navigate to the Sunshine web UI to enter the PIN."), PIN]
                                                        preferredStyle:UIAlertControllerStyleAlert];
        [self->_pairAlert addAction:[UIAlertAction actionWithTitle:ML(@"Cancel") style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
            self->_pairAlert = nil;
            [self->_discMan startDiscovery];
            [self hideLoadingFrame: ^{
                [self showHostSelectionView];
            }];
        }]];
        [[self activeViewController] presentViewController:self->_pairAlert animated:YES completion:nil];
    });
}

- (void)displayPairingFailureDialog:(NSString *)message {
    UIAlertController* failedDialog = [UIAlertController alertControllerWithTitle:ML(@"Pairing Failed")
                                                                          message:message
                                                                   preferredStyle:UIAlertControllerStyleAlert];
    [Utils addHelpOptionToDialog:failedDialog];
    [failedDialog addAction:[UIAlertAction actionWithTitle:ML(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    
    [_discMan startDiscovery];
    
    [self hideLoadingFrame: ^{
        [self showHostSelectionView];
        [[self activeViewController] presentViewController:failedDialog animated:YES completion:nil];
    }];
}

- (void)pairFailed:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_pairAlert != nil) {
            [self->_pairAlert dismissViewControllerAnimated:YES completion:^{
                [self displayPairingFailureDialog:message];
            }];
            self->_pairAlert = nil;
        }
    });
}

- (void)pairSuccessful:(NSData*)serverCert {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Store the cert from pairing with the host
        self->_selectedHost.serverCert = serverCert;
        
        [self->_pairAlert dismissViewControllerAnimated:YES completion:nil];
        self->_pairAlert = nil;
        
        [self->_discMan startDiscovery];
        [self alreadyPaired];
    });
}

// PC list: "+" to add a PC at the top right.
- (void)disableUpButton {
#if !TARGET_OS_TV
    self.navigationItem.leftBarButtonItem = nil;
    self.navigationItem.rightBarButtonItem = _addButton;
#endif
}

// The app grid is not shown on iOS, so the PC list keeps its "+".
- (void)enableUpButton {
}

- (void)updateTitle {
#if !TARGET_OS_TV
    // Home only shows PCs (no per-PC app screen), so never show a PC's name
    if (NO) {
#else
    if (_selectedHost != nil) {
#endif
        self.title = _selectedHost.name;
    }
    else if ([hostList count] == 0) {
        self.title = ML(@"Searching for PCs on your network...");
    }
    else {
        self.title = ML(@"Select Host");
    }
}

- (void)alreadyPaired {
    [self reportPairing:YES];
    BOOL usingCachedAppList = false;
    
    // Capture the host here because it can change once we
    // leave the main thread
    TemporaryHost* host = _selectedHost;
    if (host == nil) {
        [self hideLoadingFrame: nil];
        return;
    }
    
    if ([host.appList count] > 0) {
        usingCachedAppList = true;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (host != self->_selectedHost) {
                [self hideLoadingFrame: nil];
                return;
            }
            
            [self updateAppsForHost:host];
            [self hideLoadingFrame: nil];
        });
    }
    Log(LOG_I, @"Using cached app list: %d", usingCachedAppList);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Exempt this host from discovery while handling the applist query
        [self->_discMan pauseDiscoveryForHost:host];
        
        AppListResponse* appListResp = [ConnectionHelper getAppListForHost:host];
        
        [self->_discMan resumeDiscoveryForHost:host];

        if (![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            Log(LOG_W, @"Failed to get applist: %@", appListResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (host != self->_selectedHost) {
                    [self hideLoadingFrame: nil];
                    return;
                }
                
                UIAlertController* applistAlert = [UIAlertController alertControllerWithTitle:ML(@"Connection Interrupted")
                                                                                      message:appListResp.statusMessage
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                [Utils addHelpOptionToDialog:applistAlert];
                [applistAlert addAction:[UIAlertAction actionWithTitle:ML(@"OK") style:UIAlertActionStyleDefault handler:nil]];
                [self hideLoadingFrame: ^{
                    [self showHostSelectionView];
                    [[self activeViewController] presentViewController:applistAlert animated:YES completion:nil];
                }];
                host.state = StateOffline;
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateApplist:[appListResp getAppList] forHost:host];

                if (host != self->_selectedHost) {
                    [self hideLoadingFrame: nil];
                    return;
                }
                
                [self updateAppsForHost:host];
                [self->_appManager stopRetrieving];
                [self->_appManager retrieveAssetsFromHost:host];
                [self hideLoadingFrame: nil];
            });
        }
    });
}

- (void) updateAppEntry:(TemporaryApp*)app forHost:(TemporaryHost*)host {
    DataManager* database = [[DataManager alloc] init];
    NSMutableSet* newHostAppList = [NSMutableSet setWithSet:host.appList];

    for (TemporaryApp* savedApp in newHostAppList) {
        if ([app.id isEqualToString:savedApp.id]) {
            savedApp.name = app.name;
            savedApp.hdrSupported = app.hdrSupported;
            savedApp.hidden = app.hidden;
            
            host.appList = newHostAppList;

            [database updateAppsForExistingHost:host];
            return;
        }
    }
}
    
- (void) updateApplist:(NSSet*) newList forHost:(TemporaryHost*)host {
    DataManager* database = [[DataManager alloc] init];
    NSMutableSet* newHostAppList = [NSMutableSet setWithSet:host.appList];
    
    for (TemporaryApp* app in newList) {
        BOOL appAlreadyInList = NO;
        for (TemporaryApp* savedApp in newHostAppList) {
            if ([app.id isEqualToString:savedApp.id]) {
                savedApp.name = app.name;
                savedApp.hdrSupported = app.hdrSupported;
                // Don't propagate hidden, because we want the local data to prevail
                appAlreadyInList = YES;
                break;
            }
        }
        if (!appAlreadyInList) {
            app.host = host;
            [newHostAppList addObject:app];
        }
    }
    
    BOOL appWasRemoved;
    do {
        appWasRemoved = NO;
        
        for (TemporaryApp* app in newHostAppList) {
            appWasRemoved = YES;
            for (TemporaryApp* mergedApp in newList) {
                if ([mergedApp.id isEqualToString:app.id]) {
                    appWasRemoved = NO;
                    break;
                }
            }
            if (appWasRemoved) {
                // Removing the app mutates the list we're iterating (which isn't legal).
                // We need to jump out of this loop and restart enumeration.
                
                [newHostAppList removeObject:app];
                
                // It's important to remove the app record from the database
                // since we'll have a constraint violation now that appList
                // doesn't have this app in it.
                [database removeApp:app];
                
                break;
            }
        }
        
        // Keep looping until the list is no longer being mutated
    } while (appWasRemoved);
    
    host.appList = newHostAppList;

    [database updateAppsForExistingHost:host];
    
    // This host may be eligible for a shortcut now that the app list
    // has been populated
    [self updateHostShortcuts];
}

- (void)showHostSelectionView {
#if TARGET_OS_TV
    // Remove the menu button intercept to allow the app to exit
    // when at the host selection view.
    [self.navigationController.view removeGestureRecognizer:_menuRecognizer];
#endif
    
    [self reportPairing:NO];
    [_appManager stopRetrieving];
    _showHiddenApps = NO;
    _selectedHost = nil;
    _sortedAppList = nil;
    
    [self updateTitle];
    [self disableUpButton];
    
    [self.collectionView reloadData];
    [self.view addSubview:hostScrollView];
}

- (void) receivedAssetForApp:(TemporaryApp*)app {
    // Update the box art cache now so we don't have to do it
    // on the main thread
    [self updateBoxArtCacheForApp:app];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
    });
}

- (void)displayDnsFailedDialog {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:ML(@"Network Error")
                                                                   message:ML(@"Failed to resolve host.")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [Utils addHelpOptionToDialog:alert];
    [alert addAction:[UIAlertAction actionWithTitle:ML(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [[self activeViewController] presentViewController:alert animated:YES completion:nil];
}

- (void) hostClicked:(TemporaryHost *)host view:(UIView *)view {
    // Treat clicks on offline hosts to be long clicks
    // This shows the context menu with wake, delete, etc. rather
    // than just hanging for a while and failing as we would in this
    // code path.
    if (host.state == StateOffline && view != nil) {
        [self reportPairing:NO];
        [self hostLongClicked:host view:view];
        return;
    }
    
    Log(LOG_D, @"Clicked host: %@", host.name);
    _selectedHost = host;
    [self updateTitle];
    [self enableUpButton];
    [self disableNavigation];
    
#if TARGET_OS_TV
    // Intercept the menu key to go back to the host page
    [self.navigationController.view addGestureRecognizer:_menuRecognizer];
#endif
    
    // If we are online, paired, and have a cached app list, skip straight
    // to the app grid without a loading frame. This is the fast path that users
    // should hit most. Check for a valid view because we don't want to hit the fast
    // path after coming back from streaming, since we need to fetch serverinfo too
    // so that our active game data is correct.
    if (host.state == StateOnline && host.pairState == PairStatePaired && host.appList.count > 0 && view != nil) {
        [self alreadyPaired];
        return;
    }
    
    // Only explicit taps show the blocking progress screen; background refreshes
    // update the home screen quietly.
    [self showLoadingFrameWithMessage:(view != nil ? [NSString stringWithFormat:ML(@"Connecting to %@…"), host.name] : nil) completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Wait for the PC's status to be known
            while (host.state == StateUnknown) {
                sleep(1);
            }
            
            // Don't bother polling if the server is already offline
            if (host.state == StateOffline) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self hideLoadingFrame:^{
                        [self showHostSelectionView];
                    }];
                });
                return;
            }
            
            HttpManager* hMan = [[HttpManager alloc] initWithHost:host];
            ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
            
            // Exempt this host from discovery while handling the serverinfo request
            [self->_discMan pauseDiscoveryForHost:host];
            [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                                fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
            [self->_discMan resumeDiscoveryForHost:host];
            
            if (![serverInfoResp isStatusOk]) {
                Log(LOG_W, @"Failed to get server info: %@", serverInfoResp.statusMessage);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (host != self->_selectedHost) {
                        [self hideLoadingFrame:nil];
                        return;
                    }
                    
                    UIAlertController* applistAlert = [UIAlertController alertControllerWithTitle:ML(@"Connection Failed")
                                                                            message:serverInfoResp.statusMessage
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [Utils addHelpOptionToDialog:applistAlert];
                    [applistAlert addAction:[UIAlertAction actionWithTitle:ML(@"OK") style:UIAlertActionStyleDefault handler:nil]];
                    
                    // Only display an alert if this was the result of a real
                    // user action, not just passively entering the foreground again
                    [self hideLoadingFrame: ^{
                        [self showHostSelectionView];
                        if (view != nil) {
                            [[self activeViewController] presentViewController:applistAlert animated:YES completion:nil];
                        }
                    }];
                    
                    host.state = StateOffline;
                });
            } else {
                // Update the host object with this data
                [serverInfoResp populateHost:host];
                if (host.pairState == PairStatePaired) {
                    Log(LOG_I, @"Already Paired");
                    [self alreadyPaired];
                }
                // Only pair when this was the result of explicit user action
                else if (view != nil) {
                    Log(LOG_I, @"Trying to pair");
                    // Polling the server while pairing causes the server to screw up
                    [self->_discMan stopDiscoveryBlocking];
                    PairManager* pMan = [[PairManager alloc] initWithManager:hMan clientCert:self->_clientCert callback:self];
                    [self->_opQueue addOperation:pMan];
                }
                else {
                    // Not user action, so just return to host screen
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self hideLoadingFrame:^{
                            [self showHostSelectionView];
                        }];
                    });
                }
            }
        });
    }];
}

- (UIViewController*) activeViewController {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;

    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }

    return topController;
}

#if !TARGET_OS_TV
- (void) connectToHost:(TemporaryHost*)host view:(UIView*)view {
    if (host.state == StateOffline) {
        // Nothing to connect to: offer waking the PC and the other actions
        [self hostLongClicked:host view:view];
        return;
    }
    _directLaunchHost = host;
    _showHiddenApps = NO;
    [self hostClicked:host view:view ?: self.view];
}

- (void) showSettingsForHost:(TemporaryHost*)host {
    HostSettingsViewController* settings = [[HostSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    settings.host = host;
    settings.owner = self;
    UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:settings];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [[self activeViewController] presentViewController:navigation animated:YES completion:nil];
}
#endif

- (void) wakeHost:(TemporaryHost*)host {
    UIAlertController* wolAlert = [UIAlertController alertControllerWithTitle:ML(@"Wake-On-LAN") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [wolAlert addAction:[UIAlertAction actionWithTitle:ML(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    if (host.mac == nil || [host.mac isEqualToString:@"00:00:00:00:00:00"]) {
        wolAlert.message = ML(@"Host MAC unknown, unable to send WOL Packet");
    } else {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [WakeOnLanManager wakeHost:host];
        });
        wolAlert.message = ML(@"Successfully sent wake-up request. It may take a few moments for the PC to wake. If it never wakes up, ensure it's properly configured for Wake-on-LAN.");
    }
    [[self activeViewController] presentViewController:wolAlert animated:YES completion:nil];
}

- (void) testNetwork {
    [self showLoadingFrameWithMessage:ML(@"Testing your network…") completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Perform the network test on a GCD worker thread. It may take a while.
            unsigned int portTestResult = LiTestClientConnectivity(CONN_TEST_SERVER, 443, ML_PORT_FLAG_ALL);
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self hideLoadingFrame:^{
                    NSString* message;

                    if (portTestResult == 0) {
                        message = ML(@"This network does not appear to be blocking Moonlight. If you still have trouble connecting, check your PC's firewall settings.\n\nVisit the Moonlight Setup Guide on GitHub for additional setup help and troubleshooting steps.");
                    }
                    else if (portTestResult == ML_TEST_RESULT_INCONCLUSIVE) {
                        message = ML(@"The network test could not be performed because none of Moonlight's connection testing servers were reachable. Check your Internet connection or try again later.");
                    }
                    else {
                        char blockedPorts[512];
                        LiStringifyPortFlags(portTestResult, "\n", blockedPorts, sizeof(blockedPorts));
                        message = [NSString stringWithFormat:ML(@"Your current network connection seems to be blocking Moonlight. Streaming may not work while connected to this network.\n\nThe following network ports were blocked:\n%s"), blockedPorts];
                    }

                    UIAlertController* netTestAlert = [UIAlertController alertControllerWithTitle:ML(@"Network Test Complete") message:message preferredStyle:UIAlertControllerStyleAlert];
                    [netTestAlert addAction:[UIAlertAction actionWithTitle:ML(@"OK") style:UIAlertActionStyleDefault handler:nil]];
                    [[self activeViewController] presentViewController:netTestAlert animated:YES completion:nil];
                }];
            });
        });
    }];
}

- (void) confirmRemoveHost:(TemporaryHost*)host view:(UIView*)view {
    UIAlertController* confirm = [UIAlertController alertControllerWithTitle:host.name message:ML(@"Remove this PC from Moonlight? You will need to pair again to use it.") preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:ML(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:ML(@"Remove Host") style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        [self->_discMan removeHostFromDiscovery:host];
        DataManager* dataMan = [[DataManager alloc] init];
        [dataMan removeHost:host];
        @synchronized(hostList) {
            [hostList removeObject:host];
            [self updateAllHosts:[hostList allObjects]];
        }
        if (self.presentedViewController != nil) {
            [self dismissViewControllerAnimated:YES completion:nil];
        }
    }]];
    [[self activeViewController] presentViewController:confirm animated:YES completion:nil];
}

// Long press on a PC: every action in one menu
- (void)hostLongClicked:(TemporaryHost *)host view:(UIView *)view {
    Log(LOG_D, @"Long clicked host: %@", host.name);
    NSString* message;
    switch (host.state) {
        case StateOffline:
            message = ML(@"Offline");
            break;
        case StateOnline:
            message = host.pairState == PairStatePaired ? ML(@"Online - Paired") : ML(@"Online - Not Paired");
            break;
        default:
            message = ML(@"Connecting");
            break;
    }

    UIAlertController* menu = [UIAlertController alertControllerWithTitle:host.name message:message preferredStyle:UIAlertControllerStyleActionSheet];
#if !TARGET_OS_TV
    if (host.state != StateOffline) {
        [menu addAction:[UIAlertAction actionWithTitle:ML(@"Connect") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [self connectToHost:host view:view];
        }]];
    }
#endif
    [menu addAction:[UIAlertAction actionWithTitle:ML(@"Wake PC") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self wakeHost:host];
    }]];
#if !TARGET_OS_TV
    [menu addAction:[UIAlertAction actionWithTitle:ML(@"PC Settings") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self showSettingsForHost:host];
    }]];
    if ([EmbeddedTailscale matchesAddress:host.address]) {
        // "Test Network" only checks the internet; this checks the tailnet path and Sunshine
        [menu addAction:[UIAlertAction actionWithTitle:ML(@"Tailscale Connection Test") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [self showTailscaleSetup];
        }]];
    }
#endif
    [menu addAction:[UIAlertAction actionWithTitle:ML(@"Test Network") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self testNetwork];
    }]];
#if !TARGET_OS_TV
    if (host.state != StateOnline) {
        [menu addAction:[UIAlertAction actionWithTitle:ML(@"Connection Help") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [Utils launchUrl:@"https://github.com/moonlight-stream/moonlight-docs/wiki/Troubleshooting"];
        }]];
    }
#endif
    [menu addAction:[UIAlertAction actionWithTitle:ML(@"Remove Host") style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        [self confirmRemoveHost:host view:view];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:ML(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    // these two lines are required for iPad support of UIAlertSheet
    menu.popoverPresentationController.sourceView = view ?: self.view;
    menu.popoverPresentationController.sourceRect = CGRectMake(view.bounds.size.width / 2.0, view.bounds.size.height / 2.0, 1.0, 1.0);
    [[self activeViewController] presentViewController:menu animated:YES completion:nil];
}

- (void) addHostClicked {
    Log(LOG_D, @"Clicked add host");
    UIAlertController* alertController = [UIAlertController alertControllerWithTitle:ML(@"Add by IP Address") message:ML(@"Enter the IP address of a PC on this network, for example 192.168.1.10. To connect from outside, add the PC with Tailscale instead.") preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:ML(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alertController addAction:[UIAlertAction actionWithTitle:ML(@"OK") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
        NSString* hostAddress = [((UITextField*)[[alertController textFields] objectAtIndex:0]).text trim];
        [self addHostWithAddress:hostAddress pair:NO];
    }]];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = @"192.168.1.10";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [[self activeViewController] presentViewController:alertController animated:YES completion:nil];
}

// Adds a PC by address. With pair set, the PC is opened right away so
// pairing starts without another tap.
- (void) addHostWithAddress:(NSString*)hostAddress pair:(BOOL)pair {
    [self addHostWithAddress:hostAddress pair:pair finished:nil];
}

- (void) addHostWithAddress:(NSString*)hostAddress pair:(BOOL)pair finished:(void (^)(BOOL paired))finished {
    _pairingFinished = finished;
    [self showLoadingFrameWithMessage:[NSString stringWithFormat:ML(@"Looking for the PC at %@…"), hostAddress] completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [self->_discMan discoverHost:hostAddress withCallback:^(TemporaryHost* host, NSString* error){
                if (host != nil) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self hideLoadingFrame:^{
                            @synchronized(hostList) {
                                [hostList addObject:host];
                            }
                            [self updateHosts];
                            if (pair) {
                                [self hostClicked:host view:self.view];
                            }
                        }];
                    });
                    return;
                }

                // An already known PC only had its address updated
                TemporaryHost* existingHost = nil;
                if (pair) {
                    @synchronized(hostList) {
                        for (TemporaryHost* known in hostList) {
                            if (known.address.length && [known.address caseInsensitiveCompare:hostAddress] == NSOrderedSame) {
                                existingHost = known;
                                break;
                            }
                        }
                    }
                }
                if (existingHost != nil) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self hideLoadingFrame:^{
                            [self updateHosts];
                            [self hostClicked:existingHost view:self.view];
                        }];
                    });
                    return;
                }

                unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443,
                                                                        ML_PORT_FLAG_TCP_47984 | ML_PORT_FLAG_TCP_47989);
                if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
                    error = [error stringByAppendingString:@"\n\nYour device's network connection is blocking Moonlight. Streaming may not work while connected to this network."];
                }

                [self reportPairing:NO];
                UIAlertController* hostNotFoundAlert = [UIAlertController alertControllerWithTitle:ML(@"Add Host Manually") message:error preferredStyle:UIAlertControllerStyleAlert];
                [Utils addHelpOptionToDialog:hostNotFoundAlert];
                [hostNotFoundAlert addAction:[UIAlertAction actionWithTitle:ML(@"OK") style:UIAlertActionStyleDefault handler:nil]];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self hideLoadingFrame:^{
                        [[self activeViewController] presentViewController:hostNotFoundAlert animated:YES completion:nil];
                    }];
                });
            }];
        });
    }];
}

#if !TARGET_OS_TV
// Choosing the PC to reach through Tailscale: a sheet over Home that stays
// open while pairing and closes once it succeeds
- (void) showTailscalePeerPicker {
    __weak typeof(self) weakSelf = self;
    [EmbeddedTailscale presentPickerFrom:[self activeViewController] onConnect:^(NSString *address, void (^finished)(BOOL paired)) {
        [weakSelf addHostWithAddress:address pair:YES finished:^(BOOL paired) {
            finished(paired);
            if (paired) {
                [weakSelf showHostSelectionView];
            }
        }];
    }];
}

- (void) startNetworkMonitor {
    _pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_pathMonitor, dispatch_get_main_queue());
    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        NSString* kind = nw_path_uses_interface_type(path, nw_interface_type_wifi) ? @"wifi" :
                         nw_path_uses_interface_type(path, nw_interface_type_cellular) ? @"cellular" :
                         nw_path_uses_interface_type(path, nw_interface_type_wired) ? @"wired" : @"none";
        [weakSelf networkChangedTo:kind];
    });
    nw_path_monitor_start(_pathMonitor);
}

- (void) networkChangedTo:(NSString*)kind {
    BOOL first = _networkKind == nil;
    BOOL changed = !first && ![_networkKind isEqualToString:kind];
    _networkKind = kind;
    BOOL local = [kind isEqualToString:@"wifi"] || [kind isEqualToString:@"wired"];
    if (first) {
        // Only record where we are; nothing to rebuild yet
        [EmbeddedTailscale setOnLocalNetwork:local];
    }
    else if (changed) {
        // Wi-Fi <-> cellular only. Path updates also fire for unrelated
        // details; rebuilding Tailscale then would disturb a running stream.
        [EmbeddedTailscale networkChanged:local];
    }
    if (!changed || _background) {
        return;
    }
    Log(LOG_I, @"Network changed to %@; checking PCs again", kind);
    @synchronized (hostList) {
        for (TemporaryHost* host in hostList) {
            host.state = StateUnknown;
        }
    }
    [_discMan stopDiscovery];
    [_discMan resetDiscoveryState];
    [_discMan startDiscovery];
    [self updateHosts];
}

- (void) reportPairing:(BOOL)paired {
    void (^finished)(BOOL) = _pairingFinished;
    _pairingFinished = nil;
    if (finished != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            finished(paired);
        });
    }
}

// Account and settings: the Tailscale tab
- (void) showTailscaleSetup {
    self.tabBarController.selectedIndex = 1;
}
#endif

- (void) performStreamSegue {
    // Streaming follows the current orientation, portrait included
    [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
}

- (void) prepareToStreamApp:(TemporaryApp *)app {
    _streamConfig = [[StreamConfiguration alloc] init];
    _streamConfig.host = app.host.activeAddress;
#if !TARGET_OS_TV
    _streamConfig.host = [EmbeddedTailscale connectionAddressForHost:app.host];
#endif
    _streamConfig.httpsPort = app.host.httpsPort;
    _streamConfig.appID = app.id;
    _streamConfig.appName = app.name;
    _streamConfig.serverCert = app.host.serverCert;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    _streamConfig.frameRate = [streamSettings.framerate intValue];
    if (@available(iOS 10.3, *)) {
        // Don't stream more FPS than the display can show
        if (_streamConfig.frameRate > [UIScreen mainScreen].maximumFramesPerSecond) {
            _streamConfig.frameRate = (int)[UIScreen mainScreen].maximumFramesPerSecond;
            Log(LOG_W, @"Clamping FPS to maximum refresh rate: %d", _streamConfig.frameRate);
        }
    }
    
    _streamConfig.height = [streamSettings.height intValue];
    _streamConfig.width = [streamSettings.width intValue];
#if TARGET_OS_TV
    // Don't allow streaming 4K on the Apple TV HD
    struct utsname systemInfo;
    uname(&systemInfo);
    if (strcmp(systemInfo.machine, "AppleTV5,3") == 0 && _streamConfig.height >= 2160) {
        Log(LOG_W, @"4K streaming not supported on Apple TV HD");
        _streamConfig.width = 1920;
        _streamConfig.height = 1080;
    }
#endif
    
    _streamConfig.bitRate = [streamSettings.bitrate intValue];
    _streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    _streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    _streamConfig.useFramePacing = streamSettings.useFramePacing;
    _streamConfig.swapABXYButtons = streamSettings.swapABXYButtons;
    
    // multiController must be set before calling getConnectedGamepadMask
    _streamConfig.multiController = streamSettings.multiController;
    _streamConfig.gamepadMask = [ControllerSupport getConnectedGamepadMask:_streamConfig];
    
    // Probe for supported channel configurations
    int physicalOutputChannels = (int)[AVAudioSession sharedInstance].maximumOutputNumberOfChannels;
    Log(LOG_I, @"Audio device supports %d channels", physicalOutputChannels);
    
    int numberOfChannels = MIN([streamSettings.audioConfig intValue], physicalOutputChannels);
    Log(LOG_I, @"Selected number of audio channels %d", numberOfChannels);
    if (numberOfChannels >= 8) {
        _streamConfig.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
    }
    else if (numberOfChannels >= 6) {
        _streamConfig.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND;
    }
    else {
        _streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    }
    
    _streamConfig.serverCodecModeSupport = app.host.serverCodecModeSupport;
    
    switch (streamSettings.preferredCodec) {
        case CODEC_PREF_AV1:
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
                _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
            }
#endif
            // Fall-through
            
        case CODEC_PREF_AUTO:
        case CODEC_PREF_HEVC:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;
            }
            // Fall-through
            
        case CODEC_PREF_H264:
            _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H264;
            break;
    }
    
    // HEVC is supported if the user wants it (or it's required by the chosen resolution) and the SoC supports it
    if ((_streamConfig.width > 4096 || _streamConfig.height > 4096 || streamSettings.enableHdr) && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;
        
        // HEVC Main10 is supported if the user wants it and the display supports it
        if (streamSettings.enableHdr && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
            _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }
    
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
    // Add the AV1 Main10 format if AV1 and HDR are both enabled and supported
    if ((_streamConfig.supportedVideoFormats & VIDEO_FORMAT_MASK_AV1) && streamSettings.enableHdr &&
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
        _streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
    }
#endif
}

- (void)appLongClicked:(TemporaryApp *)app view:(UIView *)view {
    Log(LOG_D, @"Long clicked app: %@", app.name);
    
    [_appManager stopRetrieving];
    
#if !TARGET_OS_TV
    if (currentPosition != FrontViewPositionLeft) {
        // This must not be animated because we need the position
        // to change (and notify our callback to save settings data)
        // before we call prepareToStreamApp.
        [[self revealViewController] revealToggleAnimated:NO];
    }
#endif

    TemporaryApp* currentApp = [self findRunningApp:app.host];
    
    NSString* message;
    
    if (currentApp == nil || [app.id isEqualToString:currentApp.id]) {
        if (app.hidden) {
            message = ML(@"Hidden");
        }
        else {
            message = ML(@"");
        }
    }
    else {
        message = [NSString stringWithFormat:@"%@ is currently running", currentApp.name];
    }
    
    UIAlertController* alertController = [UIAlertController
                                          alertControllerWithTitle: app.name
                                          message:message
                                          preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alertController addAction:[UIAlertAction
                                actionWithTitle:currentApp == nil ? @"Launch App" : ([app.id isEqualToString:currentApp.id] ? ML(@"Resume App") : ML(@"Resume Running App")) style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
        if (currentApp != nil) {
            Log(LOG_I, @"Resuming application: %@", currentApp.name);
            [self prepareToStreamApp:currentApp];
        }
        else {
            Log(LOG_I, @"Launching application: %@", app.name);
            [self prepareToStreamApp:app];
        }

        [self performStreamSegue];
    }]];
    
    if (currentApp != nil) {
        [alertController addAction:[UIAlertAction actionWithTitle:
                                    [app.id isEqualToString:currentApp.id] ? ML(@"Quit App") : ML(@"Quit Running App and Start") style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action){
                                        Log(LOG_I, @"Quitting application: %@", currentApp.name);
                                        [self showLoadingFrameWithMessage:[NSString stringWithFormat:ML(@"Quitting %@…"), currentApp.name] completion:^{
                                            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                                HttpManager* hMan = [[HttpManager alloc] initWithHost:app.host];
                                                HttpResponse* quitResponse = [[HttpResponse alloc] init];
                                                HttpRequest* quitRequest = [HttpRequest requestForResponse: quitResponse withUrlRequest:[hMan newQuitAppRequest]];
                                                
                                                // Exempt this host from discovery while handling the quit operation
                                                [self->_discMan pauseDiscoveryForHost:app.host];
                                                [hMan executeRequestSynchronously:quitRequest];
                                                if (quitResponse.statusCode == 200) {
                                                    ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
                                                    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                                                                        fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
                                                    if (![serverInfoResp isStatusOk] || [[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"]) {
                                                        // On newer GFE versions, the quit request succeeds even though the app doesn't
                                                        // really quit if another client tries to kill your app. We'll patch the response
                                                        // to look like the old error in that case, so the UI behaves.
                                                        quitResponse.statusCode = 599;
                                                    }
                                                    else if ([serverInfoResp isStatusOk]) {
                                                        // Update the host object with this info
                                                        [serverInfoResp populateHost:app.host];
                                                    }
                                                }
                                                [self->_discMan resumeDiscoveryForHost:app.host];

                                                // If it fails, display an error and stop the current operation
                                                if (quitResponse.statusCode != 200) {
                                                    UIAlertController* alert = [UIAlertController alertControllerWithTitle:ML(@"Quitting App Failed")
                                                                                                message:ML(@"Failed to quit app. If this app was started by "
                                                             "another device, you'll need to quit from that device.")
                                                                                         preferredStyle:UIAlertControllerStyleAlert];
                                                    [alert addAction:[UIAlertAction actionWithTitle:ML(@"OK") style:UIAlertActionStyleDefault handler:nil]];
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        [self updateAppsForHost:app.host];
                                                        [self hideLoadingFrame: ^{
                                                            [[self activeViewController] presentViewController:alert animated:YES completion:nil];
                                                        }];
                                                    });
                                                }
                                                else {
                                                    app.host.currentGame = @"0";
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        // If it succeeds and we're to start streaming, segue to the stream
                                                        if (![app.id isEqualToString:currentApp.id]) {
                                                            [self prepareToStreamApp:app];
                                                            [self hideLoadingFrame: ^{
                                                                [self performStreamSegue];
                                                            }];
                                                        }
                                                        else {
                                                            // Otherwise, just hide the loading icon
                                                            [self hideLoadingFrame:nil];
                                                        }
                                                    });
                                                }
                                            });
                                        }];
                                        
                                    }]];
    }

    if (currentApp == nil || ![app.id isEqualToString:currentApp.id] || app.hidden) {
        [alertController addAction:[UIAlertAction actionWithTitle:app.hidden ? @"Show App" : @"Hide App"
                                                            style:app.hidden ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive
                                                          handler:^(UIAlertAction* action) {
            app.hidden = !app.hidden;
            [self updateAppEntry:app forHost:app.host];
            
            // Don't call updateAppsForHost because that will nuke this
            // app immediately if we're not showing hidden apps.
        }]];
    }
    
    [alertController addAction:[UIAlertAction actionWithTitle:ML(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    // these two lines are required for iPad support of UIAlertSheet
    alertController.popoverPresentationController.sourceView = view;
    
    alertController.popoverPresentationController.sourceRect = CGRectMake(view.bounds.size.width / 2.0, view.bounds.size.height / 2.0, 1.0, 1.0); // center of the view
    [[self activeViewController] presentViewController:alertController animated:YES completion:nil];
}

- (void) appClicked:(TemporaryApp *)app view:(UIView *)view {
    Log(LOG_D, @"Clicked app: %@", app.name);
    
    [_appManager stopRetrieving];
    
#if !TARGET_OS_TV
    if (currentPosition != FrontViewPositionLeft) {
        // This must not be animated because we need the position
        // to change (and notify our callback to save settings data)
        // before we call prepareToStreamApp.
        [[self revealViewController] revealToggleAnimated:NO];
    }
#endif
    
    if ([self findRunningApp:app.host]) {
        // If there's a running app, display a menu
        [self appLongClicked:app view:view];
    } else {
        [self prepareToStreamApp:app];
        [self performStreamSegue];
    }
}

- (TemporaryApp*) findRunningApp:(TemporaryHost*)host {
    for (TemporaryApp* app in host.appList) {
        if ([app.id isEqualToString:host.currentGame]) {
            return app;
        }
    }
    return nil;
}

#if !TARGET_OS_TV
- (void)revealController:(SWRevealViewController *)revealController didMoveToPosition:(FrontViewPosition)position {
    // If we moved back to the center position, we should save the settings
    if (position == FrontViewPositionLeft) {
        [(SettingsViewController*)[revealController rearViewController] saveSettings];
    }
    
    currentPosition = position;
}
#endif

#if TARGET_OS_TV
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [self appClicked:_sortedAppList[indexPath.row] view:nil];
}
#endif

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.destinationViewController isKindOfClass:[StreamFrameViewController class]]) {
        StreamFrameViewController* streamFrame = segue.destinationViewController;
        streamFrame.streamConfig = _streamConfig;
        // The stream uses the whole screen, without the tab bar
        streamFrame.hidesBottomBarWhenPushed = YES;
    }
}

- (void) showLoadingFrame:(void (^)(void))completion {
    [self showLoadingFrameWithMessage:ML(@"Please wait…") completion:completion];
}

// A nil message runs the work without the blocking progress screen.
- (void) showLoadingFrameWithMessage:(NSString*)message completion:(void (^)(void))completion {
    if (message == nil) {
        if (completion) {
            completion();
        }
        return;
    }
    _loadingFrame.message = message;
    [_loadingFrame showLoadingFrame:completion];
}

- (void) hideLoadingFrame:(void (^)(void))completion {
    [self enableNavigation];
    [_loadingFrame dismissLoadingFrame:completion];
}

- (void)adjustScrollViewForSafeArea:(UIScrollView*)view {
    if (@available(iOS 11.0, *)) {
        if (self.view.safeAreaInsets.left >= 20 || self.view.safeAreaInsets.right >= 20) {
            view.contentInset = UIEdgeInsetsMake(0, 20, 0, 20);
        }
        else {
            // Rotated back to portrait
            view.contentInset = UIEdgeInsetsZero;
        }
    }
}

// The host list is a manually laid out subview of the collection view, so
// it has to follow rotation explicitly. It fills the visible area below the
// navigation bar and the computers are centered vertically in it.
- (void)layoutHostScrollView {
    CGSize size = self.view.bounds.size;
    if (CGSizeEqualToSize(size, _hostLayoutSize)) {
        return;
    }
    _hostLayoutSize = size;

    UIEdgeInsets insets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        insets = self.collectionView.adjustedContentInset;
    }
    CGFloat visibleHeight = MAX(size.height - insets.top - insets.bottom, 200);
    hostScrollView.frame = CGRectMake(0, 0, size.width, visibleHeight);
#if !TARGET_OS_TV
    // Scrolls on its own inside the (empty) app collection view
    hostScrollView.contentInset = UIEdgeInsetsZero;
#endif
    [self updateHosts];
}

#if !TARGET_OS_TV
// Long titles such as "Searching for PCs on your network..." shrink to fit
// between the bar buttons in portrait instead of being cut off.
- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    UILabel* label = (UILabel*)self.navigationItem.titleView;
    if (![label isKindOfClass:[UILabel class]]) {
        label = [[UILabel alloc] init];
        label.font = [UIFont boldSystemFontOfSize:17];
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.6;
        [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        self.navigationItem.titleView = label;
    }
    label.text = title;
    [label sizeToFit];
}

// Settings open as a sheet from the bottom instead of the side drawer.
- (void)showSettings {
    self.tabBarController.selectedIndex = 2;
}

- (void)showHomeTab {
    self.tabBarController.selectedIndex = 0;
}
#endif

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutHostScrollView];
}

#if !TARGET_OS_TV
#endif

// Adjust the subviews for the safe area on the iPhone X.
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    
    [self adjustScrollViewForSafeArea:self.collectionView];
#if TARGET_OS_TV
    [self adjustScrollViewForSafeArea:self->hostScrollView];
#else
    // The host cards add the safe area themselves
    _hostLayoutSize = CGSizeZero;
    [self.view setNeedsLayout];
#endif
}

- (void)viewDidLoad
{
    [super viewDidLoad];
        
#if !TARGET_OS_TV
    // Dark interface everywhere, matching the stream and settings
    self.navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.collectionView.backgroundColor = UIColor.systemGroupedBackgroundColor;

    // Top bar: "+" opens the ways to add a PC
    __weak typeof(self) weakSelf = self;
    UIAction* addTailscale = [UIAction actionWithTitle:ML(@"Add with Tailscale") image:[EmbeddedTailscale logoImage] identifier:nil handler:^(__kindof UIAction* action) {
        [weakSelf showTailscalePeerPicker];
    }];
    addTailscale.subtitle = ML(@"Choose a PC from your tailnet. Works away from home.");
    UIAction* addAddress = [UIAction actionWithTitle:ML(@"Add by IP Address") image:[UIImage systemImageNamed:@"keyboard"] identifier:nil handler:^(__kindof UIAction* action) {
        [weakSelf addHostClicked];
    }];
    addAddress.subtitle = ML(@"For a PC on this network");
    UIAction* automatic = [UIAction actionWithTitle:ML(@"PCs on this Wi-Fi appear automatically") image:[UIImage systemImageNamed:@"wifi"] identifier:nil handler:^(__kindof UIAction* action) {}];
    automatic.attributes = UIMenuElementAttributesDisabled;
    UIMenu* addMenu = [UIMenu menuWithTitle:@"" children:@[addTailscale, addAddress,
                                                            [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[automatic]]]];
    _addButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] menu:addMenu];
    _addButton.accessibilityLabel = ML(@"Add PC");
    [self disableUpButton];
    
    // Settings no longer use the side drawer, so no reveal pan gesture
    
    // Get callbacks associated with the viewController
    [self.revealViewController setDelegate:self];
    
    // Disable bounce-back on reveal VC otherwise the settings will snap closed
    // if the user drags all the way off the screen opposite the settings pane.
    self.revealViewController.bounceBackOnOverdraw = NO;
#else
    // The settings button will direct the user into the Settings app on tvOS
    [_settingsButton setTarget:self];
    [_settingsButton setAction:@selector(openTvSettings:)];
    
    // Restore focus on the selected app on view controller pop navigation
    self.restoresFocusAfterTransition = NO;
    self.collectionView.remembersLastFocusedIndexPath = YES;
    
    _menuRecognizer = [[UITapGestureRecognizer alloc] init];
    [_menuRecognizer addTarget:self action: @selector(showHostSelectionView)];
    _menuRecognizer.allowedPressTypes = [[NSArray alloc] initWithObjects:[NSNumber numberWithLong:UIPressTypeMenu], nil];
    
    self.navigationController.navigationBar.titleTextAttributes = [NSDictionary dictionaryWithObject:[UIColor whiteColor] forKey:NSForegroundColorAttributeName];
#endif
    
    _loadingFrame = [self.storyboard instantiateViewControllerWithIdentifier:@"loadingFrame"];
    
    // Set the current position to the center
    currentPosition = FrontViewPositionLeft;
    
    // Set up crypto
    [CryptoManager generateKeyPairUsingSSL];
    _uniqueId = [IdManager getUniqueId];
    _clientCert = [CryptoManager readCertFromFile];

    _appManager = [[AppAssetManager alloc] initWithCallback:self];
    _opQueue = [[NSOperationQueue alloc] init];
    
    // Only initialize the host picker list once
    if (hostList == nil) {
        hostList = [[NSMutableSet alloc] init];
    }
    
    _boxArtCache = [[NSCache alloc] init];
        
    hostScrollView = [[ComputerScrollView alloc] init];
    hostScrollView.frame = CGRectMake(0, self.navigationController.navigationBar.frame.origin.y + self.navigationController.navigationBar.frame.size.height, self.view.frame.size.width, self.view.frame.size.height / 2);
    [hostScrollView setShowsHorizontalScrollIndicator:NO];
    hostScrollView.delaysContentTouches = NO;
    
    self.collectionView.delaysContentTouches = NO;
    self.collectionView.allowsMultipleSelection = NO;
#if !TARGET_OS_TV
    self.collectionView.multipleTouchEnabled = NO;
#else
    // This is the only way to get long press events on a UICollectionViewCell :(
    UILongPressGestureRecognizer* cellLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleCollectionViewLongPress:)];
    cellLongPress.delaysTouchesBegan = YES;
    [self.collectionView addGestureRecognizer:cellLongPress];
#endif
    
    [self retrieveSavedHosts];
    _discMan = [[DiscoveryManager alloc] initWithHosts:[hostList allObjects] andCallback:self];
        
    // Show the PC list right away. With a single saved PC, its apps open on
    // their own once discovery finds it online and paired.
    _autoOpenPending = NO;
#if !TARGET_OS_TV
    [self startNetworkMonitor];
#endif
    [self updateTitle];
    [self.view addSubview:hostScrollView];
}

#if TARGET_OS_TV
-(void)handleCollectionViewLongPress:(UILongPressGestureRecognizer *)gestureRecognizer
{
    // FIXME: Something is delaying touches so we only get to the Begin state
    // before we actually want to signal the long press.
    if (gestureRecognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    
    CGPoint point = [gestureRecognizer locationInView:self.collectionView];
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
    if (indexPath != nil) {
        [self appLongClicked:_sortedAppList[indexPath.row] view:nil];
    }
}

- (void)openTvSettings:(id)sender
{
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
}
#endif

-(void)beginForegroundRefresh
{
    if (!_background) {
        // This will kick off box art caching
        [self updateHosts];
        
        // Reset state first so we can rediscover hosts that were deleted before
        [_discMan resetDiscoveryState];
        [_discMan startDiscovery];
        
        // This will refresh the applist when a paired host is selected
        if (_selectedHost != nil && _selectedHost.pairState == PairStatePaired) {
            [self hostClicked:_selectedHost view:nil];
        }
    }
}

-(void)handlePendingShortcutAction
{
    // Check if we have a pending shortcut action
    AppDelegate* delegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
    if (delegate.pcUuidToLoad != nil) {
        // Find the host it corresponds to
        TemporaryHost* matchingHost = nil;
        for (TemporaryHost* host in hostList) {
            if ([host.uuid isEqualToString:delegate.pcUuidToLoad]) {
                matchingHost = host;
                break;
            }
        }
        
        // Clear the pending shortcut action
        delegate.pcUuidToLoad = nil;
        
        // Complete the request
        if (delegate.shortcutCompletionHandler != nil) {
            delegate.shortcutCompletionHandler(matchingHost != nil);
            delegate.shortcutCompletionHandler = nil;
        }
        
        if (matchingHost != nil && _selectedHost != matchingHost) {
            // Navigate to the host page
            [self hostClicked:matchingHost view:nil];
        }
    }
}

-(void)handleReturnToForeground
{
    _background = NO;
    
    [self beginForegroundRefresh];
    
    // Check for a pending shortcut action when returning to foreground
    [self handlePendingShortcutAction];
}

-(void)handleEnterBackground
{
    _background = YES;
    
    [_discMan stopDiscovery];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
    // The tab bar controller asks the visible screen about these
    [self.tabBarController setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self.tabBarController setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    [self.tabBarController setNeedsUpdateOfPrefersPointerLocked];

    [_hostRefreshTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _hostRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer* timer) {
        [weakSelf refreshHostCardsIfNeeded];
    }];


    // Home stays portrait; the stream controller enables rotation on entry.
    ((AppDelegate*)[UIApplication sharedApplication].delegate).orientationLock = UIInterfaceOrientationMaskPortrait;
#endif
    
    
#if !TARGET_OS_TV
    // System bar backgrounds (glass on iOS 26+) instead of the old gray bar
    UINavigationBar* navigationBar = self.navigationController.navigationBar;
    navigationBar.barTintColor = nil;
    navigationBar.backgroundColor = nil;
    navigationBar.translucent = YES;
    UINavigationBarAppearance* appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithDefaultBackground];
    UINavigationBarAppearance* edgeAppearance = [[UINavigationBarAppearance alloc] init];
    [edgeAppearance configureWithTransparentBackground];
    navigationBar.standardAppearance = appearance;
    navigationBar.compactAppearance = appearance;
    navigationBar.scrollEdgeAppearance = edgeAppearance;
    navigationBar.compactScrollEdgeAppearance = edgeAppearance;
#else
    // Hide 1px border line
    UIImage* fakeImage = [[UIImage alloc] init];
    [self.navigationController.navigationBar setShadowImage:fakeImage];
    [self.navigationController.navigationBar setBackgroundImage:fakeImage forBarPosition:UIBarPositionAny barMetrics:UIBarMetricsDefault];
#endif
    
    // Check for a pending shortcut action when appearing
    [self handlePendingShortcutAction];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleReturnToForeground)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleEnterBackground)
                                                 name: UIApplicationWillResignActiveNotification
                                               object: nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // Show the bar together with the transition back from a stream
    [self.navigationController setNavigationBarHidden:NO animated:animated];
#if !TARGET_OS_TV
    AppDelegate *appDelegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
    appDelegate.orientationLock = UIInterfaceOrientationMaskPortrait;
    [appDelegate rotateToOrientations:UIInterfaceOrientationMaskPortrait];
    [self.navigationController setToolbarHidden:YES animated:NO];

    // Back from a stream: show the PC list. This must happen before the
    // foreground refresh, which would otherwise reload the PC's apps.
    if (_returnToListAfterStream || _selectedHost != nil) {
        _returnToListAfterStream = NO;
        [self showHostSelectionView];
    }
#endif
    
    // We can get here on home press while streaming
    // since the stream view segues to us just before
    // entering the background. We can't check the app
    // state here (since it's in transition), so we have
    // to use this function that will use our internal
    // state here to determine whether we're foreground.
    //
    // Note that this is neccessary here as we may enter
    // this view via an error dialog from the stream
    // view, so we won't get a return to active notification
    // for that which would normally fire beginForegroundRefresh.
    [self beginForegroundRefresh];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
#if !TARGET_OS_TV
    [_hostRefreshTimer invalidate];
    _hostRefreshTimer = nil;
#endif
    
    // when discovery stops, we must create a new instance because
    // you cannot restart an NSOperation when it is finished
    [_discMan stopDiscovery];
    
    // Purge the box art cache
    [_boxArtCache removeAllObjects];
    
    // Remove our lifetime observers to avoid triggering them
    // while streaming
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) retrieveSavedHosts {
    DataManager* dataMan = [[DataManager alloc] init];
    NSArray* hosts = [dataMan getHosts];
    @synchronized(hostList) {
        [hostList addObjectsFromArray:hosts];
        
        // Initialize the non-persistent host state
        for (TemporaryHost* host in hostList) {
            #if !TARGET_OS_TV
            if ([EmbeddedTailscale matchesAddress:host.address]) {
                host.activeAddress = host.address;
            }
            #endif
            if (host.activeAddress == nil) {
                host.activeAddress = host.localAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.externalAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.address;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.ipv6Address;
            }
        }
    }
}

- (void) updateAllHosts:(NSArray *)hosts {
    // We must copy the array here because it could be modified
    // before our main thread dispatch happens.
    NSArray* hostsCopy = [NSArray arrayWithArray:hosts];
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_D, @"New host list:");
        for (TemporaryHost* host in hostsCopy) {
            Log(LOG_D, @"Host: \n{\n\t name:%@ \n\t address:%@ \n\t localAddress:%@ \n\t externalAddress:%@ \n\t ipv6Address:%@ \n\t uuid:%@ \n\t mac:%@ \n\t pairState:%d \n\t online:%d \n\t activeAddress:%@ \n}", host.name, host.address, host.localAddress, host.externalAddress, host.ipv6Address, host.uuid, host.mac, host.pairState, host.state, host.activeAddress);
        }
        @synchronized(hostList) {
            [hostList removeAllObjects];
            [hostList addObjectsFromArray:hostsCopy];
        }
        [self updateHosts];
    });
}

- (void)updateHostShortcuts {
#if !TARGET_OS_TV
    NSMutableArray* quickActions = [[NSMutableArray alloc] init];
    
    @synchronized (hostList) {
        for (TemporaryHost* host in hostList) {
            // Pair state may be unknown if we haven't polled it yet, but the app list
            // count will persist from paired PCs
            if ([host.appList count] > 0) {
                UIApplicationShortcutItem* shortcut = [[UIApplicationShortcutItem alloc]
                                                       initWithType:@"PC"
                                                       localizedTitle:host.name
                                                       localizedSubtitle:nil
                                                       icon:[UIApplicationShortcutIcon iconWithType:UIApplicationShortcutIconTypePlay]
                                                       userInfo:[NSDictionary dictionaryWithObject:host.uuid forKey:@"UUID"]];
                [quickActions addObject: shortcut];
            }
        }
    }
    
    [UIApplication sharedApplication].shortcutItems = quickActions;
#endif
}

- (void)updateHosts {
    Log(LOG_I, @"Updating hosts...");
#if !TARGET_OS_TV
    [self updateHostCards];
    return;
#endif
    [[hostScrollView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];
    UIComputerView* addComp = [[UIComputerView alloc] initForAddWithCallback:self];
    UIComputerView* compView;
    NSMutableArray<UIView*>* tiles = [NSMutableArray array];
    @synchronized (hostList) {
        // Sort the host list in alphabetical order
        NSArray* sortedHostList = [[hostList allObjects] sortedArrayUsingSelector:@selector(compareName:)];
        for (TemporaryHost* comp in sortedHostList) {
            compView = [[UIComputerView alloc] initWithComputer:comp andCallback:self];
            [tiles addObject:compView];
            [hostScrollView addSubview:compView];

            // Start jobs to decode the box art in advance
            for (TemporaryApp* app in comp.appList) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                    [self updateBoxArtCacheForApp:app];
                });
            }
        }
    }
    
    // Create or delete host shortcuts as needed
    [self updateHostShortcuts];
    
    // Update the title in case we now have a PC
    [self updateTitle];
    
    [tiles addObject:addComp];
    [hostScrollView addSubview:addComp];
    [self layoutHostTiles:tiles spacing:
#if TARGET_OS_TV
     100
#else
     addComp.frame.size.width / 2
#endif
    ];
}

// Centers the PCs when they fit on one row. Otherwise landscape keeps the
// horizontally scrolling row, and portrait wraps them into a vertically
// scrolling grid so nothing is cut off at the screen edge.
- (void) layoutHostTiles:(NSArray<UIView*>*)tiles spacing:(CGFloat)spacing {
    CGFloat width = hostScrollView.bounds.size.width - hostScrollView.contentInset.left - hostScrollView.contentInset.right;
    CGFloat height = hostScrollView.bounds.size.height;

    CGFloat rowWidth = -spacing;
    for (UIView* tile in tiles) {
        rowWidth += tile.frame.size.width + spacing;
    }

    BOOL portrait = self.view.bounds.size.width < self.view.bounds.size.height;
#if TARGET_OS_TV
    portrait = NO;
#endif
    if (!portrait || rowWidth + 2 * spacing <= width) {
        CGFloat x = rowWidth + 2 * spacing <= width ? (width - rowWidth) / 2 : spacing;
        for (UIView* tile in tiles) {
            tile.center = CGPointMake(x + tile.frame.size.width / 2, height / 2);
            x += tile.frame.size.width + spacing;
        }
        [hostScrollView setContentSize:CGSizeMake(MAX(width, x), height)];
        return;
    }

    // Greedy rows, each centered
    const CGFloat margin = 16;
    CGFloat gap = MIN(spacing, 24);
    NSMutableArray<NSMutableArray<UIView*>*>* rows = [NSMutableArray array];
    NSMutableArray<UIView*>* row = nil;
    CGFloat used = 0;
    for (UIView* tile in tiles) {
        if (row == nil || used + gap + tile.frame.size.width > width - 2 * margin) {
            row = [NSMutableArray array];
            [rows addObject:row];
            used = -gap;
        }
        [row addObject:tile];
        used += gap + tile.frame.size.width;
    }

    CGFloat totalHeight = -gap;
    for (NSArray<UIView*>* r in rows) {
        CGFloat rowHeight = 0;
        for (UIView* tile in r) rowHeight = MAX(rowHeight, tile.frame.size.height);
        totalHeight += rowHeight + gap;
    }
    CGFloat y = MAX(margin, (height - totalHeight) / 2);
    for (NSArray<UIView*>* r in rows) {
        CGFloat rowHeight = 0, w = -gap;
        for (UIView* tile in r) {
            rowHeight = MAX(rowHeight, tile.frame.size.height);
            w += tile.frame.size.width + gap;
        }
        CGFloat x = (width - w) / 2;
        for (UIView* tile in r) {
            tile.center = CGPointMake(x + tile.frame.size.width / 2, y + rowHeight / 2);
            x += tile.frame.size.width + gap;
        }
        y += rowHeight + gap;
    }
    [hostScrollView setContentSize:CGSizeMake(width, MAX(height, y + margin))];
}

#if !TARGET_OS_TV
// Home list: one card per PC plus an "Add PC" card. A single column in
// portrait, columns of roughly 340 points in landscape.
- (void) updateHostCards {
    [[hostScrollView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];
    hostScrollView.alwaysBounceVertical = YES;

    NSArray* sortedHostList;
    @synchronized (hostList) {
        sortedHostList = [[hostList allObjects] sortedArrayUsingSelector:@selector(compareName:)];
    }
    _hostSignature = [self hostSignature:sortedHostList];

    // Registered (paired) PCs first; PCs found on the network but not paired
    // yet in their own section.
    NSMutableArray* registered = [NSMutableArray array];
    NSMutableArray* found = [NSMutableArray array];
    for (TemporaryHost* host in sortedHostList) {
        [(host.pairState == PairStatePaired ? registered : found) addObject:host];

        // Start jobs to decode the box art in advance
        for (TemporaryApp* app in host.appList) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                [self updateBoxArtCacheForApp:app];
            });
        }
    }

    UIEdgeInsets safe = self.view.safeAreaInsets;
    const CGFloat margin = 16, gap = 12, cardHeight = 128;
    CGFloat left = MAX(margin, safe.left), right = MAX(margin, safe.right);
    CGFloat width = hostScrollView.bounds.size.width - left - right;
    NSInteger columns = MAX(1, (NSInteger)floor((width + gap) / (340 + gap)));
    if (self.view.bounds.size.height > self.view.bounds.size.width) {
        columns = 1;
    }
    CGFloat cardWidth = floor((width - gap * (columns - 1)) / columns);
    // Center a single narrow column on wide screens
    if (columns == 1 && cardWidth > 600) {
        left += floor((cardWidth - 600) / 2);
        cardWidth = 600;
    }

    __block CGFloat y = 8;
    __weak typeof(self) weakSelf = self;
    void (^section)(NSString*, NSArray*) = ^(NSString* title, NSArray* hosts) {
        if (hosts.count == 0) {
            return;
        }
        UILabel* header = [[UILabel alloc] init];
        header.text = title;
        header.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        header.textColor = UIColor.secondaryLabelColor;
        header.frame = CGRectMake(left + 4, y + 8, cardWidth * columns, 20);
        [self->hostScrollView addSubview:header];
        y += 34;
        for (NSUInteger i = 0; i < hosts.count; i++) {
            TemporaryHost* host = hosts[i];
            HostCardView* card = [[HostCardView alloc] initWithHost:host];
            card.onTap = ^(HostCardView* view) { [weakSelf connectToHost:host view:view]; };
            card.onLongPress = ^(HostCardView* view) { [weakSelf hostLongClicked:host view:view]; };
            card.onPower = ^(HostCardView* view) { [weakSelf wakeHost:host]; };
            card.onSettings = ^(HostCardView* view) { [weakSelf showSettingsForHost:host]; };
            NSUInteger column = i % columns, row = i / columns;
            card.frame = CGRectMake(left + column * (cardWidth + gap), y + row * (cardHeight + gap), cardWidth, cardHeight);
            [self->hostScrollView addSubview:card];
        }
        y += ((hosts.count + columns - 1) / columns) * (cardHeight + gap) + 4;
    };
    section(ML(@"MY PCS"), registered);
    section(ML(@"FOUND ON THIS NETWORK · TAP TO PAIR"), found);

    if (sortedHostList.count == 0) {
        // Searching: say so, and where to add a PC
        UIImageView* icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"desktopcomputer"]];
        icon.tintColor = UIColor.tertiaryLabelColor;
        icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:44];
        [icon sizeToFit];
        UILabel* message = [[UILabel alloc] init];
        message.text = ML(@"Looking for PCs on this network.\nTo add a PC yourself, tap + at the top right.");
        message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        message.textColor = UIColor.secondaryLabelColor;
        message.numberOfLines = 0;
        message.textAlignment = NSTextAlignmentCenter;
        CGFloat textWidth = MIN(width, 420);
        CGSize textSize = [message sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
        CGFloat top = MAX(40, (hostScrollView.bounds.size.height - icon.bounds.size.height - textSize.height - 20) / 2 - 40);
        icon.center = CGPointMake(left + width / 2, top + icon.bounds.size.height / 2);
        message.frame = CGRectMake(left + (width - textWidth) / 2, CGRectGetMaxY(icon.frame) + 16, textWidth, textSize.height);
        [hostScrollView addSubview:icon];
        [hostScrollView addSubview:message];
        y = CGRectGetMaxY(message.frame);
    }
    hostScrollView.contentSize = CGSizeMake(hostScrollView.bounds.size.width, y + margin);

    [self updateHostShortcuts];
    [self updateTitle];

    // Open the only saved PC once it is known to be online and paired
    if (_autoOpenPending && _selectedHost == nil && sortedHostList.count == 1) {
        TemporaryHost* only = sortedHostList.firstObject;
        if (only.state == StateOnline && only.pairState == PairStatePaired) {
            _autoOpenPending = NO;
            [self hostClicked:only view:nil];
        }
        else if (only.state == StateOffline) {
            _autoOpenPending = NO;
        }
    }
    else if (sortedHostList.count != 1) {
        _autoOpenPending = NO;
    }
}

// Everything a card shows, to redraw only when something changed
- (NSString*) hostSignature:(NSArray*)hosts {
    NSMutableString* signature = [NSMutableString string];
    for (TemporaryHost* host in hosts) {
        [signature appendFormat:@"%@|%d|%d|%@|%@;", host.name, (int)host.state, (int)host.pairState, host.address, host.activeAddress];
    }
    return signature;
}

// Discovery changes host states without telling the home screen, so check
// regularly while the PC list is visible.
- (void) refreshHostCardsIfNeeded {
    if (hostScrollView.superview == nil || _tabContent != nil || _selectedHost != nil) {
        return;
    }
    NSArray* sortedHostList;
    @synchronized (hostList) {
        sortedHostList = [[hostList allObjects] sortedArrayUsingSelector:@selector(compareName:)];
    }
    if (![[self hostSignature:sortedHostList] isEqualToString:_hostSignature ?: @""]) {
        [self updateHostCards];
    }
}
#endif

// This function forces immediate decoding of the UIImage, rather
// than the default lazy decoding that results in janky scrolling.
+ (UIImage*) loadBoxArtForCaching:(TemporaryApp*)app {
    UIImage* boxArt;
    
    NSData* imageData = [NSData dataWithContentsOfFile:[AppAssetManager boxArtPathForApp:app]];
    if (imageData == nil) {
        // No box art on disk
        return nil;
    }
    
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil);
    
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef imageContext =  CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace,
                                                       kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);

    CGContextDrawImage(imageContext, CGRectMake(0, 0, width, height), cgImage);
    
    CGImageRef outputImage = CGBitmapContextCreateImage(imageContext);

    boxArt = [UIImage imageWithCGImage:outputImage];
    
    CGImageRelease(outputImage);
    CGContextRelease(imageContext);
    
    CGImageRelease(cgImage);
    CFRelease(source);
    
    return boxArt;
}

- (void) updateBoxArtCacheForApp:(TemporaryApp*)app {
    if ([_boxArtCache objectForKey:app] == nil) {
        UIImage* image = [MainFrameViewController loadBoxArtForCaching:app];
        if (image != nil) {
            // Add the image to our cache if it was present
            [_boxArtCache setObject:image forKey:app];
        }
    }
}

- (void) updateAppsForHost:(TemporaryHost*)host {
    if (host != _selectedHost) {
        Log(LOG_W, @"Mismatched host during app update");
        return;
    }
    
    _sortedAppList = [host.appList allObjects];
    _sortedAppList = [_sortedAppList sortedArrayUsingSelector:@selector(compareName:)];
    
    if (!_showHiddenApps) {
        NSMutableArray* visibleAppList = [NSMutableArray array];
        for (TemporaryApp* app in _sortedAppList) {
            // Steam Big Picture is not used; "View All Apps" still shows it
            if (!app.hidden && ![app.name hasPrefix:@"Steam"]) {
                [visibleAppList addObject:app];
            }
        }
        _sortedAppList = visibleAppList;
    }
    
#if TARGET_OS_TV
    [hostScrollView removeFromSuperview];
    [self.collectionView reloadData];
#else
    // No app grid on iOS: the PC list stays and the stream starts directly
    // Tapped on Home: start streaming right away. Resume what is running,
    // otherwise start the desktop (or the first app).
    if (_directLaunchHost == host) {
        _directLaunchHost = nil;
        TemporaryApp* target = [self findRunningApp:host];
        for (TemporaryApp* app in _sortedAppList) {
            if (target == nil && [app.name caseInsensitiveCompare:@"Desktop"] == NSOrderedSame) {
                target = app;
            }
        }
        if (target == nil) {
            target = _sortedAppList.firstObject;
        }
        if (target != nil) {
            _returnToListAfterStream = YES;
            [_appManager stopRetrieving];
            [self prepareToStreamApp:target];
            [self performStreamSegue];
        }
    }
#endif
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell* cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"AppCell" forIndexPath:indexPath];
    
    TemporaryApp* app = _sortedAppList[indexPath.row];
    UIAppView* appView = [[UIAppView alloc] initWithApp:app cache:_boxArtCache andCallback:self];
    
    if (appView.bounds.size.width > 10.0) {
        CGFloat scale = cell.bounds.size.width / appView.bounds.size.width;
        [appView setCenter:CGPointMake(appView.bounds.size.width / 2 * scale, appView.bounds.size.height / 2 * scale)];
        appView.transform = CGAffineTransformMakeScale(scale, scale);
    }
    
    [cell.subviews.firstObject removeFromSuperview]; // Remove a view that was previously added
    [cell addSubview:appView];
    
    // Shadow opacity is controlled inside UIAppView based on whether the app
    // is hidden or not during the update cycle.
    UIBezierPath *shadowPath = [UIBezierPath bezierPathWithRect:cell.bounds];
    cell.layer.masksToBounds = NO;
    cell.layer.shadowColor = [UIColor blackColor].CGColor;
    cell.layer.shadowOffset = CGSizeMake(1.0f, 5.0f);
    cell.layer.shadowPath = shadowPath.CGPath;
    
#if !TARGET_OS_TV
    cell.layer.borderWidth = 1;
    cell.layer.borderColor = [[UIColor colorWithRed:0 green:0 blue:0 alpha:0.3f] CGColor];
    cell.exclusiveTouch = YES;
#endif

    return cell;
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 1; // App collection only
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
#if !TARGET_OS_TV
    // The PC list covers this view; the app grid is never shown on iOS
    return 0;
#endif
    if (_selectedHost != nil && _sortedAppList != nil) {
        return _sortedAppList.count;
    }
    else {
        return 0;
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    
    // Purge the box art cache on low memory
    [_boxArtCache removeAllObjects];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#if !TARGET_OS_TV
- (BOOL)shouldAutorotate {
    return YES;
}
#endif

- (void) disableNavigation {
    self.navigationController.navigationBar.topItem.rightBarButtonItem.enabled = NO;
    self.navigationController.navigationBar.topItem.leftBarButtonItem.enabled = NO;
}

- (void) enableNavigation {
    self.navigationController.navigationBar.topItem.rightBarButtonItem.enabled = YES;
    self.navigationController.navigationBar.topItem.leftBarButtonItem.enabled = YES;
}

#if TARGET_OS_TV
- (BOOL)canBecomeFocused {
    return YES;
}
#endif

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    
#if !TARGET_OS_TV
    if (context.nextFocusedView != nil) {
        [context.nextFocusedView setAlpha:0.8];
    }
    [context.previouslyFocusedView setAlpha:1.0];
#endif
}

@end
