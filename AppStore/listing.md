# App Store listing (draft)

Paste into App Store Connect. Character limits in brackets.

## App information

| Field                    | Value                                                           |
|--------------------------|-----------------------------------------------------------------|
| Name [30]                | FootBrake: a HandBrake homage                                   |
| Subtitle [30]            | Open Source video compressor                                    |
| Primary category         | Photo & Video                                                   |
| Secondary category       | Utilities                                                       |
| Age rating               | 4+ (no objectionable content)                                   |
| Price                    | Free, no in-app purchases                                       |
| Copyright                | 2026 Naveen Nathan                                              |
| Support URL              | https://github.com/nnathan/FootBrake/issues                     |
| Marketing URL (optional) | https://github.com/nnathan/FootBrake                            |
| Privacy policy URL       | https://github.com/nnathan/FootBrake/blob/main/PRIVACY.md       |
| App privacy              | Data Not Collected                                              |
| Encryption               | None beyond Apple's (ITSAppUsesNonExemptEncryption = NO is set) |

"FootBrake" alone is reserved by another developer, so the store name is "FootBrake: a
HandBrake homage". The HandBrake team has been asked about it; if they ever object, switch to
"FootBrake Transcoder". The name under the app icon on the home screen stays "FootBrake".

## Promotional text [170]

Make videos smaller and shorter with your iPhone's hardware encoder, then save them to Photos or share them. Free and open source, with no ads or tracking.

## Keywords [100]

compress,shrink,trim,convert,resize,mp4,hevc,h264,email,share,4k,hdr,cut,reduce,clip,transcode

(Words already in the name or subtitle, such as "video", "compressor", "open source" and
"HandBrake", are indexed anyway, so they're left out. Other apps' names aren't allowed in
keywords.)

## Description [4000]

FootBrake makes videos smaller and shorter, so they're easier to share or keep.

Pick a video from Photos or Files, trim it to the part you want, and choose how to export it:

• Copy: trim without re-encoding, so the picture is untouched
• Original size, 1080p, 720p or 480p: transcode with the iPhone's hardware encoder, in HEVC or H.264, at 30 or 60 fps
• Fit in size: choose 10, 20, 50 or 100 MB, or your own limit, and FootBrake picks the resolution and bitrate so the file fits

FootBrake also:

• Keeps HDR (Dolby Vision and HLG), or converts to standard range for the widest compatibility
• Makes portrait videos come out upright everywhere
• Lets you keep the original audio or choose a smaller size
• Can remove location and device details, or change the recording date
• Saves to Photos with the original date and place, or shares through any app
• Shows the expected file size before you export

FootBrake is free and open source software, licensed under the GNU GPL v3. There are no ads, subscriptions or tracking. The source code is at github.com/nnathan/FootBrake, and feedback and bug reports are welcome there.

## App Review notes

FootBrake needs no account or sign-in. To try it: tap "Choose from Photos", pick any video,
optionally trim it, choose a preset under Export (for example "720p" or "Fit in size") and tap
Export. The result can be saved to Photos or shared.

Re-encoding uses the hardware video encoder and runs while the app is open; copies (no
re-encode) can continue in the background on iOS 26 using a continued-processing task, which is
why the app has the background-tasks GPU entitlement.

FootBrake is open source: https://github.com/nnathan/FootBrake

## TestFlight: beta description

FootBrake is a free and open source video transcoder for iPhone and iPad, directly inspired by
HandBrake. It makes videos smaller and shorter using your device's hardware encoder: trim a clip,
pick a preset or a target file size, then save it to Photos or share it. No ads, no in-app
purchases, no tracking.

## TestFlight: what to test

Thanks for testing FootBrake! Take videos from your iPhone or your dashcam and try compressing,
trimming, transcoding and removing metadata (location, device, date), then save or share the
results. The "Fit in size" preset is worth trying with different limits.

If you want to try more exotic videos, use slo-mo (up to 240 fps), 4K at 60 or 120 fps, or
Cinematic videos from the iPhone Camera app.

FootBrake has not been tested on a real iPad yet (only the simulator), so iPad feedback is
especially welcome.

Report problems at https://github.com/nnathan/FootBrake/issues, or via TestFlight's feedback.
