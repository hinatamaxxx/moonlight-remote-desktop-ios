#import "EmbeddedTailscale.h"
#import "TemporaryHost.h"
#import "Utils.h"
#import <SafariServices/SafariServices.h>

extern char *MTStart(const char *);
extern char *MTSetPeer(const char *);
extern char *MTStatus(int);
extern char *MTLogout(void);
extern char *MTProbe(const char *);
extern void MTNetworkChanged(void);
extern void MTStop(void);
extern void MTFree(void *);

static NSString *const PeerKey = @"EmbeddedTailscalePeer";
static NSString *const EnabledKey = @"EmbeddedTailscaleEnabled";
static dispatch_queue_t bridgeQueue;
static NSString *startupError; // Only accessed on bridgeQueue

// Takes ownership of a bridge string.
static NSString *BridgeString(char *value) {
    NSString *string = value ? [NSString stringWithUTF8String:value] : nil;
    MTFree(value);
    return string;
}

// Only official HTTPS login URLs may be opened.
static NSURL *OfficialLoginURL(id value) {
    NSURL *url = [value isKindOfClass:NSString.class] && [value length] ? [NSURL URLWithString:value] : nil;
    if ([url.scheme isEqualToString:@"https"] && ([url.host isEqualToString:@"login.tailscale.com"] || [url.host isEqualToString:@"controlplane.tailscale.com"])) {
        return url;
    }
    return nil;
}

static UIImage *SymbolImage(NSString *name, UIColor *color) {
    return [[UIImage systemImageNamed:name] imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
}

@interface EmbeddedTailscale ()
+ (NSString *)startNode;
+ (NSString *)setPeer:(NSString *)peer;
+ (NSDictionary *)probe:(NSString *)peer;
+ (void)status:(BOOL)login completion:(void (^)(NSDictionary *status))completion;
@end

typedef NS_ENUM(NSInteger, TailscaleRow) {
    TailscaleRowStatus,
    TailscaleRowError,
    TailscaleRowLogin,
    TailscaleRowOpenLogin,
    TailscaleRowOpenInSafari,
    TailscaleRowCopyLogin,
    TailscaleRowPeer,
    TailscaleRowNoPeers,
    TailscaleRowManual,
    TailscaleRowTest,
    TailscaleRowStop,
    TailscaleRowLogout,
    TailscaleRowHistory,
};

@interface EmbeddedTailscaleViewController : UITableViewController
@property (nonatomic, copy) void (^onPeerSelected)(NSString *address);
// Shown as a tab instead of a sheet: no close button, stays open after a PC is picked
@property (nonatomic) BOOL embedded;
// Sheet: called with the chosen PC after "Connect"; finished(YES) once paired
// closes the sheet, finished(NO) keeps it open for another try.
@property (nonatomic, copy) void (^onConnect)(NSString *address, void (^finished)(BOOL paired));
@end

@implementation EmbeddedTailscaleViewController {
    NSDictionary *_status;
    NSArray<NSDictionary *> *_sections; // title, footer, rows
    NSTimer *_timer;
    BOOL _polling;
    BOOL _loginRequested;
    NSString *_busyText;
    NSString *_openedAuthURL;
    NSString *_lastProbeSummary;
    NSString *_pendingPeer; // Sheet: the PC chosen, connected with the "Connect" button
    NSTimer *_busyTimer;
    NSTimeInterval _busyStarted;
    BOOL _closed;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.embedded ? @"Tailscale" : @"Tailscaleで追加";
    if (!self.embedded) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"キャンセル" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"接続" style:UIBarButtonItemStyleDone target:self action:@selector(connectPendingPeer)];
        self.navigationItem.rightBarButtonItem.enabled = NO;
    }
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];
    self.tableView.estimatedRowHeight = 56;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    [self rebuild];
    [self poll];

    // Keeps polling while the sign-in page is shown on top of this screen
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        if (weakSelf == nil) {
            [timer invalidate];
            return;
        }
        [weakSelf poll];
    }];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(poll) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.navigationController.isBeingDismissed || self.isBeingDismissed) {
        _closed = YES;
        [_busyTimer invalidate];
        [_timer invalidate];
    }
}

