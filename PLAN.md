# FootBrake — Implementation Plan (draft for review)

A SwiftUI iOS app inspired by HandBrake: pick a video, optionally trim it to a
time range, then either **copy it 1:1** (no re-encode) or **transcode it with a
preset** using the iPhone's hardware encoders.

**Primary use case:** take iPhone camera recordings from the Photos library,
make them smaller (and optionally shorter), then either share them elsewhere
(Mail, Messenger, Files, AirDrop) or save them back to Photos with their
original date and location intact.

Nothing below has been built yet. This document is for review.

---

## 1. Core decision: native AVFoundation + VideoToolbox, no ffmpeg (for now)

| | Native (AVFoundation / VideoToolbox) | ffmpeg binary/xcframework |
|---|---|---|
| HW H.264 / HEVC encode | Yes. This is the only way to reach the HW encoder on iOS. | Only through `h264_videotoolbox`/`hevc_videotoolbox`, which wrap the same VideoToolbox API |
| HW decode | Yes, automatic | Only via `-hwaccel videotoolbox`; otherwise software |
| App size | ~0 MB | +7.6 MB measured (minimal LGPL arm64 build; see 1a) |
| Licensing | None | LGPL builds are App Store-compatible only with care; x264/x265 (GPL) are **not** |
| Input containers | MP4, MOV, M4V, 3GP | MKV, WebM, AVI, FLV, TS, … |
| Input codecs | H.264, HEVC, ProRes, MPEG-4, AV1 (A17 Pro+ only), AAC, ALAC, AC-3/E-AC-3, PCM | Nearly everything (software) |

ffmpeg gives us **more input formats** and nothing else. The output quality
comes from Apple's encoder either way.

**Decision (2026-11-15): no ffmpeg in v1.** Camera-roll video is always
HEVC/H.264 MOV, which AVFoundation handles natively. Section 1a records the
LGPL findings in case MKV/WebM input is wanted later.

### 1a. LGPL FFmpeg: verified (2026-11-15)
Source: `~/code/ffmpeg/ffmpeg-9.0.2` (same release HandBrake 9 uses).
- FFmpeg is LGPL v2.1+ unless `--enable-gpl` / `--enable-version3` /
  `--enable-nonfree` are passed (`LICENSE.md`; `configure` lines 2029–2064, 4827–4845).
- Every component FootBrake would want is LGPL: matroska/avi/flv/mpegts/asf/ogg
  demuxers; vp8/vp9/mpeg2/mpeg4/wmv/vc1/h264/hevc/ac3/eac3/dts/truehd/opus/
  vorbis/flac decoders; videotoolbox hwaccel + `h264/hevc_videotoolbox` encoders;
  swscale/swresample. GPL-only pieces are x264, x265, xvid, and ~30 filters we don't need.
- We must **not** pass `--enable-version3`: LGPLv3 §4(e) requires "Installation
  Information" for consumer devices, which the App Store makes impossible.
  LGPL v2.1 has no such clause.
- A test cross-build (arm64, iOS 16 min, `--disable-everything` + selected
  components above, shared libs) configured as **"LGPL version 2.1 or later"**
  (`CONFIG_GPL 0`), compiled cleanly, and came to **7.6 MB** total dylibs.
- ffmpeg's native AV1 decoder is hwaccel-only. Software AV1 decode needs
  libdav1d (BSD-2, LGPL-compatible). We'd add it only if wanted.
- Compliance recipe (from ffmpeg.org/legal.html): no gpl/nonfree flags; ship as
  **dynamic frameworks** in an xcframework (not static); app credits FFmpeg +
  LGPL text; publish the exact source tarball, patches, and build script;
  don't obfuscate or forbid reverse-engineering in our terms. The remaining
  grey area is App Store usage rules vs. LGPL "no further restrictions". The
  libVLC/VLC-for-iOS precedent (LGPL, on App Store since 2013) is reassuring.
  This is not legal advice.

HandBrake's own macOS VideoToolbox encoder (`libhb/platform/macosx/encvt.c`,
`vt_common.c`) is our reference for property choices and capability probing.

## 2. Codec matrix

**Video output**

| Codec | HW encode on | Notes |
|---|---|---|
| H.264 High (8-bit) | every iPhone | "Max compatibility" option. Used for email/Messenger presets. |
| HEVC Main (8-bit) | A10+ (iPhone 7+) | Default for quality presets. ~40% smaller than H.264 for the same quality. |
| HEVC Main10 (10-bit, HDR) | probed at runtime (certainly A14+) | Used only when the source is HDR (HLG/Dolby Vision from iPhone camera) and "Keep HDR" is on |
| ProRes | A15 Pro+ only | Not planned. Files are huge, which defeats the purpose. |
| AV1 | none (decode only on A17 Pro+) | Not possible |

