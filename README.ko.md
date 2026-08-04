<p align="center">
  <img src="docs/assets/banner.png" alt="마카로니 사이로 파형이 흐르고 두 화자의 발화선이 엮인 Maccheroni 배너" width="100%">
</p>

<h1 align="center">Maccheroni</h1>

<p align="center">
  Apple Silicon에서 실행하는 혼용 언어 음성용 로컬 우선 전사 앱입니다.<br>
  디코딩 시점 용어집 주입 · 전체 파일 화자 분리 · 오디오는 Mac을 벗어나지 않습니다.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%20(arm64)-black" alt="플랫폼">
  <img src="https://img.shields.io/badge/swift-6-F05138" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="라이선스">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.it.md">Italiano</a> · <a href="README.ja.md">日本語</a> · <b>한국어</b> · <a href="README.pt.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.zh-Hans.md">简体中文</a>
</p>

---

**Maccheroni**는 여러 언어를 한 발화에 섞는 *macaronic speech*에서 이름을 따왔습니다. 문장마다 영어 제품명이 등장하는 한국어 회의, 어학 수업, 다국어 통화처럼 대부분의 앱이 조용히 틀리는 대화를 전사합니다. 고정된 MLX/CoreML 모델로 모든 작업을 기기에서 처리합니다.

내보낸 결과의 예시입니다. 모델 출력이 아닌 설명용 샘플입니다.

```markdown
**화자 1** [00:04] PR을 merge하기 전에 staging에서 smoke test는 통과했나요?
**화자 2** [00:09] 네, Kubernetes rollout도 문제없었습니다. [UNCERTAIN] 다만
                  dashboard의 latency가 [CONFLICT: 릴리즈|release] 직후 잠깐 튑니다.
**화자 1** [00:17] 알겠습니다. 그럼 배포 시간은 계획대로 유지하겠습니다.
```

불확실한 교정은 조용히 치환하지 않고 표시합니다. 화자 라벨은 전체 파일을 한 번에 분석한 결과에서 가져오므로 두 시간짜리 녹음에서도 일관성을 유지합니다.

<p align="center">
  <img src="docs/assets/screenshots/transcript.png" alt="Maccheroni 전사 화면: 전역 라벨이 붙은 두 화자와 세그먼트별 증거 칩, 오른쪽에는 run 상태와 고정된 모델 revision, glossary 기록을 보여주는 인스펙터" width="100%">
</p>
<p align="center"><em>모든 run은 증거를 남깁니다. 인스펙터는 고정된 모델과 run 상태, glossary가 디코더에 도달했는지를 보여줍니다.</em></p>

## 이 프로젝트를 만든 이유

2026-08-02에 macOS 로컬 전사 앱 7개를 소스 수준에서 검토했습니다. 실제 혼용 언어 회의에 필요한 조합을 충족한 앱은 없었습니다.

- 로컬 화자 분리를 지원하는 앱은 용어집을 ASR 모델에 전달하지 않았습니다. 사후 문자열 치환을 사용하거나 SDK 파라미터가 작동하지 않았으며 사전이 클라우드에서만 작동했습니다.
- 모델 수준 용어집을 가장 제대로 지원한 앱에는 화자 분리가 없었습니다.
- "다국어 지원"은 대부분 *세션당 한 언어*를 뜻합니다. 혼용 언어 음성은 이 방식으로 처리할 수 없습니다.

필요한 구성 요소는 라이브러리 계층에 모두 있습니다. 앱 계층에는 이 조합이 없었습니다. 그래서 이 저장소에서 직접 만듭니다. 검토 내용은 [docs/reference-project-source-audit.md](docs/reference-project-source-audit.md)에 있습니다.

## 차별점

1. **디코딩 시점에 용어집을 주입합니다.** 이름과 기술 용어를 디코딩 전에 모델 context에 넣습니다. ASR 오류가 발생하는 순간 음향 근거가 사라지기 때문입니다. 후처리는 문장을 다듬을 수 있지만 decoder가 기록하지 않은 말까지 복원하지는 못합니다. 각 leaf의 용어집 payload는 hash로 봉인해 run manifest에 기록합니다.
2. **한 번의 화자 분리 결과가 화자를 결정합니다.** 전체 파일의 화자를 한 번에 분리하고 이 timeline만 화자 판단의 기준으로 삼습니다. ASR은 상한이 정해진 chunk로 처리한 뒤 timestamp를 기준으로 병합합니다. chunk 안에서 추정한 화자가 경계를 넘어 라벨을 뒤집을 수 없습니다.
3. **조용한 데이터 손실을 허용하지 않습니다.** backend 상한을 넘는 입력은 명시적으로 실패하거나 분할 계획을 만듭니다. 잘린 모델 출력은 짧은 전사가 아니라 typed failure인 `invalid_eos_output`으로 처리합니다. 원본과 raw 전사는 바꾸지 않으며 교정본과 번역본은 별도의 create-only artifact로 만듭니다.

