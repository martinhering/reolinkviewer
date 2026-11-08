# Reolink Viewer

A native macOS app for watching and steering Reolink E1 pan-tilt cameras, together with
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
- Any number of cameras: switch between them with ⌘1 … ⌘9, or watch them all at once in a grid
- Pan and tilt with on-screen buttons or the arrow keys, for as long as you hold them
  (the pad is hidden for fixed cameras, which report `ptzMode = none`)
- Sound from the camera's microphone, in step with the picture, with a mute toggle
- Night-vision controls (Day & Night mode and the infrared illuminator), as in the Reolink app
- A switch for the white spotlight on cameras that have one
- Switches for the camera's network services (ONVIF, RTSP, RTMP, HTTP, HTTPS) in Settings
- Automatic reconnection when the camera drops the connection or stops sending frames
- Credentials stay in your login keychain; nothing about your cameras is baked into the app
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

On first launch open Settings (⌘,), click **+**, enter the camera's name, address, username
and password, and click Apply. The password goes into your login keychain, the rest into
user defaults. **Write to Camera** next to the name makes the camera burn that name into its
picture too, in place of the factory name. A camera fresh out of the box, not yet set up in the Reolink app, accepts
`admin` with an empty password. **Set Password on Camera…** in the camera's settings gives it
one: the app logs in with the form's current password, changes it on the camera, checks that
the new one works and stores it in the keychain. The same button changes an existing password. Add as many cameras as you like the same way; drag them to change their order.
**Network services** at the bottom of a camera's settings has a switch for each protocol the
camera can offer besides its own (HTTP, HTTPS, RTSP, RTMP, ONVIF) with its port; flipping one
is written to the camera at once.

- **Cameras:** with more than one camera the toolbar gets a camera menu. The Camera menu in
  the menu bar lists them too, with ⌘1 … ⌘9 as shortcuts; ⌘] and ⌘[ step to the next and
  previous one. Only the camera on screen is connected.
- **Grid:** the single/grid switch next to the camera menu, ⌘0 or **All Cameras** in the
  camera menu shows every camera in a grid. Each tile carries the speaker, spotlight and
  night-vision controls in its top right corner; the speaker picks the one camera you hear.
  Click anywhere else on a tile to open that camera on its own.
- **Clear / Fluent** in the toolbar switches between the full-resolution main stream and
  the low-resolution sub stream (the same names the Reolink app uses), in the single view and
  the grid alike. Fluent is lighter on the network and the Mac when the grid holds many cameras.
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
- **Spotlight:** cameras with a white spotlight get a light bulb button. The camera keeps a
  manual "on" for three minutes, so the app renews it for as long as the button is on and the
  camera is on screen. Switching to another camera lets the light go back to its automatic
  behaviour within three minutes.
- **Reconnect** (⌘R) restarts the connection by hand, for every camera on screen. The app
  also does this by itself when a camera drops the connection or stops sending frames.

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
.build/debug/bctool led      --host 192.168.1.20 --state off      # blue status LED; omit to read
.build/debug/bctool light    --host 192.168.1.20 --state on       # white spotlight, 180 s; omit to probe
.build/debug/bctool daynight --host 192.168.1.20 --mode color     # auto | color | bw; omit to read
.build/debug/bctool osd      --host 192.168.1.20 --name 'Garden'  # name shown in the picture; omit to read
.build/debug/bctool services --host 192.168.1.20 --onvif on       # also --rtsp/--rtmp/--http/--https; omit to read
.build/debug/bctool users    --host 192.168.1.20                  # list user accounts
.build/debug/bctool passwd   --host 192.168.1.20 --new 'secret'   # change the password, then log in with it
```

For a camera that has no password yet, pass `--password` with no value.

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

Everything here was developed and verified against a Reolink E1, plus a fixed 4512×2512
H.265 camera (`type = ipc`, `ptzMode = none`) for login, streaming and the camera list.
Other Reolink cameras speak the same protocol and may well work, but have not been tried. If the app or
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
- On-screen display: message id 44 returns `OsdDatetime`, `OsdChannelName` (`name`,
  `enable`, position) and `OsdFlowData`; id 45 takes the same document back with the name
  changed, the way Day & Night is written. Reading follows reolink_aio; the write (verified
  on the fixed camera) is the get/set pairing the other settings use.
- Network services: message id 37 (no body) returns the port configuration: `ServerPort`
  (the camera's own Baichuan port, 9000) and `HttpPort`, `HttpsPort`, `RtspPort`, `RtmpPort`,
  `OnvifPort`, each with its port number (`onvifPort` …) and an `enable` switch; id 36 takes
  the document back with one `enable` changed, the way the other settings are written.
  Message ids as in Neolink and reolink_aio; the document layout is what an RLC-1240A sends.
- Users: message id 58 with an `Extension` naming `userName` returns a `UserList` of `User`
  entries (`userName`, `userId`, `userLevel` 1 = administrator, `loginState`). Message id 59
  sends the whole list back; each entry has `userSetState` `none`, `add`, `delete` or
  `modify`, and only added or modified entries carry a plain-text `password` (inside the
  AES session). This follows [Neolink](https://github.com/QuantumEntangledAndy/neolink);
  reading the list was verified on a fixed Reolink camera.
- Spotlight: message id 291, a `FloodlightStatusList` of `FloodlightStatus` entries
  (`channel`, `status` 1/0, `brightness`), arrives unasked right after login and on every
  change. Message id 438 reads the automatic settings (`FloodlightTask`); the fixed camera
  tested here refuses it with code 405 but does send 291, so the app shows the button when
  either one answers. Message id 288 with `FloodlightManual` (`channelId`, `status` 1/0,
  `duration` in seconds) switches it; the camera confirms with a 291 report. From Neolink,
  verified on the fixed camera.
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
`REOLINK_PASSWORD` overrides the keychain for every camera, so a quick check from Terminal is:

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
