//
//  StreamView.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import "Moonlight-Swift.h"
#import "StreamConfiguration.h"

@protocol UserInteractionDelegate <NSObject>

- (void) userInteractionBegan;
- (void) userInteractionEnded;

@optional
- (void) streamVideoSizeChanged;
// Text input happens in portrait; the stream view reports the keyboard so
// its controller can rotate before it opens and restore after it closes.
- (void) streamKeyboardWillOpen;
- (void) streamKeyboardDidClose;
// The settings key in the PC key bar
- (void) streamSettingsRequested;
- (void) streamToggleTextInput;

@end

#if TARGET_OS_TV
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>
#else
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate>
#endif
@property (nonatomic) BOOL panOnly;

- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig;
- (void) showOnScreenControls;
- (OnScreenControlsLevel) getCurrentOscState;
- (void) toggleKeyboard;
- (BOOL) isKeyboardVisible;
- (void)sendCommittedText:(NSString*)text completion:(void (^)(int result))completion;
- (void)sendTextBackspace:(void (^)(int result))completion;
// Where the picture is drawn inside this view (fit, fill or stretch)
- (CGSize) getVideoAreaSize;
- (CGFloat) videoAspectRatio;
- (void) updateVideoSize:(CGSize)size;
#if !TARGET_OS_TV
// PC keys (Esc, Tab, Ctrl, arrows...) as a view to place under the picture
- (UIView*) makeKeyBar;
#endif

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse;
#endif

@end