We probe what the device supports at runtime with
`VTCopySupportedPropertyDictionaryForEncoder`, the same way HandBrake does in
`vt_common.c`, and hide presets the device can't run.

**Audio output:** AAC-LC (AudioToolbox, 96–160 kbps stereo), HE-AAC for the
smallest presets (48–64 kbps), or passthrough when the source is already AAC
(this matches HandBrake's `AudioCopyMask: copy:aac`).

**Containers:** `.mp4` (default, most shareable) and `.mov`.

## 3. Engine: low-level design

Everything runs in one engine built on **`AVAssetReader` → (optional
processing) → `AVAssetWriter`**. Copy and transcode go through the same code
path, so progress, cancel, trim, and metadata handling are shared.

### 3a. Copy (passthrough) mode
- `AVAssetReaderTrackOutput(track:, outputSettings: nil)` gives us the
  compressed `CMSampleBuffer`s untouched.
- `AVAssetWriterInput(mediaType:, outputSettings: nil, sourceFormatHint:)`
  writes them untouched.
- Trim: `reader.timeRange = CMTimeRange(start:, end:)`. The video can only
  start cleanly on a **keyframe (sync sample)**. We offer two behaviours:
  1. **Snap to keyframe** (default). We find the sync sample at or before the
     requested start by checking `kCMSampleAttachmentKey_NotSync`. The UI shows
     the user the actual start time. Every player handles this.
  2. **Exact via edit list**. We keep the GOP prefix and write an MP4 edit
     list so the file starts playing at the exact frame. Apple players and
     most others honour this; a few web uploaders don't.
  - (Later) **Smart cut**: re-encode only the first partial GOP and copy the
    rest. This is frame-exact without a full transcode. It's a stretch goal.
- Speed is limited only by disk I/O, so a 1 GB clip takes seconds.

### 3b. Transcode mode
**Decode + scale + rotate.** We use
`AVAssetReaderVideoCompositionOutput` with an `AVMutableVideoComposition`
(`renderSize`, a layer instruction applying the track's
`preferredTransform`). This runs HW decode and GPU scaling in one step and
outputs `CVPixelBuffer`s (`420YpCbCr8BiPlanarVideoRange`, or
`420YpCbCr10BiPlanarVideoRange` for HDR). The composition's
`colorPrimaries/transferFunction/YCbCrMatrix` set to Rec.709 gives us **HDR→SDR
tone-mapping** for free when the output is H.264 or "Keep HDR" is off.

**Frame-rate cap** (e.g. 60→30 fps). We drop frames in our loop based on PTS,
the same as HandBrake's "peak frame rate" (`pfr`) mode.

**Encode.** In stage 3 we start with `AVAssetWriterInput(outputSettings:)`:
```swift
[AVVideoCodecKey: AVVideoCodecType.hevc,
 AVVideoWidthKey: w, AVVideoHeightKey: h,
 AVVideoCompressionPropertiesKey: [
   AVVideoAverageBitRateKey: bps,
   AVVideoMaxKeyFrameIntervalDurationKey: 2,       // keyframe every 2s (seekable)
   AVVideoExpectedSourceFrameRateKey: fps,
   AVVideoAllowFrameReorderingKey: true,           // B-frames
   AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
   kVTCompressionPropertyKey_DataRateLimits: [peakBytes, 1.0] // VBV-style cap
 ],
 AVVideoColorPropertiesKey: [...]]
```
`AVAssetWriter` drives VideoToolbox's hardware encoder internally.

If we need knobs AVAssetWriter doesn't expose (constant-quality
`kVTCompressionPropertyKey_Quality`, multi-pass via `VTMultiPassStorage`,
`PrioritizeEncodingSpeedOverQuality`), we swap in an explicit
**`VTCompressionSession`** encoder. It feeds already-compressed samples into
the same passthrough writer input from 3a. The engine hides this behind an
`VideoEncoder` protocol, so the swap is local. This is exactly the structure of
HandBrake's `encvt.c`.

**Audio.** `AVAssetReaderTrackOutput` decodes to LPCM (forced to stereo with
`AVNumberOfChannelsKey: 2`). Then
`AVAssetWriterInput(outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: …, AVSampleRateKey: 48000])`
re-encodes it. If the source is AAC at or below the target bitrate, we pass it
through as in 3a.

**Pump loop.** A Swift `actor TranscodeJob` runs
`requestMediaDataWhenReady(on:)` per track on serial queues. It reports
progress (`last PTS / range duration`) as an `AsyncStream<Progress>` and
supports cancel (`reader.cancelReading()`, `writer.cancelWriting()`).