- (void)dealloc {
    [_busyTimer invalidate];
    [_timer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)close {
    _closed = YES;
    [_busyTimer invalidate];
    [_timer invalidate];
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - State

- (NSString *)state {
    return _status[@"state"] ?: @"Off";
}

- (BOOL)isRunning {
    return [self.state isEqualToString:@"Running"];
}

- (NSURL *)authURL {
    return self.isRunning ? nil : OfficialLoginURL(_status[@"authURL"]);
}

- (NSArray<NSDictionary *> *)peers {
    NSArray *peers = _status[@"peers"];
    return [peers isKindOfClass:NSArray.class] ? peers : @[];
}

- (void)poll {
    if (_polling || _closed) {
        return;
    }
    _polling = YES;
    [EmbeddedTailscale status:_loginRequested completion:^(NSDictionary *status) {
        self->_polling = NO;
        [self.refreshControl endRefreshing];
        [self applyStatus:status];
    }];
}

- (void)pullToRefresh {
    _polling = NO;
    [self poll];
}

- (void)applyStatus:(NSDictionary *)status {
    if (_closed) return;
    _status = status;
    if (self.isRunning) {
        _loginRequested = NO;
        // Sign-in finished; return to the PC list automatically
        if ([self.presentedViewController isKindOfClass:SFSafariViewController.class]) {
            [self dismissViewControllerAnimated:YES completion:nil];
        }
    }
    else if (_loginRequested && self.authURL != nil && ![self.authURL.absoluteString isEqualToString:_openedAuthURL]) {
        _openedAuthURL = self.authURL.absoluteString;
        [self openLoginPage];
    }
    [self rebuild];
}

#pragma mark - Table model

- (void)rebuild {
    NSMutableArray *sections = [NSMutableArray array];
    NSString *state = self.state;
    BOOL running = self.isRunning;

    NSMutableArray *account = [NSMutableArray arrayWithObject:@{@"kind": @(TailscaleRowStatus)}];
    if ([self errorText].length) {
        [account addObject:@{@"kind": @(TailscaleRowError)}];
    }
    if (!running && _busyText == nil) {
        [account addObject:@{@"kind": @(TailscaleRowLogin)}];
    }
    if (self.authURL != nil) {
        [account addObject:@{@"kind": @(TailscaleRowOpenLogin)}];
        [account addObject:@{@"kind": @(TailscaleRowOpenInSafari)}];
        [account addObject:@{@"kind": @(TailscaleRowCopyLogin)}];
    }
    [sections addObject:@{@"title": @"アカウント",
                          @"footer": running ? @"" : @"Tailscaleアカウントでログインします。認証キーの入力は不要です。ログインすると、同じtailnetにあるPCが一覧に表示されます。",
                          @"rows": account}];

    // The Tailscale tab shows the account and this app's Tailscale settings;
    // choosing a PC happens in the sheet opened from Home (+ → Tailscaleで追加).
    if (self.embedded) {
        NSString *peer = [[NSUserDefaults standardUserDefaults] stringForKey:PeerKey];
        if (peer.length) {
            [sections addObject:@{@"title": @"接続先のPC",
                                  @"footer": @"接続先を変えるには、ホームの＋から「Tailscaleで追加」を選びます。",
                                  @"rows": @[@{@"kind": @(TailscaleRowTest)}]}];
        }
        else if (running) {
            [sections addObject:@{@"title": @"接続先のPC",
                                  @"footer": @"まだ接続先がありません。ホームの＋から「Tailscaleで追加」を選んでPCを追加してください。",
                                  @"rows": @[]}];
        }
    }
    else if (running) {
        NSMutableArray *pcs = [NSMutableArray array];
        for (NSDictionary *peer in self.peers) {
            [pcs addObject:@{@"kind": @(TailscaleRowPeer), @"peer": peer}];
        }
        if (pcs.count == 0) {
            [pcs addObject:@{@"kind": @(TailscaleRowNoPeers)}];
        }
        [pcs addObject:@{@"kind": @(TailscaleRowManual)}];
        [sections insertObject:@{@"title": @"接続先のPCを選択",
                                 @"footer": @"Sunshineを実行しているPCを選んで、右上の「接続」を押すとペアリングを始めます。同時に使えるPCは1台で、Sunshineは標準ポートで動かしてください。",
                                 @"rows": pcs} atIndex:0];
    }
    if (!self.embedded) {
        self.navigationItem.rightBarButtonItem.enabled = running && _pendingPeer.length > 0 && _busyText == nil;
    }

    if (self.embedded && ![state isEqualToString:@"Off"]) {
        NSMutableArray *other = [NSMutableArray arrayWithObject:@{@"kind": @(TailscaleRowStop)}];
        if (running || [state isEqualToString:@"NeedsMachineAuth"]) {
            [other addObject:@{@"kind": @(TailscaleRowLogout)}];
        }
        [sections addObject:@{@"title": @"", @"footer": @"「停止」はログイン状態を残したまま接続を切ります。次回はログインなしで再開できます。", @"rows": other}];
    }

    if (self.embedded) {
        [sections addObject:@{@"title": @"診断", @"footer": @"", @"rows": @[@{@"kind": @(TailscaleRowHistory)}]}];
    }
    _sections = sections;
    [self.tableView reloadData];
}

- (NSString *)errorText {
    NSString *error = _status[@"error"];
    return [error isKindOfClass:NSString.class] ? error : nil;
}

- (NSString *)historyText {
    NSString *transport = _status[@"transportError"];
    NSMutableArray *parts = [NSMutableArray array];
    if ([transport isKindOfClass:NSString.class] && transport.length) {
        NSNumber *timestamp = _status[@"transportErrorTime"];
        NSString *when = @"";
        if ([timestamp isKindOfClass:NSNumber.class]) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.dateStyle = NSDateFormatterShortStyle;
            formatter.timeStyle = NSDateFormatterMediumStyle;
            when = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue]];
        }
        [parts addObject:[NSString stringWithFormat:@"直近の通信エラー\n%@\n\n%@", when, transport]];
    }
    return parts.count ? [[parts componentsJoinedByString:@"\n"] stringByAppendingString:@"\n\n過去の記録です。現在の接続状態を示すものではありません。保持する通信エラーは直近1件です。"] : @"記録された通信エラーはありません。";
}

