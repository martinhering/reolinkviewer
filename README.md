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
- A switch for whether the spotlight comes on by itself when the camera sees motion in the dark
- Switches for the camera's network services (ONVIF, RTSP, RTMP, HTTP, HTTPS) in Settings
- Automatic reconnection when the camera drops the connection or stops sending frames
- Motion-triggered recording of all cameras during a daily time window, by a background
  recorder that runs while the app is closed; see [Recording](#recording)
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
first Developer ID certificate in your keychain, else the first Apple Development one, or
ad-hoc if there is neither. Without a Developer ID the app runs only on the Mac that built
it, and an ad-hoc signed app makes the keychain ask for the camera passwords again after
every build, since each build counts as a different app; see
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
  Whether the camera also lights it by itself, on motion in the dark, is the **Turn on by
  itself** switch under Spotlight in Settings.
- **Reconnect** (⌘R) restarts the connection by hand, for every camera on screen. The app
  also does this by itself when a camera drops the connection or stops sending frames.

## Recording

**Settings › Recording** records every camera during a daily time window and keeps only
the files in which something moved. The settings apply to all cameras.

- **The recorder** is the app itself, started without a window (`ReolinkViewer --recorder`).
  Switching *Record all cameras* on registers it as a login item, so macOS starts it at
  login and keeps it running while the app is closed. It keeps the Mac awake during the
  window and is idle outside it. This needs the built app (`build-app.sh`), signed with a
  certificate; see [Signing](#signing-and-notarizing-a-release).
- **Files** are MP4, one per minute, cut at the first key frame after each full minute and
  written without re-encoding, with sound. They are in
  `~/Library/Application Support/ReolinkViewer/Recordings/<camera id>/yyyy-MM-dd/HHmmssZ_60s.mp4`,
  named after their start time in UTC.
- **Motion** comes from the camera's own detector, so its sensitivity and zones are set on
  the camera. A file is kept if motion, widened by 10 s before and 20 s after, touches it;
  the decision falls 10 s after the file closes, and every other file is deleted. A camera
  that pushes no motion events is judged by the size of its predicted frames instead.
- **Clean-up:** kept files are deleted from the Mac after 2 days (adjustable).
- **Log:** `~/Library/Logs/ReolinkViewer/recorder.log` says what was kept, deleted and uploaded.

### Off-site storage

**Set Up…** under *Off-site storage* sends the kept files to a bucket at any S3-compatible
service. Without it they stay on the Mac, unencrypted.

- **Encryption:** each file is sealed on the Mac with AES-256-GCM before it is uploaded, so
  the provider holds only ciphertext. The key is random; the bucket holds it wrapped with
  your passphrase (`keys/data-key.json`). Setup can generate the passphrase and shows it
  once: keep a copy outside the Mac, or a lost Mac means lost recordings.
- **Two keys:** the *upload key* is stored in the keychain and used by the recorder; give it
  the right to upload and nothing else. The *setup key* is used during setup only: it reads
  and writes the key file and writes the bucket's lifecycle rule.
- **Retention:** the bucket deletes recordings itself after the period chosen in setup (14
  days by default), through a lifecycle rule on the `recordings/` prefix. Writing it replaces
  the lifecycle rules the bucket had. To change the period, run setup again.
- **Outages:** uploads are queued on disk and catch up when the connection is back. The
  sealed files stay on the Mac for the clean-up period as a cache.
- **In the bucket:** `recordings/<camera id>/yyyy-MM-dd/HHmmssZ_60s.mp4.enc`, and one sealed
  index per day, `recordings/index/yyyy-MM-dd.json.enc`, listing every camera's files and
  motion times. The provider sees names, sizes and upload times, not the content.

`bctool storage` tries a bucket and a key before you commit to a provider, and
`bctool decrypt` opens a downloaded file with the key file and the passphrase.

### Setting up Amazon S3

The steps use the [AWS CLI](https://aws.amazon.com/cli/) with an administrator profile; the
console does the same under S3 and IAM. Replace `my-cams` and `eu-central-1` with your
bucket name and region. The bucket name must not contain dots.

**1. Create the bucket.** New buckets are private; the second command makes sure it stays so.

```sh
aws s3api create-bucket --bucket my-cams --region eu-central-1 \
    --create-bucket-configuration LocationConstraint=eu-central-1
aws s3api put-public-access-block --bucket my-cams --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

(In `us-east-1`, leave out `--create-bucket-configuration`.)

**2. Create the upload user.** It may write below `recordings/` and nothing else: no
reading, no listing, no deleting.

```sh
aws iam create-user --user-name my-cams-upload
aws iam put-user-policy --user-name my-cams-upload --policy-name upload --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::my-cams/recordings/*"
  }]
}'
aws iam create-access-key --user-name my-cams-upload
```

Note the `AccessKeyId` and `SecretAccessKey` it prints: this is the *upload key*.

**3. Create the setup user.** It reads and writes the key file and writes the lifecycle
rule. It needs `s3:ListBucket` so that S3 reports a missing key file as missing instead of
as forbidden.

```sh
aws iam create-user --user-name my-cams-setup
aws iam put-user-policy --user-name my-cams-setup --policy-name setup --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::my-cams/keys/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:PutLifecycleConfiguration"],
      "Resource": "arn:aws:s3:::my-cams"
    }
  ]
}'
aws iam create-access-key --user-name my-cams-setup
```

This is the *setup key*.

**4. Check the upload key** before entering anything in the app:

```sh
swift build --product bctool
BC_S3_SECRET='<upload secret>' .build/debug/bctool storage --endpoint s3.eu-central-1.amazonaws.com \
    --region eu-central-1 --bucket my-cams --key-id '<upload key id>' --delete
```

The upload must succeed; the download and the delete must fail with `403 AccessDenied`.
If the delete is allowed, the key is too strong.

**5. Run storage setup** in the app, **Settings › Recording › Set Up…**:

| Field | Value |
| --- | --- |
| Endpoint | `s3.eu-central-1.amazonaws.com` (the regional endpoint, not `s3.amazonaws.com`) |
| Region | `eu-central-1` |
| Bucket | `my-cams` |
| Upload key | from step 2 |
| Setup key | from step 3 |
| Delete recordings after | 14 days, or what you want |
| Write the bucket's lifecycle rule | on |
| Passphrase | empty to have one generated; it is shown once, save it in a password manager |

Then check what setup wrote:

```sh
aws s3api get-bucket-lifecycle-configuration --bucket my-cams   # one rule: prefix recordings/, 14 days
aws s3 ls s3://my-cams/keys/                                    # data-key.json
```

**6. Retire the setup key.** It is not stored on the Mac and not needed again until you
change the retention period:

```sh
aws iam delete-access-key --user-name my-cams-setup --access-key-id '<setup key id>'
```

For the next setup run, make a new one with `aws iam create-access-key`.

**Optional: protect against overwriting.** The upload key cannot delete, but it can upload a
new object under an existing name. With versioning the old version survives that:

```sh
aws s3api put-bucket-versioning --bucket my-cams --versioning-configuration Status=Enabled
```

A versioned bucket needs a lifecycle rule that also removes old versions, which the app
does not write. Switch *Write the bucket's lifecycle rule* off in setup and set the rule
yourself:

```sh
aws s3api put-bucket-lifecycle-configuration --bucket my-cams --lifecycle-configuration '{
  "Rules": [{
    "ID": "reolinkviewer-retention",
    "Status": "Enabled",
    "Filter": {"Prefix": "recordings/"},
    "Expiration": {"Days": 14},
    "NoncurrentVersionExpiration": {"NoncurrentDays": 14}
  }, {
    "ID": "reolinkviewer-cleanup",
    "Status": "Enabled",
    "Filter": {"Prefix": "recordings/"},
    "Expiration": {"ExpiredObjectDeleteMarker": true},
    "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 1}
  }]
}'
```

**Moving from another provider.** Setup makes a new encryption key for a bucket that has no
key file, and replaces this Mac's copy of the old one. To keep one key for both, copy
`keys/data-key.json` from the old bucket into the new one before running setup, and enter
the old passphrase:

```sh
aws s3 cp s3://old-bucket/keys/data-key.json . --endpoint-url https://<old endpoint>   # with the old provider's key
aws s3 cp data-key.json s3://my-cams/keys/data-key.json                                # with an AWS administrator profile
```

Recordings already in the old bucket stay there until its own lifecycle rule deletes them.

Playing the recordings back in the app is planned; see [RECORDING_PLAN.md](RECORDING_PLAN.md).

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
.build/debug/bctool light    --host 192.168.1.20 --auto off       # spotlight no longer comes on by itself at night
.build/debug/bctool raw      --host 192.168.1.20 --id 289         # any request without a body; prints the reply
.build/debug/bctool daynight --host 192.168.1.20 --mode color     # auto | color | bw; omit to read
.build/debug/bctool osd      --host 192.168.1.20 --name 'Garden'  # name shown in the picture; omit to read
.build/debug/bctool services --host 192.168.1.20 --onvif on       # also --rtsp/--rtmp/--http/--https; omit to read
.build/debug/bctool users    --host 192.168.1.20                  # list user accounts
.build/debug/bctool passwd   --host 192.168.1.20 --new 'secret'   # change the password, then log in with it
.build/debug/bctool events   --host 192.168.1.20 --seconds 60     # ask for motion events and print them
.build/debug/bctool record   --host 192.168.1.20 --out rec --seconds 180   # 1-minute MP4 files, no re-encoding
.build/debug/bctool recorder --host 192.168.1.20 --out rec --seconds 600   # as the background recorder: keeps only files with motion
.build/debug/bctool sizes    --host 192.168.1.20 --seconds 60     # frame-size motion detection next to the camera's own
BC_S3_SECRET=… .build/debug/bctool storage --endpoint s3.example.com --bucket cams --key-id K --delete
                                                                  # can this key upload and download? may it delete?
BC_PASSPHRASE=… .build/debug/bctool decrypt --in 135400Z_60s.mp4.enc --key-file data-key.json \
    --name recordings/<camera id>/2026-11-19/135400Z_60s.mp4.enc  # open a file downloaded from the bucket
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
- Automatic spotlight: message id 289 returns the same `FloodlightTask` document on cameras
  that refuse 438: `enable` 1/0 (whether the light comes on by itself), `alarmMode` (1 = on
  motion in the dark), brightness and schedules. Id 290 takes the document back with `enable`
  changed. Switching it off makes the camera set `alarmMode` to 0 and keep the old value in
  `lastAlarmMode`; switching it on again restores it. Ids from Neolink and reolink_aio,
  verified on a fixed camera.
- Motion events: id 31 without a body asks the camera to push them; they then arrive
  unasked as id 33 with an `AlarmEventList`, one `AlarmEvent` per channel with `status`
  (`MD` or `none`) and, on cameras with object detection, `AItype` (`people`, `vehicle`,
  `dog_cat`, `none`). The camera pushes the current state right after the request, and
  uses id 33 for other lists too (`DayNightEventList`), which are ignored. Ids and fields
  from Neolink and reolink_aio, verified on an E1 and two fixed cameras.
- Message id 4 with the same message number stops the stream; the camera sometimes
  pings with id 234, which is answered with code 200.

## Development

```
Sources/Baichuan/       protocol library (pure Swift, no dependencies)
Sources/CameraMedia/    sample buffers from the camera's frames, MP4 segment recorder
Sources/Recording/      the background recorder: daily window, motion log, keep rule, local folder,
                        encryption, S3 client and upload queue
Sources/bctool/         command-line client
Sources/ReolinkViewer/  the SwiftUI app
Tests/BaichuanTests/    unit tests for framing, crypto, XML and media parsing
Tests/CameraMediaTests/ unit tests for the sample builders and the segment recorder
Tests/RecordingTests/   unit tests for the window, the keep rule, the clean-up, encryption,
                        request signing (AWS's worked examples) and the upload queue
AppIcon.icon            app icon, an Icon Composer document (SF Symbol camera.fill on blue)
build-app.sh            builds, signs and notarizes build/ReolinkViewer.app
```

### Tests

```sh
swift test
```

The tests need no camera. They cover header encoding, the login handshake, XOR and AES
round trips with known answers, XML builders, the media parser (including chunk
boundaries and resync after garbage) and the Day & Night document rewrite. The recorder
tests encode a short H.264 and H.265 stream with VideoToolbox, record it, and decode the
MP4 files again; they are skipped on a Mac without the encoder.

### Debugging

`REOLINK_DEBUG=1` makes the app log connection and decoding progress to stderr, and
`REOLINK_PASSWORD` overrides the keychain for every camera, so a quick check from Terminal is:

```sh
REOLINK_DEBUG=1 REOLINK_PASSWORD='…' .build/debug/ReolinkViewer
```

For protocol work, `bctool … --verbose` prints every packet in both directions.

The background recorder runs from Terminal too. Settings can be overridden on the command
line, and `REOLINK_RECORDINGS_DIR` sends the files somewhere else:

```sh
REOLINK_RECORDINGS_DIR=/tmp/rec build/ReolinkViewer.app/Contents/MacOS/ReolinkViewer --recorder \
    -recording.enabled YES -recording.startMinute 0 -recording.stopMinute 0 -recording.segmentLength 20
```

It reads the cameras from the app's preferences, so use the binary inside the built app;
the one in `.build` has preferences of its own. Equal start and stop times mean the whole
day. Only one recorder runs per recordings folder. For the storage, `-storage.endpoint`,
`-storage.bucket` and `-storage.uploadKeyID` work the same way, and `REOLINK_S3_SECRET`,
`REOLINK_PASSPHRASE` and `REOLINK_KEY_FILE` stand in for the keychain and the key file.

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
3. otherwise the first **Apple Development** certificate (signed, never notarized),
4. otherwise ad-hoc.

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
