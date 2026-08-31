<p align="center">
  <img src="docs/assets/banner.png" alt="マカロニの間を波形が通り、2人の話者のラインが織り合わされたMaccheroniのバナー" width="100%">
</p>

<h1 align="center">Maccheroni</h1>

<p align="center">
  Apple Silicon上で動作する、混在言語音声向けのローカルファースト文字起こし。<br>
  デコード時の用語集注入 · ファイル全体の話者分離 · 音声がMacの外に出ることはありません。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%20(arm64)-black" alt="プラットフォーム">
  <img src="https://img.shields.io/badge/swift-6-F05138" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="ライセンス">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.it.md">Italiano</a> · <b>日本語</b> · <a href="README.ko.md">한국어</a> · <a href="README.pt.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.zh-Hans.md">简体中文</a>
</p>

---

**Maccheroni**という名前は、複数の言語が一つの発話に混ざる*macaronic speech*に由来します。各文に英語の製品名が登場する韓国語の会議、語学クラス、多言語通話など、正確な文字起こしが最も難しい会話を文字起こしします。文字起こしと話者分離は、固定されたMLX/Core MLモデルを使ってデバイス上で実行します。任意のテキストのみの後処理にはリモートのCodexを利用できます。

エクスポート例です。モデルの出力ではなく、説明用のサンプルです。

```markdown
**話者1** [00:04] PRをmergeする前に、stagingのsmoke testは通りましたか？
**話者2** [00:09] はい、Kubernetesのrolloutも問題ありません。[UNCERTAIN] ただ、
                 dashboardの[CONFLICT: カナリア|カナリヤ]指標が一度跳ねています。
**話者1** [00:17] 分かりました。それならrelease windowは予定どおりで進めます。
```

不確かな修正は黙って置き換えず、フラグを付けます。話者ラベルはファイル全体に対する1回の話者分離から得るため、2時間の録音でも一貫性が保たれます。

<p align="center">
  <img src="docs/assets/screenshots/transcript.png" alt="Maccheroniのトランスクリプト画面: グローバルラベル付きの2人の話者とセグメントごとのエビデンスチップ、隣にrunステータス、固定されたモデルrevision、glossary記録を表示するインスペクタ" width="100%">
</p>
<p align="center"><em>各runはエビデンスを保持します。インスペクタには固定された正確なモデル、runのステータス、glossaryがデコーダに届いたかどうかが表示されます。表示中のレイヤー（raw・修正済み・翻訳済み）は、provenanceヘッダー付きでクリップボードにコピーできます。</em></p>

## このプロジェクトを作った理由

Maccheroniは個人用ツールです。1台のMacで混在言語の会話を話者付きの記録へ変換する、構成を調整できるワークベンチです。市場向けではなく、使う人が自分の用途に合わせて調整します。

- **プロファイルが会話ごとの構成を組み立てます。** 各プロファイルは、固定されたオンデバイスASRモデルに用語集のcontextとファイル全体の話者処理を組み合わせ、実際の会話の音声に合わせます。英語の製品名が多い韓国語の会議と、イタリア語の2話者対話では異なる選択が必要です。
- **組み合わせは仮定せず測定します。** 公開fixtureと合成fixture、用語再現率、エラー率をこのリポジトリに置いています。モデルや用語集を変更するときは、勘に頼らず同じ比較を再実行できます。
- **各runはエビデンスを保持します。** 固定されたモデルrevision、用語集の受け渡し記録、raw transcript、話者timeline、typed failureをrunに封印します。そのため、結果を後から検査して再現できます。

この設計判断の基になったソースレベルの記録は[docs/reference-project-source-audit.md](docs/reference-project-source-audit.md)にあります。

## 特長

1. **デコード時に用語集を注入します。** 名前や技術用語をデコード前にモデルのcontextへ入れます。ASRの誤りは発生した瞬間に音響的根拠を失わせるためです。後処理で文章は整えられますが、decoderが書き出さなかった言葉は復元できません。各leafの用語集payloadはhashで封印し、run manifestに記録します。
2. **1回の話者分離が話者を決定します。** ファイル全体を一度だけ話者分離し、そのtimelineだけを話者の根拠とします。ASRは上限を設けたchunk単位で実行し、timestampで結合します。chunk内の話者推定によって境界をまたいだラベルの反転が起きることはありません。
3. **無言のデータ損失を許しません。** backendの上限を超える入力は明示的に失敗するか、分割計画を生成します。切り詰められたモデル出力は短い文字起こしではなく、typed failureの`invalid_eos_output`として扱います。原本とraw transcriptは不変です。修正と翻訳は別のcreate-only artifactとして作成します。

