<p align="center">
  <img src="docs/assets/banner.png" alt="Maccheroni: una forma d’onda intrecciata con maccheroni e due tracce dei parlanti che si incrociano" width="100%">
</p>

<h1 align="center">Maccheroni</h1>

<p align="center">
  Trascrizione locale delle conversazioni multilingue su Apple Silicon.<br>
  Glossario inserito durante la decodifica · diarizzazione dei parlanti sull’intero file · l’audio non lascia mai il Mac.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%20(arm64)-black" alt="piattaforma">
  <img src="https://img.shields.io/badge/swift-6-F05138" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="licenza">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <b>Italiano</b> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.pt.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.zh-Hans.md">简体中文</a>
</p>

---

**Maccheroni** (da *macaronic speech*, cioè enunciati che mescolano più lingue) trascrive le conversazioni che molte app sbagliano senza segnalarlo: riunioni in coreano con nomi di prodotti inglesi in ogni frase, lezioni di lingua, chiamate multilingue. Tutto viene eseguito sul dispositivo con modelli MLX/CoreML fissati a versioni precise.

Esempio di esportazione (puramente illustrativo, non è l’output del modello):

```markdown
**Interlocutore 1** [00:04] Gli smoke test sono passati su staging prima del merge della PR?
**Interlocutore 2** [00:09] Sì, e il rollout Kubernetes è andato liscio. [UNCERTAIN] Però
                           resta un picco di latenza sulla dashboard durante la finestra
                           di [CONFLICT: rilascio|rilasso].
**Interlocutore 1** [00:17] Bene, allora manteniamo l’orario previsto.
```

Le correzioni incerte vengono segnalate e mai sostituite in silenzio. Le etichette dei parlanti provengono da un’unica diarizzazione dell’intero file, quindi rimangono coerenti anche in una registrazione di due ore.

<p align="center">
  <img src="docs/assets/screenshots/transcript.png" alt="Vista trascrizione di Maccheroni: due parlanti con etichette globali e chip di evidenza per segmento, accanto a un ispettore che mostra lo stato dell'esecuzione, le revisioni fissate dei modelli e il registro del glossario" width="100%">
</p>
<p align="center"><em>Ogni esecuzione conserva le sue evidenze: l'ispettore mostra i modelli fissati esatti, lo stato dell'esecuzione e se il glossario ha raggiunto il decoder.</em></p>

## Perché esiste

Il 2 agosto 2026 abbiamo esaminato a livello di codice sorgente sette app macOS per la trascrizione locale. Nessuna offriva la combinazione necessaria nelle riunioni realmente multilingue:

- Le app con diarizzazione locale non passavano il glossario al modello ASR: usavano sostituzioni di stringhe a posteriori, parametri SDK inattivi o dizionari disponibili solo nel cloud.
- L’app con il glossario più pulito a livello del modello non offriva la diarizzazione.
- «Supporto multilingue» significa quasi sempre *una lingua per sessione*, l’esatto contrario di una conversazione in cui le lingue si mescolano.

Tutti i componenti esistono già nelle librerie. Mancava la loro combinazione in un’app. Questo repository la realizza e documenta l’analisi in [docs/reference-project-source-audit.md](docs/reference-project-source-audit.md).

## Cosa lo distingue

1. **Glossario durante la decodifica.** Nomi e termini tecnici entrano nel contesto del modello prima della decodifica, perché un errore ASR distrugge l’evidenza acustica nel momento stesso in cui avviene. La post-elaborazione può rifinire il testo, ma non può recuperare ciò che il decoder non ha mai scritto. Il payload del glossario di ogni segmento finale viene sigillato con un hash nel manifest dell’esecuzione.
2. **Un’unica diarizzazione assegna i parlanti.** L’intero file viene diarizzato una sola volta e quella timeline è l’unica fonte valida per i parlanti. L’ASR lavora su segmenti di dimensione limitata, poi li unisce in base ai timestamp: le stime locali di un segmento non possono mai cambiare un’etichetta oltre il confine del segmento.
3. **Nessuna perdita silenziosa di dati.** Gli input che superano il limite di un backend causano un errore esplicito o producono un piano di suddivisione. Un output troncato del modello è un errore tipizzato (`invalid_eos_output`), non una trascrizione più corta. Gli originali e le trascrizioni grezze sono immutabili; correzioni e traduzioni sono artefatti separati e di sola creazione.

