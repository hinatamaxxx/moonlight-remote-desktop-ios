//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "DataManager.h"
#import "Localization.h"
#import "AppDelegate.h"
#import "SettingsViewController.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

#if TARGET_OS_TV
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>
#endif

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

#if !TARGET_OS_TV
// Inspect the state before deletion: removing the last draft character must
// remain local. Only a subsequent Backspace in an empty editor reaches the PC.
@interface StreamComposeTextView : UITextView
@property(nonatomic, copy) void (^onEmptyDelete)(void);
@property(nonatomic, copy) BOOL (^canDeleteRemote)(void);
@property(nonatomic, copy) NSString *draftText;
- (void)prepareForChangeInRange:(NSRange)range replacementText:(NSString *)text;
- (void)restoreDeleteAnchor;
- (void)keepSelectionInDraft;
@end

@implementation StreamComposeTextView {
    BOOL _containsDeleteAnchor;
    BOOL _restoringDeleteAnchor;
}

// UITextView's repeat handling also consults the document/selection, not just
// UIKeyInput.hasText. Keep one zero-width character before the local draft so
// the system keyboard has an actual deletion range when that draft is empty.
// Only draftText crosses the network; the anchor is never user input.
- (NSString *)draftText {
    NSString *text = self.text ?: @"";
    return _containsDeleteAnchor && [text hasPrefix:@"\u200B"] ? [text substringFromIndex:1] : text;
}

- (NSDictionary<NSAttributedStringKey, id> *)composeTextAttributes {
    return @{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleBody],
             NSForegroundColorAttributeName: UIColor.whiteColor};
}

- (void)setDraftText:(NSString *)text {
    _containsDeleteAnchor = YES;
    NSDictionary *attributes = [self composeTextAttributes];
    [super setAttributedText:[[NSAttributedString alloc]
        initWithString:[@"\u200B" stringByAppendingString:text ?: @""] attributes:attributes]];
    self.selectedRange = NSMakeRange(self.text.length, 0);
    self.typingAttributes = attributes;
    self.accessibilityValue = text ?: @"";
}

- (void)restoreDeleteAnchor {
    if (_restoringDeleteAnchor || self.markedTextRange != nil) return;
    if (_containsDeleteAnchor && ![self.text hasPrefix:@"\u200B"]) _containsDeleteAnchor = NO;
    if (!_containsDeleteAnchor) {
        _restoringDeleteAnchor = YES;
        NSRange selection = self.selectedRange;
        BOOL undoEnabled = self.undoManager.isUndoRegistrationEnabled;
        if (undoEnabled) [self.undoManager disableUndoRegistration];
        // An empty text storage has no attributes to inherit. Plain insertion
        // would reset subsequent typing to UIKit's default small black font.
        [self.textStorage insertAttributedString:[[NSAttributedString alloc]
            initWithString:@"\u200B" attributes:[self composeTextAttributes]] atIndex:0];
        _containsDeleteAnchor = YES;
        if (selection.location != NSNotFound) {
            self.selectedRange = NSMakeRange(selection.location + 1, selection.length);
        }
        if (undoEnabled) [self.undoManager enableUndoRegistration];
        _restoringDeleteAnchor = NO;
    }
    self.typingAttributes = [self composeTextAttributes];
    self.accessibilityValue = self.draftText;
}

- (void)keepSelectionInDraft {
    if (_restoringDeleteAnchor || !_containsDeleteAnchor ||
        ![self.text hasPrefix:@"\u200B"] || self.markedTextRange != nil) return;
    NSRange selection = self.selectedRange;
    if (selection.location == 0) {
        self.selectedRange = NSMakeRange(1, selection.length ? selection.length - 1 : 0);
    }
}

- (BOOL)canForwardEmptyDelete {
    return self.isFirstResponder && self.markedTextRange == nil &&
        self.canDeleteRemote && self.canDeleteRemote();
}

- (void)prepareForChangeInRange:(NSRange)range replacementText:(NSString *)text {
    BOOL removesAnchor = _containsDeleteAnchor && range.location == 0 && range.length > 0;
    BOOL remoteDelete = removesAnchor && self.draftText.length == 0 &&
        text.length == 0 && [self canForwardEmptyDelete];
    if (text.length == 0) {
        Log(LOG_I, @"TextInput deleteCallback draftUnits=%lu marked=%d rangeUnits=%lu forwarded=%d",
            (unsigned long)self.draftText.length, self.markedTextRange != nil,
            (unsigned long)range.length, remoteDelete);
    }
    if (removesAnchor) _containsDeleteAnchor = NO;
    if (remoteDelete && self.onEmptyDelete) self.onEmptyDelete();
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (self.draftText.length == 0 &&
        (action == @selector(cut:) || action == @selector(copy:) ||
         action == @selector(select:) || action == @selector(selectAll:))) {
        return NO;
    }
    return [super canPerformAction:action withSender:sender];
}
@end

// Portrait trackpad between the key bar and the keyboard: one finger moves
// the pointer, tap clicks, two-finger tap right-clicks, two fingers scroll,
// long press then move drags.
@interface StreamTrackpadView : UIView
@end

@implementation StreamTrackpadView {
    CGPoint _remainder;
    BOOL _dragging;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    self.layer.cornerRadius = 18;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.multipleTouchEnabled = YES;

    // How to use it, faint in the middle
    UILabel* hint = [[UILabel alloc] init];
    hint.text = ML(@"Trackpad: this area\nRight-click: two-finger tap");
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.35];
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [hint.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [hint.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [hint.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor constant:-24],
    ]];

    UIPanGestureRecognizer* move = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moved:)];
    move.maximumNumberOfTouches = 1;
    UIPanGestureRecognizer* scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scrolled:)];
    scroll.minimumNumberOfTouches = 2;
    scroll.maximumNumberOfTouches = 2;
    UITapGestureRecognizer* click = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(clicked:)];
    UITapGestureRecognizer* rightClick = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rightClicked:)];
    rightClick.numberOfTouchesRequired = 2;
    UILongPressGestureRecognizer* drag = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    drag.minimumPressDuration = 0.35;
    [move requireGestureRecognizerToFail:drag];
    for (UIGestureRecognizer* recognizer in @[move, scroll, click, rightClick, drag]) {
        [self addGestureRecognizer:recognizer];
    }
    return self;
}

