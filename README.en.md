# Moonlight Remote Desktop for iPhone

[日本語](README.md) · [Downloads](https://github.com/hinatamaxxx/moonlight-remote-desktop-ios/releases) · [Tailscale setup](README-Tailscale.md#english)

A fork of [Moonlight iOS](https://github.com/moonlight-stream/moonlight-ios) adapted for controlling a PC desktop from an iPhone. View the desktop in portrait, use the trackpad below the picture, and compose Japanese text with the iPhone keyboard before sending it to the PC.

The original game-streaming interface has been adapted for everyday desktop use. The on-screen gamepad and app grid have been removed from the iPhone interface. Selecting a PC opens its desktop stream.

This is an independent fork, not an official Moonlight release. Report fork-specific problems and requests in [this repository's Issues](https://github.com/hinatamaxxx/moonlight-remote-desktop-ios/issues).

## Features

- Portrait layout with a trackpad below the picture. Tap with two fingers to right-click; drag with two fingers to scroll.
- A hand button switches between moving the picture and sending touches to the PC. Zoom, pan and reset the picture position.
- Display based on the stream's actual aspect ratio, including 16:10. Stopping a full-screen stream returns to the portrait home screen.
- Compose and convert Japanese text on the iPhone, then press Send. Backspace in an empty editor is forwarded to the PC.
- A PC key panel with Esc, Tab, Ctrl, Alt, arrow keys and more.
- An optional landscape setting moves the picture up with the keyboard and restores its position when the keyboard closes.
- Embedded Tailscale for connecting to a PC on the same tailnet away from home, without connecting the separate iPhone Tailscale app.

## Requirements

- An iPhone with [LiveContainer](https://livecontainer.github.io/) already configured
- A PC running [Sunshine](https://github.com/LizardByte/Sunshine)
- For access away from home: [Tailscale on the PC](https://tailscale.com/download) and a Tailscale account

Device testing has covered iOS 27.0.1, LiveContainer 3.8.0 and Sunshine 2026.516.143833 on Windows. Streaming over a mobile connection through embedded Tailscale and Japanese text entry with Copilot Keyboard have been confirmed. iPad, tvOS, other operating systems and other IMEs have not been verified.

## Install and connect

1. Download this fork's `unsigned.ipa` from [Releases](https://github.com/hinatamaxxx/moonlight-remote-desktop-ios/releases). This is a different build from the App Store version of Moonlight.
2. Import the IPA using the plus button in LiveContainer, then launch Moonlight. The IPA is unsigned. Follow the [official LiveContainer guide](https://livecontainer.github.io/) to set up LiveContainer itself.
3. Start Sunshine on the PC and configure an application named `Desktop`. See the [Sunshine setup guide](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html).
4. On the same Wi-Fi network, select the PC on the home screen. If it does not appear, use + → Add by IP Address. For access away from home, follow the [Tailscale setup](README-Tailscale.md#english).
5. Enter the displayed PIN in Sunshine on the PC to pair the devices.
6. Tap the PC to start streaming. An existing session is resumed; otherwise, the app starts `Desktop`. If `Desktop` is missing, it starts the first available application, so configure `Desktop` for desktop use.

## Japanese text input

Open the keyboard and compose your text in the editor. Choose your predictions and conversions, then press Send. Closing the keyboard keeps the draft.

The setting “文字送信時にPCのIMEをOFF” (turn off the PC IME when sending text) is enabled by default. Send requests IME OFF on Windows before forwarding the text, avoiding a second Japanese conversion on the host. The host IME remains in A/direct-input mode afterward.

Disable this setting for non-Windows hosts. If characters are missing, focus the destination input field and check that the PC IME is in A mode. The app cannot read the host's current IME state.

While the editor contains text, Backspace deletes only the local draft. Deleting its final character does not delete anything on the PC. Subsequent Backspace events in the empty editor are sent to the PC. Holding Backspace deletes continuously on the PC and stops when you release it.

## Controls and settings

“開始時に映像移動をON” (start with picture movement enabled) defaults to ON. Use the hand button to send touches on the picture to the PC instead. The trackpad below the picture continues to control the PC in either mode.

Enable “横画面でキーボードに合わせて映像を上へ移動” to move the picture upward when the landscape keyboard opens. You can rotate the screen while the keyboard is visible. Some added controls and settings currently use Japanese labels.

## Updates and stored data

Import the new IPA into LiveContainer to update. Select the same data container to retain the app's connection settings. Deleting or resetting that container removes local settings and pairing information.

PC pairing information, connection preferences and the embedded Tailscale login state are stored in the app's data on the device. Tailscale connections use Tailscale's services. Entered text is sent to the streaming PC; text-send diagnostic logs do not contain the text itself.

To remove the app, log out in the Tailscale screen, then delete the app and any unwanted data containers in LiveContainer. Remove its pairing in Sunshine on the PC if no longer needed.

## Compatibility

The distributed build targets iPhone through LiveContainer. Continued streaming after backgrounding, and text input in every PC application or IME, are not guaranteed. Embedded Tailscale targets Sunshine's standard ports. See [Tailscale setup](README-Tailscale.md#english) for its scope.

## Upstream and license

Based on Moonlight iOS 9.0.2. Fork release tags use a suffix such as `v9.0.2-rd.1`; the app still displays Moonlight / 9.0.2 as its name and base version.

Moonlight and this fork's source are distributed under [GPL-3.0](LICENSE.txt). Thanks to the developers of Moonlight, Sunshine, Tailscale and LiveContainer. Dependencies retain their respective licenses. The IPA includes notices for Moonlight and embedded Tailscale dependencies.

This fork was developed with assistance from OpenAI Codex (GPT-6 Astra, Low / Medium / High reasoning settings) and Claude.

For source builds, see [Building](docs/BUILDING.md).