## 仕組み

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/pipeline-dark.drawio.svg">
  <img src="docs/assets/pipeline-light.drawio.svg" alt="パイプライン図: Mac内でキャプチャがファイル全体の話者分離と120秒のASR leaf(leafごとにglossary注入)につながり、タイムラインが話者を決めるタイムスタンプmergeを経て任意のオンデバイス後処理へ続く。Macから出るのはopt-inのリモート後処理レーンのみで、外部ベンダーへはCodexサインインで接続し、テキストだけを送る" width="100%">
</picture>

失敗したleafはtyped bound内で再分割します。最小30秒、深さは最大3です。End-of-sequence出力だけをcanonical transcriptへ昇格させます。任意のCodex経路は、自分のChatGPT/Codexサブスクリプションを使い、上限を設けた文字起こしテキスト、有効な用語集、指示だけを送信します。音声もファイルパスも送信しません。Correctionは用語集を補助的な文脈として扱います。segmentにその用語が実際に含まれていたと考えられる場合だけ置換し、不確実な修正は適用せずreview対象として印を付けます。

## モデル

プロダクトで使うモデルとサービスの識別情報は、各run manifestに記録します。ダウンロード可能なモデルは、Hugging Face ID + revision + quantizationで固定します。

| 役割 | モデル | リビジョン | 量子化 |
|---|---|---|---|
| ASR（イタリア語 / 混在） | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | `90aa6528` | int8-decoder + fp16-audio-vq-kv |
| ASR（韓国語） | `mlx-community/VibeVoice-ASR-8bit` | `725c72e5` | int8 |
| VAD | `aufklarer/Silero-VAD-v6.2.1-CoreML` | `52387654` | coreml-float16 |
| 話者分離 | `aufklarer/Pyannote-Community-1-CoreML` | `a14e6c42` | coreml-fp32 |
| 後処理（ローカル） | `mlx-community/gemma-4-12B-it-qat-4bit` | `e70c6b3b` | qat-int4 (mlx-vlm 0.6.6) |
| 後処理（リモート、テキストのみ） | Codex app server経由の`gpt-5.6-sol` | サービス側で管理 | 該当なし |

Qwen3 ASR、Qwen3 ForcedAligner、DiCoWは研究候補です。Appleランタイムとの互換性、変換後の同等性、プロダクト品質の改善はいずれも確立していません。

## 測定結果

すべて公開fixtureまたは合成fixtureから得た結果です。評価IDとartifact hashは[docs/](docs/)に記録しています。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/benchmarks-dark.svg">
  <img src="docs/assets/benchmarks-light.svg" alt="棒グラフ: フィクスチャ別のCERとWER（韓国語対話 0.081/0.141、イタリア語2話者 0.033/0.085）、glossary用語再現率（ゲート0.75に対して0.95と0.778）、話者分離エラー率（合成 0.048、VoxConverse 0.152）" width="100%">
</picture>

| フィクスチャ | モデル | CER | WER | 用語再現率 | 欠落 | DER |
|---|---|---:|---:|---:|---:|---:|
| 韓国語の対話、20語の用語集 | VibeVoice | 0.081 | 0.141 | 0.95 | 0 | — |
| イタリア語の2話者合成音声（10分）、9語の用語集 | MOSS | 0.033 | 0.085 | 0.78 | 0 | 0.048 |
| VoxConverseサンプル（78分） | VibeVoice + Pyannote | — | — | — | — | 0.152 |

韓国語とイタリア語が最初の2つの言語プロファイルです。HiKE、FLEURS、AMIは、transport、scoring、conversion parityの研究用fixtureに限ります。学習データからの除外を確認し、overlap音声に特化した測定を行うまで、これらのfixtureでモデルを昇格させることはできません。

78分のサンプルでは、chunk境界での話者安定性が両方の基準話者について1.0でした。固定した600秒のmatrixでは、120秒を超えるMOSS leafがtimestamp構造を完全に失いました。このためproduction leafの上限を120秒に設定しています。詳細は[docs/moss-long-audio-verdict.md](docs/moss-long-audio-verdict.md)にあります。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/leaf-cap-dark.svg">
  <img src="docs/assets/leaf-cap-light.svg" alt="棒グラフ: 同じ600秒の入力で、120秒leafは5つの正準EOS leafを生成（合格）、240秒と300秒のleafは有効leaf 0（型付きinvalid_eos_output失敗）、240秒の親からの強制リカバリは有効な120秒の子を5つ生成" width="100%">
</picture>

Correctionの改善幅は、raw出力とcorrected出力、decode時の用語集注入の有無を組み合わせた4-state比較で測定し、有害な修正も明示的に数えます。`maccheroni postprocess`とアプリは、ASRを再実行せずに封印されたセグメントから新しい修正セットや翻訳セットを導出できます。保存済みのglossary revisionはcontent-addressedで、元のrunが記録したバイト列をそのまま再利用します。

## インストール

パッケージreleaseはまだありません。ソースからbuildしてください。

