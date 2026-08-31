<p align="center">
  <img src="docs/assets/banner.png" alt="Maccheroni: uma forma de onda entrelaçada com macarrões e duas linhas de falantes que se cruzam" width="100%">
</p>

<h1 align="center">Maccheroni</h1>

<p align="center">
  Transcrição local de conversas multilíngues no Apple Silicon.<br>
  Injeção de glossário durante a decodificação · diarização de falantes do arquivo inteiro · o áudio nunca sai do seu Mac.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%20(arm64)-black" alt="plataforma">
  <img src="https://img.shields.io/badge/swift-6-F05138" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="licença">
</p>

<p align="center"><a href="https://gigio1023.github.io/maccheroni/">Research journal (English)</a></p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.it.md">Italiano</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <b>Português</b> · <a href="README.ru.md">Русский</a> · <a href="README.zh-Hans.md">简体中文</a>
</p>

---

**Maccheroni** (de *macaronic speech*, isto é, enunciados que misturam idiomas) transcreve as conversas mais difíceis de transcrever corretamente: reuniões em coreano com nomes de produtos em inglês em todas as frases, aulas de idiomas e chamadas multilíngues. A transcrição de áudio e a diarização são executadas localmente com modelos MLX/CoreML fixados; o pós-processamento opcional do Codex envia somente texto e pode ser executado remotamente.

Exemplo de exportação (amostra ilustrativa, não é uma saída do modelo):

```markdown
**Falante 1** [00:04] Os smoke tests passaram em staging antes de fazermos o merge da PR?
**Falante 2** [00:09] Sim, e o rollout do Kubernetes ocorreu sem problemas. [UNCERTAIN]
                    Ainda há um pico de latência na janela de
                    [CONFLICT: implantação|implementação] do dashboard.
**Falante 1** [00:17] Ótimo, então mantemos o horário planejado.
```

As correções incertas são marcadas e nunca substituídas silenciosamente. Os rótulos dos falantes vêm de uma única diarização do arquivo inteiro, por isso permanecem consistentes ao longo de uma gravação de duas horas.

<p align="center">
  <img src="docs/assets/screenshots/transcript.png" alt="Visão de transcrição do Maccheroni: dois falantes com rótulos globais e chips de evidência por segmento, ao lado de um inspetor que mostra o status da execução, as revisões fixadas dos modelos e o registro do glossário" width="100%">
</p>
<p align="center"><em>Cada execução guarda sua evidência: o inspetor mostra os modelos fixados exatos, o status da execução e se o glossário chegou ao decodificador. A camada exibida — bruta, corrigida ou traduzida — é copiada para a área de transferência com um cabeçalho de procedência.</em></p>

## Por que este projeto existe

Maccheroni é uma ferramenta pessoal: uma bancada configurável para transformar conversas que misturam idiomas em registros atribuídos aos falantes em um único Mac. Quem a utiliza ajusta essa bancada às próprias necessidades, não às de um mercado.

- **Os perfis compõem a configuração de cada conversa.** Cada perfil combina um modelo ASR fixado e executado no dispositivo com o contexto do glossário e o tratamento dos falantes no arquivo inteiro, de acordo com o som real da conversa. Uma reunião em coreano repleta de nomes de produtos em inglês exige escolhas diferentes de um diálogo em italiano entre dois falantes.
- **As combinações são medidas, não presumidas.** Os fixtures públicos e sintéticos, a recuperação de termos e as taxas de erro ficam neste repositório. Assim, mudar um modelo ou glossário se torna uma comparação que pode ser refeita, não um palpite.
- **Cada execução guarda sua evidência.** As revisões fixadas dos modelos, o registro de entrega do glossário, as transcrições brutas, a linha do tempo dos falantes e as falhas tipadas ficam selados na execução. Assim, o resultado pode ser inspecionado e reproduzido mais tarde.

As notas no nível do código-fonte que orientaram essas escolhas estão em [docs/reference-project-source-audit.md](docs/reference-project-source-audit.md).

## O que o torna diferente