- (void)sendMoveBy:(CGPoint)delta {
    // A little faster than the finger, keeping fractions for smooth motion
    const CGFloat speed = MLTrackpadSpeed();
    CGFloat x = delta.x * speed + _remainder.x, y = delta.y * speed + _remainder.y;
    short dx = (short)x, dy = (short)y;
    _remainder = CGPointMake(x - dx, y - dy);
    if (dx != 0 || dy != 0) {
        LiSendMouseMoveEvent(dx, dy);
    }
}

- (void)moved:(UIPanGestureRecognizer*)recognizer {
    [self sendMoveBy:[recognizer translationInView:self]];
    [recognizer setTranslation:CGPointZero inView:self];
}

- (void)scrolled:(UIPanGestureRecognizer*)recognizer {
    CGPoint translation = [recognizer translationInView:self];
    [recognizer setTranslation:CGPointZero inView:self];
    short amount = (short)(translation.y * 6);
    if (amount != 0) {
        LiSendHighResScrollEvent(amount);
    }
}

- (void)clicked:(UITapGestureRecognizer*)recognizer {
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
}

- (void)rightClicked:(UITapGestureRecognizer*)recognizer {
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
}

- (void)dragged:(UILongPressGestureRecognizer*)recognizer {
    static CGPoint last;
    CGPoint point = [recognizer locationInView:self];
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            last = point;
            _dragging = YES;
            LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
            break;
        case UIGestureRecognizerStateChanged:
            [self sendMoveBy:CGPointMake(point.x - last.x, point.y - last.y)];
            last = point;
            break;
        default:
            if (_dragging) {
                _dragging = NO;
                LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            }
            break;
    }
}

@end
#endif

@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    NSTimer *_inactivityTimer;
    NSTimer *_statsUpdateTimer;
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
    UITextView *_overlayView;
    UILabel *_stageLabel;
    UILabel *_tipLabel;
    UIActivityIndicatorView *_spinner;
    StreamView *_streamView;
    UIScrollView *_scrollView;
    BOOL _userIsInteracting;
    CGSize _keyboardSize;
    
#if !TARGET_OS_TV
    UIScreenEdgePanGestureRecognizer *_exitSwipeRecognizer;
    // Portrait controls under the picture: stop, keyboard, full screen
    // Overlay controls in the style of video players: close and rotate at the
    // top left, keyboard at the bottom right.
    UIButton *_closeButton;
    UIButton *_rotateButton;
    UIButton *_keyboardButton;
    UIButton *_hideKeyboardButton;
    // Shows the PC keys over the picture when needed
    UIButton *_specialKeysButton;
    // Shown while the picture is zoomed or moved
    UIButton *_resetViewButton;
    UIButton *_panModeButton;
    NSString *_rotateSymbol; // current rotate icon, to avoid needless updates
    BOOL _specialKeysVisible;
    // Portrait only: PC keys under the picture, trackpad below them
    UIView *_keyBar;
    UIView *_composeBar;
    StreamComposeTextView *_composeField;
    UIButton *_sendTextButton;
    UILabel *_composeHint;
    BOOL _composing;
    BOOL _textSendPending;
    StreamTrackpadView *_trackpad;
    BOOL _streamRunning;
    // Height of the keyboard over this view; in portrait the video moves above it
    CGFloat _keyboardOverlap;
    UIInterfaceOrientation _orientationBeforeKeyboard;
#endif
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
#endif
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
- (void)controllerPlayPauseButtonPressed:(id)sender {
    Log(LOG_I, @"Play/Pause button pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif


- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
#if !TARGET_OS_TV
    ((AppDelegate*)[UIApplication sharedApplication].delegate).orientationLock = 0;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:@"WholePictureDefaultV1"]) {
        [defaults setInteger:0 forKey:MLVideoFillModeKey];
        [defaults setBool:YES forKey:@"WholePictureDefaultV1"];
    }
#endif
    
    [self.navigationController setNavigationBarHidden:YES animated:YES];
    [self.navigationController setToolbarHidden:YES animated:YES];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    _settings = [[[DataManager alloc] init] getSettings];
    
    _stageLabel = [[UILabel alloc] init];
    [_stageLabel setUserInteractionEnabled:NO];
    [_stageLabel setText:[NSString stringWithFormat:ML(@"Starting %@..."), self.streamConfig.appName]];
    [_stageLabel sizeToFit];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    
    _spinner = [[UIActivityIndicatorView alloc] init];
    [_spinner setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhiteLarge];
#else
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhite];
#endif
    [_spinner sizeToFit];
    [_spinner startAnimating];
    _spinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    
    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig delegate:self];
    _inactivityTimer = nil;
    
    _streamView = [[StreamView alloc] initWithFrame:self.view.frame];
    [_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig];
    
#if TARGET_OS_TV
    if (!_menuTapGestureRecognizer || !_menuDoubleTapGestureRecognizer || !_playPauseTapGestureRecognizer) {
        _menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonPressed:)];
        _menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];

        _playPauseTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPlayPauseButtonPressed:)];
        _playPauseTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        
        _menuDoubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonDoublePressed:)];
        _menuDoubleTapGestureRecognizer.numberOfTapsRequired = 2;
        [_menuTapGestureRecognizer requireGestureRecognizerToFail:_menuDoubleTapGestureRecognizer];
        _menuDoubleTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    }
    
    [self.view addGestureRecognizer:_menuTapGestureRecognizer];
    [self.view addGestureRecognizer:_menuDoubleTapGestureRecognizer];
    [self.view addGestureRecognizer:_playPauseTapGestureRecognizer];