- (NSString *)stateTitle {
    NSString *state = self.state;
    if (_busyText != nil) return _busyText;
    if ([state isEqualToString:@"Running"]) return @"接続済み";
    if ([state isEqualToString:@"NeedsLogin"]) return @"ログインが必要です";
    if ([state isEqualToString:@"NeedsMachineAuth"]) return @"管理者の承認待ちです";
    if ([state isEqualToString:@"Starting"] || [state isEqualToString:@"NoState"]) return @"接続中…";
    if ([state isEqualToString:@"Off"] || [state isEqualToString:@"Stopped"]) return @"停止中";
    return state;
}

- (NSString *)stateDetail {
    NSString *state = self.state;
    if ([state isEqualToString:@"Running"]) {
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *key in @[@"user", @"tailnet"]) {
            NSString *value = _status[key];
            if ([value isKindOfClass:NSString.class] && value.length && ![lines containsObject:value]) {
                [lines addObject:value];
            }
        }
        NSString *selfIP = _status[@"selfIP"];
        if ([selfIP isKindOfClass:NSString.class] && selfIP.length) {
            [lines addObject:[@"この端末: " stringByAppendingString:selfIP]];
        }
        NSString *peer = _status[@"peer"];
        if ([peer isKindOfClass:NSString.class] && peer.length) {
            [lines addObject:[@"接続先PC: " stringByAppendingString:peer]];
        }
        return [lines componentsJoinedByString:@"\n"];
    }
    if ([state isEqualToString:@"NeedsLogin"]) {
        if (self.authURL != nil) return @"開いたページでTailscaleにログインしてください。完了すると自動でこの画面に戻ります。";
        if (_loginRequested) return @"ログインページを準備しています…";
        return @"下の「Tailscaleにログイン」をタップしてください。";
    }
    if ([state isEqualToString:@"NeedsMachineAuth"]) {
        return @"Tailscaleの管理画面で、この端末（moonlight-ios）を承認してください。";
    }
    if ([state isEqualToString:@"Off"]) {
        return @"ログインするとPC一覧が表示されます。";
    }
    return nil;
}

- (BOOL)isWaiting {
    if (_busyText != nil) return YES;
    NSString *state = self.state;
    return !self.isRunning && ((_loginRequested && self.authURL == nil) || [state isEqualToString:@"Starting"] || [state isEqualToString:@"NoState"]);
}

- (BOOL)isSelectedPeer:(NSDictionary *)peer {
    NSString *selected = self.embedded ? [[NSUserDefaults standardUserDefaults] stringForKey:PeerKey] : _pendingPeer;
    if (selected.length == 0) return NO;
    return [selected caseInsensitiveCompare:peer[@"ip"] ?: @""] == NSOrderedSame || [selected caseInsensitiveCompare:peer[@"dns"] ?: @""] == NSOrderedSame;
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *title = _sections[section][@"title"];
    return title.length ? title : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *footer = _sections[section][@"footer"];
    return footer.length ? footer : nil;
}

