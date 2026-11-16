# Gauss — Implementation Plan (draft for review)

A SwiftUI iOS app paying homage to HandBrake: pick a video, optionally trim it to a
time range, then either **copy it 1:1** (no re-encode) or **transcode it with a
preset** using the iPhone's hardware encoders.

**Primary use case:** take iPhone camera recordings from the Photos library,
make them smaller (and optionally shorter), then either share them elsewhere
(Mail, Messenger, Files, AirDrop) or save them back to Photos with their
original date and location intact.

**Ethos**: free and open source software licensed under GPLv3, no ads, no
monetisation, no telemetry. Gauss will always respect its users.

**Name** (decision 2026-11-16): renamed from FootBrake to **Gauss**, after Carl
Friedrich Gauss, because the HandBrake team asked for no look-alike name. App
Store name "Gauss: Video Transcoder", bundle ID `net.lastninja.gauss`. HandBrake
stays out of the App Store listing and promotional text. Attribution stays: code
comments and this plan say where ideas came from, and About and the README say
"Gauss is a homage to the venerable HandBrake."

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
- Every component Gauss would want is LGPL: matroska/avi/flv/mpegts/asf/ogg
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

### 3b′. As built (Stage 3, 2026-11-15)
- **Rotation is baked into the pixels** (user decision): the composition's
  layer transform rotates portrait video upright, the output has no display
  matrix, and "720p" output of a portrait clip is 720×1280.
- Video path: `AVAssetReaderVideoCompositionOutput` (HW decode + rotate + scale
  + colour in one GPU pass, `sourceTrackIDForFrameTiming` keeps VFR timestamps)
  → frame-rate cap by timestamp (min gap 0.7/cap) → **`VTCompressionSession`
  directly** (needed for `VariableBitRate`/`ConstantQualityFactor`) →
  `AVAssetWriterInput` passthrough.
- Audio: the stereo AAC track (not APAC), passed through if already ≤ target
  bitrate, otherwise LPCM → AAC.
- MP4 output keeps creation date and location (AVAssetWriter maps them to MP4
  boxes); make/model only survive in MOV.

### 3c. Rate control & "fits in N MB" (revised 2026-11-15)
"Constant quality" and "variable bitrate" are not opposites: a good
constant-quality mode (x264 CRF) *is* VBR. What matters is which VideoToolbox
mode we pick. From the iOS 27.2 SDK headers (`VTCompressionProperties.h`):

| Mode | iOS | Behaviour | Use |
|---|---|---|---|
| `ConstantQualityFactor` (0–1) | 27+ | CRF-like: "consistent visual quality with or without bitrate limit" | Resolution presets on iOS 27+ |
| `VariableBitRate` + `VBVMaxBitRate` | 26+ | True VBR: "allocates higher bitrate for complex segments" | **Not used**: the iPhone 17 Pro Max HEVC encoder ignores its target (see below) |
| `AverageBitRate` + `DataRateLimits` | 8+ | Soft average target plus hard peak cap (VBR in practice) | **Default for all presets** (decided 2026-11-15) |
| `Quality` | 8+ | "For some formats… a fixed quantization parameter". This is constant QP, not CRF, so it's inefficient | Not a default; maybe a hidden advanced option |
| `ConstantBitRate` | 16+ | Legacy CBR | Never |
| Multi-pass | n/a | Not available on iOS | n/a |

- **On-device measurement (iPhone 17 Pro Max, iOS 26.7.1, 60 s handheld 4K60
  Dolby Vision clip, 2026-11-15):** HEVC VBR produced the same size whatever
  the target (≈5.8 Mbps at 1080p for targets 1.9–5.6 Mbps; ≈3.1 at 720p,
  ≈1.75 at 480p). ABR landed within ~5% of target on both codecs. VBR 5.8 Mbps
  vs ABR 5.7 and 3.8 Mbps looked practically the same, so **ABR is the
  default**. Every encode took ≈19.5 s for 60 s of 4K60, limited by
  decoding the source, not by encoding.
- **Deferred pending user feedback:** a size-based bitrate retune (≈0.8× at
  ≥1080, 1.0× at 720, 1.3× at 480). On-device VMAF at the current 1×: HEVC
  1080 99.4, 720 97.6, **480 93.3** (the soft spot); H.264 99.6 / 98.5 / 95.8.
