# SimpleRec 仕様書

## 概要

macOSネイティブの録音＋ローカル文字起こしアプリ。  
Zoom などのオンライン会議を「システム音声（相手）＋マイク（自分）」の2トラックで横取り録音し、WhisperKit を使って完全ローカルで文字起こしする。

---

## 動作環境

| 項目 | 内容 |
|------|------|
| OS | macOS 14+ (Apple Silicon 推奨) |
| Swift | 6.3.2 (Command Line Tools) |
| 主要ライブラリ | WhisperKit 1.0.0 |
| 作業フォルダ | `/Users/tatsuzuk/work/claude/SimpleRec` |

---

## ビルド・起動

```sh
# ビルド → 署名 → /Applications/SimpleRec.app に配置 → 起動
./build.sh

# 再起動のみ（再ビルド不要）
./run.sh
```

### 自己署名証明書（推奨）

画面収録の TCC 許可はコード署名（cdhash）に紐づく。アドホック署名だと再ビルドのたびに許可が外れる。
「キーチェーンアクセス → 証明書アシスタント → 自己署名ルート」で **`SimpleRec Self-Signed`** という名前のコード署名証明書を作ると、`build.sh` が自動で使用し許可が維持される。

---

## アーキテクチャ

### 録音

```
マイク → inputNode tap → AudioPump(mic) → RingBuffer
                                                  ↘
システム音声 → SCStream → AudioPump(sys) → RingBuffer → Mixer → SegmentWriter × 3
```

- **AudioPump** — 入力音声を 48kHz / 2ch / Float32 に変換してリングバッファへ書き込む
- **Mixer** — 約40ms 間隔のクロックで mic・sys 各リングから同数フレームを読み出し、3トラック（mic / sys / mix）に書き出す
- **SegmentWriter** — AVAudioFile（AAC 48kHz/2ch/128kbps）に書き込み、推定サイズが 24MB を超えると次のパートに自動分割

> **設計制約**: AVAudioEngine の出力ノードを録音グラフに接続しないこと。Bluetooth マイク（16kHz等）接続時に `engine.start()` が NSException でクラッシュする実績あり。マイクは `inputNode` タップのみで取得する。

### ファイル保存

```
ライブラリ（親フォルダ、一度だけ選択・ブックマーク保存）
  └─ yyyyMMdd_HHmmss [- 録音名]/        ← レコーディング
       ├─ mic_part01.m4a
       ├─ mic_part02.m4a  …（24MB超で自動分割）
       ├─ system_part01.m4a
       ├─ system_part02.m4a  …
       ├─ mix_part01.m4a
       ├─ mix_part02.m4a  …
       ├─ transcript_self.txt            ← 文字起こし後
       ├─ transcript_other.txt           ← 文字起こし後
       └─ transcript.txt                 ← 文字起こし後（マージ）
  ├─ _models/                           ← WhisperKit モデル保存先
  └─ SimpleRec_log.txt                  ← ログ
```

- `_` で始まるフォルダはシステムフォルダ扱い（レコーディング一覧に表示しない）

### 文字起こし（WhisperKit）

- **エンジン**: WhisperKit 1.0.0（完全ローカル、初回のみネット経由でモデルをダウンロード）
- **モデル保存先**: `ライブラリ/_models/`（`downloadBase` として指定）
- **モデル準備確認**: `_models/.ready_{モデル名}` マーカーファイルの有無で判定
- **実行**: 手動（「文字起こし」ボタン）。要約・議事録生成は別途対応

#### 文字起こしの流れ

1. レコーディングフォルダ内の `mic_part*.m4a`、`system_part*.m4a` を昇順ソートで列挙
2. 1ファイルずつ逐次処理（メモリ節約）
3. 各パートのタイムスタンプを `AVAudioFile.length / sampleRate` で求めた再生時間分オフセット加算し、通算秒に変換
4. 出力:
   - `transcript_self.txt` — mic トラック全文（スペース区切り連結）
   - `transcript_other.txt` — system トラック全文
   - `transcript.txt` — mic / system セグメントを通算タイムスタンプで時刻順マージ、`[自分]` / `[相手]` ラベル付き

