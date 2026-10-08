//
//  SettingsViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/27/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "SettingsViewController.h"
#import "TemporarySettings.h"
#import "DataManager.h"
#import "Localization.h"

#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>

@implementation SettingsViewController {
    NSInteger _bitrate;
    NSInteger _lastSelectedResolutionIndex;
    // Storyboard frames of the controls. Rotation re-derives the layout from
    // these instead of accumulating safe-area offsets.
    NSMapTable<UIView*, NSValue*>* _baseFrames;
    int _narrowFonts; // 0 = not applied yet, 1 = narrow, 2 = regular
    // Controller rows (on-screen controls, multi-controller, A/B swap) are
    // hidden; later rows move up by the space they used.
    NSHashTable<UIView*>* _hiddenViews;
    NSMapTable<UIView*, NSNumber*>* _rowShifts;
}

@dynamic overrideUserInterfaceStyle;

static NSString* bitrateFormat = @"Bitrate: %.1f Mbps";
static const int bitrateTable[] = {
    500,
    1000,
    1500,
    2000,
    2500,
    3000,
    4000,
    5000,
    6000,
    7000,
    8000,
    9000,
    10000,
    12000,
    15000,
    18000,
    20000,
    30000,
    40000,
    50000,
    60000,
    70000,
    80000,
    100000,
    120000,
    150000,
};

const int RESOLUTION_TABLE_SIZE = 7;
const int RESOLUTION_TABLE_CUSTOM_INDEX = RESOLUTION_TABLE_SIZE - 1;
CGSize resolutionTable[RESOLUTION_TABLE_SIZE];

-(int)getSliderValueForBitrate:(NSInteger)bitrate {
    int i;
    
    for (i = 0; i < (sizeof(bitrateTable) / sizeof(*bitrateTable)); i++) {
        if (bitrate <= bitrateTable[i]) {
            return i;
        }
    }
    
    // Return the last entry in the table
    return i - 1;
}

// Fit the fixed-width storyboard controls into the settings sheet, which is
// narrower than the controls in portrait and wider in landscape.
- (void)layoutControlsForVisibleWidth {
    if (_baseFrames == nil) {
        _baseFrames = [NSMapTable weakToStrongObjectsMapTable];
        for (UIView* view in self.view.subviews) {
            // Skip UIKit's private scroll indicators
            if ([view isKindOfClass:[UIImageView class]] || [NSStringFromClass(view.class) hasPrefix:@"_"]) {
                continue;
            }
            [_baseFrames setObject:[NSValue valueWithCGRect:view.frame] forKey:view];
        }
        [self computeHiddenControllerRows];
    }

    CGFloat inset = 0;
    if (@available(iOS 11.0, *)) {
        // HACK: The official safe area is much too large for our purposes
        // so we'll just use the presence of any safe area to indicate we should
        // pad by 20.
        if (self.view.safeAreaInsets.left >= 20 || self.view.safeAreaInsets.right >= 20) {
            inset = 20;
        }
    }

    CGFloat visibleWidth = self.view.bounds.size.width;
    // The storyboard column is 450 points wide starting at x=16; center it
    // when there is room and squeeze it otherwise.
    const CGFloat columnWidth = 482;
    if (visibleWidth > columnWidth + 2 * inset) {
        inset = floor((visibleWidth - columnWidth) / 2);
    }
    BOOL narrow = visibleWidth - inset < columnWidth;

    BOOL resized = NO;
    for (UIView* view in _baseFrames) {
        CGRect frame = [[_baseFrames objectForKey:view] CGRectValue];
        frame.origin.x += inset;
        frame.origin.y -= [[_rowShifts objectForKey:view] doubleValue];
        view.hidden = [_hiddenViews containsObject:view];
        frame.size.width = MAX(80, MIN(frame.size.width, visibleWidth - frame.origin.x - 12));
        if (!CGRectEqualToRect(view.frame, frame)) {
            resized |= view.frame.size.width != frame.size.width;
            view.frame = frame;
        }
        if (_narrowFonts != (narrow ? 1 : 2) && [view isKindOfClass:[UISegmentedControl class]]) {
            // Keep segments like "Safe Area" readable on phones in portrait
            UISegmentedControl* control = (UISegmentedControl*)view;
            control.apportionsSegmentWidthsByContent = YES;
            [control setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:narrow ? 11 : 13]} forState:UIControlStateNormal];
        }
    }
    _narrowFonts = narrow ? 1 : 2;

    if (resized) {
        [self updateResolutionDisplayViewText];
    }
}

// Finds the controller selectors and their title labels (the label just
// above each selector), and how far every later view moves up.
- (void)computeHiddenControllerRows {
    _hiddenViews = [NSHashTable weakObjectsHashTable];
    _rowShifts = [NSMapTable weakToStrongObjectsMapTable];
    NSMutableArray<NSValue*>* removedSpans = [NSMutableArray array]; // (top, height)
    
    for (UIView* selector in @[self.onscreenControlSelector, self.multiControllerSelector, self.swapABXYButtonsSelector]) {
        if (selector == nil || [_baseFrames objectForKey:selector] == nil) {
            continue;
        }
        CGRect selectorFrame = [[_baseFrames objectForKey:selector] CGRectValue];
        CGFloat top = CGRectGetMinY(selectorFrame);
        [_hiddenViews addObject:selector];
        for (UIView* view in _baseFrames) {
            CGRect frame = [[_baseFrames objectForKey:view] CGRectValue];
            if ([view isKindOfClass:[UILabel class]] && CGRectGetMaxY(frame) <= CGRectGetMinY(selectorFrame) + 2 &&
                CGRectGetMinY(selectorFrame) - CGRectGetMinY(frame) < 45) {
                [_hiddenViews addObject:view];
                top = MIN(top, CGRectGetMinY(frame));
            }
        }
        // The row ends where the next visible row starts
        CGFloat next = CGFLOAT_MAX;
        for (UIView* view in _baseFrames) {
            CGFloat y = CGRectGetMinY([[_baseFrames objectForKey:view] CGRectValue]);
            if (y > CGRectGetMaxY(selectorFrame) - 1 && ![_hiddenViews containsObject:view]) {
                next = MIN(next, y);
            }
        }
        if (next == CGFLOAT_MAX) {
            next = CGRectGetMaxY(selectorFrame) + 8;
        }
        [removedSpans addObject:[NSValue valueWithCGPoint:CGPointMake(top, next - top)]];
    }
    
    for (UIView* view in _baseFrames) {
        CGFloat y = CGRectGetMinY([[_baseFrames objectForKey:view] CGRectValue]);
        CGFloat shift = 0;
        for (NSValue* span in removedSpans) {
            if (span.CGPointValue.x < y && ![_hiddenViews containsObject:view]) {
                shift += span.CGPointValue.y;
            }
        }
        [_rowShifts setObject:@(shift) forKey:view];
    }
}