#else
    _exitSwipeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeSwiped)];
    _exitSwipeRecognizer.edges = UIRectEdgeLeft;
    _exitSwipeRecognizer.delaysTouchesBegan = NO;
    _exitSwipeRecognizer.delaysTouchesEnded = NO;
    
    [self.view addGestureRecognizer:_exitSwipeRecognizer];
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    [_tipLabel setText:ML(@"Tip: Swipe from the left edge to disconnect from your PC")];
#endif
    
    [_tipLabel sizeToFit];
    _tipLabel.textColor = [UIColor whiteColor];
    _tipLabel.textAlignment = NSTextAlignmentCenter;
    _tipLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height * 0.9);
    
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:_streamView
                                   connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidBecomeActive:)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidEnterBackground:)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];

#if 0
    // FIXME: This doesn't work reliably on iPad for some reason. Showing and hiding the keyboard
    // several times in a row will not correctly restore the state of the UIScrollView.
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillShow:)
                                                 name: UIKeyboardWillShowNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillHide:)
                                                 name: UIKeyboardWillHideNotification
                                               object: nil];
#endif
    
    // Pinch to zoom the picture in every touch mode; one-finger input still
    // goes to the stream, two fingers move around a zoomed picture
    BOOL zoomable = YES;
#if TARGET_OS_TV
    zoomable = _settings.absoluteTouchMode;
#endif
    if (zoomable) {
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.frame];
        _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        _scrollView.bouncesZoom = YES;
#if !TARGET_OS_TV
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        [_scrollView setMaximumZoomScale:5.0f];
        
        // Add StreamView inside a UIScrollView for absolute mode
        [_scrollView addSubview:_streamView];
        [self.view addSubview:_scrollView];
    }
    else {
        // Add StreamView directly in relative mode
        [self.view addSubview:_streamView];
    }
    
    [self.view addSubview:_stageLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_tipLabel];

#if !TARGET_OS_TV
    __weak typeof(self) weakSelf = self;
    __weak StreamView* weakStreamView = _streamView;
    UIButton* (^glassCircle)(NSString*, NSString*, void (^)(void)) = ^UIButton*(NSString* symbol, NSString* label, void (^handler)(void)) {
        UIButtonConfiguration* config;
        if (@available(iOS 26.0, *)) {
            config = [UIButtonConfiguration glassButtonConfiguration];
        }
        else {
            config = [UIButtonConfiguration grayButtonConfiguration];
        }
        config.image = [UIImage systemImageNamed:symbol];
        config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        config.baseForegroundColor = UIColor.whiteColor;
        config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightMedium];
        UIButton* button = [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(__kindof UIAction* action) {
            handler();
        }]];
        button.accessibilityLabel = label;
        return button;
    };
    _closeButton = glassCircle(@"xmark", ML(@"Stop"), ^{
        [weakSelf returnToMainFrame];
    });
    _keyboardButton = glassCircle(@"keyboard", ML(@"Keyboard"), ^{
        [weakSelf toggleTextInput];
    });
    // iOS's keyboard-dismiss symbol, at the keyboard's top right while it is open
    _hideKeyboardButton = glassCircle(@"keyboard.chevron.compact.down", ML(@"Hide Keyboard"), ^{
        [weakSelf toggleTextInput];
    });
    (void)weakStreamView;
    _resetViewButton = glassCircle(@"arrow.down.right.and.arrow.up.left", ML(@"Reset View"), ^{
        [weakSelf resetView];
    });
    _resetViewButton.hidden = YES;
    _panModeButton = glassCircle(@"hand.draw", @"映像を移動", ^{
        typeof(self) s = weakSelf;
        if (!s) return;
        BOOL enabled = !s->_streamView.panOnly;
        [s setPanMode:enabled];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, enabled ? @"指で映像を移動できます" : @"PCのタッチ操作に戻りました");
    });
    _specialKeysButton = glassCircle(@"command", ML(@"Special Keys"), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.view layoutIfNeeded];
        strongSelf->_specialKeysVisible = !strongSelf->_specialKeysVisible;
        [strongSelf.view setNeedsLayout];
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut animations:^{
            [strongSelf.view layoutIfNeeded];
        } completion:nil];
    });

    // Plain icon next to the close button, like video players
    UIButtonConfiguration* rotateConfig = [UIButtonConfiguration plainButtonConfiguration];
    rotateConfig.baseForegroundColor = UIColor.whiteColor;
    rotateConfig.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
    _rotateButton = [UIButton buttonWithConfiguration:rotateConfig primaryAction:[UIAction actionWithHandler:^(__kindof UIAction* action) {
        [weakSelf toggleOrientation];
    }]];
    _rotateButton.layer.shadowColor = UIColor.blackColor.CGColor;
    _rotateButton.layer.shadowOpacity = 0.6;
    _rotateButton.layer.shadowRadius = 4;
    _rotateButton.layer.shadowOffset = CGSizeZero;

    // PC keys on a dark glass panel, laid over the picture
    UIView* keys = [_streamView makeKeyBar];
    UIVisualEffectView* keyPanel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    keyPanel.layer.cornerRadius = 16;
    keyPanel.layer.cornerCurve = kCACornerCurveContinuous;
    keyPanel.clipsToBounds = YES;
    keys.translatesAutoresizingMaskIntoConstraints = NO;
    [keyPanel.contentView addSubview:keys];
    [NSLayoutConstraint activateConstraints:@[
        [keys.leadingAnchor constraintEqualToAnchor:keyPanel.contentView.leadingAnchor constant:6],
        [keys.trailingAnchor constraintEqualToAnchor:keyPanel.contentView.trailingAnchor constant:-6],
        [keys.topAnchor constraintEqualToAnchor:keyPanel.contentView.topAnchor constant:6],
        [keys.bottomAnchor constraintEqualToAnchor:keyPanel.contentView.bottomAnchor constant:-6],
    ]];
    _keyBar = keyPanel;
    [self createComposeBar];
    _trackpad = [[StreamTrackpadView alloc] initWithFrame:CGRectZero];
    for (UIView* view in @[_keyBar, _trackpad, _composeBar, _closeButton, _rotateButton, _panModeButton, _keyboardButton, _hideKeyboardButton, _specialKeysButton]) {
        view.hidden = YES; // Shown once the stream is running
        [self.view addSubview:view];
    }
    [self.view addSubview:_resetViewButton];
    // Stacking order, set once: trackpad, then the panels over it, then the
    // buttons. (Reordering during layout would trigger layout again.)
    for (UIView* view in @[_trackpad, _keyBar, _composeBar, _closeButton, _rotateButton, _panModeButton, _resetViewButton, _keyboardButton, _hideKeyboardButton, _specialKeysButton]) {
        [self.view bringSubviewToFront:view];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardFrameWillChange:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHideNotification:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
#endif
}

