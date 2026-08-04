<p align="center">
  <img src="docs/assets/banner.png" alt="Maccheroni: eine mit Makkaroni verflochtene Wellenform, durchzogen von zwei Sprecherlinien" width="100%">
</p>

<h1 align="center">Maccheroni</h1>

<p align="center">
  Lokale Transkription gemischtsprachiger Gespräche auf Apple Silicon.<br>
  Glossarinjektion beim Dekodieren · Sprecherdiarisierung der gesamten Datei · Audio verlässt niemals deinen Mac.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%20(arm64)-black" alt="Plattform">
  <img src="https://img.shields.io/badge/swift-6-F05138" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="Lizenz">
</p>

<p align="center">
  <a href="README.md">English</a> · <b>Deutsch</b> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.it.md">Italiano</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.pt.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.zh-Hans.md">简体中文</a>
</p>

---

**Maccheroni** (von *macaronic speech*, also Äußerungen, die Sprachen mischen) transkribiert die Gespräche, an denen die meisten Apps unbemerkt scheitern: koreanische Meetings mit englischen Produktnamen in jedem Satz, Sprachunterricht und mehrsprachige Anrufe. Alles läuft mit festgeschriebenen MLX/CoreML-Modellen auf dem Gerät.

So sieht ein Export aus (anschauliches Beispiel, keine Modellausgabe):

```markdown
**Sprecher 1** [00:04] Sind die Smoke Tests auf Staging durchgelaufen, bevor wir den PR gemergt haben?
**Sprecher 2** [00:09] Ja, und der Kubernetes-Rollout war sauber. [UNCERTAIN] Im
                      Dashboard gibt es aber noch einen Ausschlag bei der
                      [CONFLICT: Latenz|Lizenz].
**Sprecher 1** [00:17] Alles klar, dann bleibt das Release-Fenster wie geplant.
```

Unsichere Korrekturen werden gekennzeichnet und niemals stillschweigend ersetzt. Die Sprecherbezeichnungen stammen aus einem einzigen Diarisierungslauf über die gesamte Datei und bleiben dadurch auch in einer zweistündigen Aufnahme konsistent.

<p align="center">
  <img src="docs/assets/screenshots/transcript.png" alt="Maccheroni-Transkriptansicht: zwei Sprecher mit globalen Labels und Evidenz-Chips pro Segment, daneben ein Run-Inspektor mit Run-Status, gepinnten Modellrevisionen und dem Glossareintrag" width="100%">
</p>
<p align="center"><em>Jeder Lauf behält seine Evidenz: Der Inspektor zeigt die exakt gepinnten Modelle, den Status des Laufs und ob das Glossar den Decoder erreicht hat.</em></p>

## Warum es dieses Projekt gibt

Am 2. August 2026 haben wir sieben lokale macOS-Transkriptions-Apps auf Quellcodeebene geprüft. Keine erfüllte die Kombination, die echte gemischtsprachige Meetings brauchen:

- Apps mit lokaler Diarisierung übergaben das Glossar nicht an das ASR-Modell. Stattdessen nutzten sie nachträgliche Zeichenkettenersetzung, wirkungslose SDK-Parameter oder Wörterbücher, die nur in der Cloud verfügbar waren.
- Die App mit dem saubersten Glossar auf Modellebene bot keine Diarisierung.
- „Mehrsprachige Unterstützung“ bedeutet fast immer *eine Sprache pro Sitzung*. Gemischtsprachige Äußerungen funktionieren gerade nicht so.

Auf Bibliotheksebene sind alle Bausteine vorhanden. Auf App-Ebene fehlte ihre Kombination. Dieses Repository setzt sie um; die Prüfung ist unter [docs/reference-project-source-audit.md](docs/reference-project-source-audit.md) dokumentiert.

## Was Maccheroni unterscheidet