---

## ソースファイル

| ファイル | 責務 |
|----------|------|
| `SimpleRecApp.swift` | `@main`、ウィンドウ定義 |
| `ContentView.swift` | UI 全体 |
| `AudioRecorder.swift` | 録音制御・ライブラリ管理・文字起こし呼び出し |
| `RingBuffer.swift` | スレッドセーフなリングバッファ |
| `Logger.swift` | ファイルロガー（`RecLog.shared`） |
| `Transcriber.swift` | WhisperKit 依存をここだけに隔離 |

---

## UI 機能一覧

| 機能 | 備考 |
|------|------|
| ライブラリ選択 | フォルダ選択ダイアログ、ブックマーク永続化 |
| ソース切替 | システム音声 / マイク のトグル |
| 録音名入力 | 録音前後どちらでも入力可能 |
| 録音タイマー | 経過時間（HH:MM:SS）を表示 |
| 録音開始/停止 | 停止時に録音名を適用してフォルダをリネーム |
| 画面収録許可バナー | 未許可時のみ表示。「許可を取得する」「再確認」ボタン |
| レコーディング一覧 | プルダウン（`_` 始まりフォルダを除外）、更新ボタン |
| フォルダを開く | Finder でレコーディングフォルダを開く |
| 名前変更 | 既存レコーディングのフォルダ名サフィックスを変更 |
| モデル選択 | `openai_whisper-large-v3_turbo`（デフォルト）等 |
| モデル取得 | 未取得時のみ表示 |
| 文字起こし | 選択レコーディングの全パートを処理し3ファイルを出力 |
| ビルドID表示 | 下部に `build YYYYMMDD.HHmmss` |

---

## モデル名（WhisperKit 1.0.0）

WhisperKit 1.0.0 のモデル名は `openai_whisper-` プレフィックス＋アンダースコア区切りを使用する（`large-v3-turbo` のようなハイフン区切りの短縮名は存在しない）。

| 表示 | WhisperKit 名 | 目安サイズ | 備考 |
|------|--------------|-----------|------|
| large-v3-turbo | `openai_whisper-large-v3_turbo` | ~954MB | デフォルト。M2以降推奨 |
| large-v3 | `openai_whisper-large-v3` | ~1.5GB | 高精度・低速 |
| medium | `openai_whisper-medium` | ~500MB | バランス型 |
| small | `openai_whisper-small` | ~250MB | 軽量・高速 |

16GB Mac（Chrome常駐）での推奨: `openai_whisper-large-v3_turbo`  
メモリが厳しい場合: `openai_whisper-medium`

---

## 既知の課題・TODO

| # | 内容 | 優先度 |
|---|------|--------|
| 1 | モデルダウンロード中も「文字起こし中…」と表示されて区別できない | 中 |
| 2 | `_models` 等 `_` 始まりフォルダをレコーディング一覧に表示しない | 中 |
| 3 | 保存済みライブラリパスが実在しなければデフォルトにフォールバック | 低 |
| 4 | 録音開始直後に system バッファが届かなければ「画面収録未許可かも」と警告 | 低 |

### 解決済み

| 内容 |
|------|
| `modelFolder` 指定によりダウンロードがスキップされていた → `downloadBase` に変更 |
| `large-v3-turbo` はWhisperKit 1.0.0 に存在しない → `openai_whisper-large-v3_turbo` に修正 |
| 文字起こし結果が英語になる → `DecodingOptions(language: "ja")` を指定 |

---

## ログ

`ライブラリ/SimpleRec_log.txt` に追記。主なプレフィックス:

| プレフィックス | 内容 |
|----------------|------|
| `start:` | 録音開始パラメータ |
| `mic:` | マイク関連 |
| `scstream:` | ScreenCaptureKit 関連 |
| `mixer:` | Mixer 起動/停止 |
| `writer:` | SegmentWriter のファイル開閉・書き込み |
| `stopRecording:` | 停止時のファイルサイズ等 |
| `whisper:` | WhisperKit のモデルロード・文字起こし結果 |
| `transcribe:` | 文字起こし完了・出力ファイル名 |