// Translates the storyboard's fixed English text.
- (void)localizeStoryboardText {
    for (UIView* view in self.view.subviews) {
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel* label = (UILabel*)view;
            label.text = ML(label.text);
        }
        else if ([view isKindOfClass:[UISegmentedControl class]]) {
            UISegmentedControl* control = (UISegmentedControl*)view;
            for (NSUInteger i = 0; i < control.numberOfSegments; i++) {
                [control setTitle:ML([control titleForSegmentAtIndex:i]) forSegmentAtIndex:i];
            }
        }
    }
}

// This view is rooted at a ScrollView. To make it scrollable,
// we'll update content size here.
-(void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutControlsForVisibleWidth];

    CGFloat highestViewY = 0;
    
    // Enumerate the scroll view's subviews looking for the
    // highest view Y value to set our scroll view's content
    // size.
    for (UIView* view in self.scrollView.subviews) {
        // UIScrollViews have 2 default child views
        // which represent the horizontal and vertical scrolling
        // indicators. Ignore any views we don't recognize.
        if (![view isKindOfClass:[UILabel class]] &&
            ![view isKindOfClass:[UISegmentedControl class]] &&
            ![view isKindOfClass:[UISlider class]]) {
            continue;
        }
        
        if (view.hidden) {
            continue;
        }
        CGFloat currentViewY = view.frame.origin.y + view.frame.size.height;
        if (currentViewY > highestViewY) {
            highestViewY = currentViewY;
        }
    }
    
    // Add a bit of padding so the view doesn't end right at the button of the display.
    // The controls always fit horizontally, so only allow vertical scrolling.
    self.scrollView.contentSize = CGSizeMake(MIN(self.scrollView.contentSize.width, self.scrollView.bounds.size.width),
                                             highestViewY + 20);
}

// Adjust the subviews for the safe area on the iPhone X.
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self.view setNeedsLayout];
}

BOOL isCustomResolution(CGSize res) {
    if (res.width == 0 && res.height == 0) {
        return NO;
    }
    
    for (int i = 0; i < RESOLUTION_TABLE_CUSTOM_INDEX; i++) {
        if (res.width == resolutionTable[i].width && res.height == resolutionTable[i].height) {
            return NO;
        }
    }
    
    return YES;
}