## Come funziona

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/pipeline-dark.drawio.svg">
  <img src="docs/assets/pipeline-light.drawio.svg" alt="Diagramma della pipeline: sul Mac, l'acquisizione alimenta la diarizzazione dell'intero file e i segmenti ASR da 120 secondi con iniezione del glossario per segmento; la fusione per timestamp, in cui la timeline decide i parlanti, alimenta la post-elaborazione opzionale sul dispositivo; l'unica cosa che lascia il Mac è la corsia opzionale di post-elaborazione remota verso un fornitore esterno tramite l'accesso Codex, solo testo" width="100%">
</picture>

I segmenti non riusciti vengono suddivisi di nuovo entro limiti tipizzati (minimo 30 s, profondità 3). Solo gli output con token di fine sequenza vengono promossi nella trascrizione canonica. Il percorso Codex facoltativo invia, tramite il tuo abbonamento ChatGPT/Codex, testo della trascrizione in blocchi limitati, glossario attivo e istruzioni: mai l’audio e mai i percorsi dei file.

## Modelli

Ogni modello è fissato tramite ID Hugging Face + revisione + quantizzazione e viene registrato nel manifest di ogni esecuzione.

| Ruolo | Modello | Revisione | Quantizzazione |
|---|---|---|---|
| ASR (italiano / misto) | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | `90aa6528` | int8-decoder + fp16-audio-vq-kv |
| ASR (coreano) | `mlx-community/VibeVoice-ASR-8bit` | `725c72e5` | int8 |
| VAD | `aufklarer/Silero-VAD-v6.2.1-CoreML` | `52387654` | coreml-float16 |
| Diarizzazione | `aufklarer/Pyannote-Community-1-CoreML` | `a14e6c42` | coreml-fp32 |
| Post-elaborazione (locale) | `mlx-community/gemma-4-12B-it-qat-4bit` | `e70c6b3b` | qat-int4 (mlx-vlm 0.6.6) |
| Post-elaborazione (remota, solo testo) | `gpt-5.6-sol` tramite il server applicativo Codex | gestita dal servizio | n/a |

## Risultati misurati

Tutti i risultati provengono da fixture pubbliche o sintetiche. Gli ID delle valutazioni e gli hash degli artefatti sono registrati in [docs/](docs/).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/benchmarks-dark.svg">
  <img src="docs/assets/benchmarks-light.svg" alt="Grafici a barre: CER e WER per fixture (dialogo coreano 0.081/0.128, due parlanti italiani 0.033/0.081), recupero dei termini del glossario (0.95 e 0.778 rispetto alla soglia 0.75) e tasso di errore di diarizzazione (0.048 sintetico, 0.152 VoxConverse)" width="100%">
</picture>

| Fixture | Modello | CER | WER | Recupero dei termini | Omissioni | DER |
|---|---|---:|---:|---:|---:|---:|
| Dialogo coreano, glossario di 20 termini | VibeVoice | 0.081 | 0.128 | 0.95 | 0 | — |
| Conversazione sintetica in italiano con 2 parlanti (10 min), glossario di 9 termini | MOSS | 0.033 | 0.081 | 0.78 | 0 | 0.048 |
| Campione VoxConverse (78 min) | VibeVoice + Pyannote | — | — | — | — | 0.152 |

Coreano e italiano sono i primi due profili di lingua; nuove fixture linguistiche entrano in questa tabella man mano che vengono misurate.

Nel campione di 78 minuti, la stabilità dei parlanti ai confini dei segmenti è 1.0 per entrambi i parlanti di riferimento. Una matrice fissa di 600 secondi ha mostrato che i segmenti MOSS oltre 120 s perdono completamente la struttura dei timestamp. Per questo il limite di produzione è 120 s; i dettagli sono in [docs/moss-long-audio-verdict.md](docs/moss-long-audio-verdict.md).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/leaf-cap-dark.svg">
  <img src="docs/assets/leaf-cap-light.svg" alt="Grafico a barre: sullo stesso input di 600 secondi, i segmenti da 120 s producono 5 foglie canoniche con fine sequenza (superato), quelli da 240 e 300 s producono 0 foglie valide (errori tipizzati invalid_eos_output), e il recupero forzato da genitori di 240 s produce 5 figli validi da 120 s" width="100%">
</picture>

## Installazione

Non esistono ancora release preconfezionate: occorre compilare il progetto dal codice sorgente.