- (NSDictionary *)rowAtIndexPath:(NSIndexPath *)indexPath {
    return _sections[indexPath.section][@"rows"][indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }
    UIColor *primary = UIColor.labelColor, *secondary = UIColor.secondaryLabelColor, *tint = self.view.tintColor;
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.textColor = tint;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = secondary;
    cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.contentView.alpha = 1.0;

    NSDictionary *row = [self rowAtIndexPath:indexPath];
    switch ([row[@"kind"] integerValue]) {
        case TailscaleRowStatus: {
            cell.textLabel.text = self.stateTitle;
            cell.textLabel.textColor = primary;
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            cell.detailTextLabel.text = self.stateDetail;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            if (self.isRunning) {
                cell.imageView.image = SymbolImage(@"checkmark.circle.fill", UIColor.systemGreenColor);
            }
            else if ([self.state isEqualToString:@"NeedsLogin"] || [self.state isEqualToString:@"NeedsMachineAuth"]) {
                cell.imageView.image = SymbolImage(@"person.crop.circle.badge.exclamationmark", UIColor.systemOrangeColor);
            }
            else {
                cell.imageView.image = SymbolImage(@"pause.circle", UIColor.systemGrayColor);
            }
            if (self.isWaiting) {
                UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                [spinner startAnimating];
                cell.accessoryView = spinner;
            }
            break;
        }
        case TailscaleRowError:
            cell.textLabel.text = self.errorText;
            cell.textLabel.textColor = UIColor.systemRedColor;
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        case TailscaleRowLogin:
            cell.textLabel.text = [self.state isEqualToString:@"Off"] || [self.state isEqualToString:@"Stopped"] ? @"Tailscaleにログイン" : @"ログインをやり直す";
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            cell.imageView.image = SymbolImage(@"person.crop.circle.badge.plus", tint);
            break;
        case TailscaleRowOpenLogin:
            cell.textLabel.text = @"ログインページを開く";
            cell.imageView.image = SymbolImage(@"safari", tint);
            break;
        case TailscaleRowOpenInSafari:
            cell.textLabel.text = @"Safariアプリで開く";
            cell.detailTextLabel.text = @"ページが表示されないときに使います";
            cell.imageView.image = SymbolImage(@"arrow.up.forward.app", tint);
            break;
        case TailscaleRowCopyLogin:
            cell.textLabel.text = @"ログインURLをコピー";
            cell.detailTextLabel.text = @"別の端末のブラウザでもログインできます";
            cell.imageView.image = SymbolImage(@"doc.on.doc", tint);
            break;
        case TailscaleRowPeer: {
            NSDictionary *peer = row[@"peer"];
            BOOL online = [peer[@"online"] boolValue];
            NSMutableArray *detail = [NSMutableArray arrayWithObject:peer[@"ip"] ?: @""];
            NSString *os = peer[@"os"];
            if ([os isKindOfClass:NSString.class] && os.length) {
                [detail addObject:os];
            }
            [detail addObject:online ? @"オンライン" : @"オフライン"];
            cell.textLabel.text = peer[@"name"];
            cell.textLabel.textColor = online ? primary : secondary;
            cell.detailTextLabel.text = [detail componentsJoinedByString:@" · "];
            NSString *lowerOS = [os isKindOfClass:NSString.class] ? os.lowercaseString : @"";
            NSString *symbol = [lowerOS isEqualToString:@"ios"] || [lowerOS isEqualToString:@"android"] ? @"iphone" : @"desktopcomputer";
            cell.imageView.image = SymbolImage(symbol, online ? UIColor.systemGreenColor : UIColor.systemGrayColor);
            cell.accessoryType = [self isSelectedPeer:peer] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            break;
        }
        case TailscaleRowNoPeers:
            cell.textLabel.text = @"PCが見つかりません";
            cell.textLabel.textColor = secondary;
            cell.detailTextLabel.text = @"ゲームPCにTailscaleを入れて、同じアカウントでログインしてください。";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        case TailscaleRowManual:
            cell.textLabel.text = @"アドレスを入力…";
            cell.detailTextLabel.text = @"Tailscale IPまたは .ts.net の名前";
            if (!self.embedded && _pendingPeer.length) {
                BOOL listed = NO;
                for (NSDictionary *peer in self.peers) {
                    listed |= [self isSelectedPeer:peer];
                }
                if (!listed) {
                    cell.detailTextLabel.text = _pendingPeer;
                    cell.accessoryType = UITableViewCellAccessoryCheckmark;
                }
            }
            cell.imageView.image = SymbolImage(@"keyboard", tint);
            break;
        case TailscaleRowTest:
            cell.textLabel.text = @"接続テスト";
            cell.detailTextLabel.text = [@"選択中のPC: " stringByAppendingString:[[NSUserDefaults standardUserDefaults] stringForKey:PeerKey] ?: @""];
            cell.imageView.image = SymbolImage(@"stethoscope", tint);
            break;
        case TailscaleRowStop:
            cell.textLabel.text = @"停止";
            cell.imageView.image = SymbolImage(@"stop.circle", tint);
            break;
        case TailscaleRowLogout:
            cell.textLabel.text = @"ログアウト";
            cell.textLabel.textColor = UIColor.systemRedColor;
            cell.imageView.image = SymbolImage(@"rectangle.portrait.and.arrow.right", UIColor.systemRedColor);
            break;
        case TailscaleRowHistory:
            cell.textLabel.text = @"診断履歴";
            cell.detailTextLabel.text = @"過去の通信エラーを確認";
            cell.imageView.image = SymbolImage(@"clock.arrow.circlepath", tint);
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
    }
    if (_busyText != nil && cell.selectionStyle != UITableViewCellSelectionStyleNone) {
        cell.contentView.alpha = 0.4;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
    } else {
        cell.accessibilityTraits &= ~UIAccessibilityTraitNotEnabled;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_busyText != nil) {
        return;
    }
    NSDictionary *row = [self rowAtIndexPath:indexPath];
    switch ([row[@"kind"] integerValue]) {
        case TailscaleRowLogin:
            [self login];
            break;
        case TailscaleRowOpenLogin:
            [self openLoginPage];
            break;
        case TailscaleRowOpenInSafari:
            if (self.authURL != nil) {
                [[UIApplication sharedApplication] openURL:self.authURL options:@{} completionHandler:nil];
            }
            break;
        case TailscaleRowCopyLogin:
            if (self.authURL != nil) {
                [UIPasteboard generalPasteboard].string = self.authURL.absoluteString;
                [self showMessage:@"ログインURLをコピーしました" title:nil];
            }
            break;
        case TailscaleRowPeer: {
            NSDictionary *peer = row[@"peer"];
            if (!self.embedded) {
                _pendingPeer = [peer[@"ip"] lowercaseString];
                [self rebuild];
            }
            else if ([peer[@"online"] boolValue]) {
                [self choosePeer:peer[@"ip"]];
            }
            else {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:peer[@"name"] message:@"このPCは現在オフラインです。PCとTailscaleが起動しているか確認してください。それでも追加しますか？" preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
                [alert addAction:[UIAlertAction actionWithTitle:@"追加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self choosePeer:peer[@"ip"]];
                }]];
                [self presentViewController:alert animated:YES completion:nil];
            }
            break;
        }
        case TailscaleRowManual:
            [self enterAddress];
            break;
        case TailscaleRowTest:
            [self testSelectedPeer];
            break;
        case TailscaleRowStop:
            [self stop];
            break;
        case TailscaleRowLogout:
            [self confirmLogout];
            break;
        case TailscaleRowHistory: {
            UIViewController *history = [[UIViewController alloc] init];
            history.title = @"診断履歴";
            UITextView *text = [[UITextView alloc] init];
            text.editable = NO;
            text.alwaysBounceVertical = YES;
            text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            text.adjustsFontForContentSizeCategory = YES;
            text.textColor = UIColor.labelColor;
            text.backgroundColor = UIColor.systemBackgroundColor;
            text.textContainerInset = UIEdgeInsetsMake(20, 16, 20, 16);
            text.text = self.historyText;
            history.view = text;
            [self.navigationController pushViewController:history animated:YES];
            break;
        }
    }
}