// Settings is a tab now: save whenever another tab is chosen
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self saveSettings];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Always run settings in dark mode because we want the light fonts
    if (@available(iOS 13.0, tvOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* currentSettings = [dataMan getSettings];
    
    // Ensure we pick a bitrate that falls exactly onto a slider notch
    _bitrate = bitrateTable[[self getSliderValueForBitrate:[currentSettings.bitrate intValue]]];

    // Get the size of the screen with and without safe area insets
    UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
    CGFloat screenScale = window.screen.scale;
    // Streaming is always landscape, even when settings load in portrait.
    // The portrait top inset matches the landscape side insets of notched iPhones.
    BOOL portrait = window.frame.size.height > window.frame.size.width;
    CGFloat sideInsets = portrait ? window.safeAreaInsets.top * 2 : window.safeAreaInsets.left + window.safeAreaInsets.right;
    if (portrait && (window.safeAreaInsets.top < 40 || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone)) {
        // A plain status bar inset is not a notch
        sideInsets = 0;
    }
    CGFloat longSide = MAX(window.frame.size.width, window.frame.size.height);
    CGFloat shortSide = MIN(window.frame.size.width, window.frame.size.height);
    CGFloat safeAreaWidth = (longSide - sideInsets) * screenScale;
    CGFloat fullScreenWidth = longSide * screenScale;
    CGFloat fullScreenHeight = shortSide * screenScale;
    
    self.resolutionDisplayView.layer.cornerRadius = 10;
    self.resolutionDisplayView.clipsToBounds = YES;
    UITapGestureRecognizer *resolutionDisplayViewTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(resolutionDisplayViewTapped:)];
    [self.resolutionDisplayView addGestureRecognizer:resolutionDisplayViewTap];
    
    resolutionTable[0] = CGSizeMake(640, 360);
    resolutionTable[1] = CGSizeMake(1280, 720);
    resolutionTable[2] = CGSizeMake(1920, 1080);
    resolutionTable[3] = CGSizeMake(3840, 2160);
    resolutionTable[4] = CGSizeMake(safeAreaWidth, fullScreenHeight);
    resolutionTable[5] = CGSizeMake(fullScreenWidth, fullScreenHeight);
    resolutionTable[6] = CGSizeMake([currentSettings.width integerValue], [currentSettings.height integerValue]); // custom initial value
    
    // Don't populate the custom entry unless we have a custom resolution
    if (!isCustomResolution(resolutionTable[6])) {
        resolutionTable[6] = CGSizeMake(0, 0);
    }
    
    NSInteger framerate;
    switch ([currentSettings.framerate integerValue]) {
        case 30:
            framerate = 0;
            break;
        default:
        case 60:
            framerate = 1;
            break;
        case 120:
            framerate = 2;
            break;
    }

    NSInteger resolution = 1;
    for (int i = 0; i < RESOLUTION_TABLE_SIZE; i++) {
        if ((int) resolutionTable[i].height == [currentSettings.height intValue]
            && (int) resolutionTable[i].width == [currentSettings.width intValue]) {
            resolution = i;
            break;
        }
    }

    // Only show the 120 FPS option if we have a > 60-ish Hz display
    bool enable120Fps = false;
    if (@available(iOS 10.3, tvOS 10.3, *)) {
        if ([UIScreen mainScreen].maximumFramesPerSecond > 62) {
            enable120Fps = true;
        }
    }
    if (!enable120Fps) {
        [self.framerateSelector removeSegmentAtIndex:2 animated:NO];
    }

    // Disable codec selector segments for unsupported codecs
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
#endif
    {
        [self.codecSelector removeSegmentAtIndex:2 animated:NO];
    }
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        [self.codecSelector removeSegmentAtIndex:1 animated:NO];

        // Only enable the 4K option for "recent" devices. We'll judge that by whether
        // they support HEVC decoding (A9 or later).
        [self.resolutionSelector setEnabled:NO forSegmentAtIndex:3];
    }
    switch (currentSettings.preferredCodec) {
        case CODEC_PREF_AUTO:
            [self.codecSelector setSelectedSegmentIndex:self.codecSelector.numberOfSegments - 1];
            break;
            
        case CODEC_PREF_AV1:
            [self.codecSelector setSelectedSegmentIndex:2];
            break;
            
        case CODEC_PREF_HEVC:
            [self.codecSelector setSelectedSegmentIndex:1];
            break;
            
        case CODEC_PREF_H264:
            [self.codecSelector setSelectedSegmentIndex:0];
            break;
    }
    
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) || !(AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10)) {
        [self.hdrSelector removeAllSegments];
        [self.hdrSelector insertSegmentWithTitle:ML(@"Unsupported on this device") atIndex:0 animated:NO];
        [self.hdrSelector setEnabled:NO];
    }
    else {
        [self.hdrSelector setSelectedSegmentIndex:currentSettings.enableHdr ? 1 : 0];
    }
    
    [self.touchModeSelector setSelectedSegmentIndex:currentSettings.absoluteTouchMode ? 1 : 0];
    [self.touchModeSelector addTarget:self action:@selector(touchModeChanged) forControlEvents:UIControlEventValueChanged];
    [self.statsOverlaySelector setSelectedSegmentIndex:currentSettings.statsOverlay ? 1 : 0];
    [self.btMouseSelector setSelectedSegmentIndex:currentSettings.btMouseSupport ? 1 : 0];
    [self.optimizeSettingsSelector setSelectedSegmentIndex:currentSettings.optimizeGames ? 1 : 0];
    [self.framePacingSelector setSelectedSegmentIndex:currentSettings.useFramePacing ? 1 : 0];
    [self.multiControllerSelector setSelectedSegmentIndex:currentSettings.multiController ? 1 : 0];
    [self.swapABXYButtonsSelector setSelectedSegmentIndex:currentSettings.swapABXYButtons ? 1 : 0];
    [self.audioOnPCSelector setSelectedSegmentIndex:currentSettings.playAudioOnPC ? 1 : 0];
    NSInteger onscreenControls = [currentSettings.onscreenControls integerValue];
    _lastSelectedResolutionIndex = resolution;
    [self.resolutionSelector setSelectedSegmentIndex:resolution];
    [self.resolutionSelector addTarget:self action:@selector(newResolutionChosen) forControlEvents:UIControlEventValueChanged];
    [self.framerateSelector setSelectedSegmentIndex:framerate];
    [self.framerateSelector addTarget:self action:@selector(updateBitrate) forControlEvents:UIControlEventValueChanged];
    // On-screen controls were removed; keep the stored setting off
    (void)onscreenControls;
    [self.onscreenControlSelector setSelectedSegmentIndex:0]; // "Off"
    [self.bitrateSlider setMinimumValue:0];
    [self.bitrateSlider setMaximumValue:(sizeof(bitrateTable) / sizeof(*bitrateTable)) - 1];
    [self.bitrateSlider setValue:[self getSliderValueForBitrate:_bitrate] animated:YES];
    [self.bitrateSlider addTarget:self action:@selector(bitrateSliderMoved) forControlEvents:UIControlEventValueChanged];
    [self updateBitrateText];
    [self updateResolutionDisplayViewText];
    [self localizeStoryboardText];
    
    // Same grouped background as Home and the Tailscale screen
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.resolutionDisplayView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    
    [self addKeyboardOnStartSetting];
}

// "Show keyboard when streaming starts" (portrait streams), after the
// storyboard's last row. Stored in user defaults; on by default.
- (void)addKeyboardOnStartSetting {
    CGFloat bottom = 0;
    for (UIView* view in self.view.subviews) {
        if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UISegmentedControl class]]) {
            bottom = MAX(bottom, CGRectGetMaxY(view.frame));
        }
    }
    UILabel* title = [[UILabel alloc] initWithFrame:CGRectMake(22, bottom + 16, 450, 21)];
    title.text = ML(@"Show Keyboard When Streaming Starts");
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textColor = [UIColor colorWithRed:0.95 green:0.97 blue:1.0 alpha:1];
    UISegmentedControl* selector = [[UISegmentedControl alloc] initWithItems:@[ML(@"No"), ML(@"Yes")]];
    selector.frame = CGRectMake(16, bottom + 45, 450, 28);
    // Same look as the storyboard selectors
    selector.selectedSegmentTintColor = self.resolutionSelector.selectedSegmentTintColor;
    selector.tintColor = self.resolutionSelector.tintColor;
    NSNumber* stored = [[NSUserDefaults standardUserDefaults] objectForKey:@"ShowKeyboardOnStreamStart"];
    selector.selectedSegmentIndex = (stored == nil || stored.boolValue) ? 1 : 0;
    [selector addAction:[UIAction actionWithHandler:^(__kindof UIAction* action) {
        UISegmentedControl* control = (UISegmentedControl*)action.sender;
        [[NSUserDefaults standardUserDefaults] setBool:control.selectedSegmentIndex == 1 forKey:@"ShowKeyboardOnStreamStart"];
    }] forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:title];
    [self.view addSubview:selector];
}

- (void) touchModeChanged {
}