1. **Glossário durante a decodificação.** Nomes e termos técnicos entram no contexto do modelo antes da decodificação, porque um erro de ASR destrói a evidência acústica no momento em que acontece. O pós-processamento pode aprimorar o texto, mas não recuperar o que o decodificador nunca escreveu. A carga do glossário de cada segmento final é selada por hash no manifesto da execução.
2. **Uma única diarização atribui os falantes.** O arquivo inteiro é diarizado uma vez e essa linha do tempo é a única fonte válida para os falantes. O ASR trabalha em segmentos de tamanho limitado e os une por timestamp: estimativas locais de um segmento jamais podem trocar um rótulo ao cruzar um limite.
3. **Nenhuma perda silenciosa de dados.** Entradas que ultrapassam o limite de um backend falham explicitamente ou geram um plano de divisão. Uma saída truncada do modelo é uma falha tipada (`invalid_eos_output`), não uma transcrição mais curta. Os originais e as transcrições brutas são imutáveis; correções e traduções são artefatos separados e somente de criação.

## Como funciona

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/pipeline-dark.drawio.svg">
  <img src="docs/assets/pipeline-light.drawio.svg" alt="Diagrama do pipeline: no Mac, a captura alimenta a diarização do arquivo inteiro e as folhas ASR de 120 segundos com injeção de glossário por folha; a fusão por timestamps, em que a linha do tempo decide os falantes, alimenta o pós-processamento opcional no dispositivo; a única coisa que sai do Mac é a faixa opcional de pós-processamento remoto para um fornecedor externo via login do Codex, somente texto" width="100%">
</picture>

Os segmentos que falham são subdivididos dentro de limites tipados (mínimo de 30 s, profundidade 3). Somente saídas com fim de sequência são incorporadas à transcrição canônica. A via opcional do Codex envia, pela sua própria assinatura do ChatGPT/Codex, texto da transcrição em blocos limitados, o glossário ativo e instruções: nunca áudio ou caminhos de arquivos. A correção trata o glossário como contexto de apoio: um termo só é substituído onde o segmento plausivelmente o contém, e todo reparo incerto é marcado para revisão em vez de aplicado.

## Modelos

As identidades dos modelos e serviços do produto são registradas no manifesto de cada execução. Os modelos disponíveis para download são fixados por ID do Hugging Face, revisão e quantização.

| Função | Modelo | Revisão | Quantização |
|---|---|---|---|
| ASR (italiano / misto) | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | `90aa6528` | int8-decoder + fp16-audio-vq-kv |
| ASR (coreano) | `mlx-community/VibeVoice-ASR-8bit` | `725c72e5` | int8 |
| VAD | `aufklarer/Silero-VAD-v6.2.1-CoreML` | `52387654` | coreml-float16 |
| Diarização | `aufklarer/Pyannote-Community-1-CoreML` | `a14e6c42` | coreml-fp32 |
| Pós-processamento (local) | `mlx-community/gemma-4-12B-it-qat-4bit` | `e70c6b3b` | qat-int4 (mlx-vlm 0.6.6) |
| Pós-processamento (remoto, somente texto) | `gpt-5.6-sol` pelo servidor de aplicações Codex | gerenciado pelo serviço | n/a |

Qwen3 ASR/ForcedAligner e DiCoW são candidatos de pesquisa. A compatibilidade com os ambientes de execução da Apple, a paridade de conversão e os ganhos de qualidade no produto ainda não foram estabelecidos.

## Resultados medidos

Todos vêm de fixtures públicas ou sintéticas. Os IDs de avaliação e hashes dos artefatos estão registrados em [docs/](docs/).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/benchmarks-dark.svg">
  <img src="docs/assets/benchmarks-light.svg" alt="Gráficos de barras: CER e WER por fixture (diálogo coreano 0.081/0.141, dois falantes em italiano 0.033/0.085), recuperação de termos do glossário (0.95 e 0.778 frente ao limite de 0.75) e taxa de erro de diarização (0.048 sintético, 0.152 VoxConverse)" width="100%">
</picture>

| Fixture | Modelo | CER | WER | Recuperação de termos | Omissões | DER |
|---|---|---:|---:|---:|---:|---:|
| Diálogo em coreano, glossário de 20 termos | VibeVoice | 0.081 | 0.141 | 0.95 | 0 | — |
| Conversa sintética em italiano com 2 falantes (10 min), glossário de 9 termos | MOSS | 0.033 | 0.085 | 0.78 | 0 | 0.048 |
| Amostra do VoxConverse (78 min) | VibeVoice + Pyannote | — | — | — | — | 0.152 |

