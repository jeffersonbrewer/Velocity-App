#!/bin/bash
# usage: track_swift.sh IMG_05xx setNN
set -e
v=/mnt/project-files/$1.MOV; s=$2
ffprobe -v error -select_streams v:0 -show_entries frame=pts_time -of csv=p=0 "$v" | tr -d , | grep -v "^$" > $s.times
rm -f /tmp/claude-0/ref/$s.fifo; mkfifo /tmp/claude-0/ref/$s.fifo
ffmpeg -v error -i "$v" -map 0:v:0 -fps_mode passthrough -pix_fmt gray -f rawvideo -y /tmp/claude-0/ref/$s.fifo &
docker run --rm -e VBT_ALWAYS_TEMPLATE=$TPL -v /tmp/claude-0:/w swift:6.1-noble /w/va/ios/VelocityCore/.build/release/vbt-cli track /w/ref/$s.fifo /w/ref/$s.times 1080 1920 /w/ref/$s$SUFFIX.swift.json
wait