### 3c. Rate control & "fits in N MB"
- Quality presets use **average bitrate** derived from bits-per-pixel:
  `bps = width × height × fps × bpp`. Here `bpp ≈ 0.10` for H.264 and `≈ 0.06`
  for HEVC, tuned during testing. We cap it at the source bitrate, because
  re-encoding should never make a file bigger.
- Target-size presets work like HandBrake's "Social 10/25 MB" presets:
  `videoBps = (targetBytes × 8 × 0.95) / duration − audioBps`, plus a
  `DataRateLimits` peak cap. Single-pass hardware rate control can overshoot,
  so after encoding we check the size. If it's over the limit, we re-encode
  once at a reduced bitrate. (Later: two-pass via `VTMultiPassStorage` if the
  device supports it.)
- Constant-quality (`kVTCompressionPropertyKey_Quality`) is probed at runtime.
  HandBrake's VT presets use it on Apple Silicon Macs, but support on A-series
  phones is not guaranteed.

### 3d. Correctness details we'll handle
- **Rotation:** portrait iPhone video is stored 1920×1080 with a 90° transform.
  "720p" means the *short side* is 720, the aspect ratio is kept, and
  dimensions are rounded to mod-2, like HandBrake's `PictureKeepRatio` +
  `PictureModulus: 2`.
- **VFR sources:** iPhone camera output can be variable frame rate. We
  preserve timestamps rather than resampling.
- **Metadata:** we copy creation date, GPS location, and make/model
  (`AVMetadataItem`) so the output sorts correctly when saved back to Photos.
- **HDR:** we carry color attachments through. Dolby Vision RPU metadata is
  dropped on re-encode, but the base HLG layer stays.
- **Disk space:** before starting, we check estimated output size against free
  space.

### 3e. Backgrounding & thermals
iOS suspends apps in the background, and the GPU/encoder can't be used there
on older iOS.
- iOS 26+: `BGContinuedProcessingTask` lets a user-started export keep running
  with a system progress UI.
- Older iOS: `isIdleTimerDisabled = true` during export, a short
  `beginBackgroundTask` grace period, and a clear "keep FootBrake open" banner.
  If the app gets interrupted, the job fails cleanly and offers a restart.
- We watch `ProcessInfo.thermalState` and show a warning when the device runs
  hot.

## 4. Presets (inspired by `~/code/handbrake/preset/preset_builtin.json`)

| FootBrake preset | Video | Max size (short side) | Frame rate | Audio | HandBrake analogue |
|---|---|---|---|---|---|
| **Copy (no re-encode)** | passthrough | source | source | passthrough | n/a |
| **Original Size — HEVC** | HEVC (10-bit if HDR) | source | 30 / 60 | AAC 160k / copy | H.265 Apple VideoToolbox |
| **Original Size — H.264** | H.264 High | source | 30 / 60 | AAC 160k / copy | Fast 1080p30 |
| **1080p** | HEVC or H.264 | 1080 | 30 / 60 | AAC 160k | Fast 1080p30 / Apple 1080p60 |
| **720p** | HEVC or H.264 | 720 | 30 / 60 | AAC 128k | Fast 720p30 / Creator 720p60 |
| **480p** | H.264 | 480 | 30 / 60 | AAC 96k | Fast 480p30 |
| **Small Streaming — 25 MB** | H.264 | auto by duration: ≤30s→1080, ≤1m→720, ≤2m→540, ≤5m→360 | 30 / 60 | HE-AAC 64k | Social 25 MB * |
| **Small Streaming — 10 MB** | H.264 | auto: ≤30s→720, ≤1m→540, ≤2m→360, longer→240 | 30 / 60 | HE-AAC 48k | Social 10 MB * |
| **Custom** | any supported | any | any | any | n/a |

**Frame rate:** every transcode preset has a **30 / 60 fps** switch, and it
**defaults to 30**. The app remembers your last choice.
- The value is a *cap*, never an increase. A 24/25/30 fps source stays at its
  own rate even with 60 selected, and the 60 option is greyed out with a note
  when the source is ≤30 fps.