// Everything follows the view size, so the stream keeps working when the
// device rotates or the keyboard opens.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGRect streamFrame = bounds;
#if !TARGET_OS_TV
    BOOL portrait = bounds.size.height > bounds.size.width;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    const CGFloat button = 46, margin = 16;
    CGFloat left = MAX(safe.left, margin), right = MAX(safe.right, margin);
    CGFloat top = MAX(safe.top, margin) + (portrait ? 4 : 0);
    CGFloat bottom = MAX(safe.bottom, margin);
    _closeButton.frame = CGRectMake(left, top, button, button);
    _rotateButton.frame = CGRectMake(CGRectGetMaxX(_closeButton.frame) + 8, top, button, button);
    _keyboardButton.frame = CGRectMake(CGRectGetMaxX(bounds) - right - button, CGRectGetMaxY(bounds) - bottom - button, button, button);

    NSString* rotateSymbol = portrait ? @"rectangle.landscape.rotate" : @"rectangle.portrait.rotate";
    if (![_rotateSymbol isEqualToString:rotateSymbol]) {
        _rotateSymbol = rotateSymbol;
        UIButtonConfiguration* rotateConfig = _rotateButton.configuration;
        rotateConfig.image = [UIImage systemImageNamed:rotateSymbol];
        _rotateButton.configuration = rotateConfig;
    }
    _rotateButton.accessibilityLabel = portrait ? ML(@"Full Screen") : ML(@"Portrait");

    BOOL showControls = _streamRunning;
    _composeBar.hidden = !showControls || !_composing;
    CGFloat inputBottom = bounds.size.height - (_keyboardOverlap > 0 ? _keyboardOverlap : bottom);
    CGFloat composeHeight = _composing ? 100 : 0;
    _composeBar.frame = CGRectMake(left, inputBottom - composeHeight, MAX(0, bounds.size.width - left - right), composeHeight);
    CGFloat composeWidth = _composeBar.bounds.size.width;
    _composeField.frame = CGRectMake(8, 6, MAX(0, composeWidth - 84), 64);
    _sendTextButton.frame = CGRectMake(MAX(8, composeWidth - 68), 12, 60, 50);
    _composeHint.frame = CGRectMake(10, 72, MAX(0, composeWidth - 20), 24);
    _closeButton.hidden = _rotateButton.hidden = !showControls;
    _panModeButton.hidden = !showControls;
    _keyboardButton.hidden = !showControls || _keyboardOverlap > 0;
    _hideKeyboardButton.hidden = !showControls || _keyboardOverlap == 0;
    _hideKeyboardButton.frame = CGRectMake(CGRectGetMaxX(bounds) - right - button, CGRectGetMaxY(bounds) - _keyboardOverlap - 8 - button, button, button);
    _trackpad.hidden = !(portrait && showControls);
    _keyBar.hidden = !(showControls && _specialKeysVisible);
    _specialKeysButton.hidden = !showControls;
    if (_specialKeysButton.selected != _specialKeysVisible) {
        _specialKeysButton.selected = _specialKeysVisible;
        UIButtonConfiguration* keysConfig = _specialKeysButton.configuration;
        keysConfig.baseForegroundColor = _specialKeysVisible ? self.view.tintColor : UIColor.whiteColor;
        _specialKeysButton.configuration = keysConfig;
    }
    if (portrait) {
        // Picture right under the status bar, the PC keys under it, and the
        // rest down to the keyboard is a trackpad. The close and rotate
        // buttons sit in the trackpad's top left corner.
        const CGFloat gap = 8;
        // Room for the keys, the close row and the keyboard row when keys are shown
        CGFloat minTrackpad = _specialKeysVisible ? 220 : 140;
        CGFloat aspect = [_streamView videoAspectRatio];
        CGFloat videoTop = safe.top;
        CGFloat bottomEdge = inputBottom - composeHeight;
        // Always the full screen width; the trackpad takes what is left
        (void)minTrackpad;
        CGFloat videoWidth = bounds.size.width;
        CGFloat videoHeight = videoWidth / aspect;
        streamFrame = CGRectMake((bounds.size.width - videoWidth) / 2, videoTop, videoWidth, videoHeight);
        CGFloat trackpadTop = CGRectGetMaxY(streamFrame) + gap;
        // Special keys lie over the top of the trackpad; the close and rotate
        // buttons move below them while they are shown
        const CGFloat keyBarHeight = 96;
        CGFloat controlsTop = trackpadTop + 8 + (_specialKeysVisible ? keyBarHeight + 4 : 0);
        _trackpad.frame = CGRectMake(left - 8, trackpadTop, bounds.size.width - (left - 8) - (right - 8), MAX(60, bottomEdge - gap - trackpadTop));
        if ([[NSUserDefaults standardUserDefaults] boolForKey:MLControlsOnRightKey]) {
            // Option: close at the far right, rotate next to it
            _closeButton.frame = CGRectMake(CGRectGetMaxX(_trackpad.frame) - 8 - button, controlsTop, button, button);
            _rotateButton.frame = CGRectMake(CGRectGetMinX(_closeButton.frame) - 8 - button, controlsTop, button, button);
        }
        else {
            _closeButton.frame = CGRectMake(CGRectGetMinX(_trackpad.frame) + 8, controlsTop, button, button);
            _rotateButton.frame = CGRectMake(CGRectGetMaxX(_closeButton.frame) + 8, CGRectGetMinY(_closeButton.frame), button, button);
        }
        _keyboardButton.frame = CGRectMake(CGRectGetMaxX(_trackpad.frame) - 8 - button, CGRectGetMaxY(_trackpad.frame) - 8 - button, button, button);
        _hideKeyboardButton.frame = _keyboardButton.frame;
        // Special keys button next to the keyboard button
        _specialKeysButton.frame = CGRectMake(CGRectGetMinX(_keyboardButton.frame) - 8 - button, CGRectGetMinY(_keyboardButton.frame), button, button);
        _keyBar.frame = CGRectMake(CGRectGetMinX(_trackpad.frame), CGRectGetMinY(_trackpad.frame), CGRectGetWidth(_trackpad.frame), keyBarHeight);
    }
    else {
        // Landscape: the picture stays full screen under the keyboard. While
        // typing, the input box sits on the keyboard and the buttons above it.
        const CGFloat keyBarHeight = 96;
        CGFloat rowBottom = CGRectGetMaxY(bounds) - bottom;
        if (_keyboardOverlap > 0) {
            rowBottom = bounds.size.height - _keyboardOverlap - 8;
        }
        rowBottom -= composeHeight;
        _keyboardButton.frame = CGRectMake(CGRectGetMaxX(bounds) - right - button, rowBottom - button, button, button);
        _hideKeyboardButton.frame = _keyboardButton.frame;
        _specialKeysButton.frame = CGRectMake(CGRectGetMinX(_keyboardButton.frame) - 8 - button, CGRectGetMinY(_keyboardButton.frame), button, button);
        CGFloat keysRight = CGRectGetMinX(_specialKeysButton.frame) - 8;
        _keyBar.frame = CGRectMake(left, rowBottom - keyBarHeight, MAX(200, keysRight - left), keyBarHeight);
        if (_keyboardOverlap > 0 && MLBoolPreference(MLShiftForKeyboardKey, NO)) {
            // Keep the picture's lower edge above the keyboard, preserving scale.
            CGFloat scaledHeight = bounds.size.width / [_streamView videoAspectRatio];
            NSInteger fillMode = MLVideoFillMode();
            CGFloat pictureHeight = fillMode == 1 ? MAX(bounds.size.height, scaledHeight) :
                fillMode == 2 ? bounds.size.height : MIN(bounds.size.height, scaledHeight);
            CGFloat lowerMargin = MAX(0, (bounds.size.height - pictureHeight) / 2);
            streamFrame.origin.y -= MAX(0, _keyboardOverlap + composeHeight - lowerMargin);
        }
    }
    _panModeButton.frame = CGRectMake(CGRectGetMaxX(_rotateButton.frame) + 8, CGRectGetMinY(_rotateButton.frame), button, button);
    _resetViewButton.frame = CGRectMake(CGRectGetMaxX(_panModeButton.frame) + 8, CGRectGetMinY(_rotateButton.frame), button, button);
    if ([[NSUserDefaults standardUserDefaults] boolForKey:MLControlsOnRightKey] && portrait) {
        _panModeButton.frame = CGRectMake(CGRectGetMinX(_rotateButton.frame) - 8 - button, CGRectGetMinY(_rotateButton.frame), button, button);
        _resetViewButton.frame = CGRectMake(CGRectGetMinX(_panModeButton.frame) - 8 - button, CGRectGetMinY(_rotateButton.frame), button, button);
    }

