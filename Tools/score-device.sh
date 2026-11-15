#!/bin/sh
# Scores a measurement run pulled from the iPhone (MeasurementView, debug builds).
#
#   Tools/score-device.sh <Measurements/<clip> folder>... > scored.csv
#
# Each folder holds results.csv, the encodes and a near-lossless reference per
# codec/size ("<codec>-<size>-ref.mp4"). Appends a VMAF column to every
# non-reference row. Needs Homebrew ffmpeg with libvmaf.
set -eu

vmaf() {   # vmaf <distorted> <reference>
    ffmpeg -nostdin -hide_banner -nostats -i "$1" -i "$2" -lavfi \
        "[0:v]setpts=PTS-STARTPTS[d];[1:v]setpts=PTS-STARTPTS[r];[d][r]libvmaf=n_threads=8" \
        -f null - 2>&1 | sed -n 's/.*VMAF score: \([0-9.]*\).*/\1/p'
}

echo "clip,name,codec,size,mode,multiplier,target_kbps,video_kbps,file_bytes,encode_s,hardware,width,height,vmaf"
for dir in "$@"; do
    clip="$(basename "$dir")"
    tail -n +2 "$dir/results.csv" | while IFS=, read -r name codec size mode mult target actual bytes secs hw w h; do
        [ "$mode" = ref ] && continue   # the reference itself
        score=$(vmaf "$dir/$name.mp4" "$dir/$codec-$size-ref.mp4")
        echo "$clip,$name,$codec,$size,$mode,$mult,$target,$actual,$bytes,$secs,$hw,$w,$h,$score"
    done
done
