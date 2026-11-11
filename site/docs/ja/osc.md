# OSC

上部の「連携」の OSC で、iPad（TouchOSC など）や TouchDesigner から操作する方法と、Halo VJ から送る値を説明する。

## 受け取る

ポートは、はじめ 9000。

- 送り先に入れる、この Mac の IP アドレスが出る。
- 届いたメッセージの最近 6 つが出る。

### 決まったアドレス

番号は 1 から。

- `/halo/layer/L/clip/C`（クリップを出す）
- `/halo/column/C`
- `/halo/layer/L/stop`
- `/halo/layer/L/opacity 0〜1`
- `/halo/stop`
- `/halo/master/opacity`
- `/halo/master/volume`
- `/halo/blackout [0/1]`
- `/halo/bpm 数`
- `/halo/tap`
- `/halo/resync`
- `/halo/pad/N 1/0`（押す・離す）
- `/halo/cue/next`
- `/halo/cue/back`
- `/halo/cue/N`
- `/halo/scene/N`
- `/halo/deck/N`
- `/halo/record [0/1]`
- `/halo/auto`（自動操縦。→ [自動操縦](autopilot.md)）

ボタンの 0（離した）は、出す・止める などをしない。

### どの値も OSC で

波形ボタンで動かし方を「OSC」にしてアドレスを入れるか、「覚える」を押してフェーダーを動かすと、その値（0〜1）で「から」〜「まで」を動く。逆もできる。まだ届いていなければ元の値のまま。→ [値の動かし方](animation.md)

## 送る

送り先は、はじめ 127.0.0.1:7000。

1 秒に 30 回送るもの：

- `/halo/bpm`
- `/halo/beat`（拍の数）
- `/halo/beat/phase`・`/halo/bar/phase`（0〜1）
- `/halo/audio/level`・`low`・`mid`・`high`・`attack`

クリップを出したときに送るもの：

- `/halo/layer/L/clip`（名前）

TouchDesigner では OSC In CHOP で受け取る。

## 保存

設定は Mac ごと（プロジェクトには入らない。動かし方は入る）。