1. **Glossar beim Dekodieren.** Namen und Fachbegriffe gelangen vor dem Dekodieren in den Modellkontext, denn ein ASR-Fehler zerstört die akustische Evidenz in dem Moment, in dem er entsteht. Nachbearbeitung kann Text glätten, aber nicht wiederherstellen, was der Decoder nie geschrieben hat. Die Glossarnutzlast jedes Blatts wird mit einem Hash versiegelt im Ausführungsmanifest abgelegt.
2. **Ein Diarisierungslauf bestimmt die Sprecher.** Die gesamte Datei wird einmal diarisiert; ausschließlich diese Zeitleiste legt die Sprecher fest. ASR arbeitet in begrenzten Abschnitten und führt sie anhand der Zeitstempel zusammen. Lokale Sprecherschätzungen eines Abschnitts können daher an einer Grenze niemals eine Bezeichnung vertauschen.
3. **Niemals stiller Datenverlust.** Eingaben oberhalb des Backend-Limits schlagen ausdrücklich fehl oder erzeugen einen Aufteilungsplan. Abgeschnittene Modellausgabe ist ein typisierter Fehler (`invalid_eos_output`) und kein kürzeres Transkript. Originale und Rohtranskripte sind unveränderlich; Korrekturen und Übersetzungen werden als getrennte, nur neu angelegte Artefakte gespeichert.

## Funktionsweise

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/pipeline-dark.drawio.svg">
  <img src="docs/assets/pipeline-light.drawio.svg" alt="Pipeline-Diagramm: Auf dem Mac speist die Aufnahme die Ganzdatei-Diarisierung und 120-Sekunden-ASR-Blätter mit Glossar-Injektion pro Blatt; der Zeitstempel-Merge, in dem die Timeline die Sprecher bestimmt, führt zur optionalen Nachbearbeitung auf dem Gerät; den Mac verlässt nur die Opt-in-Spur für entfernte Nachbearbeitung zu einem externen Anbieter über die Codex-Anmeldung, ausschließlich Text" width="100%">
</picture>

Fehlgeschlagene Blätter werden innerhalb typisierter Grenzen erneut aufgeteilt (mindestens 30 s, Tiefe 3). Nur Ausgaben mit einem Ende-der-Sequenz-Marker werden in das kanonische Transkript übernommen. Der optionale Codex-Pfad sendet begrenzte Transkriptabschnitte, das aktive Glossar und Anweisungen über dein eigenes ChatGPT/Codex-Abonnement. Audio und Dateipfade werden niemals gesendet.

## Modelle

Alle Modelle sind durch Hugging-Face-ID + Revision + Quantisierung festgeschrieben und werden in jedem Ausführungsmanifest protokolliert.

| Rolle | Modell | Revision | Quantisierung |
|---|---|---|---|
| ASR (Italienisch / gemischt) | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | `90aa6528` | int8-decoder + fp16-audio-vq-kv |
| ASR (Koreanisch) | `mlx-community/VibeVoice-ASR-8bit` | `725c72e5` | int8 |
| VAD | `aufklarer/Silero-VAD-v6.2.1-CoreML` | `52387654` | coreml-float16 |
| Diarisierung | `aufklarer/Pyannote-Community-1-CoreML` | `a14e6c42` | coreml-fp32 |
| Nachbearbeitung (lokal) | `mlx-community/gemma-4-12B-it-qat-4bit` | `e70c6b3b` | qat-int4 (mlx-vlm 0.6.6) |
| Nachbearbeitung (remote, nur Text) | `gpt-5.6-sol` über den Codex-App-Server | vom Dienst verwaltet | nicht zutreffend |

## Messergebnisse

Alle Ergebnisse stammen aus öffentlichen oder synthetischen Fixtures. Auswertungs-IDs und Artefakt-Hashes sind unter [docs/](docs/) dokumentiert.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/benchmarks-dark.svg">
  <img src="docs/assets/benchmarks-light.svg" alt="Balkendiagramme: CER und WER je Fixture (koreanischer Dialog 0.081/0.128, italienisches Zwei-Sprecher-Beispiel 0.033/0.081), Begriffstrefferquote des Glossars (0.95 und 0.778 gegenüber der Schwelle 0.75) und Diarisierungsfehlerrate (0.048 synthetisch, 0.152 VoxConverse)" width="100%">