#endif
    if (_scrollView != nil) {
        BOOL viewportChanged = !CGSizeEqualToSize(_scrollView.bounds.size, streamFrame.size);
        _scrollView.frame = streamFrame;
        if (_scrollView.zoomScale == 1.0) {
            _streamView.frame = CGRectMake(0, 0, streamFrame.size.width, streamFrame.size.height);
            _scrollView.contentSize = streamFrame.size;
            if (viewportChanged) [_scrollView setContentOffset:CGPointZero animated:NO];
        }
    }
    else {
        _streamView.frame = streamFrame;
    }
#if !TARGET_OS_TV
    [self updateZoomRoom];
#endif

    _stageLabel.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    _spinner.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds) - _stageLabel.frame.size.height - _spinner.frame.size.height);
    _tipLabel.center = CGPointMake(CGRectGetMidX(bounds), bounds.size.height * 0.9);

}

#if !TARGET_OS_TV
- (void)keyboardFrameWillChange:(NSNotification*)notification {
    CGRect keyboard = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.view convertRect:keyboard fromCoordinateSpace:self.view.window.screen.coordinateSpace];
    CGRect overlap = CGRectIntersection(self.view.bounds, local);
    _keyboardOverlap = CGRectIsNull(overlap) || CGRectGetMaxY(local) < CGRectGetMaxY(self.view.bounds) - 1 ? 0 : overlap.size.height;
    [self.view setNeedsLayout];
    UIViewAnimationOptions options = ([notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16) | UIViewAnimationOptionBeginFromCurrentState;
    [UIView animateWithDuration:[notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] delay:0 options:options animations:^{
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)keyboardWillHideNotification:(NSNotification*)notification {
    _keyboardOverlap = 0;
    [self.view setNeedsLayout];
    UIViewAnimationOptions options = ([notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16) | UIViewAnimationOptionBeginFromCurrentState;
    [UIView animateWithDuration:[notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] delay:0 options:options animations:^{
        [self.view layoutIfNeeded];
    } completion:nil];
}

// Text input happens in portrait. Rotate before the keyboard opens and go
// back to the previous landscape orientation once it closes.
- (void)streamKeyboardWillOpen {
    // Typing works in both orientations now; nothing to rotate
}

- (void)streamKeyboardDidClose {
    // Stay in the current orientation; the rotate button or turning the
    // device switches to landscape
    ((AppDelegate*)[UIApplication sharedApplication].delegate).orientationLock = 0;
    _orientationBeforeKeyboard = UIInterfaceOrientationUnknown;
}

// ---- Zoom and pan

- (void)setPanMode:(BOOL)enabled {
    _streamView.panOnly = enabled;
    _panModeButton.selected = enabled;
    UIButtonConfiguration *configuration = _panModeButton.configuration;
    configuration.baseForegroundColor = enabled ? UIColor.systemBlueColor : UIColor.whiteColor;
    _panModeButton.configuration = configuration;
    _panModeButton.accessibilityLabel = enabled ? @"映像移動中・タップでPC操作に戻る" : @"映像を移動";
    [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:enabled ? 1 : 2];
    [self updateZoomRoom];
}

// While zoomed, the picture may be dragged past the screen edge
// (two fingers), e.g. to bring what the keyboard covers into view. At least
// a quarter of it stays on screen, and the reset button brings it back.
- (void)updateZoomRoom {
    if (_scrollView == nil) {
        return;
    }
    BOOL free = _scrollView.zoomScale > 1.01 || _streamView.panOnly;
    CGSize size = _scrollView.bounds.size;
    UIEdgeInsets room = free ? UIEdgeInsetsMake(size.height * 0.75, size.width * 0.75, size.height * 0.75, size.width * 0.75) : UIEdgeInsetsZero;
    if (!UIEdgeInsetsEqualToEdgeInsets(_scrollView.contentInset, room)) {
        // UIKit moves a scroll view that rests at its top to the new inset's
        // top, which would push the picture off screen. Keep it where it was.
        CGPoint offset = _scrollView.contentOffset;
        _scrollView.contentInset = room;
        if (free) {
            _scrollView.contentOffset = offset;
        }
        else {
            [_scrollView setContentOffset:CGPointZero animated:NO];
        }
    }
    [self updateResetButton];
}

- (void)updateResetButton {
    BOOL moved = _scrollView != nil && (_scrollView.zoomScale > 1.01 ||
                                        fabs(_scrollView.contentOffset.x) > 2 || fabs(_scrollView.contentOffset.y) > 2);
    _resetViewButton.hidden = !(_streamRunning && moved);
}

- (void)resetView {
    [_scrollView setZoomScale:1.0 animated:YES];
    [_scrollView setContentOffset:CGPointZero animated:YES];
    [self updateZoomRoom];
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    if (scrollView != _scrollView) return;
    [self updateZoomRoom];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != _scrollView) return;
    [self updateResetButton];
}

// Compose locally. Only the explicit Send action forwards text to the PC.

- (void)createComposeBar {
    _composeBar = [[UIView alloc] init];
    _composeBar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    _composeBar.layer.cornerRadius = 14;
    _composeField = [[StreamComposeTextView alloc] init];
    _composeField.delegate = self;
    _composeField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _composeField.textColor = UIColor.whiteColor;
    _composeField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _composeField.layer.cornerRadius = 8;
    _composeField.draftText = @"";
    _composeField.autocorrectionType = UITextAutocorrectionTypeDefault;
    _composeField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _composeField.accessibilityLabel = @"PCへ送る文字列";
    _composeHint = [[UILabel alloc] init];
    _composeHint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    _composeHint.textColor = UIColor.secondaryLabelColor;
    _composeHint.text = [self composeInputHint];
    _composeHint.adjustsFontSizeToFitWidth = YES;
    _composeHint.minimumScaleFactor = 0.8;
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = @"送信";
    __weak typeof(self) weakSelf = self;
    _composeField.canDeleteRemote = ^BOOL{
        typeof(self) s = weakSelf;
        return s && s->_streamRunning && !s->_textSendPending;
    };
    _composeField.onEmptyDelete = ^{
        typeof(self) s = weakSelf;
        if (!s || !s->_streamRunning || s->_textSendPending) return;
        [s->_streamView sendTextBackspace:^(int result) {
            typeof(self) current = weakSelf;
            if (current && result != 0 && current->_composeField.isFirstResponder) {
                current->_composeHint.text = @"削除を送れません。接続を確認してください";
            }
        }];
    };
    _sendTextButton = [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        [weakSelf sendComposedText];
    }]];
    _sendTextButton.enabled = NO;
    for (UIView *view in @[_composeField, _sendTextButton, _composeHint]) [_composeBar addSubview:view];
}

