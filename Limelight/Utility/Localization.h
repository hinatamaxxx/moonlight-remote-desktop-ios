//
//  Localization.h
//  Moonlight
//
//  Japanese UI text. The storyboards and resources come from a prebuilt
//  resource kit, so translations live in code instead of .strings files.
//  ML(@"English") returns the Japanese text when the device's preferred
//  language is Japanese, otherwise the English text unchanged.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

static inline BOOL MLPrefersJapanese(void) {
    static BOOL japanese;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        japanese = [[NSLocale preferredLanguages].firstObject hasPrefix:@"ja"];
    });
    return japanese;
}

// Streaming preferences kept in user defaults (not in the Core Data settings)
static NSString* const MLTrackpadSpeedKey = @"TrackpadSpeed";          // pointer speed multiplier
static NSString* const MLControlsOnRightKey = @"PortraitControlsOnRight"; // close/rotate side in portrait
static NSString* const MLDirectTextInputKey = @"DirectTextInput";        // YES: send each key as typed
static NSString* const MLVideoFillModeKey = @"VideoFillMode";            // 0 fit, 1 fill (crop), 2 stretch
static NSString* const MLPanOnStartKey = @"PanOnStreamStart";
// Keep the stored key so existing ON/OFF preferences survive the timing change.
static NSString* const MLImeOffBeforeTextSendKey = @"ImeOffOnInputStart";
static NSString* const MLShiftForKeyboardKey = @"LandscapeShiftForKeyboard";

static inline BOOL MLBoolPreference(NSString *key, BOOL defaultValue) {
    NSNumber *value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value == nil ? defaultValue : value.boolValue;
}

static inline NSInteger MLVideoFillMode(void) {
    NSNumber* mode = [[NSUserDefaults standardUserDefaults] objectForKey:MLVideoFillModeKey];
    return mode != nil ? mode.integerValue : 0;
}

static inline CGFloat MLTrackpadSpeed(void) {
    double speed = [[NSUserDefaults standardUserDefaults] doubleForKey:MLTrackpadSpeedKey];
    return speed > 0 ? speed : 2.0;
}