</picture>

| Fixture | Modell | CER | WER | Begriffstrefferquote | Auslassungen | DER |
|---|---|---:|---:|---:|---:|---:|
| Koreanischer Dialog, Glossar mit 20 Begriffen | VibeVoice | 0.081 | 0.128 | 0.95 | 0 | — |
| Italienischer synthetischer Dialog mit 2 Sprechern (10 min), Glossar mit 9 Begriffen | MOSS | 0.033 | 0.081 | 0.78 | 0 | 0.048 |
| VoxConverse-Beispiel (78 min) | VibeVoice + Pyannote | — | — | — | — | 0.152 |

Koreanisch und Italienisch sind die ersten beiden Sprachprofile; neue Sprach-Fixtures kommen in diese Tabelle, sobald sie gemessen sind.

Stabilität der Sprecher an Abschnittsgrenzen im 78-Minuten-Beispiel: 1.0 für beide Referenzsprecher. Eine feste Matrix von 600 Sekunden zeigte, dass MOSS-Blätter über 120 s ihre Zeitstempelstruktur vollständig verlieren. Deshalb liegt die Obergrenze für produktive Blätter bei 120 s. Einzelheiten stehen unter [docs/moss-long-audio-verdict.md](docs/moss-long-audio-verdict.md).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/leaf-cap-dark.svg">
  <img src="docs/assets/leaf-cap-light.svg" alt="Balkendiagramm: Auf demselben 600-Sekunden-Input liefern 120-Sekunden-Blätter 5 kanonische End-of-Sequence-Blätter (bestanden), 240- und 300-Sekunden-Blätter 0 gültige Blätter (typisierte invalid_eos_output-Fehler), und die erzwungene Wiederherstellung aus 240-Sekunden-Eltern liefert 5 gültige 120-Sekunden-Kinder" width="100%">
</picture>

## Installation

Es gibt noch keine paketierten Releases. Baue das Projekt aus dem Quellcode.