- (void) updateBitrate {
    NSInteger fps = [self getChosenFrameRate];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger defaultBitrate;
    
    // This logic is shamelessly stolen from Moonlight Qt:
    // https://github.com/moonlight-stream/moonlight-qt/blob/master/app/settings/streamingpreferences.cpp
    
    // Don't scale bitrate linearly beyond 60 FPS. It's definitely not a linear
    // bitrate increase for frame rate once we get to values that high.
    float frameRateFactor = (fps <= 60 ? fps : (sqrtf(fps / 60.f) * 60.f)) / 30.f;

    // TODO: Collect some empirical data to see if these defaults make sense.
    // We're just using the values that the Shield used, as we have for years.
    struct {
        NSInteger pixels;
        int factor;
    } resTable[] = {
        { 640 * 360, 1 },
        { 854 * 480, 2 },
        { 1280 * 720, 5 },
        { 1920 * 1080, 10 },
        { 2560 * 1440, 20 },
        { 3840 * 2160, 40 },
        { -1, -1 }
    };

    // Calculate the resolution factor by linear interpolation of the resolution table
    float resolutionFactor;
    NSInteger pixels = width * height;
    for (int i = 0;; i++) {
        if (pixels == resTable[i].pixels) {
            // We can bail immediately for exact matches
            resolutionFactor = resTable[i].factor;
            break;
        }
        else if (pixels < resTable[i].pixels) {
            if (i == 0) {
                // Never go below the lowest resolution entry
                resolutionFactor = resTable[i].factor;
            }
            else {
                // Interpolate between the entry greater than the chosen resolution (i) and the entry less than the chosen resolution (i-1)
                resolutionFactor = ((float)(pixels - resTable[i-1].pixels) / (resTable[i].pixels - resTable[i-1].pixels)) * (resTable[i].factor - resTable[i-1].factor) + resTable[i-1].factor;
            }
            break;
        }
        else if (resTable[i].pixels == -1) {
            // Never go above the highest resolution entry
            resolutionFactor = resTable[i-1].factor;
            break;
        }
    }

    defaultBitrate = round(resolutionFactor * frameRateFactor) * 1000;
    _bitrate = MIN(defaultBitrate, 100000);
    [self.bitrateSlider setValue:[self getSliderValueForBitrate:_bitrate] animated:YES];
    
    [self updateBitrateText];
}

- (void) newResolutionChosen {
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        [self promptCustomResolutionDialog];
    }
    else {
        [self updateBitrate];
        [self updateResolutionDisplayViewText];
        _lastSelectedResolutionIndex = [self.resolutionSelector selectedSegmentIndex];
    }
}

- (void) promptCustomResolutionDialog {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:ML(@"Enter Custom Resolution") message:nil preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = ML(@"Video Width");
        textField.clearButtonMode = UITextFieldViewModeAlways;
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.keyboardType = UIKeyboardTypeNumberPad;
        
        if (resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width == 0) {
            textField.text = @"";
        }
        else {
            textField.text = [NSString stringWithFormat:@"%d", (int) resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width];
        }
    }];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = ML(@"Video Height");
        textField.clearButtonMode = UITextFieldViewModeAlways;
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.keyboardType = UIKeyboardTypeNumberPad;
        
        if (resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height == 0) {
            textField.text = @"";
        }
        else {
            textField.text = [NSString stringWithFormat:@"%d", (int) resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height];
        }
    }];

    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSArray * textfields = alertController.textFields;
        UITextField *widthField = textfields[0];
        UITextField *heightField = textfields[1];
        
        long width = [widthField.text integerValue];
        long height = [heightField.text integerValue];
        if (width <= 0 || height <= 0) {
            // Restore the previous selection
            [self.resolutionSelector setSelectedSegmentIndex:self->_lastSelectedResolutionIndex];
            return;
        }
        
        // H.264 maximum
        int maxResolutionDimension = 4096;
        if (@available(iOS 11.0, tvOS 11.0, *)) {
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                // HEVC maximum
                maxResolutionDimension = 8192;
            }
        }
        
        // Cap to maximum valid dimensions
        width = MIN(width, maxResolutionDimension);
        height = MIN(height, maxResolutionDimension);
        
        // Cap to minimum valid dimensions
        width = MAX(width, 256);
        height = MAX(height, 256);

        resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX] = CGSizeMake(width, height);
        [self updateBitrate];
        [self updateResolutionDisplayViewText];
        self->_lastSelectedResolutionIndex = [self.resolutionSelector selectedSegmentIndex];
        
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:ML(@"Custom Resolution Selected") message: @"Custom resolutions are not officially supported by GeForce Experience, so it will not set your host display resolution. You will need to set it manually while in game.\n\nResolutions that are not supported by your client or host PC may cause streaming errors." preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alertController animated:YES completion:nil];
    }]];

    [alertController addAction:[UIAlertAction actionWithTitle:ML(@"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        // Restore the previous selection
        [self.resolutionSelector setSelectedSegmentIndex:self->_lastSelectedResolutionIndex];
    }]];

    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)resolutionDisplayViewTapped:(UITapGestureRecognizer *)sender {
    NSURL *url = [NSURL URLWithString:@"https://moonlight-stream.org/custom-resolution"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void) updateResolutionDisplayViewText {
    NSInteger width = [self getChosenStreamWidth];
    NSInteger height = [self getChosenStreamHeight];
    CGFloat viewFrameWidth = self.resolutionDisplayView.frame.size.width;
    CGFloat viewFrameHeight = self.resolutionDisplayView.frame.size.height;
    CGFloat padding = 10;
    CGFloat fontSize = [UIFont smallSystemFontSize];
    
    for (UIView *subview in self.resolutionDisplayView.subviews) {
        [subview removeFromSuperview];
    }
    UILabel *label1 = [[UILabel alloc] init];
    label1.text = ML(@"Set PC/Game resolution: ");
    label1.font = [UIFont systemFontOfSize:fontSize];
    [label1 sizeToFit];
    label1.frame = CGRectMake(padding, (viewFrameHeight - label1.frame.size.height) / 2, label1.frame.size.width, label1.frame.size.height);

    UILabel *label2 = [[UILabel alloc] init];
    label2.text = [NSString stringWithFormat:@"%ld x %ld", (long)width, (long)height];
    [label2 sizeToFit];
    label2.frame = CGRectMake(viewFrameWidth - label2.frame.size.width - padding, (viewFrameHeight - label2.frame.size.height) / 2, label2.frame.size.width, label2.frame.size.height);

    [self.resolutionDisplayView addSubview:label1];
    [self.resolutionDisplayView addSubview:label2];
}

- (void) bitrateSliderMoved {
    assert(self.bitrateSlider.value < (sizeof(bitrateTable) / sizeof(*bitrateTable)));
    _bitrate = bitrateTable[(int)self.bitrateSlider.value];
    [self updateBitrateText];
}

- (void) updateBitrateText {
    // Display bitrate in Mbps
    [self.bitrateLabel setText:[NSString stringWithFormat:ML(bitrateFormat), _bitrate / 1000.]];
}

- (NSInteger) getChosenFrameRate {
    switch ([self.framerateSelector selectedSegmentIndex]) {
        case 0:
            return 30;
        case 1:
            return 60;
        case 2:
            return 120;
        default:
            abort();
    }
}

- (uint32_t) getChosenCodecPreference {
    // Auto is always the last segment
    if (self.codecSelector.selectedSegmentIndex == self.codecSelector.numberOfSegments - 1) {
        return CODEC_PREF_AUTO;
    }
    else {
        switch (self.codecSelector.selectedSegmentIndex) {
            case 0:
                return CODEC_PREF_H264;
                
            case 1:
                return CODEC_PREF_HEVC;
                
            case 2:
                return CODEC_PREF_AV1;
                
            default:
                abort();
        }
    }
}

- (NSInteger) getChosenStreamHeight {
    // because the 4k resolution can be removed
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        return resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height;
    }

    return resolutionTable[[self.resolutionSelector selectedSegmentIndex]].height;
}