#pragma mark - Actions

- (void)setBusy:(NSString *)text {
    if (_closed) return;
    [_busyTimer invalidate];
    _busyTimer = nil;
    _busyText = text;
    if (text != nil) {
        _busyStarted = NSProcessInfo.processInfo.systemUptime;
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        UILabel *title = [[UILabel alloc] init];
        title.text = @"処理中";
        title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[spinner, title]];
        stack.spacing = 8;
        stack.alignment = UIStackViewAlignmentCenter;
        self.navigationItem.titleView = stack;
        self.navigationItem.rightBarButtonItem.accessibilityHint = @"待機画面を閉じます。Tailscaleの接続は維持します。";
        [self updateBusyIndicator];
        __weak typeof(self) weakSelf = self;
        _busyTimer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
            [weakSelf updateBusyIndicator];
        }];
        [[NSRunLoop mainRunLoop] addTimer:_busyTimer forMode:NSRunLoopCommonModes];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, text);
    } else {
        self.navigationItem.titleView = nil;
        self.navigationItem.prompt = nil;
        self.navigationItem.rightBarButtonItem.accessibilityHint = nil;
    }
    [self rebuild];
}

- (void)updateBusyIndicator {
    NSInteger elapsed = (NSInteger)(NSProcessInfo.processInfo.systemUptime - _busyStarted);
    self.navigationItem.prompt = [NSString stringWithFormat:@"%@ %ld秒", _busyText, (long)elapsed];
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    if (_closed) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)login {
    [self setBusy:@"Tailscaleを起動しています…"];
    _openedAuthURL = nil;
    dispatch_async(bridgeQueue, ^{
        NSString *error = [EmbeddedTailscale startNode];
        if (error == nil) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:EnabledKey];
            // Restore the previously chosen PC once the node runs again
            NSString *peer = [[NSUserDefaults standardUserDefaults] stringForKey:PeerKey];
            if (peer.length) {
                [EmbeddedTailscale setPeer:peer];
            }
        }
        startupError = error;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_loginRequested = error == nil;
            [self setBusy:nil];
            if (error != nil) {
                [self showMessage:error title:@"Tailscaleを起動できません"];
            }
            self->_polling = NO;
            [self poll];
        });
    });
}

- (void)openLoginPage {
    NSURL *url = self.authURL;
    if (url == nil || self.presentedViewController != nil) {
        return;
    }
    SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
    safari.dismissButtonStyle = SFSafariViewControllerDismissButtonStyleClose;
    [self presentViewController:safari animated:YES completion:nil];
}

