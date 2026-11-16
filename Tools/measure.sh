#!/bin/sh
# Measures file size vs VMAF for Gauss's rate-control modes.
#
#   Tools/measure.sh <clip>... > results.csv
#
# For each clip, size and codec, a near-lossless reference is encoded through
# Gauss's own pipeline (same scaling, rotation, frame-rate cap and tone
# mapping), so VMAF measures only compression loss. Needs Homebrew ffmpeg with
# libvmaf and a built gauss-cli (swift build in GaussCore).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/GaussCore/.build/debug/gauss-cli"
WORK="${TMPDIR:-/tmp}/gauss-measure"
mkdir -p "$WORK"

SIZES="${SIZES:-1080 720 480}"
MULTS="${MULTS:-0.5 1 1.5 2}"
MODES="${MODES:-vbr abr}"
FPS="${FPS:-30}"

vmaf() {   # vmaf <distorted> <reference>
    ffmpeg -nostdin -hide_banner -nostats -i "$1" -i "$2" -lavfi \
        "[0:v]setpts=PTS-STARTPTS[d];[1:v]setpts=PTS-STARTPTS[r];[d][r]libvmaf=n_threads=8" \
        -f null - 2>&1 | sed -n 's/.*VMAF score: \([0-9.]*\).*/\1/p'
}

echo "clip,codec,size,fps,mode,target_kbps,video_kbps,file_bytes,vmaf,encode_s"
for clip in "$@"; do
    name="$(basename "${clip%.*}")"
    for codec in hevc h264; do
        bpp=$([ "$codec" = hevc ] && echo 0.06 || echo 0.10)
        sdr=$([ "$codec" = h264 ] && echo --sdr || echo "")
        for size in $SIZES; do
            ref="$WORK/$name-$codec-$size-ref.mov"
            "$CLI" transcode "$clip" "$ref" --codec "$codec" --short "$size" --fps "$FPS" --qp 1.0 $sdr --audio 64 >/dev/null
            dims=$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 "$ref" | head -1 | cut -d, -f1,2)
            w=${dims%,*}; h=${dims#*,}
            fps=$(ffprobe -v error -select_streams v -show_entries stream=avg_frame_rate -of default=nk=1:nw=1 "$ref" | head -1 | awk -F/ '{print $1/$2}')
            eff=$(awk -v f="$fps" 'BEGIN { print (f <= 30) ? f : 30 + (f - 30) * 0.5 }')
            for mult in $MULTS; do
                kbps=$(awk -v w="$w" -v h="$h" -v f="$eff" -v b="$bpp" -v m="$mult" 'BEGIN { printf "%d", w*h*f*b*m/1000 }')
                for mode in $MODES; do
                    out="$WORK/$name-$codec-$size-$mode-$mult.mp4"
                    start=$(date +%s.%N)
                    "$CLI" transcode "$clip" "$out" --codec "$codec" --short "$size" --fps "$FPS" "--$mode" "$kbps" $sdr >/dev/null
                    secs=$(awk -v s="$start" -v e="$(date +%s.%N)" 'BEGIN { printf "%.2f", e - s }')
                    vbr=$(ffprobe -v error -select_streams v -show_entries stream=bit_rate -of default=nk=1:nw=1 "$out" | head -1)
                    bytes=$(stat -f %z "$out")
                    echo "$name,$codec,${w}x${h},$FPS,$mode,$kbps,$((vbr / 1000)),$bytes,$(vmaf "$out" "$ref"),$secs"
                done
            done
        done
    done
done