- (NSInteger) getChosenStreamWidth {
    // because the 4k resolution can be removed
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        return resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width;
    }

    return resolutionTable[[self.resolutionSelector selectedSegmentIndex]].width;
}

- (void) saveSettings {
    DataManager* dataMan = [[DataManager alloc] init];
    NSInteger framerate = [self getChosenFrameRate];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger onscreenControls = [self.onscreenControlSelector selectedSegmentIndex];
    BOOL optimizeGames = [self.optimizeSettingsSelector selectedSegmentIndex] == 1;
    BOOL multiController = [self.multiControllerSelector selectedSegmentIndex] == 1;
    BOOL swapABXYButtons = [self.swapABXYButtonsSelector selectedSegmentIndex] == 1;
    BOOL audioOnPC = [self.audioOnPCSelector selectedSegmentIndex] == 1;
    uint32_t preferredCodec = [self getChosenCodecPreference];
    BOOL btMouseSupport = [self.btMouseSelector selectedSegmentIndex] == 1;
    BOOL useFramePacing = [self.framePacingSelector selectedSegmentIndex] == 1;
    BOOL absoluteTouchMode = [self.touchModeSelector selectedSegmentIndex] == 1;
    BOOL statsOverlay = [self.statsOverlaySelector selectedSegmentIndex] == 1;
    BOOL enableHdr = [self.hdrSelector selectedSegmentIndex] == 1;
    [dataMan saveSettingsWithBitrate:_bitrate
                           framerate:framerate
                              height:height
                               width:width
                         audioConfig:2 // Stereo
                    onscreenControls:onscreenControls
                       optimizeGames:optimizeGames
                     multiController:multiController
                     swapABXYButtons:swapABXYButtons
                           audioOnPC:audioOnPC
                      preferredCodec:preferredCodec
                      useFramePacing:useFramePacing
                           enableHdr:enableHdr
                      btMouseSupport:btMouseSupport
                   absoluteTouchMode:absoluteTouchMode
                        statsOverlay:statsOverlay];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
}


@end


#if !TARGET_OS_TV
// Settings as an iOS-style list (like the Tailscale screen): pull-down menus
// for choices, switches for on/off, a slider for the bitrate. Every change is
// saved right away.
@implementation MoonlightSettingsViewController {
    NSArray<NSDictionary*>* _sections;
    NSInteger _width, _height, _framerate, _bitrate;
    uint32_t _codec;
    BOOL _absoluteTouch, _optimizeGames, _multiController, _swapABXY, _audioOnPC;
    BOOL _framePacing, _hdr, _btMouse, _statsOverlay;
    CGSize _safeAreaSize, _fullScreenSize;
}

static NSInteger MLDefaultBitrate(NSInteger width, NSInteger height, NSInteger fps) {
    // Same defaults as the original Moonlight settings (from Moonlight Qt)
    float frameRateFactor = (fps <= 60 ? fps : (sqrtf(fps / 60.f) * 60.f)) / 30.f;
    struct { NSInteger pixels; int factor; } table[] = {
        { 640 * 360, 1 }, { 854 * 480, 2 }, { 1280 * 720, 5 }, { 1920 * 1080, 10 },
        { 2560 * 1440, 20 }, { 3840 * 2160, 40 }, { -1, -1 }
    };
    float resolutionFactor = 1;
    NSInteger pixels = width * height;
    for (int i = 0;; i++) {
        if (table[i].pixels == -1) { resolutionFactor = table[i - 1].factor; break; }
        if (pixels == table[i].pixels) { resolutionFactor = table[i].factor; break; }
        if (pixels < table[i].pixels) {
            resolutionFactor = i == 0 ? table[0].factor :
                ((float)(pixels - table[i - 1].pixels) / (table[i].pixels - table[i - 1].pixels)) * (table[i].factor - table[i - 1].factor) + table[i - 1].factor;
            break;
        }
    }
    return MIN(round(resolutionFactor * frameRateFactor) * 1000, 100000);
}

static int MLBitrateIndex(NSInteger bitrate) {
    int count = (int)(sizeof(bitrateTable) / sizeof(*bitrateTable));
    for (int i = 0; i < count; i++) {
        if (bitrate <= bitrateTable[i]) return i;
    }
    return count - 1;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.duringStream ? ML(@"Streaming Settings") : ML(@"Settings");
    if (self.duringStream) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeFromStream)];
    }

    TemporarySettings* settings = [[[DataManager alloc] init] getSettings];
    _width = settings.width.integerValue;
    _height = settings.height.integerValue;
    _framerate = settings.framerate.integerValue ?: 60;
    _bitrate = bitrateTable[MLBitrateIndex(settings.bitrate.integerValue)];
    _codec = settings.preferredCodec;
    _absoluteTouch = settings.absoluteTouchMode;
    _optimizeGames = settings.optimizeGames;
    _multiController = settings.multiController;
    _swapABXY = settings.swapABXYButtons;
    _audioOnPC = settings.playAudioOnPC;
    _framePacing = settings.useFramePacing;
    _hdr = settings.enableHdr;
    _btMouse = settings.btMouseSupport;
    _statsOverlay = settings.statsOverlay;

    // "Safe area" and "full screen" sizes in landscape, the streaming orientation
    UIWindowScene* scene = (UIWindowScene*)UIApplication.sharedApplication.connectedScenes.anyObject;
    UIWindow* window = scene.windows.firstObject;
    CGFloat scale = window.screen.scale ?: UIScreen.mainScreen.scale;
    CGSize size = window ? window.bounds.size : UIScreen.mainScreen.bounds.size;
    BOOL portrait = size.height > size.width;
    UIEdgeInsets insets = window.safeAreaInsets;
    CGFloat sideInsets = portrait ? insets.top * 2 : insets.left + insets.right;
    if (portrait && (insets.top < 40 || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone)) {
        sideInsets = 0;
    }
    CGFloat longSide = MAX(size.width, size.height), shortSide = MIN(size.width, size.height);
    _safeAreaSize = CGSizeMake((longSide - sideInsets) * scale, shortSide * scale);
    _fullScreenSize = CGSizeMake(longSide * scale, shortSide * scale);

    [self rebuild];
}