- Bitrate targets come from bits-per-pixel: `bps = width × height × fps × bpp`,
  starting at `bpp ≈ 0.10` (H.264) and `≈ 0.06` (HEVC). 60 fps uses about ×1.5,
  not ×2. We cap at the source bitrate, because re-encoding should never grow
  a file.
- Target-size presets: `videoBps = (targetBytes × 8 × 0.95) / duration − audioBps`.
  Single-pass can overshoot, so we check the size after encoding and re-encode
  once at a reduced bitrate if it's over.
- The capability probe detects each mode per device. A **debug override**
  forces older code paths (ABR-only, no 10-bit) so fallbacks can be tested on a
  new phone.
- **Defaults are set by measurement** (Stage 3): file size vs VMAF over the
  fixtures and real camera clips, for each mode and setting.

### Test devices & OS plan
- **iPhone 17 Pro Max** is the primary test device. Stage 3 measures the
  iOS 26.7.1 paths first (`VariableBitRate`, and the forced
  `AverageBitRate` fallback). Then the phone is upgraded to **iOS 27.2** to
  measure `ConstantQualityFactor`. The upgrade is one-way.
- Mac (`gauss-cli`): fast bulk runs and relative comparisons; macOS 27
  is not required.
- Simulator: UI only (no hardware encoder).
- Before App Store submission: a used iPhone 8/X (A11, stuck on iOS 16) or
  TestFlight testers, to check the slowest chip, oldest iOS, and memory/thermal
  limits.

### 3d. Correctness details we'll handle
- **Rotation:** portrait iPhone video is stored 1920×1080 with a 90° transform.
  "720p" means the *short side* is 720, the aspect ratio is kept, and
  dimensions are rounded to mod-2, like HandBrake's `PictureKeepRatio` +
  `PictureModulus: 2`.
- **VFR sources:** iPhone camera output can be variable frame rate. We
  preserve timestamps rather than resampling.
- **Metadata:** we copy creation date, GPS location, and make/model
  (`AVMetadataItem`) so the output sorts correctly when saved back to Photos.
- **HDR:** HEVC keeps HDR as 10-bit HLG (Main 10). VideoToolbox regenerates
  **Dolby Vision 8.4** metadata (config record + per-frame RPU) for HLG Main 10
  encodes, so outputs match the iPhone's own format (verified on Mac
  2026-11-15; to confirm on iPhone). H.264 or "keep HDR" off → tone-mapped to
  SDR BT.709 by the compositor, matching Apple's own SDR rendering.
- **Disk space:** before starting, we check estimated output size against free
  space.

### 3e. Backgrounding (as built, Stage 6)
- iOS 26+: each export is submitted as a `BGContinuedProcessingTask`
  (`net.lastninja.gauss.export.*`, strategy `.fail`, GPU requested where
  supported). It shows system progress and keeps the app running if the user
  leaves. The entitlement `continued-processing.gpu` is granted.
- **Background GPU is device-dependent.** The iPhone 17 Pro Max reports
  none, so only **copies** run in the background. **Re-encodes** (GPU
  rotate/scale) stay foreground-only: the export sheet says so, and leaving
  stops the job with a clear message and Try Again (decision 2026-11-15).
- iOS 16–25: foreground only; screen kept awake during exports.
- Low storage: export blocked with an explanation if the estimate + 20% +
  50 MB doesn't fit.
- **No job queue** (decision 2026-11-15): Gauss is for handling one clip
  when the need arises (e.g. trimming and sharing a dashcam clip), not batch
  processing, and re-encodes need the app open anyway.

## 3f. Real iPhone 17 Pro Max footage (Stage 1 findings, 2026-11-15)
- Video: HEVC Main 10, **Dolby Vision profile 8.4** (HLG base layer), BT.2020.
  Portrait clips are stored landscape with a 90° rotation.
- Frame timing really is variable. A 4K60 clip averages ~59.9 fps with single
  frames as close as 15 ms apart, so the frame-rate cap must work on
  timestamps.
- Audio: **two tracks**, AAC stereo (~130–200 kbps) plus **APAC spatial audio**
  (4–5 channel ambisonic, ~400–500 kbps). Size presets should drop APAC by
  default; Copy mode keeps it.
- 2–6 timed-metadata tracks (`mebx`, camera/stabilisation data). These are
  dropped on transcode; Copy mode keeps them if AVAssetWriter allows.
