#import <UIKit/UIKit.h>
@class TemporaryHost;

// The tvOS build stays independent of the iOS-only bridge.
@interface EmbeddedTailscale : NSObject
+ (BOOL)matchesAddress:(NSString *)address;
+ (NSString *)routedAddress:(NSString *)address;
+ (NSString *)connectionAddressForHost:(TemporaryHost *)host;
// Shows sign-in and the tailnet's PCs. The handler runs on the main thread
// after the user picked a PC and the relay points at it.
+ (void)presentFrom:(UIViewController *)controller onPeerSelected:(void (^)(NSString *address))handler;
// Sheet to choose the PC and pair with it. finished(YES) after pairing closes
// the sheet; finished(NO) keeps it open to try again.
+ (void)presentPickerFrom:(UIViewController *)controller onConnect:(void (^)(NSString *address, void (^finished)(BOOL paired)))onConnect;
// The same screen for a tab: a navigation controller without a close button.
+ (UIViewController *)tabControllerOnPeerSelected:(void (^)(NSString *address))handler;
+ (void)restore;
// Tailscale's dotted logo as a template image
+ (UIImage *)logoImage;
// For a PC added through Tailscale: 0 automatic (LAN first), 1 LAN only, 2 Tailscale only
+ (NSInteger)routePreferenceForHost:(TemporaryHost *)host;
// 100.64.0.0/10 or Tailscale's IPv6 range
+ (BOOL)isTailscaleAddress:(NSString *)address;
// The PC's LAN address when Tailscale currently reaches it directly on the
// same network, otherwise nil. Blocking; call off the main thread.
+ (NSString *)lanAddressForPeer:(NSString *)address;
// Wi-Fi/wired vs. cellular. Off the local network the LAN addresses are
// skipped, and the node is told to find a new path right away.
+ (void)networkChanged:(BOOL)onLocalNetwork;
+ (BOOL)onLocalNetwork;
+ (void)setOnLocalNetwork:(BOOL)onLocalNetwork;
+ (void)setRoutePreference:(NSInteger)preference forHost:(TemporaryHost *)host;
@end