- (void)save {
    [[[DataManager alloc] init] saveSettingsWithBitrate:_bitrate
                                              framerate:_framerate
                                                 height:_height
                                                  width:_width
                                            audioConfig:2 // Stereo
                                       onscreenControls:0 // Removed from this app
                                          optimizeGames:_optimizeGames
                                        multiController:_multiController
                                        swapABXYButtons:_swapABXY
                                              audioOnPC:_audioOnPC
                                         preferredCodec:_codec
                                         useFramePacing:_framePacing
                                              enableHdr:_hdr
                                         btMouseSupport:_btMouse
                                      absoluteTouchMode:_absoluteTouch
                                           statsOverlay:_statsOverlay];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self save];
    if (self.onClose) {
        self.onClose();
    }
}

- (void)closeFromStream {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

// Changing resolution or frame rate resets the bitrate to its default, as before
- (void)setResolutionWidth:(NSInteger)width height:(NSInteger)height {
    _width = width;
    _height = height;
    _bitrate = bitrateTable[MLBitrateIndex(MLDefaultBitrate(_width, _height, _framerate))];
    [self save];
    [self rebuild];
}

#pragma mark - Rows

- (NSString*)resolutionName {
    struct { NSInteger w, h; NSString* name; } named[] = {
        { 640, 360, @"360p" }, { 1280, 720, @"720p" }, { 1920, 1080, @"1080p" }, { 3840, 2160, @"4K" },
    };
    for (int i = 0; i < 4; i++) {
        if (named[i].w == _width && named[i].h == _height) return named[i].name;
    }
    if (_width == (NSInteger)_safeAreaSize.width && _height == (NSInteger)_safeAreaSize.height) return ML(@"Safe Area");
    if (_width == (NSInteger)_fullScreenSize.width && _height == (NSInteger)_fullScreenSize.height) return ML(@"Full");
    return [NSString stringWithFormat:@"%ld×%ld", (long)_width, (long)_height];
}

- (NSString*)codecName:(uint32_t)codec {
    switch (codec) {
        case CODEC_PREF_H264: return @"H.264";
        case CODEC_PREF_HEVC: return @"HEVC";
        case CODEC_PREF_AV1: return @"AV1";
        default: return ML(@"Auto");
    }
}

- (UIMenu*)resolutionMenu {
    __weak typeof(self) weakSelf = self;
    NSMutableArray* items = [NSMutableArray array];
    NSArray* sizes = @[@[@"360p", @640, @360], @[@"720p", @1280, @720], @[@"1080p", @1920, @1080], @[@"4K", @3840, @2160],
                       @[ML(@"Safe Area"), @(_safeAreaSize.width), @(_safeAreaSize.height)],
                       @[ML(@"Full"), @(_fullScreenSize.width), @(_fullScreenSize.height)]];
    BOOL hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    for (NSArray* entry in sizes) {
        NSInteger width = [entry[1] integerValue], height = [entry[2] integerValue];
        NSString* title = [entry[0] hasSuffix:@"p"] || [entry[0] isEqualToString:@"4K"] ? entry[0] :
            [NSString stringWithFormat:@"%@（%ld×%ld）", entry[0], (long)width, (long)height];
        UIAction* action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction* a) {
            [weakSelf setResolutionWidth:width height:height];
        }];
        action.state = width == _width && height == _height ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (width == 3840 && !hevc) {
            // 4K needs a device that decodes HEVC (A9 or later)
            action.attributes = UIMenuElementAttributesDisabled;
        }
        [items addObject:action];
    }
    [items addObject:[UIAction actionWithTitle:ML(@"Custom…") image:nil identifier:nil handler:^(__kindof UIAction* a) {
        [weakSelf promptCustomResolution];
    }]];
    return [UIMenu menuWithChildren:items];
}

- (void)promptCustomResolution {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:ML(@"Enter Custom Resolution") message:nil preferredStyle:UIAlertControllerStyleAlert];
    for (NSString* placeholder in @[ML(@"Video Width"), ML(@"Video Height")]) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
            field.placeholder = placeholder;
            field.keyboardType = UIKeyboardTypeNumberPad;
        }];
    }
    alert.textFields[0].text = [NSString stringWithFormat:@"%ld", (long)_width];
    alert.textFields[1].text = [NSString stringWithFormat:@"%ld", (long)_height];
    [alert addAction:[UIAlertAction actionWithTitle:ML(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ML(@"OK") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        NSInteger width = alert.textFields[0].text.integerValue, height = alert.textFields[1].text.integerValue;
        if (width <= 0 || height <= 0) {
            return;
        }
        // Even sizes within what decoders handle
        width = MAX(256, MIN(width, 7680)) & ~1;
        height = MAX(256, MIN(height, 4320)) & ~1;
        [self setResolutionWidth:width height:height];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIMenu*)choiceMenuWithTitles:(NSArray<NSString*>*)titles values:(NSArray<NSNumber*>*)values current:(NSInteger)current handler:(void (^)(NSInteger value))handler {
    NSMutableArray* items = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSInteger value = values[i].integerValue;
        UIAction* action = [UIAction actionWithTitle:titles[i] image:nil identifier:nil handler:^(__kindof UIAction* a) {
            handler(value);
        }];
        action.state = value == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:action];
    }
    return [UIMenu menuWithChildren:items];
}

