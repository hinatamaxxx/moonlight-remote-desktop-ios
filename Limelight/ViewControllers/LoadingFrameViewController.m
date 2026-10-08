//
//  LoadingFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/24/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "LoadingFrameViewController.h"
#import "Localization.h"

@implementation LoadingFrameViewController {
    BOOL presented;
#if !TARGET_OS_TV
    UIVisualEffectView* _card;
    UILabel* _messageLabel;
    UILabel* _hintLabel;
    NSUInteger _generation;
#endif
};

- (void)viewDidLoad {
    [super viewDidLoad];

#if !TARGET_OS_TV
    // A card that says what is happening, instead of a bare spinner
    UIBlurEffect* blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    _card = [[UIVisualEffectView alloc] initWithEffect:blur];
    _card.layer.cornerRadius = 22;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    [self.view insertSubview:_card belowSubview:self.loadingSpinner];

    _messageLabel = [[UILabel alloc] init];
    _messageLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _messageLabel.textColor = UIColor.whiteColor;
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageLabel.numberOfLines = 0;
    [_card.contentView addSubview:_messageLabel];

    _hintLabel = [[UILabel alloc] init];
    _hintLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _hintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.numberOfLines = 0;
    _hintLabel.text = ML(@"This is taking a while. Check that the PC and Sunshine are running.");
    _hintLabel.hidden = YES;
    [_card.contentView addSubview:_hintLabel];

    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
#endif
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
#if !TARGET_OS_TV
    _messageLabel.text = self.message;
    _hintLabel.hidden = YES;
    // Explain long waits instead of spinning silently
    NSUInteger generation = ++_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->presented && generation == self->_generation) {
            self->_hintLabel.hidden = NO;
            [self.view setNeedsLayout];
        }
    });
    [self.view setNeedsLayout];
#endif
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGPoint center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2);
#if !TARGET_OS_TV
    const CGFloat width = MIN(300, self.view.bounds.size.width - 48), padding = 20;
    CGSize message = [_messageLabel sizeThatFits:CGSizeMake(width - 2 * padding, CGFLOAT_MAX)];
    CGSize hint = _hintLabel.hidden ? CGSizeZero : [_hintLabel sizeThatFits:CGSizeMake(width - 2 * padding, CGFLOAT_MAX)];
    CGFloat spinnerHeight = self.loadingSpinner.bounds.size.height;
    CGFloat height = padding + spinnerHeight + 14 + message.height + (hint.height > 0 ? 8 + hint.height : 0) + padding;
    _card.frame = CGRectMake(center.x - width / 2, center.y - height / 2, width, height);
    self.loadingSpinner.center = CGPointMake(center.x, _card.frame.origin.y + padding + spinnerHeight / 2);
    _messageLabel.frame = CGRectMake(padding, padding + spinnerHeight + 14, width - 2 * padding, message.height);
    _hintLabel.frame = CGRectMake(padding, CGRectGetMaxY(_messageLabel.frame) + 8, width - 2 * padding, hint.height);
#else
    self.loadingSpinner.center = center;
#endif
}

- (UIViewController*) activeViewController {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    
    return topController;
}

- (void)showLoadingFrame:(void (^)(void))completion {
    if (!presented) {
        Log(LOG_I, @"Loading frame presenting start");
        presented = YES;
        [[self activeViewController] presentViewController:self animated:NO completion:^{
            Log(LOG_I, @"Loading frame presenting complete");
            if (completion) {
                completion();
            }
        }];
    }
    else if (completion) {
        Log(LOG_E, @"Loading frame already shown!");
        completion();
    }
}

- (void)dismissLoadingFrame:(void (^)(void))completion {
    if (presented) {
        Log(LOG_I, @"Loading frame hiding start");
        [self dismissViewControllerAnimated:NO completion:^{
            Log(LOG_I, @"Loading frame hiding complete");
            
            // Since presented is set to NO here rather than
            // immediately in dismissLoadingFrame, we may
            // falsely avoid displaying the loading frame if
            // a dismiss is in progress while attempting to show
            // the frame. That's preferable to crashing due to
            // displaying the same VC twice though.
            //
            // This scenario can happen if the app is suspended
            // while the dismiss is in progress then on resume
            // it attempts to display it again before the dismiss
            // completes. It can be reproduced by rapidly pressing
            // Home and switching back to Moonlight while in the app grid.
            // It reproduces more easily if the VC transitions are animated.
            self->presented = NO;
            
            if (completion) {
                completion();
            }
        }];
    }
    else if (completion) {
        completion();
    }
}

- (BOOL)isShown {
    return presented;
}

@end