- Cinematic mode: the picker gives a rendered file (focus effect baked in, no
  depth track) tagged `com.apple.quicktime.cinematic-video`. Treat it as normal
  video.
- Photos library (Stage 2): saving byte-identical video data twice creates two
  items, but both show the **first** save's original filename. A repeat save
  under a new name (Gauss's button or the share sheet's Save Video)
  therefore uses a fresh passthrough copy (new container
  timestamps) first. Verified on device 2026-11-15.

## 4. Presets (inspired by `~/code/handbrake/preset/preset_builtin.json`)

| Gauss preset | Video | Max size (short side) | Frame rate | Audio | HandBrake analogue |
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
- **Slo-mo (120/240 fps) recordings:** the Photos picker hands over the
  *rendered* slo-mo (30 fps, slowed section baked in, as Photos/Messages show
  it). Verified on device 2026-11-15. No special handling is needed. The raw
  high-frame-rate original would need Photos library permission
  (`PHAssetResourceManager`); that's an optional later feature.

The small presets use H.264 on purpose, because Messenger, email clients, and
web uploaders handle it everywhere. Presets are a `Codable` struct, so user
presets can be saved as JSON later. Before encoding, the UI always shows the
**estimated output size**.

## 5. App structure

```
Gauss.xcodeproj
├── Gauss (iOS app, SwiftUI)
│   ├── SourceView        – PhotosPicker + .fileImporter, recent sources
│   ├── InspectorView     – codec, resolution, fps, duration, bitrate, HDR, tracks
│   ├── TrimView          – AVPlayer preview, filmstrip (AVAssetImageGenerator),
│   │                       two drag handles, HH:MM:SS.mmm fields,
│   │                       "set start/end at playhead", frame-step buttons
│   ├── PresetView        – preset list + est. size; Custom editor
│   ├── ExportView        – progress, cancel, thermal warnings
│   └── OutputView        – Save to Photos / Save to Files / ShareLink (Mail, Messenger…)
├── GaussCore (local Swift package, no UI; iOS + macOS)
│   ├── MediaProbe        – AVURLAsset.load(.tracks, .duration, formatDescriptions…)
│   ├── Capabilities      – VT encoder probing per device
│   ├── Preset / JobPlanner – preset + source → concrete EncodeSettings (pure, unit-testable)
│   └── TranscodeEngine   – reader/writer pipeline, AsyncStream<Progress>
└── gauss-cli (macOS command-line tool using GaussCore)
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
paid team via automatic signing; bundle ID `net.lastninja.gauss` (changeable).

## 6. Staged delivery — each stage ends with something you test

| Stage | Deliverable | How we test |
|---|---|---|
| **0. Scaffold** | Xcode project, Core package, CLI, "Hello Gauss" on your iPhone; ffmpeg-generated fixture clips (H.264/HEVC, HDR HLG, portrait, 60fps, VFR, 5.1 audio, multi-audio) | App launches on device; `swift test` passes |
| **1. Import & inspect** | Pick from Photos/Files, show full media info, play it | Compare InspectorView against `ffprobe` for each fixture + your own camera-roll clips |
| **2. Trim + Copy** | Trim UI, passthrough export with keyframe snap/edit-list option, save/share | `ffprobe` output durations & first PTS; no quality loss (bit-identical frames) |
| **3. Transcode** | Original-size / 1080 / 720 / 480 presets, H.264 & HEVC, AAC, fps cap, progress + cancel | CLI on Mac first (VMAF scores, sizes), then device: speed, thermal, playback in Photos |
| **3½. Metadata** | Editor "Metadata" section: Remove location, Remove device info (toggles, remembered), Recording date Original / Custom (date-time picker, starts at original, phone's time zone) / Remove (not remembered). Rows show current values and only appear if present. Export button moves below it. Applies to Copy, shrink-audio, transcode and Save to Photos; Copy+Keep drops camera-data tracks if they carry location/device data | `ffprobe` + Gauss probe for every combination; Photos info panel |
| **4. Small Streaming** | 10 MB / 25 MB target-size presets with size check + retry, size estimate in UI | Outputs ≤ target for a range of durations; send via Mail / Messenger |
| **5. Fidelity** | HDR keep/tone-map, metadata copy, rotation edge cases, audio track selection | Saved-to-Photos item shows correct date/location/orientation; HDR badge |
| **6. Robustness** | Backgrounding (BGContinuedProcessingTask on 26+), interruptions, low disk, job queue | Lock phone mid-export, incoming call, fill disk |
| **7. Polish** | App icon, About/credits, App Store prep. **No share extension** (decision 2026-11-15): iOS won't let a share extension open its app, so it needed an extra "open Gauss" step; importing from inside Gauss is simpler | Manual |
| **Later (not v1)** | Background re-encodes on devices without background GPU (incl. iPhone 17 Pro Max): replace the GPU video composition with `VTPixelRotationSession` + `VTPixelTransferSession`, *if* the media engine runs under a continued-processing task (untested). v1: copies run in the background (iOS 26+); re-encodes need Gauss open | Only if users ask |
| **Later (not v1)** | Container picker ("Copy as MP4"): no picker in 1.0 (decision 2026-11-16). Copy keeps the source's container so a 1:1 copy keeps everything (MOV carries spatial audio, camera data, make/model); re-encodes are MP4 for compatibility. A "Copy as MP4" toggle via the remux path would drop APAC and camera data | Only if users ask |
| **Later (not v1)** | ffmpeg (LGPL) input module for MKV/WebM/AVI, see 1a | Only if wanted |
| **Later (not v1)** | Photos library access for unrendered originals: raw high-frame-rate slo-mo, and Cinematic with depth/focus data (Cinematic framework) | Only if wanted |

## 8. Post-1.0 roadmap (agreed 2026-11-16)

1. **Multiple slices from one clip** (e.g. keep 0–2 s and 5–8 s, joined).
   Lives inside the existing editor; no home-screen change. Design below.
2. **Join videos**, with a two-button home screen: "Shrink & trim a video"
   and "Join videos", each then offering Photos or Files. Start narrow:
   lossless join when all clips match (codec, profile, size, frame rate,
   HDR, audio); otherwise transcode all to the chosen preset ("match the
   first clip" by default), letterboxing mixed orientations. No mixing of
   copied and re-encoded segments. Only if users ask.

### 8a. Multi-slice design (for review before coding)

**Model.** The selection becomes a list of slices, each a start–end range,
kept in time order, never overlapping, at least 0.1 s long. One slice
covering the whole clip is the default, so the editor behaves exactly as
today until you add a second slice.

**Filmstrip.** Every slice is drawn as a yellow-framed range; everything
outside the slices is dimmed. One slice is *selected* (solid frame and
handles); the others have a thinner frame. Tap a slice to select it. The
handles, the Start/End fields with their ‹ › nudges, and Set Start / Set End
all act on the selected slice.

**Adding and removing.**
- **Add Slice** (next to Set Start / Set End) adds a 2-second slice at the
  playhead, shortened if it would overlap a neighbour, and selects it. If the
  playhead is inside an existing slice, it's split there instead, which is
  the natural way to cut out a middle part: split, then shorten one side.
- Each slice can be deleted (swipe on its row in the list, or a delete
  button when selected); the last remaining slice can't be.
- A compact list under the filmstrip: "1  0:00.0 – 0:02.0", "2  0:05.0 –
  0:08.0", and **Total length** (the sum), which replaces "Length".

**Playback.** Play runs through the slices in order, skipping the gaps, so
the preview matches the export.

**Export.**
- Built from an `AVMutableComposition` of the slices, so rotation, scaling,
  HDR, the frame-rate cap, audio choice, metadata edits and Fit in size
  (budgeted on the total length) all work unchanged.
- **Copy, "At keyframe":** each slice starts at the keyframe at or before its
  start; the list shows each slice's actual start, as today.
- **Copy, "Exact":** frame-exact via edit lists. The footnote warns that
  some web players may hiccup at the joins.
- **Risk to test first:** whether passthrough reading (Gauss's lossless
  remux) works from a multi-range composition as well as Apple's export
  session does. If not, slices that need the remux path fall back to
  stitching sample ranges directly.

**Not in this feature:** reordering slices, transitions, per-slice settings.

## 7. Open questions

1. ~~Minimum iOS version~~: decided, iOS 16.0.
2. ~~Distribution~~: decided, App Store eventually, no submission until tested.
3. ~~MKV/WebM input~~: decided, not in v1.
4. **Screenshots of HandBrake:** they'd help for the Summary/Dimensions/Audio
   tabs if you want the Custom editor to feel familiar. They're not needed for
   stages 0–2.