Coreano e italiano são os dois primeiros perfis de idioma. HiKE, FLEURS e AMI são fixtures de pesquisa usadas somente para verificar transporte, pontuação e paridade de conversão. Elas não podem justificar a promoção de um modelo sem demonstrar primeiro que estão ausentes dos dados de treinamento e medir separadamente a fala sobreposta.

A estabilidade dos falantes nos limites dos segmentos da amostra de 78 minutos foi 1.0 para ambos os falantes de referência. Uma matriz fixa de 600 segundos mostrou que segmentos MOSS com mais de 120 s perdem completamente a estrutura dos timestamps. Por isso, o limite de produção é 120 s; os detalhes estão em [docs/moss-long-audio-verdict.md](docs/moss-long-audio-verdict.md).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/leaf-cap-dark.svg">
  <img src="docs/assets/leaf-cap-light.svg" alt="Gráfico de barras: na mesma entrada de 600 segundos, folhas de 120 s produzem 5 folhas canônicas com fim de sequência (aprovado), folhas de 240 e 300 s produzem 0 folhas válidas (falhas tipadas invalid_eos_output), e a recuperação forçada de pais de 240 s produz 5 filhos válidos de 120 s" width="100%">
</picture>

Os ganhos da correção são medidos por um arnês de quatro estados que compara a saída bruta e a corrigida com a mesma referência, com e sem glossário na decodificação, e conta cada mudança que afasta um segmento dela. `maccheroni postprocess` e o aplicativo podem derivar novos conjuntos de correção ou tradução a partir dos segmentos selados sem executar o ASR novamente; cada salvamento do glossário preserva uma revisão endereçada por conteúdo para reutilizar os bytes exatos registrados na execução original.

## Instalação

Ainda não há versões empacotadas: compile o projeto a partir do código-fonte.

