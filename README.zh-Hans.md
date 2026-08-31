<p align="center">
  <img src="docs/assets/banner.png" alt="Maccheroni 横幅：波形穿过通心粉，两位说话人的声纹线交织其中" width="100%">
</p>

<h1 align="center">Maccheroni</h1>

<p align="center">
  在 Apple Silicon 上运行的本地优先混合语言语音转写工具。<br>
  解码时注入术语表 · 全文件说话人分离 · 音频绝不离开你的 Mac。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%20(arm64)-black" alt="平台">
  <img src="https://img.shields.io/badge/swift-6-F05138" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="许可证">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.it.md">Italiano</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.pt.md">Português</a> · <a href="README.ru.md">Русский</a> · <b>简体中文</b>
</p>

---

**Maccheroni** 得名于 *macaronic speech*，即在一句话中混用多种语言。它能转写最难准确转写的对话，例如每句话都夹有英文产品名的韩语会议、语言课和多语言通话。转写和说话人分离由固定版本的 MLX/Core ML 模型在设备上完成。可选的纯文本后处理可使用远程 Codex。

下面是导出效果示例，仅供说明，并非模型输出：

```markdown
**说话人 1** [00:04] 合并那个 PR 之前，staging 上的 smoke test 通过了吗？
**说话人 2** [00:09] 通过了，Kubernetes rollout 也很顺利。[UNCERTAIN] 不过
                    dashboard 上的 [CONFLICT: 回滚|回购] 开关触发得有点晚。
**说话人 1** [00:17] 好，那就按原计划保留 release window。
```

不确定的修正会标记出来，绝不会静默替换。说话人标签来自一次全文件说话人分离，因此在两小时的录音中也能保持一致。

<p align="center">
  <img src="docs/assets/screenshots/transcript.png" alt="Maccheroni 转写视图：两位说话人带全局标签和每段证据标记，旁边的检查器显示运行状态、固定的模型 revision 和词汇表记录" width="100%">
</p>
<p align="center"><em>每次运行都保留证据：检查器显示固定的模型、运行状态，以及词汇表是否送达解码器。当前显示的图层（原始、修正或翻译）可连同来源标头一起复制到剪贴板。</em></p>

## 项目缘起

Maccheroni 是一款个人工具：一个可配置的工作台，用一台 Mac 把混合语言对话转成标注说话人的记录。它由使用者按自己的需要调校，不面向市场需求。

- **profile 为每段对话组合所需设置。** 每个 profile 将固定版本的设备端 ASR 模型与术语表上下文和全文件说话人处理组合起来，使其贴合这段对话的实际语音特点。英文产品名密集的韩语会议与意大利语双人对话需要不同的选择。
- **组合以测量为准。** 本仓库保存公开及合成测试样本、术语召回率和错误率。更换模型或术语表时，可以重新运行对比，无须凭感觉判断。
- **每次运行都保留证据。** 固定的模型 revision、术语表传递记录、原始转写、说话人时间线和类型化失败都封存在运行记录中，便于日后检查和复现结果。

这些选择所依据的源码级记录见 [docs/reference-project-source-audit.md](docs/reference-project-source-audit.md)。

## 独特之处

1. **解码时注入术语表。** 姓名和技术术语会在解码前进入模型的 context，因为 ASR 一旦出错，当时的声学证据就会丢失。后处理可以润色文本，却无法找回 decoder 从未写出的内容。每个 leaf 的术语表 payload 都以 hash 封存到 run manifest 中。
2. **一次说话人分离决定全部说话人。** 整个文件只做一次说话人分离，并将该 timeline 作为说话人身份的唯一依据。ASR 按有明确上限的 chunk 运行，再根据 timestamp 合并。chunk 内的说话人猜测无法在边界处翻转标签。
3. **绝不静默丢失数据。** 超过 backend 限制的输入会明确失败或生成分割计划。被截断的模型输出会成为 typed failure（`invalid_eos_output`），不会伪装成更短的转写。原始文件和 raw transcript 不可修改；修正和翻译会生成独立的 create-only artifact。

## 工作原理

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/pipeline-dark.drawio.svg">
  <img src="docs/assets/pipeline-light.drawio.svg" alt="流水线图:在 Mac 上,采集送入整文件说话人分离和120秒 ASR leaf(每个 leaf 注入词汇表);时间戳合并由时间线决定说话人,再送入可选的设备端后处理;离开 Mac 的只有可选的远程后处理通道,通过 Codex 登录连接外部供应商,且仅传输文本" width="100%">
