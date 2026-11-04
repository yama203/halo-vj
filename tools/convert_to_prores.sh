#!/bin/bash
# DXV などの動画を ProRes 422（音声は非圧縮PCM）に変換する。
# 使い方: tools/convert_to_prores.sh 入力1.mov 入力2.mov ...
#   → 同じフォルダに「元の名前_prores.mov」を書き出す
# 軽くしたいときは PROFILE=1（ProRes 422 LT）を付けて実行
set -euo pipefail
PROFILE="${PROFILE:-2}"
for f in "$@"; do
  out="${f%.*}_prores.mov"
  echo "変換中: $f → $out"
  ffmpeg -hide_banner -loglevel error -stats -i "$f" \
    -map 0:v:0 -map '0:a:0?' \
    -c:v prores_ks -profile:v "$PROFILE" -pix_fmt yuv422p10le \
    -c:a pcm_s16le "$out"
done
