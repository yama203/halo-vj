# OSC

このページでは、上部の「連携」の OSC を使って iPad（TouchOSC など）や TouchDesigner から操作する方法と、Halo VJ から送信する値について説明します。

## 受信する

受信ポートの初期設定は 9000 です。

- 送信側に入力する、この Mac の IP アドレスが表示されます。
- 受信したメッセージのうち、最近の 6 件が表示されます。

### 決まったアドレス

番号は 1 から始まります。

- `/halo/layer/L/clip/C`（クリップを再生）
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

ボタンの 0（離したとき）では、再生や停止などの動作は行いません。

### すべての値を OSC で操作する

値の波形ボタンで動かし方（アニメーション）を「OSC」にしてアドレスを入力するか、「覚える」（ラーン）を押してフェーダーを動かすと、受信した値（0〜1）に応じて「から」〜「まで」の範囲で値が変化します。逆向きにも設定できます。まだ値を受信していないときは、元の値のままです。→ [値の動かし方](animation.md)

## 送信する

送信先の初期設定は 127.0.0.1:7000 です。

毎秒 30 回送信する値は次のとおりです。

- `/halo/bpm`
- `/halo/beat`（拍の数）
- `/halo/beat/phase`・`/halo/bar/phase`（0〜1）
- `/halo/audio/level`・`low`・`mid`・`high`・`attack`

クリップを再生したときに送信する値は次のとおりです。

- `/halo/layer/L/clip`（名前）

TouchDesigner では、OSC In CHOP で受信します。

## 保存

設定は Mac ごとに保存され、プロジェクトには含まれません（各値の動かし方の設定はプロジェクトに含まれます）。