</picture>

失败的 leaf 会在 typed bound 内重新分割，最短30秒，最大深度为3。只有 end-of-sequence 输出才能升级为 canonical transcript。可选的 Codex 路径通过你自己的 ChatGPT/Codex 订阅发送有长度上限的转写文本、当前术语表和指令。它绝不发送音频或文件路径。Correction 把术语表当作辅助上下文：只有当 segment 里确实可能出现某个术语时才会替换，任何不确定的修正都会标记为待审核，而不是直接应用。

## 模型

每次运行的 run manifest 都会记录产品所用模型和服务的标识。可下载模型以 Hugging Face ID + revision + quantization 固定。

| 用途 | 模型 | 修订版本 | 量化方式 |
|---|---|---|---|
| ASR（意大利语 / 混合语言） | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | `90aa6528` | int8-decoder + fp16-audio-vq-kv |
| ASR（韩语） | `mlx-community/VibeVoice-ASR-8bit` | `725c72e5` | int8 |
| VAD | `aufklarer/Silero-VAD-v6.2.1-CoreML` | `52387654` | coreml-float16 |
| 说话人分离 | `aufklarer/Pyannote-Community-1-CoreML` | `a14e6c42` | coreml-fp32 |
| 后处理（本地） | `mlx-community/gemma-4-12B-it-qat-4bit` | `e70c6b3b` | qat-int4 (mlx-vlm 0.6.6) |
| 后处理（远程，仅文本） | 通过 Codex 应用服务器使用 `gpt-5.6-sol` | 由服务管理 | 不适用 |

Qwen3 ASR、Qwen3 ForcedAligner 和 DiCoW 仍是研究候选方案。它们与 Apple runtime 的兼容性、转换一致性和产品质量提升均未确立。

## 实测结果

所有结果均来自公开或合成 fixture；评估 ID 和 artifact hash 记录在 [docs/](docs/) 中。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/benchmarks-dark.svg">
  <img src="docs/assets/benchmarks-light.svg" alt="柱状图：各测试样本的 CER 和 WER（韩语对话 0.081/0.141，意大利语双说话人 0.033/0.085）、词汇表术语召回率（0.95 和 0.778，门限 0.75）以及说话人分离错误率（合成 0.048，VoxConverse 0.152）" width="100%">
</picture>

| 测试样本 | 模型 | CER | WER | 术语召回率 | 遗漏数 | DER |
|---|---|---:|---:|---:|---:|---:|
| 韩语对话，20个术语 | VibeVoice | 0.081 | 0.141 | 0.95 | 0 | — |
| 意大利语双人合成音频（10分钟），9个术语 | MOSS | 0.033 | 0.085 | 0.78 | 0 | 0.048 |
| VoxConverse 样本（78分钟） | VibeVoice + Pyannote | — | — | — | — | 0.152 |

韩语和意大利语是最早的两个语言配置。HiKE、FLEURS 和 AMI 仅作为传输、评分和转换一致性研究用 fixture。确认它们未用于训练并完成重叠语音专项测量前，不能用它们晋级模型。

在78分钟样本中，两位参考说话人的 chunk 边界稳定性都是1.0。固定的600秒 matrix 显示，超过120秒的 MOSS leaf 会完全丢失 timestamp 结构，因此生产环境的 leaf 上限设为120秒。详情见 [docs/moss-long-audio-verdict.md](docs/moss-long-audio-verdict.md)。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/leaf-cap-dark.svg">
  <img src="docs/assets/leaf-cap-light.svg" alt="柱状图：在同一段600秒输入上，120秒 leaf 产生5个规范的 EOS leaf（通过），240秒和300秒 leaf 产生0个有效 leaf（类型化的 invalid_eos_output 失败），从240秒父节点强制恢复产生5个有效的120秒子节点" width="100%">
</picture>

Correction 的收益通过四状态对比测量，包括 raw 和 corrected 输出、decode 时是否注入术语表，并明确统计有害修正。`maccheroni postprocess` 和应用无需重新运行 ASR，即可从封存的分段派生新的修正集或翻译集。保存的 glossary revision 按内容寻址，并复用原始运行记录的字节。

## 安装

目前尚无打包release，请从源码build。