- (void)choosePeer:(NSString *)address {
    if (address.length == 0) {
        return;
    }
    NSString *normalized = address.lowercaseString;
    [self setBusy:@"PCへの経路を確認しています…"];
    dispatch_async(bridgeQueue, ^{
        NSString *error = [EmbeddedTailscale setPeer:normalized];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error != nil) {
                [self setBusy:nil];
                [self showMessage:error title:@"PCを選択できません"];
                return;
            }
            // Must be stored before Moonlight contacts the PC so it routes through Tailscale
            [[NSUserDefaults standardUserDefaults] setObject:normalized forKey:PeerKey];
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:EnabledKey];
            [self runProbe:normalized completion:^(BOOL ok) {
                if (ok) {
                    [self finishWithPeer:normalized];
                }
            } offerAddAnyway:YES];
        });
    });
}

- (void)connectPendingPeer {
    if (_pendingPeer.length) {
        [self choosePeer:_pendingPeer];
    }
}

- (void)finishWithPeer:(NSString *)address {
    if (!self.embedded && self.onConnect) {
        // Pair while this sheet waits behind the PIN; retry here on failure
        [self setBusy:@"ペアリングしています…"];
        __weak typeof(self) weakSelf = self;
        self.onConnect(address, ^(BOOL paired) {
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf setBusy:nil];
            if (paired) {
                strongSelf->_closed = YES;
                [strongSelf->_busyTimer invalidate];
                [strongSelf->_timer invalidate];
                [strongSelf.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
            }
        });
        return;
    }
    if (self.embedded) {
        // The tab owner switches back to Home
        if (self.onPeerSelected) {
            self.onPeerSelected(address);
        }
        return;
    }
    if (_closed) return;
    _closed = YES;
    [_busyTimer invalidate];
    void (^handler)(NSString *) = self.onPeerSelected;
    [_timer invalidate];
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (handler) {
            handler(address);
        }
    }];
}

- (void)testSelectedPeer {
    NSString *peer = [[NSUserDefaults standardUserDefaults] stringForKey:PeerKey];
    if (peer.length == 0) {
        return;
    }
    [self setBusy:@"PCへの経路を確認しています…"];
    dispatch_async(bridgeQueue, ^{
        // Make sure the relay points at the selected PC (e.g. after a restart)
        NSString *error = [EmbeddedTailscale setPeer:peer];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error != nil) {
                [self setBusy:nil];
                [self showMessage:error title:@"接続テスト"];
                return;
            }
            [self runProbe:peer completion:^(BOOL ok) {
                if (ok) {
                    [self showMessage:self->_lastProbeSummary title:@"接続テスト: 成功"];
                }
            } offerAddAnyway:NO];
        });
    });
}

// Checks the tailnet path and Sunshine's port. On failure, explains which part
// failed and offers a retry. The completion receives YES only on success.
- (void)runProbe:(NSString *)peer completion:(void (^)(BOOL ok))completion offerAddAnyway:(BOOL)offerAddAnyway {
    [self setBusy:@"PCへの経路を確認しています…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Off the bridge queue so status polling continues; may take ~25 seconds
        NSDictionary *result = [EmbeddedTailscale probe:peer];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_closed) return;
            [self setBusy:nil];
            if ([result[@"ok"] boolValue]) {
                NSMutableArray *lines = [NSMutableArray arrayWithObject:@"PCのSunshineに接続できました。"];
                if (result[@"latencyMs"]) {
                    [lines addObject:[NSString stringWithFormat:@"応答時間: %@ ms", result[@"latencyMs"]]];
                }
                NSString *path = result[@"path"];
                if ([path isEqualToString:@"direct"]) {
                    [lines addObject:@"経路: 直接接続"];
                }
                else if ([path hasPrefix:@"relay "]) {
                    [lines addObject:[NSString stringWithFormat:@"経路: Tailscaleの中継サーバー経由（%@）。配信が重い場合があります。", [path substringFromIndex:6]]];
                }
                self->_lastProbeSummary = [lines componentsJoinedByString:@"\n"];
                completion(YES);
                return;
            }

            NSString *stage = result[@"stage"];
            NSString *detail = result[@"error"] ?: @"";
            NSString *message;
            if ([stage isEqualToString:@"ping"]) {
                message = @"Tailscaleでこの端末からPCに届きません。\n\n・PCのTailscaleが起動してログインしているか\n・PCがスリープしていないか\n・tailnetのアクセス制御（ACL）でこの端末からPCへの通信が許可されているか\nを確認してください。";
            }
            else if ([stage isEqualToString:@"sunshine"]) {
                message = @"PCには届きましたが、Sunshine（TCP 47989）に接続できません。\n\n・PCでSunshineが起動しているか\n・Windowsファイアウォールで、Tailscaleのネットワークからの受信がSunshineに許可されているか\n・Sunshineのポート設定が標準（47989）のままか\nを確認してください。";
            }
            else {
                message = @"Tailscaleが起動していません。";
            }
            message = [NSString stringWithFormat:@"%@\n\n詳細: %@", message, detail];

            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"PCに接続できません" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"再試行" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [self runProbe:peer completion:completion offerAddAnyway:offerAddAnyway];
            }]];
            if (offerAddAnyway) {
                [alert addAction:[UIAlertAction actionWithTitle:@"このまま追加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self finishWithPeer:peer];
                }]];
            }
            [alert addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                completion(NO);
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (void)enterAddress {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"PCのアドレス" message:@"PCのTailscale IP（100.x.y.z）または完全なMagicDNS名を入力してください。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"100.x.y.z または pc.tailnet.ts.net";
        field.text = [[NSUserDefaults standardUserDefaults] stringForKey:PeerKey];
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"接続" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *address = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (self.embedded) {
            [self choosePeer:address];
        }
        else if (address.length) {
            self->_pendingPeer = address.lowercaseString;
            [self rebuild];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)stop {
    [self setBusy:@"停止しています…"];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:EnabledKey];
    dispatch_async(bridgeQueue, ^{
        MTStop();
        startupError = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_loginRequested = NO;
            [self setBusy:nil];
            self->_polling = NO;
            [self poll];
        });
    });
}