- (void)rebuild {
    __weak typeof(self) weakSelf = self;
    BOOL hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    BOOL av1 = NO;
#if defined(__IPHONE_16_0)
    av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
#endif
    BOOL hdrSupported = hevc && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10);
    BOOL fps120 = UIScreen.mainScreen.maximumFramesPerSecond > 62;

    NSMutableArray* fpsTitles = [NSMutableArray arrayWithArray:@[@"30 FPS", @"60 FPS"]];
    NSMutableArray* fpsValues = [NSMutableArray arrayWithArray:@[@30, @60]];
    if (fps120) {
        [fpsTitles addObject:@"120 FPS"];
        [fpsValues addObject:@120];
    }
    NSMutableArray* codecTitles = [NSMutableArray arrayWithArray:@[ML(@"Auto"), @"H.264"]];
    NSMutableArray* codecValues = [NSMutableArray arrayWithArray:@[@(CODEC_PREF_AUTO), @(CODEC_PREF_H264)]];
    if (hevc) { [codecTitles addObject:@"HEVC"]; [codecValues addObject:@(CODEC_PREF_HEVC)]; }
    if (av1) { [codecTitles addObject:@"AV1"]; [codecValues addObject:@(CODEC_PREF_AV1)]; }

    NSNumber* keyboardSetting = [[NSUserDefaults standardUserDefaults] objectForKey:@"ShowKeyboardOnStreamStart"];
    BOOL keyboardOnStart = keyboardSetting == nil || keyboardSetting.boolValue;

    _sections = @[
        @{@"title": ML(@"Video"), @"footer": ML(@"Higher resolution and bitrate look sharper but need a faster connection. Changing the resolution or frame rate resets the bitrate to a suitable value."), @"rows": @[
            @{@"title": ML(@"Resolution"), @"value": [self resolutionName], @"menu": [self resolutionMenu]},
            @{@"title": ML(@"Picture Size"), @"detail": ML(@"Fill covers the whole screen and cuts what does not fit; pinch to see the edges. Stretch fills without cutting but distorts the picture."),
              @"value": @[ML(@"Fit (whole picture)"), ML(@"Fill (crop edges)"), ML(@"Stretch")][MLVideoFillMode()],
              @"menu": [self choiceMenuWithTitles:@[ML(@"Fit (whole picture)"), ML(@"Fill (crop edges)"), ML(@"Stretch")] values:@[@0, @1, @2]
                                          current:MLVideoFillMode()
                                          handler:^(NSInteger value) {
                  [[NSUserDefaults standardUserDefaults] setInteger:value forKey:MLVideoFillModeKey];
                  [weakSelf rebuild];
              }]},
            @{@"title": ML(@"Frame Rate"), @"value": [NSString stringWithFormat:@"%ld FPS", (long)_framerate],
              @"menu": [self choiceMenuWithTitles:fpsTitles values:fpsValues current:_framerate handler:^(NSInteger value) {
                  typeof(self) s = weakSelf; s->_framerate = value;
                  [s setResolutionWidth:s->_width height:s->_height];
              }]},
            @{@"title": ML(@"Bitrate"), @"slider": @YES},
            @{@"title": ML(@"Preferred Codec"), @"value": [self codecName:_codec],
              @"menu": [self choiceMenuWithTitles:codecTitles values:codecValues current:_codec handler:^(NSInteger value) {
                  typeof(self) s = weakSelf; s->_codec = (uint32_t)value; [s save]; [s rebuild];
              }]},
            @{@"title": ML(@"HDR (Beta)"), @"switch": @(_hdr), @"enabled": @(hdrSupported), @"detail": hdrSupported ? @"" : ML(@"Unsupported on this device"),
              @"toggle": ^(BOOL on) { typeof(self) s = weakSelf; s->_hdr = on; [s save]; }},
            @{@"title": ML(@"Frame Pacing Preference"), @"value": _framePacing ? ML(@"Smoothest Video") : ML(@"Lowest Latency"),
              @"menu": [self choiceMenuWithTitles:@[ML(@"Lowest Latency"), ML(@"Smoothest Video")] values:@[@0, @1] current:_framePacing handler:^(NSInteger value) {
                  typeof(self) s = weakSelf; s->_framePacing = value == 1; [s save]; [s rebuild];
              }]},
            @{@"title": ML(@"Statistics Overlay"), @"switch": @(_statsOverlay),
              @"toggle": ^(BOOL on) { typeof(self) s = weakSelf; s->_statsOverlay = on; [s save]; }},
        ]},
        @{@"title": ML(@"Input"), @"footer": ML(@"Touchpad moves the pointer like a laptop trackpad. Touchscreen clicks where you touch."), @"rows": @[
            @{@"title": @"開始時に映像移動をON", @"switch": @(MLBoolPreference(MLPanOnStartKey, YES)),
              @"toggle": ^(BOOL on) { [NSUserDefaults.standardUserDefaults setBool:on forKey:MLPanOnStartKey]; }},
            @{@"title": @"横画面でキーボードに合わせて映像を上へ移動", @"switch": @(MLBoolPreference(MLShiftForKeyboardKey, NO)),
              @"detail": @"キーボードを閉じると元の位置へ戻ります。",
              @"toggle": ^(BOOL on) { [NSUserDefaults.standardUserDefaults setBool:on forKey:MLShiftForKeyboardKey]; }},
            @{@"title": @"文字入力", @"value": @"入力欄で変換して送信",
              @"detail": @"iPhoneで変換し、送信ボタンでまとめて送ります。"},
            @{@"title": @"文字送信時にPCのIMEをOFF", @"switch": @(MLBoolPreference(MLImeOffBeforeTextSendKey, YES)),
              @"detail": @"送信ボタンを押すと、IME OFF、文字列の順に送ります。送信後もAのままにします。Windows以外ではOFFにしてください。",
              @"toggle": ^(BOOL on) { [NSUserDefaults.standardUserDefaults setBool:on forKey:MLImeOffBeforeTextSendKey]; }},
            @{@"title": ML(@"Touch Mode"), @"value": _absoluteTouch ? ML(@"Touchscreen") : ML(@"Touchpad"),
              @"menu": [self choiceMenuWithTitles:@[ML(@"Touchpad"), ML(@"Touchscreen")] values:@[@0, @1] current:_absoluteTouch handler:^(NSInteger value) {
                  typeof(self) s = weakSelf; s->_absoluteTouch = value == 1; [s save]; [s rebuild];
              }]},
            @{@"title": ML(@"Show Keyboard When Streaming Starts"), @"switch": @(keyboardOnStart),
              @"toggle": ^(BOOL on) { [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"ShowKeyboardOnStreamStart"]; }},
            @{@"title": ML(@"Citrix X1 Mouse Support"), @"switch": @(_btMouse),
              @"toggle": ^(BOOL on) { typeof(self) s = weakSelf; s->_btMouse = on; [s save]; }},
        ]},
        @{@"title": ML(@"Trackpad"), @"footer": ML(@"Pointer speed applies to the trackpad under the picture. Resolution and codec changes apply from the next stream."), @"rows": @[
            @{@"title": ML(@"Pointer Speed"), @"speed": @YES},
            @{@"title": ML(@"Close Button Position (Portrait)"),
              @"value": [[NSUserDefaults standardUserDefaults] boolForKey:MLControlsOnRightKey] ? ML(@"Right") : ML(@"Left"),
              @"menu": [self choiceMenuWithTitles:@[ML(@"Left"), ML(@"Right")] values:@[@0, @1]
                                          current:[[NSUserDefaults standardUserDefaults] boolForKey:MLControlsOnRightKey]
                                          handler:^(NSInteger value) {
                  [[NSUserDefaults standardUserDefaults] setBool:value == 1 forKey:MLControlsOnRightKey];
                  [weakSelf rebuild];
              }]},
        ]},
        @{@"title": ML(@"PC"), @"footer": @"", @"rows": @[
            @{@"title": ML(@"Play Audio on PC"), @"switch": @(_audioOnPC),
              @"toggle": ^(BOOL on) { typeof(self) s = weakSelf; s->_audioOnPC = on; [s save]; }},
            @{@"title": ML(@"Optimize Game Settings"), @"switch": @(_optimizeGames),
              @"toggle": ^(BOOL on) { typeof(self) s = weakSelf; s->_optimizeGames = on; [s save]; }},
        ]},
    ];
    [self.tableView reloadData];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return _sections.count;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return [_sections[section][@"rows"] count];
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    return _sections[section][@"title"];
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    NSString* footer = _sections[section][@"footer"];
    return footer.length ? footer : nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* row = _sections[indexPath.section][@"rows"][indexPath.row];
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = row[@"title"];
    cell.textLabel.numberOfLines = 0;
    NSString* detail = row[@"detail"];
    cell.detailTextLabel.text = detail.length ? detail : nil;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    if (row[@"menu"] != nil) {
        UIButtonConfiguration* config = [UIButtonConfiguration plainButtonConfiguration];
        config.title = row[@"value"];
        config.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"];
        config.imagePlacement = NSDirectionalRectEdgeTrailing;
        config.imagePadding = 4;
        config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
        config.baseForegroundColor = UIColor.secondaryLabelColor;
        config.contentInsets = NSDirectionalEdgeInsetsZero;
        UIButton* button = [UIButton buttonWithConfiguration:config primaryAction:nil];
        button.menu = row[@"menu"];
        button.showsMenuAsPrimaryAction = YES;
        [button sizeToFit];
        cell.accessoryView = button;
    }
    else if (row[@"switch"] != nil) {
        UISwitch* toggle = [[UISwitch alloc] init];
        toggle.on = [row[@"switch"] boolValue];
        toggle.enabled = row[@"enabled"] == nil || [row[@"enabled"] boolValue];
        void (^handler)(BOOL) = row[@"toggle"];
        [toggle addAction:[UIAction actionWithHandler:^(__kindof UIAction* action) {
            handler(((UISwitch*)action.sender).isOn);
        }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    else if ([row[@"speed"] boolValue]) {
        // Pointer speed: 0.5x to 4x in 0.25 steps
        UILabel* title = [[UILabel alloc] init];
        title.text = row[@"title"];
        title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        UILabel* value = [[UILabel alloc] init];
        value.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        value.textColor = UIColor.secondaryLabelColor;
        value.textAlignment = NSTextAlignmentRight;
        value.text = [NSString stringWithFormat:@"%.2f×", MLTrackpadSpeed()];
        UISlider* slider = [[UISlider alloc] init];
        slider.minimumValue = 0.5;
        slider.maximumValue = 4.0;
        slider.value = MLTrackpadSpeed();
        slider.minimumValueImage = [UIImage systemImageNamed:@"tortoise"];
        slider.maximumValueImage = [UIImage systemImageNamed:@"hare"];
        [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction* action) {
            UISlider* s = (UISlider*)action.sender;
            double speed = round(s.value * 4) / 4;
            [[NSUserDefaults standardUserDefaults] setDouble:speed forKey:MLTrackpadSpeedKey];
            value.text = [NSString stringWithFormat:@"%.2f×", speed];
        }] forControlEvents:UIControlEventValueChanged];
        UIStackView* top = [[UIStackView alloc] initWithArrangedSubviews:@[title, value]];
        UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, slider]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 8;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        cell.textLabel.text = nil;
        [cell.contentView addSubview:stack];
        UILayoutGuide* margins = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        ]];
    }
    else if ([row[@"slider"] boolValue]) {
        // "Bitrate   10.0 Mbps" with the slider underneath
        cell.textLabel.text = nil;
        UILabel* title = [[UILabel alloc] init];
        title.text = row[@"title"];
        title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        UILabel* value = [[UILabel alloc] init];
        value.text = [NSString stringWithFormat:@"%.1f Mbps", _bitrate / 1000.0];
        value.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        value.textColor = UIColor.secondaryLabelColor;
        value.textAlignment = NSTextAlignmentRight;
        UISlider* slider = [[UISlider alloc] init];
        slider.minimumValue = 0;
        slider.maximumValue = (sizeof(bitrateTable) / sizeof(*bitrateTable)) - 1;
        slider.value = MLBitrateIndex(_bitrate);
        __weak typeof(self) weakSelf = self;
        [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction* action) {
            UISlider* s = (UISlider*)action.sender;
            int index = (int)lroundf(s.value);
            typeof(self) strongSelf = weakSelf;
            strongSelf->_bitrate = bitrateTable[index];
            value.text = [NSString stringWithFormat:@"%.1f Mbps", strongSelf->_bitrate / 1000.0];
        }] forControlEvents:UIControlEventValueChanged];
        [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction* action) {
            UISlider* s = (UISlider*)action.sender;
            s.value = lroundf(s.value); // snap to a notch
            [weakSelf save];
        }] forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        UIStackView* top = [[UIStackView alloc] initWithArrangedSubviews:@[title, value]];
        UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, slider]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 8;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:stack];
        UILayoutGuide* margins = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        ]];
    }
    return cell;
}

@end
#endif