## 작동 방식

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/pipeline-dark.drawio.svg">
  <img src="docs/assets/pipeline-light.drawio.svg" alt="파이프라인 다이어그램: Mac 안에서 캡처가 전체 파일 화자분리와 120초 ASR leaf(leaf마다 glossary 주입)로 이어지고 타임라인이 화자를 결정하는 타임스탬프 병합을 거쳐 선택적 온디바이스 후처리로 연결됩니다. Mac을 떠나는 것은 opt-in 원격 후처리 레인뿐이고 외부 벤더에는 Codex 로그인으로 연결되며 텍스트만 전송됩니다" width="100%">
</picture>

실패한 leaf는 typed bound 안에서 다시 나눕니다. 최소 길이는 30초이고 최대 깊이는 3입니다. End-of-sequence 출력만 canonical transcript로 승격합니다. 선택 기능인 Codex 경로는 사용자 자신의 ChatGPT/Codex 구독을 사용해 상한이 정해진 전사 텍스트, 활성 용어집, 지침만 전송합니다. 오디오와 파일 경로는 보내지 않습니다.

## 모델

모든 모델은 Hugging Face ID + revision + quantization으로 고정하며 각 run manifest에 기록합니다.

| 역할 | 모델 | 리비전 | 양자화 |
|---|---|---|---|
| ASR(이탈리아어 / 혼용) | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | `90aa6528` | int8-decoder + fp16-audio-vq-kv |
| ASR(한국어) | `mlx-community/VibeVoice-ASR-8bit` | `725c72e5` | int8 |
| VAD | `aufklarer/Silero-VAD-v6.2.1-CoreML` | `52387654` | coreml-float16 |
| 화자 분리 | `aufklarer/Pyannote-Community-1-CoreML` | `a14e6c42` | coreml-fp32 |
| 후처리(로컬) | `mlx-community/gemma-4-12B-it-qat-4bit` | `e70c6b3b` | qat-int4 (mlx-vlm 0.6.6) |
| 후처리(원격, 텍스트만) | Codex 앱 서버를 통한 `gpt-5.6-sol` | 서비스에서 관리 | 해당 없음 |

## 측정 결과

모든 결과는 공개 또는 합성 fixture에서 얻었습니다. 평가 ID와 artifact hash는 [docs/](docs/)에 기록했습니다.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/benchmarks-dark.svg">
  <img src="docs/assets/benchmarks-light.svg" alt="막대 그래프: 테스트 자료별 CER과 WER(한국어 대화 0.081/0.128, 이탈리아어 2화자 0.033/0.081), glossary 용어 재현율(게이트 0.75 대비 0.95와 0.778), 화자분리 오류율(합성 0.048, VoxConverse 0.152)" width="100%">
</picture>

| 테스트 자료 | 모델 | CER | WER | 용어 재현율 | 누락 | DER |
|---|---|---:|---:|---:|---:|---:|
| 한국어 대화, 20개 용어집 | VibeVoice | 0.081 | 0.128 | 0.95 | 0 | — |
| 이탈리아어 화자 2명 합성 녹음(10분), 9개 용어집 | MOSS | 0.033 | 0.081 | 0.78 | 0 | 0.048 |
| VoxConverse 샘플(78분) | VibeVoice + Pyannote | — | — | — | — | 0.152 |

한국어와 이탈리아어가 첫 두 언어 프로필입니다. 새 언어 fixture를 측정하는 대로 이 표에 추가합니다.

78분 샘플에서 chunk 경계의 화자 안정성은 두 기준 화자 모두 1.0이었습니다. 고정된 600초 matrix에서는 120초를 넘긴 MOSS leaf가 timestamp 구조를 완전히 잃었습니다. 이 결과를 근거로 production leaf 상한을 120초로 정했습니다. 자세한 내용은 [docs/moss-long-audio-verdict.md](docs/moss-long-audio-verdict.md)에 있습니다.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/leaf-cap-dark.svg">
  <img src="docs/assets/leaf-cap-light.svg" alt="막대 그래프: 같은 600초 입력에서 120초 leaf는 정준 EOS leaf 5개를 생성(통과), 240초와 300초 leaf는 유효 leaf 0개(타입이 지정된 invalid_eos_output 실패), 240초 부모의 강제 복구는 유효한 120초 자식 5개를 생성" width="100%">
</picture>

## 설치