- (void)confirmLogout {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ログアウトしますか？" message:@"この端末はtailnetから外れます。もう一度使うにはログインが必要です。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"ログアウト" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self setBusy:@"ログアウトしています…"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:EnabledKey];
        dispatch_async(bridgeQueue, ^{
            NSString *error = BridgeString(MTLogout());
            MTStop();
            startupError = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_loginRequested = NO;
                [self setBusy:nil];
                if (error != nil) {
                    [self showMessage:error title:@"ログアウトできませんでした"];
                }
                self->_polling = NO;
                [self poll];
            });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@implementation EmbeddedTailscale
// Tailscale's mark: a 3x3 grid of dots with a bright "T" (middle row and
// bottom center) and faint remaining dots. A template image, so it takes the
// tint of tab bars and menus.
+ (UIImage *)logoImage {
    static UIImage *logo;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const CGFloat size = 26, dot = 6.6;
        const CGFloat step = (size - dot) / 2;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
        UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            for (int row = 0; row < 3; row++) {
                for (int column = 0; column < 3; column++) {
                    BOOL bright = row == 1 || (row == 2 && column == 1);
                    [[UIColor colorWithWhite:0 alpha:bright ? 1.0 : 0.28] setFill];
                    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(column * step, row * step, dot, dot)] fill];
                }
            }
        }];
        logo = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    });
    return logo;
}
+ (void)initialize {
    if (self == [EmbeddedTailscale class]) bridgeQueue = dispatch_queue_create("moonlight.tailscale", DISPATCH_QUEUE_SERIAL);
}
+ (BOOL)matchesAddress:(NSString *)address {
    NSString *peer = [[NSUserDefaults standardUserDefaults] stringForKey:PeerKey];
    return peer.length && address.length && [[Utils addressPortStringToAddress:address] caseInsensitiveCompare:peer] == NSOrderedSame;
}
+ (NSString *)routedAddress:(NSString *)address {
    // Keep configured peers on loopback even when stopped; never silently fall
    // back to a system VPN/direct connection after an embedded-node error.
    return [self matchesAddress:address] ? @"127.0.0.1" : address;
}
+ (BOOL)isTailscaleAddress:(NSString *)address {
    if ([address.lowercaseString hasPrefix:@"fd7a:115c:a1e0:"]) {
        return YES;
    }
    NSArray<NSString *> *parts = [address componentsSeparatedByString:@"."];
    if (parts.count != 4 || ![parts[0] isEqualToString:@"100"]) {
        return NO;
    }
    NSInteger second = parts[1].integerValue;
    return second >= 64 && second <= 127;
}
// LAN addresses learned from the node, cached briefly (discovery asks every
// couple of seconds); cleared when the network changes
static NSTimeInterval lanFetched;
static BOOL offLocalNetwork;
+ (void)networkChanged:(BOOL)onLocalNetwork {
    offLocalNetwork = !onLocalNetwork;
    lanFetched = 0;
    if (bridgeQueue != nil) {
        dispatch_async(bridgeQueue, ^{
            MTNetworkChanged();
        });
    }
}
+ (void)setOnLocalNetwork:(BOOL)onLocalNetwork {
    offLocalNetwork = !onLocalNetwork;
}
+ (BOOL)onLocalNetwork {
    return !offLocalNetwork;
}
+ (NSString *)lanAddressForPeer:(NSString *)address {
    static NSMutableDictionary<NSString *, NSString *> *cache;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
        lock = [[NSObject alloc] init];
    });
    if (address.length == 0 || bridgeQueue == nil) {
        return nil;
    }
    @synchronized (lock) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (now - lanFetched > 5) {
            __block NSString *json;
            dispatch_sync(bridgeQueue, ^{
                json = BridgeString(MTStatus(0));
            });
            NSDictionary *status = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data] options:0 error:nil];
            [cache removeAllObjects];
            NSArray *peers = [status isKindOfClass:NSDictionary.class] ? status[@"peers"] : nil;
            for (NSDictionary *peer in [peers isKindOfClass:NSArray.class] ? peers : @[]) {
                NSString *lan = peer[@"lan"];
                if ([lan isKindOfClass:NSString.class] && lan.length) {
                    if ([peer[@"ip"] isKindOfClass:NSString.class]) cache[[peer[@"ip"] lowercaseString]] = lan;
                    if ([peer[@"dns"] isKindOfClass:NSString.class]) cache[[peer[@"dns"] lowercaseString]] = lan;
                }
            }
            lanFetched = now;
        }
        return cache[address.lowercaseString];
    }
}
+ (NSString *)routeKeyForHost:(TemporaryHost *)host {
    return [@"MoonlightRoute-" stringByAppendingString:host.uuid ?: host.address ?: @""];
}
+ (NSInteger)routePreferenceForHost:(TemporaryHost *)host {
    return [[NSUserDefaults standardUserDefaults] integerForKey:[self routeKeyForHost:host]];
}
+ (void)setRoutePreference:(NSInteger)preference forHost:(TemporaryHost *)host {
    [[NSUserDefaults standardUserDefaults] setInteger:preference forKey:[self routeKeyForHost:host]];
}
+ (NSString *)connectionAddressForHost:(TemporaryHost *)host {
    // Discovery picks the address that answered: the LAN address at home,
    // the Tailscale address elsewhere. Use it; fall back to the registered one.
    return host.activeAddress ?: host.address;
}
// Must run on bridgeQueue.
+ (NSString *)startNode {
    NSURL *dir = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"EmbeddedTailscale" isDirectory:YES];
    NSError *error;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error]) return error.localizedDescription;
    [dir setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return BridgeString(MTStart(dir.path.UTF8String));
}
// Must run on bridgeQueue.
+ (NSString *)setPeer:(NSString *)peer {
    return BridgeString(MTSetPeer(peer.UTF8String));
}
// Blocking; may run off bridgeQueue because the bridge only reads its server.
+ (NSDictionary *)probe:(NSString *)peer {
    NSString *json = BridgeString(MTProbe(peer.UTF8String));
    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data] options:0 error:nil];
    return [result isKindOfClass:NSDictionary.class] ? result : @{@"ok": @NO, @"error": @"Invalid probe result"};
}
+ (void)restore {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:EnabledKey]) return;
    NSString *peer = [[NSUserDefaults standardUserDefaults] stringForKey:PeerKey];
    dispatch_async(bridgeQueue, ^{
        startupError = [self startNode];
        if (startupError == nil && peer.length) {
            startupError = [self setPeer:peer];
        }
    });
}
+ (void)status:(BOOL)login completion:(void (^)(NSDictionary *status))completion {
    dispatch_async(bridgeQueue, ^{
        NSString *json = BridgeString(MTStatus(login));
        NSDictionary *status = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data] options:0 error:nil];
        NSMutableDictionary *result = [status isKindOfClass:NSDictionary.class] ? [status mutableCopy] : [NSMutableDictionary dictionaryWithObject:@"Off" forKey:@"state"];
        if (startupError != nil) {
            result[@"error"] = startupError;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}
+ (UIViewController *)tabControllerOnPeerSelected:(void (^)(NSString *address))handler {
    EmbeddedTailscaleViewController *setup = [[EmbeddedTailscaleViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    setup.embedded = YES;
    setup.onPeerSelected = handler;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:setup];
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    return navigation;
}
+ (void)presentPickerFrom:(UIViewController *)controller onConnect:(void (^)(NSString *address, void (^finished)(BOOL paired)))onConnect {
    EmbeddedTailscaleViewController *setup = [[EmbeddedTailscaleViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    setup.onConnect = onConnect;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:setup];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    // Picking a PC is a task: no accidental swipe-down while pairing
    navigation.modalInPresentation = YES;
    [controller presentViewController:navigation animated:YES completion:nil];
}
+ (void)presentFrom:(UIViewController *)controller onPeerSelected:(void (^)(NSString *address))handler {
    EmbeddedTailscaleViewController *setup = [[EmbeddedTailscaleViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    setup.onPeerSelected = handler;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:setup];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    // Match Moonlight's dark settings
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [controller presentViewController:navigation animated:YES completion:nil];
}
@end