- iPhone camera footage is variable frame rate (VFR) around the target rate. We
  pick frames by timestamp (HandBrake's "peak frame rate" mode), so 60→30 is
  smooth and audio stays in sync.
- 60 fps raises the bitrate by about ×1.5 rather than ×2, because consecutive
  frames are more alike. For the fixed-size presets, 60 fps means each frame
  gets fewer bits. The UI notes "60 fps will look softer at this size".
  (HandBrake's Social presets use 60. We default to 30 because at 10–25 MB
  sharpness matters more than smoothness.)
- **Slo-mo (120/240 fps) recordings:** with a 30/60 cap they play at real
  speed, without the slow-motion section. Keeping the slow-mo effect (rendering
  Photos' time ramp) is a Stage 5 item.

The small presets use H.264 on purpose, because Messenger, email clients, and
web uploaders handle it everywhere. Presets are a `Codable` struct, so user
presets can be saved as JSON later. Before encoding, the UI always shows the
**estimated output size**.

## 5. App structure

```
FootBrake.xcodeproj
├── FootBrake (iOS app, SwiftUI)
│   ├── SourceView        – PhotosPicker + .fileImporter, recent sources
│   ├── InspectorView     – codec, resolution, fps, duration, bitrate, HDR, tracks
│   ├── TrimView          – AVPlayer preview, filmstrip (AVAssetImageGenerator),
│   │                       two drag handles, HH:MM:SS.mmm fields,
│   │                       "set start/end at playhead", frame-step buttons
│   ├── PresetView        – preset list + est. size; Custom editor
│   ├── ExportView        – progress, cancel, thermal warnings
│   └── OutputView        – Save to Photos / Save to Files / ShareLink (Mail, Messenger…)
├── FootBrakeCore (local Swift package, no UI; iOS + macOS)
│   ├── MediaProbe        – AVURLAsset.load(.tracks, .duration, formatDescriptions…)
│   ├── Capabilities      – VT encoder probing per device
│   ├── Preset / JobPlanner – preset + source → concrete EncodeSettings (pure, unit-testable)
│   └── TranscodeEngine   – reader/writer pipeline, AsyncStream<Progress>
└── footbrake-cli (macOS command-line tool using FootBrakeCore)
```

Why the separate Core package plus a Mac CLI: VideoToolbox and AVFoundation
behave almost identically on macOS. So we can run the engine against a folder
of test clips on the Mac in seconds, check the outputs with `ffprobe`, and
measure quality objectively with VMAF (`ffmpeg -lavfi libvmaf`) **before** we
put anything on the phone. The iOS Simulator has no hardware encoder, so we
test encoding on the device.

Tooling: Swift 6, SwiftUI, **Xcode 27.2**, **iOS 16.0 minimum**, **App Store target**
(nothing is submitted until you finish testing). `xcode-select` points at
CommandLineTools; I'd build with `DEVELOPER_DIR=/Applications/Xcode.app/...`
or you'd run `sudo xcode-select -s /Applications/Xcode.app`. Signing uses your
paid team via automatic signing; bundle ID `net.lastninja.footbrake` (changeable).

## 6. Staged delivery — each stage ends with something you test

| Stage | Deliverable | How we test |
|---|---|---|
| **0. Scaffold** | Xcode project, Core package, CLI, "Hello FootBrake" on your iPhone; ffmpeg-generated fixture clips (H.264/HEVC, HDR HLG, portrait, 60fps, VFR, 5.1 audio, multi-audio) | App launches on device; `swift test` passes |
| **1. Import & inspect** | Pick from Photos/Files, show full media info, play it | Compare InspectorView against `ffprobe` for each fixture + your own camera-roll clips |
| **2. Trim + Copy** | Trim UI, passthrough export with keyframe snap/edit-list option, save/share | `ffprobe` output durations & first PTS; no quality loss (bit-identical frames) |
| **3. Transcode** | Original-size / 1080 / 720 / 480 presets, H.264 & HEVC, AAC, fps cap, progress + cancel | CLI on Mac first (VMAF scores, sizes), then device: speed, thermal, playback in Photos |
| **4. Small Streaming** | 10 MB / 25 MB target-size presets with size check + retry, size estimate in UI | Outputs ≤ target for a range of durations; send via Mail / Messenger |
| **5. Fidelity** | HDR keep/tone-map, metadata copy, rotation edge cases, audio track selection | Saved-to-Photos item shows correct date/location/orientation; HDR badge |
| **6. Robustness** | Backgrounding (BGContinuedProcessingTask on 26+), interruptions, low disk, job queue | Lock phone mid-export, incoming call, fill disk |
| **7. Polish** | Custom preset editor, saved presets, Share Extension ("Open in FootBrake" from Photos) | Manual |
| **Later (not v1)** | ffmpeg (LGPL) input module for MKV/WebM/AVI, see 1a | Only if wanted |

## 7. Open questions

1. ~~Minimum iOS version~~: decided, iOS 16.0.
2. ~~Distribution~~: decided, App Store eventually, no submission until tested.
3. ~~MKV/WebM input~~: decided, not in v1.
4. **Screenshots of HandBrake:** they'd help for the Summary/Dimensions/Audio
   tabs if you want the Custom editor to feel familiar. They're not needed for
   stages 0–2.