- (void)sendComposedText {
    if (_textSendPending || !_streamRunning) return;
    // Finish the local composition once, without relaying intermediate edits.
    [_composeField unmarkText];
    [_composeField restoreDeleteAnchor];
    NSString *text = [_composeField.draftText copy];
    if (!text.length) return;
    _textSendPending = YES;
    _sendTextButton.enabled = NO;
    __weak typeof(self) weakSelf = self;
    [_streamView sendCommittedText:text completion:^(int result) {
        typeof(self) s = weakSelf;
        if (!s) return;
        s->_textSendPending = NO;
        if (result == 0) {
            // Preserve edits made while the send was queued.
            if ([s->_composeField.draftText isEqualToString:text] && s->_composeField.markedTextRange == nil) {
                s->_composeField.draftText = @"";
            }
            s->_composeHint.text = [s composeInputHint];
        } else {
            s->_composeHint.text = @"送信できません。接続を確認してください";
        }
        s->_sendTextButton.enabled = s->_composeField.draftText.length > 0;
    }];
}

- (void)textViewDidChange:(UITextView *)textView {
    if (textView != _composeField) return;
    [_composeField restoreDeleteAnchor];
    _sendTextButton.enabled = !_textSendPending && _composeField.draftText.length > 0;
}

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    if (textView == _composeField) {
        [_composeField prepareForChangeInRange:range replacementText:text];
    }
    return YES;
}

- (void)textViewDidChangeSelection:(UITextView *)textView {
    if (textView == _composeField) [_composeField keepSelectionInDraft];
}

