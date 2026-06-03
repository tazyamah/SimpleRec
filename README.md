# SimpleRec — Mac用シンプル録音アプリ

Zoom などの**システム音声（相手の声）＋マイク（自分の声）**をミックスして `.m4a` で保存する、Piezo 的な最小録音アプリです。Zoom 側には一切手を加えません（ScreenCaptureKit でOSレベルから音声を取得）。文字起こしはしません。

- 出力: AAC `.m4a`（48kHz / ステレオ / 128kbps）。1回の録音ごとに mic / system / mix の3トラックを保存
- **25MB を超えないよう約24MBで自動分割**（`rec_日付_part01.m4a`, `part02` …）
- **保存先フォルダを指定可能**（未指定時は `~/Music/SimpleRec`）
- macOS 13 (Ventura) 以降

## 必要なもの

- Xcode または Command Line Tools（Swift ツールチェーン）
  - 入っていなければ: `xcode-select --install`

## 使い方（コマンド1発）

アーカイブを展開して、フォルダ内で次を実行するだけです。

```sh
tar xzf SimpleRec.tar.gz
cd SimpleRec
./build.sh
```

`build.sh` が「ビルド → `SimpleRec.app` を生成 → アドホック署名 → 起動」まで行います。
2回目以降も `./build.sh` でOK（再ビルドして起動し直します）。

## 「画面収録の許可」を何度も聞かれる場合

macOS は画面収録の許可をアプリの**コード署名（同一性）**に紐づけて記憶します。`build.sh` を実行するたびにアドホック署名が変わると「別アプリ」とみなされ、毎回許可を聞かれます。対策は2つ。

1. **ビルドし直さず再起動する** — 一度ビルドしたら、テスト時は `./run.sh`（または `open SimpleRec.app`）で起動し直す。`build.sh` は署名が変わるので毎回は使わない。
2. **固定の自己署名証明書を作る（恒久対策）** — 一度だけ:
   - 「キーチェーンアクセス」→ メニュー「証明書アシスタント > 証明書を作成…」
   - 名前 `SimpleRec Self-Signed` / 固有名のタイプ **自己署名ルート** / 証明書のタイプ **コード署名** → 作成
   - 以後 `build.sh` はこの証明書で署名し、再ビルドしても許可が保持されます。

許可は **アプリを完全終了（⌘Q）して再起動**して初めて有効になります。`システム設定 > プライバシーとセキュリティ > 画面収録` で SimpleRec を ON にしたら必ず再起動を。古い SimpleRec 項目が残っている場合は「−」で削除してから入れ直すと確実です。

> Tip: `.app` が Dropbox 配下だと同期でバイナリが入れ替わり同一性がブレることがあります。`/Applications` などDropbox外に置くと安定します。

## アプリの操作

1. 録音するソース（システム音声 / マイク）にチェック。
2. 「保存先」で必要ならフォルダを「変更」。
3. **録音開始** を押す。
   - 初回は **マイク** と **画面収録** の許可ダイアログが出ます。
   - 画面収録はシステム音声取得に必須です。許可後、`システム設定 > プライバシーとセキュリティ > 画面収録` で SimpleRec を ON にし、アプリを起動し直してください。
4. Zoom 会議を進行 →「停止」で保存。分割された場合は「保存ファイルを Finder で表示」で全パートを選択表示します。

## 分割の仕組み

録音中、各パートの推定サイズ（128kbps から算出 = 約16KB/秒）を監視し、約24MBに達した時点で次のファイルへ切り替えます。25MB のメールやアップロード上限を超えないためのマージンを取っています。
※ 厳密なバイト数ではなくビットレートからの推定です。確実に 25MB 未満にしたい用途には十分なマージン（約1MB）を設けています。閾値は `AudioRecorder.swift` の `maxBytes` で変更できます。

## 仕組み（概要）

```
[Zoom等のシステム音声] --ScreenCaptureKit--> RingBuffer --> AVAudioSourceNode ┐
                                                                              ├─> recordMixer --(tap)--> SegmentWriter --> rec_*.m4a (分割)
[マイク] --------------------------- AVAudioEngine.inputNode -----------------┘
```
`mainMixerNode.outputVolume = 0` のため、録音中にスピーカーへ音が回り込むエコーは起きません。

## トラブルシュート

- **音が無音/システム音声が入らない** → 「画面収録」許可後にアプリを再起動。`open SimpleRec.app` で再度開く。
- **`swift: command not found`** → `xcode-select --install` 後に再実行。
- **WAV で残したい** → `AudioRecorder.swift` の `settings` を `AVFormatIDKey: kAudioFormatLinearPCM` に。
- **macOS 15 以降**は ScreenCaptureKit 単体でマイクも取得でき、相手音声と完全同期できます（`SCStreamConfiguration.captureMicrophone`）。

## 録音同意について
相手の声を録音する場合は、参加者への録音同意の取得をお願いします。

## 文字起こし（WhisperKit / 第2段-a）

- エンジン: WhisperKit（完全ローカル）。デフォルトモデル `large-v3-turbo`。
- モデル保存先: `<ライブラリ>/_models/`（録音と一緒に持ち運べる）。アプリを再ビルド・再署名してもパスは変わらないので再ダウンロードは発生しません。
- UI: モデル未取得のときだけ「モデルを取得」ボタンを表示。取得済みなら隠れます。
- 第2段-aの範囲: 選択中レコーディングの `mic_part01.m4a` を文字起こしし、同じフォルダに `transcript_self.txt` を書き出します（system側・分割連結・時刻マージは第2段-bで対応）。

### 注意
- 初回の `swift build` は WhisperKit と CoreML 依存の取得・ビルドで**かなり時間がかかります**（数分〜）。
- WhisperKit は macOS 14 以降が必要（Package を `.macOS(.v14)` に変更済み）。
- モデルの初回取得はネット接続が必要。以後はオフラインで動作します。
- WhisperKit に触れるコードは `Transcriber.swift` だけに隔離してあります。インストールした WhisperKit のバージョンで API が違ってビルドが通らない場合は、このファイルの `WhisperKit(...)` 初期化と `transcribe(audioPath:)` 呼び出しだけ調整してください。
