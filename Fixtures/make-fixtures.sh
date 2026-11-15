#!/bin/sh
# Generates synthetic test clips covering the cases iPhone camera footage hits.
# Requires Homebrew ffmpeg (libx264, libx265). Output: Fixtures/out/ (gitignored).
set -eu

cd "$(dirname "$0")"
mkdir -p out
FF="ffmpeg -hide_banner -loglevel error -y"
VIDEO="testsrc2=size=1920x1080:rate=30"
TONE="sine=frequency=440:sample_rate=48000"

# 1. Plain H.264 1080p30 + stereo AAC (MP4)
$FF -f lavfi -i "$VIDEO" -f lavfi -i "$TONE" -t 10 \
    -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p -g 30 \
    -c:a aac -b:a 160k -ac 2 out/h264_1080p30_stereo.mp4

# 2. HEVC 1080p60 (like iPhone "1080p HD at 60 fps"), hvc1-tagged MOV
$FF -f lavfi -i "testsrc2=size=1920x1080:rate=60" -f lavfi -i "$TONE" -t 10 \
    -c:v libx265 -preset fast -crf 22 -pix_fmt yuv420p -tag:v hvc1 \
    -x265-params log-level=error:keyint=60 \
    -c:a aac -b:a 160k -ac 2 out/hevc_1080p60.mov

# 3. HEVC 10-bit HLG 4K30 (like iPhone HDR video)
$FF -f lavfi -i "testsrc2=size=3840x2160:rate=30" -f lavfi -i "$TONE" -t 5 \
    -c:v libx265 -preset fast -crf 22 -pix_fmt yuv420p10le -tag:v hvc1 \
    -x265-params log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc \
    -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
    -c:a aac -b:a 160k -ac 2 out/hevc_hlg_10bit_2160p30.mov

# 4. Portrait: stored landscape with a 90° display matrix, as the iPhone camera does
$FF -f lavfi -i "$VIDEO" -f lavfi -i "$TONE" -t 10 \
    -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p \
    -c:a aac -b:a 160k -ac 2 out/_portrait_tmp.mov
$FF -display_rotation 90 -i out/_portrait_tmp.mov -c copy out/portrait_rotated_1080p30.mov
rm out/_portrait_tmp.mov

# 5. Variable frame rate around 30 fps (every 7th frame delayed by 8 ms)
$FF -f lavfi -i "$VIDEO" -f lavfi -i "$TONE" -t 10 \
    -vf "setpts='N/(30*TB)+if(eq(mod(N,7),0),0.008/TB,0)'" -fps_mode passthrough \
    -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p \
    -c:a aac -b:a 160k -ac 2 out/vfr_1080p30.mov

# 6. Two audio tracks: 5.1 AAC + stereo AAC
$FF -f lavfi -i "$VIDEO" -f lavfi -i "$TONE" -f lavfi -i "sine=frequency=880:sample_rate=48000" -t 10 \
    -filter_complex "[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a51]" \
    -map 0:v -map "[a51]" -map 2:a \
    -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p \
    -c:a:0 aac -b:a:0 384k -c:a:1 aac -b:a:1 160k -ac:a:1 2 out/multi_audio_51_stereo.mov

# 7. 24 fps source (must stay 24 even when 30/60 is selected)
$FF -f lavfi -i "testsrc2=size=1280x720:rate=24" -f lavfi -i "$TONE" -t 10 \
    -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p \
    -c:a aac -b:a 128k -ac 2 out/h264_720p24.mp4

echo "Fixtures written to $(pwd)/out:"
for f in out/*; do
    ffprobe -v error -show_entries stream=codec_name,width,height,r_frame_rate,channels,color_transfer:stream_side_data=rotation \
        -of compact=nk=0:p=0 "$f" | sed "s|^|  $(basename "$f"): |"
done