Voraussetzungen: Apple-Silicon-Mac, macOS 26, Xcode 26, [uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/gigio1023/maccheroni.git
cd maccheroni
swift build && swift test          # 157 tests
zsh scripts/build-app.zsh          # builds and codesigns Maccheroni.app
```

Die App gibt ihren Bundle-Pfad aus, wenn Build, Ressourcen-Allowlist-Inventur und strenge Codesign-Prüfungen erfolgreich sind. Modellgewichte werden bei der ersten Nutzung heruntergeladen. Die ausführbare Datei enthält weder Modellgewichte noch Python-Umgebungen; `maccheroni doctor` prüft Laufzeitumgebungen und festgeschriebene Snapshots.

Die ausführbare Datei bietet vier Produktbefehle:

```bash
.build/debug/maccheroni help [help|run|doctor|capabilities]
.build/debug/maccheroni run recording.wav --profile it-dialogue
.build/debug/maccheroni doctor [--profile NAME] [--profiles PATH] [--json]
.build/debug/maccheroni capabilities [--json]
```

`maccheroni help`, `maccheroni doctor --json` und `maccheroni capabilities --json` liefern auffindbare Hilfe und strukturierte Ausgaben. Der kurze [CLI-Leitfaden](docs/cli-guide.md) beschreibt Befehls- und Ausgabeverträge. Transkription und Sprechertrennung laufen auf diesem Mac, sodass das Audio lokal bleibt.

Mitgeliefert werden Profile für koreanische Meetings (`ko-meeting`, VibeVoice) und italienische Dialoge (`it-dialogue`, MOSS). Führe für das optionale lokale Nachbearbeitungsmodell `zsh scripts/setup-postprocess-runtime.zsh` aus.

## Datenschutz

<p align="center">
  <img src="docs/assets/screenshots/capture.png" alt="Maccheroni-Aufnahmeansicht: Profilauswahl mit gemessenen Metriken, Nachbearbeitungswahl zwischen Codex, Local und None sowie der Hinweis, dass Audio diesen Mac nie verlässt" width="100%">
</p>

- Transkription, VAD und Diarisierung laufen vollständig lokal. Audiobytes gelangen auf keinen Netzwerkpfad. Tests erzwingen dies, nicht bloß eine Richtlinie.
- Der optionale Codex-Nachbearbeitungspfad arbeitet ausschließlich mit Text und muss für jeden Lauf aktiviert werden. Er öffnet mit der gespeicherten ChatGPT-Abonnementanmeldung eine einmalige `codex app-server`-Sitzung. Der Thread ist temporär und schreibgeschützt, Werkzeuge sind deaktiviert und Genehmigungsanfragen werden abgelehnt. Der Prompt enthält Segmenttext, das aktive Glossar und Anweisungen. Eine API-Key-Anmeldung wird für diesen Pfad nicht akzeptiert. Wer stattdessen das lokale MLX-Modell wählt, behält auch den Text auf dem Gerät.
- Fehlermeldungen werden in ihrer Länge begrenzt und Pfade daraus entfernt, bevor sie in Ausführungsmanifeste gelangen.

## Einschränkungen

- Nur Apple Silicon + macOS 26. Kein Intel, iOS, Windows oder Linux.
- Nur Nachbearbeitung aufgezeichneter Sprache, keine Live-Untertitel. Diese Entscheidung priorisiert bewusst die Qualität.
- Die Qualität bei Sprachmischung ist anhand von Fixtures verifiziert, aber noch nicht durch monatelange echte Meetings.
- Der Codex-Pfad benötigt deine eigene Anmeldung an der Codex CLI und das Kontingent deines Abonnements.
- Die Benutzeroberfläche ist standardmäßig englisch und bietet 10 Lokalisierungen; ko/it-Zeichenketten sind weiterhin zur menschlichen Prüfung markiert.

## Mitwirken

Issues und gezielte Pull Requests sind willkommen. Build- und Testbefehle, der Verifizierungsstandard hinter den Aussagen in dieser README, Commit-Regeln sowie Konventionen für Issues und PRs stehen in [CONTRIBUTING.md](CONTRIBUTING.md).

## Repository-Übersicht

| Pfad | Inhalt |
|---|---|
| `Sources/` | Swift-Paket: Core, Preprocess, ASR, Diarize, Merge, Postprocess, CLI, App |
| `Tests/` | 157 fixturebasierte Tests in 17 Suites |
| `benchmarks/scripts/` | Runner und Scorer mit abgeleiteten Urteilen und Negativtests |
| `docs/` | Forschungsübersicht, Quellcodeprüfungen, Richtlinie für Beschränkungen, Verträge (JSON-Schemas), UI-Design |
| `scripts/` | App-Bundle-Build, MOSS-Harness-Build, Einrichtung der Nachbearbeitungslaufzeit |
| [PROJECT.md](PROJECT.md) | Absichtshierarchie: Grundsätze, Nicht-Ziele, Entscheidungsregeln, ausschließlich ergänztes Entscheidungsprotokoll |
| [AGENTS.md](AGENTS.md) | Arbeitskonventionen für dieses Repository |

Jede Abschlussbehauptung in der Dokumentation enthält den Befehl, der sie hervorgebracht hat, und dessen beobachtete Ausgabe.

## Lizenz und Danksagungen

MIT. Dieses Projekt baut auf [speech-swift](https://github.com/soniqo/speech-swift) (MLX/CoreML-Laufzeitumgebungen für Sprache), den Autorinnen und Autoren der Modelle MOSS, VibeVoice, Silero und pyannote sowie [mlx](https://github.com/ml-explore/mlx) auf. Die Quellcodeprüfung der Referenzprojekte unter `docs/` würdigt die 24 Open-Source-Projekte, deren gute wie schlechte Entwurfsentscheidungen dieses Projekt geprägt haben.
