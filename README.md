# Reolink Viewer

A native macOS app for watching and steering a Reolink E1 pan-tilt camera, together with
the Swift library and command-line tool it is built on.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

Reolink Viewer talks to the camera directly over Reolink's proprietary Baichuan protocol
(TCP port 9000). There is no Docker container, Neolink, go2rtc or RTSP relay in between:
the app logs in, pulls the H.264 stream, decodes it with VideoToolbox and sends pan/tilt
commands while you hold an arrow button or key.

## Features

- Live view of the main ("Clear") or sub ("Fluent") stream, decoded in hardware
- Pan and tilt with on-screen buttons or the arrow keys, for as long as you hold them
- Sound from the camera's microphone, in step with the picture, with a mute toggle
- Night-vision controls (Day & Night mode and the infrared illuminator), as in the Reolink app
- Automatic reconnection when the camera drops the connection or stops sending frames
- Credentials stay in your login keychain; nothing about your camera is baked into the app
- `Baichuan`, a pure-Swift package implementing the protocol with no third-party
  dependencies, and `bctool`, a command-line client for scripting and experiments

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later to build from source
- A Reolink camera on your local network. Development and testing happened on a
  Reolink E1; see [Compatibility](#compatibility) for other models.

## Installation

There are no prebuilt binaries yet, so build it from source:

```sh
git clone https://github.com/martinhering/reolinkviewer.git
cd reolinkviewer
./build-app.sh              # → build/ReolinkViewer.app
open build/ReolinkViewer.app
```

`build-app.sh` produces a universal (Apple silicon + Intel) binary and signs it with the
first Developer ID certificate in your keychain, or ad-hoc if there is none. An ad-hoc
signed app runs only on the Mac that built it; see
[Signing and notarizing a release](#signing-and-notarizing-a-release) to pass it on.

Alternatively `open Package.swift` in Xcode and run the `ReolinkViewer` scheme. A bare
`swift run ReolinkViewer` works too but shows no app icon, because there is no bundle.

## Usage

On first launch open Settings (⌘,), enter the camera's address, username and password,
and click Apply. The password goes into your login keychain, the rest into user defaults.

- **Clear / Fluent** in the toolbar switches between the full-resolution main stream and
  the low-resolution sub stream (the same names the Reolink app uses).
- **Pan and tilt:** hold an arrow button, or an arrow key. The camera moves until you let
  go. Drag the grip in the middle of the pad to put the controls wherever you like over
  the picture; the position is remembered, and the grip's context menu resets it.
- **Sound:** the speaker button mutes and unmutes the camera's microphone. The setting
  is remembered. Audio is decoded on the Mac and plays with about the same delay as the
  picture.
- **Night vision:** the moon menu holds **Day & Night** (Auto / Color / Black & White),
  which decides whether the picture is in colour, and **Infrared LEDs** (Auto / On / Off),
  which controls the illuminator. For a colour picture at night with the LEDs dark, set
  Color and Off; Auto on both gives the camera's default behaviour back.
- **Reconnect** restarts the connection by hand. The app also does this by itself when
  the camera drops the connection or stops sending frames.

## Command-line tool

`bctool` exercises the library without the UI. The password comes from `--password` or
the `BC_PASSWORD` environment variable.

```sh
swift build --product bctool
export BC_PASSWORD='…'
.build/debug/bctool info     --host 192.168.1.20                  # login and device info
.build/debug/bctool ping     --host 192.168.1.20
.build/debug/bctool stream   --host 192.168.1.20 --seconds 10 --out cam.h264 --audio-out cam.aac
.build/debug/bctool stream   --host 192.168.1.20 --sub
.build/debug/bctool switch   --host 192.168.1.20                  # main → sub → main, 3 s each
.build/debug/bctool ptz      --host 192.168.1.20 --dir left --ms 500
.build/debug/bctool ir       --host 192.168.1.20 --mode off       # auto | on | off; omit to read
.build/debug/bctool daynight --host 192.168.1.20 --mode color     # auto | color | bw; omit to read
```

`--verbose` logs every packet. The dumped `.h264` file is a raw Annex B stream that
`ffprobe` and `ffplay` can read.

## Using the library

The `Baichuan` product can be used on its own from another Swift package:

```swift
// Package.swift
.package(url: "https://github.com/martinhering/reolinkviewer.git", branch: "main"),
// …
.product(name: "Baichuan", package: "reolinkviewer"),
```

```swift
import Baichuan

let camera = BaichuanCamera(host: "192.168.1.20", password: "secret")
let info = try await camera.connect()
print(info.summary)

let frames = try await camera.startVideo(.main)
for try await frame in frames {
    switch frame {
    case .videoKeyFrame(_, let data, _, _), .videoFrame(_, let data, _):
        decode(data)            // Annex B H.264
    case .aac(let adts):
        play(adts)              // AAC-LC with ADTS header
    default:
        break
    }
}

try await camera.ptz(.left)     // moves until .stop
try await camera.ptz(.stop)
try await camera.setInfrared(.off)
await camera.disconnect()
```

`BaichuanCamera` is an actor. Its calls are `async`; protocol-level failures surface as `BCError`.

## Compatibility

Everything here was developed and verified against a single Reolink E1. Other Reolink
cameras speak the same protocol and may well work, but have not been tried. If the app or
`bctool` works, or fails, with another model, please open an issue with the model name,
the firmware version and the output of `bctool info`.

Baichuan is undocumented, so a firmware update could change the camera's behaviour.

## Protocol notes

These notes describe what the library implements. They may help if you want to extend
it, port it or compare against another camera.

- Packets have a 20-byte little-endian header (magic `0x0abcdef0`, message id, body
  length, channel, stream type, message number, response code, class). Class `0x6414`
  adds a 4-byte payload offset; the body is then `extension XML + payload`.
- Login is three messages on one message number: a header-only legacy login (class
  `0x6514`, response code `0xdc12` = "I support AES"); the camera's reply with a nonce
  (XOR-obfuscated, response code `0xddNN` announcing the encryption level); and the
  modern login with `MD5(username+nonce)` and `MD5(password+nonce)`, uppercase hex cut to
  31 characters.
- Control messages are then AES-128-CFB with IV `0123456789abcdef` and key = first 16
  characters of the uppercase hex `MD5("nonce-password")`. Login messages stay XOR-only.
  The E1 picks "full" AES (`0xdd12`), which encrypts the video payload too; the
  extension of those messages carries `encryptLen`.
- Video is message id 3 with a `Preview` XML body. Main stream: header stream type 0,
  handle 0, name `mainStream`. Sub stream: stream type 1, handle 256, `subStream`. The
  camera acknowledges with code 200, then sends binary payloads that form a continuous
  media container: items tagged `0x6364303x` (key frame), `0x6364313x` (P frame),
  `0x62773530` (AAC), `0x62773130` (ADPCM), `0x31303031`/`0x32303031` (info), each
  padded to 8 bytes. Video items are Annex B H.264 with SPS/PPS in every key frame.
- Audio rides in the same container as AAC-LC frames with ADTS headers (16 kHz mono on
  the E1). The app strips the header, decodes with AVAudioConverter and plays through
  AVAudioEngine, dropping anything that falls more than a second behind live. The
  ADPCM variant some older cameras send is parsed but not played.
- Pan/tilt is message id 18 with a `PtzControl` body: `command` of `up`, `down`,
  `left`, `right` or `stop`, and `speed` (32 like the official client).
- Infrared: message id 208 (with a channel extension, no body) returns a `LedState` XML
  with `state` = `auto` / `open` / `close` and `lightState` for the blue status LED; id 209
  writes it back without the `ledVersion` field. The E1 acknowledges with code 200.
- Day & Night: message id 26 returns the ISP configuration (`VideoInput` plus
  `InputAdvanceCfg`, about 2 KB of XML); `InputAdvanceCfg/DayNight/mode` is `auto`,
  `color` or `blackAndWhite`. To change it the whole document is sent back with id 25
  and only that element edited, which is what the official client does too.
- Message id 4 with the same message number stops the stream; the camera sometimes
  pings with id 234, which is answered with code 200.

## Development

```
Sources/Baichuan/       protocol library (pure Swift, no dependencies)
Sources/bctool/         command-line client
Sources/ReolinkViewer/  the SwiftUI app
Tests/BaichuanTests/    unit tests for framing, crypto, XML and media parsing
AppIcon.icon            app icon, an Icon Composer document (SF Symbol camera.fill on blue)
build-app.sh            builds, signs and notarizes build/ReolinkViewer.app
```

### Tests

```sh
swift test
```

The tests need no camera. They cover header encoding, the login handshake, XOR and AES
round trips with known answers, XML builders, the media parser (including chunk
boundaries and resync after garbage) and the Day & Night document rewrite.

### Debugging

`REOLINK_DEBUG=1` makes the app log connection and decoding progress to stderr, and
`REOLINK_PASSWORD` overrides the keychain, so a quick check from Terminal is:

```sh
REOLINK_DEBUG=1 REOLINK_PASSWORD='…' .build/debug/ReolinkViewer
```

For protocol work, `bctool … --verbose` prints every packet in both directions.

### App icon

`AppIcon.icon` is an Icon Composer document: open it with Icon Composer (in Xcode's
Applications folder) to change colours or layers. Its single layer is the SF Symbol
`camera.fill`, rendered to `Assets/camera.png`. `build-app.sh` compiles it with `actool`
into the layered icon macOS 26 uses plus a flattened `.icns` for older systems.

### Signing and notarizing a release

Other Macs open the app without a Gatekeeper warning only if it is signed with a
Developer ID Application certificate **and** notarized. `build-app.sh` picks the
certificate in this order:

1. `CODESIGN_IDENTITY` if set (a certificate name or its SHA-1 hash from
   `security find-identity -v -p codesigning`),
2. otherwise the first **Developer ID Application** certificate in the keychain,
3. otherwise ad-hoc.

One-time setup:

1. Create the certificate: Xcode ▸ Settings ▸ Accounts ▸ your team ▸ Manage Certificates ▸
   **+** ▸ Developer ID Application (the team's Account Holder has to do this, or create it
   at developer.apple.com ▸ Certificates and install the `.cer`).
2. Store notarization credentials once, using an app-specific password from
   appleid.apple.com:

   ```sh
   xcrun notarytool store-credentials reolinkviewer --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
   ```

Then every release is:

```sh
NOTARY_PROFILE=reolinkviewer ./build-app.sh
```

This signs, submits to Apple (usually a minute or two), staples the ticket and leaves
`build/ReolinkViewer.zip` ready to send, plus `build/ReolinkViewer.dSYM` for
symbolicating crash logs. Without `NOTARY_PROFILE` the script stops after signing.
`APP_BUILD=<n>` sets the bundle's build number; the header comment in `build-app.sh`
lists the remaining environment variables, including the ones meant for CI.

## Contributing

Issues and pull requests are welcome.

- Run `swift test` before opening a pull request, and keep each one to a single change.
- For protocol changes, say which camera model and firmware you tested against and,
  where it helps, attach a `bctool --verbose` capture.
- Nobody can test against hardware they do not own, so please state what you tried a
  change on and what you could not try.

## Related projects

- [Neolink](https://github.com/QuantumEntangledAndy/neolink) exposes Baichuan cameras
  over RTSP and supports many more Reolink models.

## Disclaimer

This project is not affiliated with, endorsed by or supported by Reolink. Reolink is a
trademark of its owner. The Baichuan protocol is undocumented; this implementation is
based on observing an E1 and comes without any warranty. Use it at your own risk.

## License

[MIT](LICENSE) © 2026 Martin Hering