Requisitos: Mac com Apple Silicon, macOS 26, Xcode 26 e [uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/gigio1023/maccheroni.git
cd maccheroni
swift build && swift test
zsh scripts/build-app.zsh          # builds and codesigns Maccheroni.app
```

A suíte Swift padrão usa fixtures incluídas no repositório ou geradas durante os testes. Ela não depende do cache de modelos de um mantenedor, de execuções externas de benchmark nem do ambiente Python de modelos preparado pelo mantenedor, e não executa inferência real.

Prepare o runtime externo exato do perfil de reuniões em coreano com:

```bash
cache_root="$HOME/Library/Caches/Maccheroni/benchmarks"
MACCHERONI_BENCHMARK_CACHE="$cache_root" \
  zsh scripts/setup-transcription-runtime.zsh --profile ko-meeting
```

O comando instala o conjunto completo e fixado de dependências de `ko-meeting`, com VibeVoice, Silero e Community-1, além do ambiente Python, no cache de benchmarks do Maccheroni. Os pesos dos modelos e os ambientes Python permanecem fora do repositório e do bundle do aplicativo. A dependência indireta `Qwen/Qwen2.5-7B` contém somente arquivos do tokenizer. Esse perfil não instala pesos de inferência do MOSS nem do Qwen ASR/ForcedAligner.

Depois do provisionamento, ative explicitamente os testes de integração real de VibeVoice, Silero e Community-1:

```bash
MACCHERONI_RUN_MODEL_INTEGRATION=1 MACCHERONI_BENCHMARK_CACHE="$cache_root" MACCHERONI_HF_HOME="$cache_root/models/huggingface" swift test --filter MaccheroniModelIntegrationTests
```

A suíte opcional falha com um erro claro de pré-requisito quando o runtime exato está ausente ou incompleto. Altere `cache_root` para usar outro cache externo.

O aplicativo exibe o caminho do bundle quando a compilação, o inventário da lista de recursos permitidos e as verificações rigorosas de assinatura de código passam. O executável não inclui pesos de modelos nem ambientes Python, mas inclui as definições dos perfis `ko-meeting` e `it-dialogue`.

O executável oferece estes comandos do produto:

```bash
.build/debug/maccheroni help [help|run|postprocess|doctor|capabilities]
.build/debug/maccheroni run recording.wav --profile it-dialogue
.build/debug/maccheroni postprocess Runs/meeting --profile ko-meeting
.build/debug/maccheroni doctor [--profile NAME] [--profiles PATH] [--json]
.build/debug/maccheroni capabilities [--json]
```

Use `maccheroni help`, `maccheroni doctor --json` e `maccheroni capabilities --json` para consultar a ajuda e obter uma saída estruturada. O breve [guia da CLI](docs/cli-guide.md) descreve os contratos dos comandos e da saída. A transcrição e a diarização são executadas neste Mac, portanto o áudio permanece local.

Para usar o modelo local opcional de pós-processamento, execute `zsh scripts/setup-postprocess-runtime.zsh`.

## Privacidade

<p align="center">
  <img src="docs/assets/screenshots/capture.png" alt="Visão de captura do Maccheroni: seletor de perfil com métricas medidas, escolha de pós-processamento entre Codex, Local e None, e o aviso de que o áudio nunca sai deste Mac" width="100%">
</p>

- A transcrição, o VAD e a diarização são totalmente locais. Os bytes de áudio nunca chegam a nenhum caminho de rede: isso é garantido por testes, não por uma simples política.
- A via opcional de pós-processamento com Codex envia somente texto e exige adesão a cada execução. Ela abre uma sessão de um único turno com `codex app-server` usando o login salvo da assinatura do ChatGPT. A thread é temporária e somente de leitura, os servidores MCP e as ferramentas opcionais ficam desativados e as solicitações de aprovação são recusadas. O prompt contém o texto dos segmentos, o glossário ativo e as instruções. Essa via não aceita autenticação por chave de API. Se você escolher o modelo MLX local, até o texto permanecerá no dispositivo.
- As mensagens de falha da via do Codex têm o comprimento limitado e os caminhos ocultados antes de entrarem nos manifestos de execução.

## Limitações

- Somente Apple Silicon + macOS 26. Sem Intel, iOS, Windows ou Linux.
- Somente após a gravação: sem legendas ao vivo, por uma escolha deliberada de priorizar a qualidade.
- A qualidade multilíngue foi verificada em fixtures, mas ainda não ao longo de meses de reuniões reais.
- A via Codex exige seu próprio login na CLI do Codex e cota da assinatura.
- A interface usa inglês por padrão e inclui 10 localizações; as strings ko/it ainda estão marcadas para revisão humana.

## Como contribuir

Issues e pull requests focados são bem-vindos. Os comandos de compilação e teste, o padrão de verificação que sustenta as afirmações deste README, as regras de commit e as convenções para issues e PR estão em [CONTRIBUTING.md](CONTRIBUTING.md).

## Mapa do repositório

| Caminho | Conteúdo |
|---|---|
| `Sources/` | Pacote Swift: Core, Preprocess, ASR, Diarize, Merge, Postprocess, CLI, App |
| `Tests/` | Testes baseados em fixtures |
| `benchmarks/scripts/` | Executores, avaliadores e o arnês de comparação de vias de correção, com veredictos derivados e testes negativos |
| `docs/` | Resumo da pesquisa, auditorias de código-fonte, política de restrições, contratos (esquemas JSON), design da interface |
| `scripts/` | Compilação do bundle do aplicativo, configuração dos runtimes de transcrição e pós-processamento e compilação dos harnesses de benchmark |
| [PROJECT.md](PROJECT.md) | Hierarquia de intenções: pilares, objetivos excluídos, regras de decisão e registro de decisões somente de acréscimo |
| [AGENTS.md](AGENTS.md) | Convenções operacionais para trabalhar neste repositório |

Cada afirmação de conclusão nos documentos inclui o comando que a produziu e a saída observada.

## Licença e agradecimentos

MIT. Com base no trabalho de [speech-swift](https://github.com/soniqo/speech-swift) (runtimes de voz MLX/CoreML), dos autores dos modelos MOSS, VibeVoice, Silero e pyannote e de [mlx](https://github.com/ml-explore/mlx). A auditoria do código-fonte dos projetos de referência em `docs/` dá crédito aos projetos de código aberto cujos designs, bons ou ruins, ajudaram a moldar este projeto.