要件：Apple Silicon Mac、macOS 26、Xcode 26、[uv](https://docs.astral.sh/uv/)。

```bash
git clone https://github.com/gigio1023/maccheroni.git
cd maccheroni
swift build && swift test
zsh scripts/build-app.zsh          # builds and codesigns Maccheroni.app
```

build、resource allowlist inventory、strict codesignの各チェックに合格すると、アプリがbundle pathを表示します。実行ファイルにはモデルweightもPython環境も含まれません。`ko-meeting`と`it-dialogue`のprofile定義は付属し、`maccheroni doctor`は観測した依存関係とストレージの状態を報告します。空のcacheからの`ko-meeting` provisioningと`doctor`による完全な検証は、まだ完了していません。間接依存するQwen tokenizerとHugging Face metadataを手動で準備しておく必要があります。

実行ファイルには5つの製品コマンドがあります。

```bash
.build/debug/maccheroni help [help|run|postprocess|doctor|capabilities]
.build/debug/maccheroni run recording.wav --profile it-dialogue
.build/debug/maccheroni postprocess Runs/meeting --profile ko-meeting
.build/debug/maccheroni doctor [--profile NAME] [--profiles PATH] [--json]
.build/debug/maccheroni capabilities [--json]
```

`maccheroni help`、`maccheroni doctor --json`、`maccheroni capabilities --json`でヘルプと構造化出力を利用できます。簡潔な[CLIガイド](docs/cli-guide.md)にコマンドと出力の契約を記載しています。文字起こしと話者分離はこのMacで実行されるため、音声はローカルに残ります。

任意のローカル後処理モデルを使う場合は、`zsh scripts/setup-postprocess-runtime.zsh`を実行してください。

## プライバシー

<p align="center">
  <img src="docs/assets/screenshots/capture.png" alt="Maccheroniのキャプチャ画面: 測定済みメトリクス付きのプロファイル選択、Codex・Local・Noneのpost-processing選択、音声がこのMacから出ないことの表示" width="100%">
</p>

- 文字起こし、VAD、話者分離は完全にローカルで実行します。音声byteがnetwork pathへ到達することはありません。ポリシーではなくtestで強制しています。
- 任意のCodex後処理経路はテキストのみを扱い、runごとに選択します。保存済みのChatGPTサブスクリプション認証を使い、1ターンだけの`codex app-server`セッションを開きます。threadは一時的かつread-onlyで、MCP serverと付加的なtoolingは無効、承認要求は拒否されます。promptに含まれるのはsegment text、有効な用語集、指示です。この経路ではAPI key認証を受け付けません。代わりにローカルMLXモデルを選ぶと、テキストもデバイス内に残ります。
- Codex経路のfailure messageはrun manifestへ入る前に長さを制限し、pathを秘匿します。

## 制約

- Apple Silicon + macOS 26専用です。Intel、iOS、Windows/Linuxには対応しません。
- 文字起こし後の処理のみです。品質を優先するためlive captionはありません。
- 混在言語の品質はfixtureで検証しましたが、数か月にわたる実際の会議ではまだ検証していません。
- Codex経路を使うには、自分のCodex CLI loginとサブスクリプションquotaが必要です。
- UIの標準言語は英語で、10言語にローカライズしています。ko/itのstringにはまだ人手によるレビューの印が付いています。

## コントリビューション

Issueと対象を絞ったpull requestを歓迎します。Buildとtestのコマンド、このREADMEの主張を支える検証基準、commit規則、issue/PRの規約は[CONTRIBUTING.md](CONTRIBUTING.md)にあります。

## リポジトリ構成

| パス | 内容 |
|---|---|
| `Sources/` | Swiftパッケージ：Core、Preprocess、ASR、Diarize、Merge、Postprocess、CLI、App |
| `Tests/` | fixtureベースのSwift test |
| `benchmarks/scripts/` | Derived verdictとnegative testを備えたrunner、scorer、correction経路比較harness |
| `docs/` | 調査digest、source audit、constraint policy、契約（JSON schema）、UI design |
| `scripts/` | App bundle build、MOSS harness build、post-processing runtime setup |
| [PROJECT.md](PROJECT.md) | 意図の階層：柱、対象外、判断規則、追記専用の意思決定記録 |
| [AGENTS.md](AGENTS.md) | このリポジトリで作業するための運用規約 |

文書内の完了を示す主張には、それを裏付けたコマンドと観測した出力を記載します。

## ライセンスと謝辞

MIT。このプロジェクトは、[speech-swift](https://github.com/soniqo/speech-swift)のMLX/CoreML音声runtime、MOSS、VibeVoice、Silero、pyannoteの各モデル作者、[mlx](https://github.com/ml-explore/mlx)の成果を土台にしています。`docs/`にあるreference project source auditでは、良い設計も悪い設計も含め、このプロジェクトに影響を与えた24件のオープンソースプロジェクトをクレジットしています。