要求：Apple Silicon Mac、macOS 26、Xcode 26、[uv](https://docs.astral.sh/uv/)。

```bash
git clone https://github.com/gigio1023/maccheroni.git
cd maccheroni
swift build && swift test
zsh scripts/build-app.zsh          # builds and codesigns Maccheroni.app
```

build、resource allowlist inventory 和 strict codesign 检查全部通过后，应用会输出 bundle path。可执行文件不内置模型 weight 或 Python 环境。项目包含 `ko-meeting` 和 `it-dialogue` 的 profile 定义，`maccheroni doctor` 会报告实际检测到的依赖项和存储状态。全新 cache 下的 `ko-meeting` provisioning 和完整 `doctor` 验证尚未完成；它间接依赖的 Qwen tokenizer 和 Hugging Face metadata 必须手动准备。

可执行文件提供五个产品命令：

```bash
.build/debug/maccheroni help [help|run|postprocess|doctor|capabilities]
.build/debug/maccheroni run recording.wav --profile it-dialogue
.build/debug/maccheroni postprocess Runs/meeting --profile ko-meeting
.build/debug/maccheroni doctor [--profile NAME] [--profiles PATH] [--json]
.build/debug/maccheroni capabilities [--json]
```

使用 `maccheroni help`、`maccheroni doctor --json` 和 `maccheroni capabilities --json` 可查看帮助并获取结构化输出。简明的 [CLI 指南](docs/cli-guide.md)说明了命令和输出约定。转写和说话人分离在这台 Mac 上运行，因此音频始终留在本地。

若要使用可选的本地后处理模型，请运行 `zsh scripts/setup-postprocess-runtime.zsh`。

## 隐私

<p align="center">
  <img src="docs/assets/screenshots/capture.png" alt="Maccheroni 采集视图：带实测指标的配置选择、Codex、Local 与 None 之间的后处理选择，以及音频绝不离开这台 Mac 的提示" width="100%">
</p>

- 转写、VAD 和说话人分离完全在本地执行。音频 byte 绝不会进入任何 network path。这一限制由 test 强制执行，并非只写在政策中。
- 可选的 Codex 后处理路径只发送文本，并且每次运行都需要主动选择。它使用已保存的 ChatGPT 订阅登录打开单轮 `codex app-server` 会话。thread 是临时且只读的，MCP server 和可选 tooling 会被禁用，审批请求会被拒绝。prompt 只包含 segment text、当前术语表和指令。此路径不接受 API key 身份验证。选择本地 MLX 模型后，连文本也会留在设备上。
- Codex 路径的 failure message 在进入 run manifest 前会限制长度并隐去 path。

## 限制

- 仅支持 Apple Silicon + macOS 26，不支持 Intel、iOS 或 Windows/Linux。
- 仅支持转写后处理，不提供 live caption，这是出于质量优先的设计选择。
- 混合语言质量已在 fixture 上验证，但尚未经过数月真实会议的检验。
- Codex 路径需要你自己的 Codex CLI login 和订阅 quota。
- UI 默认使用英语，提供10种本地化；ko/it string 仍标记为需要人工审查。

## 贡献

欢迎提交 issue 和范围明确的 pull request。构建和测试命令、支撑本 README 各项声明的验证标准、commit 规则以及 issue/PR 约定均见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `Sources/` | Swift 包：Core、Preprocess、ASR、Diarize、Merge、Postprocess、CLI、App |
| `Tests/` | 基于 fixture 的 Swift test |
| `benchmarks/scripts/` | 带有 derived verdict 和 negative test 的 runner、scorer 与 correction 路径对比 harness |
| `docs/` | 调研 digest、source audit、constraint policy、契约（JSON schema）、UI design |
| `scripts/` | App bundle build、MOSS harness build、post-processing runtime setup |
| [PROJECT.md](PROJECT.md) | 意图层级：支柱、非目标、判断规则和只追加不删除的决策日志 |
| [AGENTS.md](AGENTS.md) | 在本仓库中工作的操作约定 |

文档中的每项完成声明都附有得出该声明的命令及其实际输出。

## 许可证与致谢

MIT。本项目建立在 [speech-swift](https://github.com/soniqo/speech-swift) 的 MLX/CoreML 语音 runtime、MOSS、VibeVoice、Silero 和 pyannote 模型作者的成果以及 [mlx](https://github.com/ml-explore/mlx) 之上。`docs/` 中的 reference project source audit 列出了24个影响本项目设计的开源项目，无论其设计经验值得借鉴还是警惕。