- (NSString *)composeInputHint {
    return MLBoolPreference(MLImeOffBeforeTextSendKey, YES) ?
        @"iPhoneで変換・確定してから「送信」" : @"PCの日本語入力はOFF（A）にしてください";
}

- (void)textViewDidBeginEditing:(UITextView *)textView {
    if (textView != _composeField) return;
    [_composeField restoreDeleteAnchor];
    [_composeField keepSelectionInDraft];
    _composeHint.text = [self composeInputHint];
}

- (void)textViewDidEndEditing:(UITextView *)textView {
    _composing = NO;
    [self.view setNeedsLayout];
}

- (void)streamToggleTextInput {
    [self toggleTextInput];
}

- (BOOL)textInputVisible {
    return _composing;
}

- (void)toggleTextInput {
    if (_composing) {
        [_composeField resignFirstResponder];
        _composing = NO;
    } else {
        _composing = YES;
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        _composing = [_composeField becomeFirstResponder];
    }
    [self.view setNeedsLayout];
}

- (void)streamSettingsRequested {
    MoonlightSettingsViewController* settings = [[MoonlightSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    settings.duringStream = YES;
    UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:settings];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    __weak typeof(self) weakSelf = self;
    settings.onClose = ^{
        // Button position may have changed
        [weakSelf.view setNeedsLayout];
    };
    [self presentViewController:navigation animated:YES completion:nil];
}
#endif

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    // The input box is a scroll view with the same delegate; only the stream zooms
    return scrollView == _scrollView ? _streamView : nil;
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
        [_controllerSupport cleanup];
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
#if !TARGET_OS_TV
        // The destination home controller selects portrait during appearance.
#endif
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

#if 0
- (void)keyboardWillShow:(NSNotification *)notification {
    _keyboardSize = [[[notification userInfo] objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;

    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height -= self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}

-(void)keyboardWillHide:(NSNotification *)notification {
    // NOTE: UIKeyboardFrameEndUserInfoKey returns a different keyboard size
    // than UIKeyboardFrameBeginUserInfoKey, so it's unsuitable for use here
    // to undo the changes made by keyboardWillShow.
    
    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height += self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}
#endif

- (void)updateStatsOverlay {
    NSString* overlayText = [self->_streamMan getStatsOverlayText];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateOverlayText:overlayText];
    });
}

- (void)updateOverlayText:(NSString*)text {
    if (_overlayView == nil) {
        _overlayView = [[UITextView alloc] init];
#if !TARGET_OS_TV
        [_overlayView setEditable:NO];
#endif
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setSelectable:NO];
        [_overlayView setScrollEnabled:NO];
        
        // HACK: If not using stats overlay, center the text
        if (_statsUpdateTimer == nil) {
            [_overlayView setTextAlignment:NSTextAlignmentCenter];
        }
        
        [_overlayView setTextColor:[UIColor lightGrayColor]];
        [_overlayView setBackgroundColor:[UIColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24]];
#else
        [_overlayView setFont:[UIFont systemFontOfSize:12]];
#endif
        [_overlayView setAlpha:0.5];
        [self.view addSubview:_overlayView];
    }
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(self.view.frame.origin.x,
                                           _overlayView.frame.origin.y,
                                           self.view.frame.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2, _overlayView.frame.size.height / 2)];
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
    // Reset display mode back to default
    [self updatePreferredDisplayMode:NO];
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
}

- (void)streamVideoSizeChanged {
    [self.view setNeedsLayout];
}

// This will fire if the user opens control center or gets a low battery message
- (void)applicationWillResignActive:(NSNotification *)notification {
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
    }
    
#if !TARGET_OS_TV
    // Terminate the stream if the app is inactive for 60 seconds
    Log(LOG_I, @"Starting inactivity termination timer");
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      target:self
                                                    selector:@selector(inactiveTimerExpired:)
                                                    userInfo:nil
                                                     repeats:NO];
#endif
}