아직 패키지 release는 없습니다. 소스에서 build하세요.

요구 사항: Apple Silicon Mac, macOS 26, Xcode 26, [uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/gigio1023/maccheroni.git
cd maccheroni
swift build && swift test          # 153 tests
zsh scripts/build-app.zsh          # builds and codesigns Maccheroni.app
```

build, resource allowlist inventory, strict codesign 검사를 모두 통과하면 앱이 bundle 경로를 출력합니다. 모델 weight는 처음 사용할 때 다운로드합니다. `maccheroni doctor`는 runtime과 고정된 snapshot을 검증합니다.

```bash
.build/debug/maccheroni doctor
.build/debug/maccheroni run recording.wav --profile it-dialogue
```

한국어 회의용 profile(`ko-meeting`, VibeVoice)과 이탈리아어 대화용 profile(`it-dialogue`, MOSS)을 제공합니다. 선택 기능인 로컬 후처리 모델을 사용하려면 `zsh scripts/setup-postprocess-runtime.zsh`를 실행하세요.

## 개인정보 보호

<p align="center">
  <img src="docs/assets/screenshots/capture.png" alt="Maccheroni 캡처 화면: 측정된 지표가 붙은 프로필 선택, Codex/Local/None 후처리 선택, 오디오가 이 Mac을 떠나지 않는다는 안내" width="100%">
</p>

- 전사, VAD, 화자 분리는 모두 로컬에서 실행합니다. 오디오 byte는 어떤 network path로도 전달하지 않습니다. 정책 선언에 그치지 않고 test로 강제합니다.
- 선택 기능인 Codex 후처리 경로는 텍스트만 보내며 실행마다 사용자가 선택합니다. 저장된 ChatGPT 구독 로그인을 사용해 한 번의 turn만 처리하는 `codex app-server` 세션을 엽니다. thread는 임시 상태이며 읽기 전용입니다. tool은 끄고 승인 요청은 거절합니다. prompt에는 segment text, 활성 용어집, 지침이 들어갑니다. 이 경로는 API key 인증을 받지 않습니다. 로컬 MLX 모델을 선택하면 텍스트도 기기를 떠나지 않습니다.
- Failure message는 run manifest에 들어가기 전에 길이를 제한하고 path를 가립니다.

## 제약

- Apple Silicon + macOS 26 전용입니다. Intel, iOS, Windows/Linux는 지원하지 않습니다.
- 전사가 끝난 뒤에만 처리합니다. 품질을 우선하므로 live caption은 제공하지 않습니다.
- 혼용 언어 품질은 fixture에서 검증했으며 수개월 분량의 실제 회의에서는 아직 검증하지 않았습니다.
- Codex 경로를 사용하려면 본인의 Codex CLI login과 구독 quota가 필요합니다.
- UI 기본 언어는 영어이며 10개 언어를 지원합니다. ko/it string에는 여전히 사람 검토 표시가 붙어 있습니다.

## 기여

Issue와 범위를 명확히 한 pull request를 환영합니다. Build 및 test 명령, 이 README의 주장을 뒷받침하는 검증 기준, commit 규칙, issue/PR 관례는 [CONTRIBUTING.md](CONTRIBUTING.md)에 있습니다.

## 저장소 구성

| 경로 | 내용 |
|---|---|
| `Sources/` | Swift 패키지: Core, Preprocess, ASR, Diarize, Merge, Postprocess, CLI, App |
| `Tests/` | 17개 suite에 걸친 fixture 기반 test 153개 |
| `benchmarks/scripts/` | Derived verdict와 negative test를 포함한 runner 및 scorer |
| `docs/` | 조사 digest, source audit, constraint policy, 계약(JSON schema), UI design |
| `scripts/` | App bundle build, MOSS harness build, post-processing runtime setup |
| [PROJECT.md](PROJECT.md) | 의도 계층: 기둥, 비목표, 판단 규칙, 추가만 가능한 결정 기록 |
| [AGENTS.md](AGENTS.md) | 이 저장소에서 작업할 때 따르는 운영 규칙 |

문서의 모든 완료 주장에는 이를 입증한 명령과 관찰 결과를 기록합니다.

## 라이선스와 감사의 말

MIT. 이 프로젝트는 [speech-swift](https://github.com/soniqo/speech-swift)의 MLX/CoreML 음성 runtime, MOSS, VibeVoice, Silero, pyannote 모델 제작자, [mlx](https://github.com/ml-explore/mlx)를 토대로 만들었습니다. `docs/`의 reference project source audit에는 좋은 설계와 나쁜 설계 모두 이 프로젝트에 영향을 준 오픈 소스 프로젝트 24개의 출처를 밝혔습니다.