Requisiti: Mac con Apple Silicon, macOS 26, Xcode 26, [uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/gigio1023/maccheroni.git
cd maccheroni
swift build && swift test          # 153 tests
zsh scripts/build-app.zsh          # builds and codesigns Maccheroni.app
```

L’app stampa il percorso del bundle quando la compilazione, l’inventario della lista delle risorse consentite e i controlli rigorosi della firma del codice hanno esito positivo. I pesi dei modelli vengono scaricati al primo utilizzo; `maccheroni doctor` verifica i runtime e gli snapshot fissati:

```bash
.build/debug/maccheroni doctor
.build/debug/maccheroni run recording.wav --profile it-dialogue
```

Sono inclusi profili per riunioni in coreano (`ko-meeting`, VibeVoice) e dialoghi in italiano (`it-dialogue`, MOSS). Per il modello locale facoltativo di post-elaborazione, esegui `zsh scripts/setup-postprocess-runtime.zsh`.

## Privacy

<p align="center">
  <img src="docs/assets/screenshots/capture.png" alt="Vista di acquisizione di Maccheroni: selettore del profilo con metriche misurate, scelta di post-elaborazione tra Codex, Local e None, e l'avviso che l'audio non lascia mai questo Mac" width="100%">
</p>

- Trascrizione, VAD e diarizzazione vengono eseguite interamente in locale. I byte dell’audio non raggiungono mai alcun percorso di rete: lo garantiscono i test, non una semplice regola.
- Il percorso facoltativo di post-elaborazione Codex invia solo testo e richiede il consenso per ogni esecuzione. Apre una sessione a turno singolo con `codex app-server` usando l’accesso salvato all’abbonamento ChatGPT. Il thread è temporaneo e di sola lettura, gli strumenti sono disabilitati e le richieste di approvazione vengono rifiutate. Il prompt contiene il testo dei segmenti, il glossario attivo e le istruzioni. Questo percorso non accetta l’autenticazione con chiave API. Scegliendo il modello MLX locale, anche il testo rimane sul dispositivo.
- Prima di entrare nei manifest di esecuzione, i messaggi di errore vengono limitati in lunghezza e privati dei percorsi dei file.

## Limiti

- Solo Apple Silicon + macOS 26. Niente Intel, iOS, Windows o Linux.
- Solo post-trascrizione: niente sottotitoli in tempo reale, per privilegiare deliberatamente la qualità.
- La qualità multilingue è stata verificata sulle fixture, non ancora su mesi di riunioni reali.
- Il percorso Codex richiede un accesso personale alla CLI Codex e la quota del relativo abbonamento.
- L’interfaccia è in inglese per impostazione predefinita e comprende 10 localizzazioni; le stringhe ko/it sono ancora contrassegnate per la revisione umana.

## Contribuire

Issue e pull request mirate sono benvenute. I comandi di build e test, lo standard di verifica alla base delle affermazioni di questo README, le regole per i commit e le convenzioni per issue e PR sono descritti in [CONTRIBUTING.md](CONTRIBUTING.md).

## Mappa del repository

| Percorso | Contenuto |
|---|---|
| `Sources/` | Pacchetto Swift: Core, Preprocess, ASR, Diarize, Merge, Postprocess, CLI, App |
| `Tests/` | 153 test basati su fixture in 17 suite |
| `benchmarks/scripts/` | Runner e script di valutazione con verdetti derivati e test negativi |
| `docs/` | Sintesi della ricerca, analisi del codice sorgente, regole sui vincoli, contratti (schemi JSON), progettazione dell’interfaccia |
| `scripts/` | Compilazione del bundle dell’app, compilazione dell’harness MOSS, configurazione del runtime di post-elaborazione |
| [PROJECT.md](PROJECT.md) | Gerarchia degli intenti: principi, non-obiettivi, regole di giudizio e registro decisionale append-only |
| [AGENTS.md](AGENTS.md) | Convenzioni operative per lavorare in questo repository |

Ogni dichiarazione di completamento nei documenti riporta il comando che l’ha prodotta e l’output osservato.

## Licenza e ringraziamenti

MIT. Basato sul lavoro di: [speech-swift](https://github.com/soniqo/speech-swift) (runtime vocali MLX/CoreML), gli autori dei modelli MOSS, VibeVoice, Silero e pyannote, e [mlx](https://github.com/ml-explore/mlx). L’analisi del codice sorgente dei progetti di riferimento in `docs/` riconosce i 24 progetti open source le cui scelte progettuali, riuscite o meno, hanno contribuito a questo progetto.