static inline NSString* ML(NSString* english) {
    if (english == nil || !MLPrefersJapanese()) {
        return english;
    }
    static NSDictionary<NSString*, NSString*>* table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            // Common
            @"OK": @"OK",
            @"Cancel": @"キャンセル",
            @"Help": @"ヘルプ",
            @"Done": @"完了",
            @"Settings": @"設定",
            @"Yes": @"はい",
            @"No": @"いいえ",
            @"Off": @"オフ",
            @"Auto": @"自動",

            // Home
            @"Select Host": @"PCを選択",
            @"Select New Host": @"PC一覧",
            @"Searching for PCs on your network...": @"ネットワーク上のPCを探しています…",
            @"Add Host Manually": @"PCを追加",
            @"If Moonlight doesn't find your local gaming PC automatically,\nenter the IP address of your PC": @"PCが自動で見つからない場合は、PCのIPアドレスを入力してください。",
            @"Pairing": @"ペアリング",
            @"Enter the following PIN on the host machine: %@\n\nIf your host PC is running Sunshine, navigate to the Sunshine web UI to enter the PIN.": @"PCで次のPINを入力してください: %@\n\nSunshineを使っている場合は、SunshineのWeb画面でPINを入力します。",
            @"Pairing Failed": @"ペアリングに失敗しました",
            @"Connection Interrupted": @"接続が中断されました",
            @"Network Error": @"ネットワークエラー",
            @"Failed to resolve host.": @"PCの名前を解決できませんでした。",
            @"Connection Failed": @"接続できませんでした",
            @"Offline": @"オフライン",
            @"Online - Paired": @"オンライン・ペアリング済み",
            @"Online - Not Paired": @"オンライン・未ペアリング",
            @"Connecting": @"確認中",
            @"Wake PC": @"PCを起動（Wake-on-LAN）",
            @"Wake-On-LAN": @"Wake-on-LAN",
            @"Host MAC unknown, unable to send WOL Packet": @"PCのMACアドレスが不明なため、起動信号を送れません。",
            @"Successfully sent wake-up request. It may take a few moments for the PC to wake. If it never wakes up, ensure it's properly configured for Wake-on-LAN.": @"起動信号を送りました。PCが起動するまで少し待ってください。起動しない場合は、PCのWake-on-LAN設定を確認してください。",
            @"View All Apps": @"すべてのアプリを表示",
            @"Test Network": @"インターネット回線のテスト",
            @"Network Test Complete": @"回線テスト完了",
            @"This network does not appear to be blocking Moonlight. If you still have trouble connecting, check your PC's firewall settings.\n\nVisit the Moonlight Setup Guide on GitHub for additional setup help and troubleshooting steps.": @"このネットワークはMoonlightの通信を妨げていないようです。それでも接続できない場合は、PCのファイアウォール設定を確認してください。",
            @"The network test could not be performed because none of Moonlight's connection testing servers were reachable. Check your Internet connection or try again later.": @"テスト用サーバーに接続できなかったため、回線テストを実行できませんでした。インターネット接続を確認して、しばらくしてからもう一度試してください。",
            @"Your current network connection seems to be blocking Moonlight. Streaming may not work while connected to this network.\n\nThe following network ports were blocked:\n%s": @"現在のネットワークはMoonlightの通信を妨げているようです。このネットワークではストリーミングできない可能性があります。\n\nブロックされているポート:\n%s",
            @"Connection Help": @"接続のヘルプ",
            @"Remove Host": @"このPCを削除",
            @"Hidden": @"非表示",
            @"Launch App": @"アプリを起動",
            @"Resume App": @"アプリを再開",
            @"Resume Running App": @"実行中のアプリを再開",
            @"Quit App": @"アプリを終了",
            @"Quit Running App and Start": @"実行中のアプリを終了して起動",
            @"Quitting App Failed": @"アプリを終了できませんでした",
            @"Show App": @"アプリを表示",
            @"Hide App": @"アプリを隠す",
            @"Tailscale…": @"Tailscale…",
            @"Your device's network connection is blocking Moonlight. Streaming may not work while connected to this network.": @"この端末のネットワークがMoonlightの通信を妨げています。このネットワークではストリーミングできない可能性があります。",

            // Home cards and progress
            @"Add PC": @"PCを追加",
            @"Home": @"ホーム",
            @"Reset View": @"表示をリセット",
            @"Trackpad: this area\nRight-click: two-finger tap": @"ここがトラックパッド\n2本指タップで右クリック",
            @"Special Keys": @"特殊キー",
            @"Picture Size": @"映像の表示",
            @"Fit (whole picture)": @"全体を表示",
            @"Fill (crop edges)": @"画面いっぱい（端をカット）",
            @"Stretch": @"引き伸ばし",
            @"Fill covers the whole screen and cuts what does not fit; pinch to see the edges. Stretch fills without cutting but distorts the picture.": @"「画面いっぱい」は画面全体に表示し、はみ出す部分をカットします（ピンチで縮小すると端も見られます）。「引き伸ばし」はカットせずに画面に合わせますが、映像が少し横に伸びます。",
            @"Text Input": @"文字入力の方法",
            @"Input Box": @"入力欄でまとめて送信",
            @"Direct": @"打つたびに直接送信",
            @"Input box: type and edit on the iPhone, then send the text to the PC. Direct: every key goes to the PC as you type.": @"入力欄：iPhoneで入力・変換・修正してから、まとめてPCに送ります。直接：打った文字がそのままPCに送られます。",
            @"Text for the PC": @"PCに送る文字を入力",
            @"Send": @"送信",
            @"Send with Enter": @"送信してEnter",
            @"Trackpad": @"トラックパッド",
            @"Pointer Speed": @"カーソルの速さ",
            @"Close Button Position (Portrait)": @"閉じるボタンの位置（縦画面）",
            @"Left": @"左",
            @"Right": @"右",
            @"Streaming Settings": @"配信中の設定",
            @"Pointer speed applies to the trackpad under the picture. Resolution and codec changes apply from the next stream.": @"カーソルの速さは、映像の下のトラックパッドに反映されます。解像度やコーデックの変更は次の配信から反映されます。",
            @"Move: one finger\nClick: tap · Right-click: two-finger tap\nScroll: two fingers · Drag: press and hold, then move": @"カーソル移動：1本指でなぞる\nクリック：タップ　右クリック：2本指でタップ\nスクロール：2本指でなぞる　ドラッグ：長押ししてなぞる",
            @"Video": @"映像",
            @"Input": @"入力",
            @"PC": @"PC",
            @"Bitrate": @"ビットレート",
            @"Custom…": @"カスタム…",
            @"Higher resolution and bitrate look sharper but need a faster connection. Changing the resolution or frame rate resets the bitrate to a suitable value.": @"解像度とビットレートを上げるほどきれいになりますが、速い回線が必要です。解像度やフレームレートを変えると、ビットレートはそれに合った値に戻ります。",
            @"Touchpad moves the pointer like a laptop trackpad. Touchscreen clicks where you touch.": @"タッチパッドはノートPCのようにポインタを動かします。タッチスクリーンは触れた場所をクリックします。",
            @"Show Keyboard When Streaming Starts": @"配信開始時にキーボードを表示",
            @"Wake": @"起動",
            @"Connect": @"接続",
            @"PC Settings": @"PCの設定",
            @"Tailscale Connection Test": @"Tailscale接続テスト",
            @"Status": @"状態",
            @"Paired": @"済み",
            @"Not paired": @"未ペアリング",
            @"Current route": @"現在の経路",
            @"Connection": @"接続方法",
            @"Route": @"経路",
            @"Local network only": @"LANのみ",
            @"Tailscale only": @"Tailscaleのみ",
            @"Automatic (local network first)": @"自動（LANを優先）",
            @"Local IP address": @"ローカルIPアドレス",
            @"External IP address": @"外部IPアドレス",
            @"MAC address": @"MACアドレス",
            @"Not used": @"未使用",
            @"Save": @"保存",
            @"Automatic uses the local network when the PC answers there, and Tailscale otherwise.": @"「自動」は、同じネットワークでPCが応答すればLANで直接つなぎ、応答しなければTailscaleを使います。",
            @"The PC's address on your home network, for example 192.168.1.10.": @"家のネットワークでのPCのアドレスです（例: 192.168.1.10）。",
            @"Remove this PC from Moonlight? You will need to pair again to use it.": @"このPCをMoonlightから削除しますか？もう一度使うにはペアリングが必要です。",
            @"Add with Tailscale": @"Tailscaleで追加",
            @"Choose a PC from your tailnet. Works away from home.": @"tailnet内のPCから選びます。外出先からも使えます",
            @"Add by IP Address": @"IPアドレスで追加",
            @"For a PC on this network": @"同じネットワークにあるPC",
            @"PCs on this Wi-Fi appear automatically": @"同じWi-FiのPCは自動で表示されます",
            @"Enter the IP address of a PC on this network, for example 192.168.1.10. To connect from outside, add the PC with Tailscale instead.": @"同じネットワークにあるPCのIPアドレスを入力してください（例: 192.168.1.10）。外出先から使う場合は「Tailscaleで追加」を使ってください。",
            @"MY PCS": @"登録済みのPC",
            @"FOUND ON THIS NETWORK · TAP TO PAIR": @"このネットワークで見つかったPC・タップしてペアリング",
            @"Looking for PCs on this network.\nTo add a PC yourself, tap + at the top right.": @"このネットワーク上のPCを探しています。\n自分で追加する場合は、右上の＋をタップしてください。",
            @"Stop": @"停止",
            @"Keyboard": @"キーボード",
            @"Full Screen": @"全画面",
            @"Portrait": @"縦画面",
            @"Hide Keyboard": @"キーボードを閉じる",
            @"Enter an IP address, or use Tailscale from the bar below": @"IPアドレスで追加するか、下のバーのTailscaleから追加",
            @"Online": @"オンライン",
            @"Online · Tap to pair": @"オンライン・タップしてペアリング",
            @"Checking…": @"確認中…",
            @"Looking for PCs on this network. You can also add one below.": @"このネットワーク上のPCを探しています。下から追加することもできます。",
            @"Connecting to %@…": @"「%@」に接続しています…",
            @"Testing your network…": @"回線をテストしています…",
            @"Looking for the PC at %@…": @"%@ のPCを探しています…",
            @"Quitting %@…": @"「%@」を終了しています…",
            @"Please wait…": @"お待ちください…",
            @"This is taking a while. Check that the PC and Sunshine are running.": @"時間がかかっています。PCとSunshineが起動しているか確認してください。",
            @"Failed to quit app. If this app was started by another device, you'll need to quit from that device.": @"アプリを終了できませんでした。別の端末から起動したアプリは、その端末から終了してください。",
            @"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.": @"PCでストリームの開始中に問題が起きました。\n\nPCで著作権保護されたコンテンツを開いていないか確認してください。PCの再起動も試してください。",
            @"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.": @"PCで映像のエンコードに失敗しました。\n\nHDRをオフにする、解像度を変える、PCの画面解像度を変えるなどを試してください。",

            // Stream
            @"Starting %@...": @"%@ を開始しています…",
            @"Tip: Swipe from the left edge to disconnect from your PC": @"画面の左端からスワイプすると切断します",
            @"Connection Error": @"接続エラー",
            @"No video received from host.": @"PCから映像が届きませんでした。",
            @"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection.": @"通信が不安定です。設定でビットレートを下げるか、速い回線で試してください。",
            @"Connection Terminated": @"接続が終了しました",
            @"The connection was terminated\n\nError code: %@": @"接続が終了しました\n\nエラーコード: %@",
            @"Slow connection to PC\nReduce your bitrate": @"PCとの通信が遅くなっています\nビットレートを下げてください",
            @"Poor connection to PC": @"PCとの通信が不安定です",
            @"Check your firewall and port forwarding rules for port(s):\n%s": @"次のポートのファイアウォールとポート転送の設定を確認してください:\n%s",
            @"%@ failed with error %d": @"%@に失敗しました（エラー %d）",
            @"%@ in progress...": @"%@中…",
            @"Show Keyboard": @"キーボードを表示",
            @"none": @"準備",
            @"platform initialization": @"初期化",
            @"name resolution": @"PCの名前解決",
            @"audio stream initialization": @"音声の準備",
            @"RTSP handshake": @"ストリームの交渉",
            @"control stream initialization": @"操作チャネルの準備",
            @"video stream initialization": @"映像の準備",
            @"input stream initialization": @"入力の準備",
            @"control stream establishment": @"操作チャネルの接続",
            @"video stream establishment": @"映像の受信開始",
            @"audio stream establishment": @"音声の受信開始",
            @"input stream establishment": @"入力の接続",

            // Settings (storyboard text)
            @"Resolution": @"解像度",
            @"Frame Rate": @"フレームレート",
            @"Bitrate: %.1f Mbps": @"ビットレート: %.1f Mbps",
            @"Touch Mode": @"タッチ操作",
            @"Touchpad": @"タッチパッド",
            @"Touchscreen": @"タッチスクリーン",
            @"On-Screen Controls": @"画面上のコントローラー",
            @"Simple": @"シンプル",
            @"Full": @"フル",
            @"Optimize Game Settings": @"ゲーム設定を最適化",
            @"Multi-Controller Mode": @"複数コントローラー",
            @"Single": @"1台",
            @"Swap A/B and X/Y Buttons": @"A/BとX/Yを入れ替え",
            @"Play Audio on PC": @"PCでも音声を再生",
            @"Preferred Codec": @"優先コーデック",
            @"HDR (Beta)": @"HDR（ベータ）",
            @"Frame Pacing Preference": @"フレームペーシング",
            @"Lowest Latency": @"低遅延優先",
            @"Smoothest Video": @"なめらかさ優先",
            @"Citrix X1 Mouse Support": @"Citrix X1マウス対応",
            @"Statistics Overlay": @"統計情報の表示",
            @"Safe Area": @"セーフエリア",
            @"Custom": @"カスタム",
            @"Unsupported on this device": @"この端末は非対応",
            @"Enter Custom Resolution": @"カスタム解像度を入力",
            @"Video Width": @"幅",
            @"Video Height": @"高さ",
            @"Custom Resolution Selected": @"カスタム解像度を選択しました",
            @"Set PC/Game resolution: ": @"PC/ゲームの解像度: ",
        };
    });
    return table[english] ?: english;
}
