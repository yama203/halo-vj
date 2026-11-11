# 公証（ノータライズ）の準備

公証を通すと、ダウンロードした人が初めて開くときに「開発元を確認できません」で止められなくなる。
署名と公証の処理は `tools/release.sh` に組み込み済み。下の 1〜3 を一度だけやれば、あとはいつもどおり `tools/release.sh 0.5.0` で公証まで通る。

## 1. Apple Developer Program に登録する（自分で）

- https://developer.apple.com/programs/enroll/ から「個人」で登録する。年 99 ドル（日本円の額は登録の画面で確認）。
- Apple ID は 2 ファクタ認証が必要。登録の確認に、数時間から数日かかることがある。
- 登録が終わったら、https://developer.apple.com/account の「メンバーシップの詳細」にある **チーム ID**（英数字 10 文字）を控えておく。

## 2. 「Developer ID Application」の証明書を作る（自分で）

1. Xcode を開き、Xcode → 設定… →「アカウント」で、登録した Apple ID を追加する。
2. そのチームを選んで「証明書を管理…」→ 左下の「＋」→「**Developer ID Application**」。
   （「Apple Development」や「Apple Distribution」ではない。App Store の外で配るための証明書）
3. キーチェーンアクセスの「ログイン」→「自分の証明書」に `Developer ID Application: 名前 (チーム ID)` が出ていれば OK。

確かめ方：

```bash
security find-identity -v -p codesigning
```

**控えを取る**：キーチェーンアクセスでその証明書を右クリック →「書き出す」で .p12 を作り、パスワードを付けて安全な所（Sparkle の鍵と同じ所など）に置く。Mac を替えたときにこれが要る。リポジトリには入れない。

## 3. 公証に出すための資格情報をキーチェーンに入れる（自分で）

1. https://account.apple.com →「サインインとセキュリティ」→「App 用パスワード」で、`halo-vj notarytool` などの名前で作る。
2. ターミナルで次を実行する。メールアドレスとチーム ID を自分のものにする。パスワードは聞かれたときに、1. で作った App 用パスワードを入れる。

```bash
xcrun notarytool store-credentials halo-vj --apple-id あなたのApple ID --team-id チームID
```

`halo-vj` という名前でキーチェーンに保存される（`tools/release.sh` はこの名前を使う。変えるときは `HALO_NOTARY_PROFILE`）。

## 4. 試す

```bash
tools/release.sh 0.4.4 --dry-run
```

- 「署名に使う証明書：Developer ID Application: …」→「Apple の公証に出しています」→「公証が通りました」と出れば成功。初回は 10 分以上かかることもある。
- `build/release/Halo-VJ-0.4.4.zip` を別の Mac（または AirDrop で受け取り直したもの）で開いて、止められずに開ければ OK。
- 通らなかったときは、表示される `xcrun notarytool log …` を実行すると理由が出る。

うまくいったら、いつもどおり `tools/release.sh 0.4.4`（`--dry-run` なし）で公開する。

## 公証にしてから変わること

- 署名が変わるので、最初の 1 回だけ、マイク・カメラの許可をもう一度聞かれる。
- 前の版（公証なし）から自動アップデートで入れ替わるかは、Sparkle が EdDSA の鍵（今までと同じ）で確かめるので通る想定。最初の公証版を出したら、古い版から「アップデートを確認…」で入れ替わることを一度確かめる。
- README の「インストール・アップデート」と、紹介ページ（`site/index.html` の「入れ方」の 3 番目）から「このまま開く」の説明を消す。

## 中身（組み込み済みのところ）

- `tools/make_app.sh`：`HALO_SIGN_ID` が渡されたら、Hardened Runtime で Sparkle の部品 → 同梱の NDI → アプリ本体の順に署名する。許可は `tools/HaloVJ.entitlements`（マイク、カメラ、外の NDI ランタイムを読み込むためのライブラリ検証の解除）。
- `HALO_SIGN_ID=- tools/make_app.sh` で、証明書なしに同じ形（アドホック署名 + Hardened Runtime）を作れる。許可が足りずに動かない所がないか確かめる用。
- `tools/release.sh`：キーチェーンに「Developer ID Application」があれば、それで署名 → 公証に出す → 結果を貼り付け（staple）→ `spctl` で確かめてから zip にする。無ければ今までどおり公証なしで作る。
- バンドル ID は今までの `local.yama.vjplayer` のまま（変えると設定と自動アップデートが別のアプリ扱いになる）。Developer ID での配布には、バンドル ID の登録は要らない。