- (void)inactiveTimerExpired:(NSTimer*)timer {
    Log(LOG_I, @"Terminating stream after inactivity");

    [self returnToMainFrame];
    
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(UIApplication *)application {
    Log(LOG_I, @"Terminating stream immediately for backgrounding");

    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
    
    [self returnToMainFrame];
}

- (void)edgeSwiped {
    Log(LOG_I, @"User swiped to end stream");
    
    [self returnToMainFrame];
}

- (void) connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
        // Leave the spinner spinning until it's obscured by
        // the first frame of video.
        self->_stageLabel.hidden = YES;
        self->_tipLabel.hidden = YES;
#if !TARGET_OS_TV
        self->_streamRunning = YES;
        [self setPanMode:MLBoolPreference(MLPanOnStartKey, YES)];
        [self.view setNeedsLayout];
        [self showControlsTemporarily];
        BOOL portrait = self.view.bounds.size.height > self.view.bounds.size.width;
        NSNumber* showKeyboard = [[NSUserDefaults standardUserDefaults] objectForKey:@"ShowKeyboardOnStreamStart"];
        if (portrait && (showKeyboard == nil || showKeyboard.boolValue) && ![self textInputVisible]) {
            [self toggleTextInput];
        }
#endif
        
        [self->_streamView showOnScreenControls];
        
        [self->_controllerSupport connectionEstablished];
        
        if (self->_settings.statsOverlay) {
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);
    
    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* title;
        NSString* message;
        
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = ML(@"Connection Error");
            message = ML(@"Your device's network connection is blocking Moonlight. Streaming may not work while connected to this network.");
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = ML(@"Connection Error");
                    message = ML(@"No video received from host.");
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[NSString stringWithFormat:[@"\n\n" stringByAppendingString:ML(@"Check your firewall and port forwarding rules for port(s):\n%s")], failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = ML(@"Connection Error");
                    message = ML(@"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection.");
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = ML(@"Connection Error");
                    message = ML(@"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.");
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = ML(@"Connection Error");
                    message = ML(@"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.");
                    break;
                    
                default:
                {
                    NSString* errorString;
                    if (abs(errorCode) > 1000) {
                        // We'll assume large errors are hex values
                        errorString = [NSString stringWithFormat:@"%08X", (uint32_t)errorCode];
                    }
                    else {
                        // Smaller values will just be printed as decimal (probably errno.h values)
                        errorString = [NSString stringWithFormat:@"%d", errorCode];
                    }
                    
                    title = ML(@"Connection Terminated");
                    message = [NSString stringWithFormat:ML(@"The connection was terminated\n\nError code: %@"), errorString];
                    break;
                }
            }
        }
        
        UIAlertController* conTermAlert = [UIAlertController alertControllerWithTitle:title
                                                                              message:message
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:conTermAlert];
        [conTermAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:conTermAlert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void) stageStarting:(const char*)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* lowerCase = [NSString stringWithFormat:ML(@"%@ in progress..."), ML([NSString stringWithUTF8String:stageName])];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
    
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* message = [NSString stringWithFormat:ML(@"%@ failed with error %d"), ML([NSString stringWithUTF8String:stageName]), errorCode];
        if (portTestFlags != 0) {
            char failingPorts[256];
            LiStringifyPortFlags(portTestFlags, "\n", failingPorts, sizeof(failingPorts));
            message = [message stringByAppendingString:[NSString stringWithFormat:[@"\n\n" stringByAppendingString:ML(@"Check your firewall and port forwarding rules for port(s):\n%s")], failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:[@"\n\n" stringByAppendingString:ML(@"Your device's network connection is blocking Moonlight. Streaming may not work while connected to this network.")]];
        }
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:ML(@"Connection Failed")
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:ML(@"Connection Error")
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    Log(LOG_I, @"Rumble on gamepad %d: %04x %04x", controllerNumber, lowFreqMotor, highFreqMotor);
    
    [_controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

- (void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger {
    Log(LOG_I, @"Trigger rumble on gamepad %d: %04x %04x", controllerNumber, leftTrigger, rightTrigger);
    
    [_controllerSupport rumbleTriggers:controllerNumber leftTrigger:leftTrigger rightTrigger:rightTrigger];
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    Log(LOG_I, @"Set motion state on gamepad %d: %02x %u Hz", controllerNumber, motionType, reportRateHz);
    
    [_controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

- (void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    Log(LOG_I, @"Set controller LED on gamepad %d: l%02x%02x%02x", controllerNumber, r, g, b);
    
    [_controllerSupport setControllerLed:controllerNumber r:r g:g b:b];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    // The stats overlay takes precedence over these warnings
    if (_statsUpdateTimer != nil) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;
                
            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:ML(@"Slow connection to PC\nReduce your bitrate")];
                }
                else {
                    [self updateOverlayText:ML(@"Poor connection to PC")];
                }
                break;
        }
    });
}

- (void) updatePreferredDisplayMode:(BOOL)streamActive {
#if TARGET_OS_TV
    if (@available(tvOS 11.2, *)) {
        UIWindow* window = [[[UIApplication sharedApplication] delegate] window];
        AVDisplayManager* displayManager = [window avDisplayManager];
        
        // This logic comes from Kodi and MrMC
        if (streamActive) {
            int dynamicRange;
            
            if (LiGetCurrentHostDisplayHdrMode()) {
                dynamicRange = 2; // HDR10
            }
            else {
                dynamicRange = 0; // SDR
            }
            
            AVDisplayCriteria* displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:[_settings.framerate floatValue]
                                                                              videoDynamicRange:dynamicRange];
            displayManager.preferredDisplayCriteria = displayCriteria;
        }
        else {
            // Switch back to the default display mode
            displayManager.preferredDisplayCriteria = nil;
        }
    }
#endif
}

- (void) setHdrMode:(bool)enabled {
    Log(LOG_I, @"HDR is now: %s", enabled ? "active" : "inactive");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePreferredDisplayMode:YES];
    });
}

- (void) videoContentShown {
    [_spinner stopAnimating];
    [self.view setBackgroundColor:[UIColor blackColor]];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)mousePresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 14.0, *)) {
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
#endif
}

- (void) streamExitRequested {
    Log(LOG_I, @"Gamepad combo requested stream exit");
    
    [self returnToMainFrame];
}

#if !TARGET_OS_TV
- (void)toggleOrientation {
    BOOL portrait = self.view.bounds.size.height > self.view.bounds.size.width;
    [(AppDelegate*)[UIApplication sharedApplication].delegate rotateToOrientations:portrait ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskPortrait];
    [self showControlsTemporarily];
}

// The overlay controls stay visible in every orientation
- (void)showControlsTemporarily {
    for (UIView* view in @[_closeButton, _rotateButton, _keyboardButton]) {
        view.alpha = 1;
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    // A zoom made for the old size makes no sense after rotating
    [_scrollView setZoomScale:1.0 animated:NO];
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self showControlsTemporarily];
    }];
}
#endif

- (void)userInteractionBegan {
#if !TARGET_OS_TV
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showControlsTemporarily];
    });
#endif
    // Disable hiding home bar when user is interacting.
    // iOS will force it to be shown anyway, but it will
    // also discard our edges deferring system gestures unless
    // we willingly give up home bar hiding preference.
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    // Enable home bar hiding again if conditions allow
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

#if !TARGET_OS_TV
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    // Nothing deferred: one swipe up goes to the iPhone home screen, one swipe
    // down opens notifications
    return UIRectEdgeNone;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    if ([_controllerSupport getConnectedGamepadCount] > 0 &&
        [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        _userIsInteracting == NO) {
        // Autohide the home bar when a gamepad is connected
        // and the on-screen controls are disabled. We can't
        // do this all the time because any touch on the display
        // will cause the home indicator to reappear, and our
        // preferredScreenEdgesDeferringSystemGestures will also
        // be suppressed (leading to possible errant exits of the
        // stream).
        return YES;
    }
    
    return NO;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return [GCMouse mice].count > 0;
}
#endif

@end
