<p align="center">
  <img src="docs/assets/banner.png" alt="Maccheroni : une forme d’onde entremêlée de macaronis, traversée par deux lignes de locuteurs" width="100%">
</p>

<h1 align="center">Maccheroni</h1>

<p align="center">
  Transcription locale des conversations multilingues sur Apple Silicon.<br>
  Injection du glossaire au décodage · diarisation des locuteurs sur le fichier entier · l’audio ne quitte jamais votre Mac.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%20(arm64)-black" alt="plateforme">
  <img src="https://img.shields.io/badge/swift-6-F05138" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="licence">
</p>

<p align="center"><a href="https://gigio1023.github.io/maccheroni/">Research journal (English)</a></p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <b>Français</b> · <a href="README.it.md">Italiano</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.pt.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.zh-Hans.md">简体中文</a>
</p>

---

**Maccheroni** (de *macaronic speech*, des énoncés qui mélangent les langues) transcrit les conversations les plus difficiles à transcrire correctement : réunions en coréen où chaque phrase contient des noms de produits anglais, cours de langue, appels multilingues. La transcription audio et la diarisation s’exécutent localement avec des modèles MLX/CoreML épinglés ; le post-traitement Codex facultatif n’envoie que du texte et peut s’exécuter à distance.

Voici à quoi ressemble un export (exemple illustratif, et non sortie d’un modèle) :

```markdown
**Intervenant 1** [00:04] Les smoke tests sont bien passés sur staging avant le merge de la PR ?
**Intervenant 2** [00:09] Oui, et le rollout Kubernetes s’est déroulé sans problème. [UNCERTAIN] Il reste
                          quand même un pic sur le graphique de [CONFLICT: latence|la danse]
                          dans le dashboard.
**Intervenant 1** [00:17] D’accord, on garde donc la fenêtre de release prévue.
```

Les corrections incertaines sont signalées, jamais remplacées en silence. Les étiquettes de locuteur proviennent d’une unique passe de diarisation sur le fichier entier, ce qui les maintient cohérentes sur un enregistrement de deux heures.

<p align="center">
  <img src="docs/assets/screenshots/transcript.png" alt="Vue de transcription de Maccheroni : deux locuteurs avec des étiquettes globales et des puces d'évidence par segment, à côté d'un inspecteur affichant l'état de l'exécution, les révisions épinglées des modèles et l'enregistrement du glossaire" width="100%">
</p>
<p align="center"><em>Chaque exécution conserve ses preuves : l'inspecteur affiche les modèles épinglés exacts, l'état de l'exécution et si le glossaire a atteint le décodeur. La couche affichée — brute, corrigée ou traduite — se copie dans le presse-papiers avec un en-tête de provenance.</em></p>

## Pourquoi ce projet existe

Maccheroni est un outil personnel : un établi configurable qui transforme, sur un seul Mac, des conversations mêlant plusieurs langues en comptes rendus attribués aux locuteurs. La personne qui l’utilise le règle selon ses besoins plutôt qu’en fonction d’un marché.

- **Les profils composent la configuration de chaque conversation.** Chaque profil associe un modèle ASR épinglé exécuté sur l’appareil au contexte du glossaire et à la gestion des locuteurs sur l’ensemble du fichier, choisis en fonction des caractéristiques sonores réelles de la conversation. Une réunion en coréen riche en noms de produits anglais demande des choix différents d’un dialogue italien à deux locuteurs.
- **Les associations sont mesurées, pas supposées.** Les fixtures publiques et synthétiques, le rappel des termes et les taux d’erreur se trouvent dans ce dépôt. Changer de modèle ou de glossaire devient ainsi une comparaison que l’on peut relancer, pas une intuition.
- **Chaque exécution conserve ses preuves.** Les révisions épinglées des modèles, le registre de transmission du glossaire, les transcriptions brutes, la chronologie des locuteurs et les échecs typés sont scellés dans l’exécution. Le résultat peut ainsi être inspecté et reproduit plus tard.

Les notes au niveau du code source qui ont guidé ces choix se trouvent dans [docs/reference-project-source-audit.md](docs/reference-project-source-audit.md).

## Ce qui le distingue

1. **Glossaire injecté au décodage.** Les noms et les termes techniques entrent dans le contexte du modèle avant le décodage, car une erreur ASR détruit la preuve acoustique au moment où elle survient. Le post-traitement peut améliorer le texte, mais il ne peut pas récupérer ce que le décodeur n’a jamais écrit. La charge utile du glossaire de chaque feuille est scellée par hachage dans le manifeste d’exécution.
2. **Une seule passe de diarisation fait autorité sur les locuteurs.** Le fichier entier est soumis une fois à la diarisation et cette chronologie constitue l’unique référence pour les locuteurs. L’ASR traite des fragments de taille limitée, puis les fusionne selon leurs horodatages : une estimation locale à un fragment ne peut jamais inverser une étiquette à une frontière.
3. **Aucune perte de données silencieuse.** Une entrée qui dépasse la limite d’un backend échoue explicitement ou produit un plan de découpage. Une sortie de modèle tronquée constitue un échec typé (`invalid_eos_output`), pas une transcription raccourcie. Les originaux et les transcriptions brutes restent immuables ; les corrections et traductions forment des artefacts distincts créés une seule fois.

## Fonctionnement

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/pipeline-dark.drawio.svg">
  <img src="docs/assets/pipeline-light.drawio.svg" alt="Diagramme du pipeline : sur le Mac, la capture alimente la diarisation du fichier entier et les feuilles ASR de 120 secondes avec injection du glossaire par feuille ; la fusion par horodatage, où la timeline décide des locuteurs, alimente le post-traitement optionnel sur l'appareil ; la seule chose qui quitte le Mac est la voie opt-in de post-traitement distant vers un fournisseur externe via la connexion Codex, texte uniquement" width="100%">
</picture>

Les feuilles en échec sont redécoupées dans des limites typées (minimum de 30 s, profondeur 3), et seules les sorties terminées par un marqueur de fin de séquence sont intégrées à la transcription canonique. Le chemin Codex facultatif envoie, par votre propre abonnement ChatGPT/Codex, des blocs limités de texte transcrit, le glossaire actif et des instructions, jamais l’audio ni les chemins de fichiers. La correction traite le glossaire comme un contexte d’appui : un terme n’est substitué que là où le segment le contient plausiblement, et toute réparation incertaine est signalée pour relecture au lieu d’être appliquée.

## Modèles

Les identités des modèles et services du produit sont consignées dans chaque manifeste d’exécution. Les modèles téléchargeables sont épinglés par identifiant Hugging Face, révision et quantification.

| Rôle | Modèle | Révision | Quantification |
|---|---|---|---|
| ASR (italien / mixte) | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | `90aa6528` | int8-decoder + fp16-audio-vq-kv |
| ASR (coréen) | `mlx-community/VibeVoice-ASR-8bit` | `725c72e5` | int8 |
| VAD | `aufklarer/Silero-VAD-v6.2.1-CoreML` | `52387654` | coreml-float16 |
| Diarisation | `aufklarer/Pyannote-Community-1-CoreML` | `a14e6c42` | coreml-fp32 |
| Post-traitement (local) | `mlx-community/gemma-4-12B-it-qat-4bit` | `e70c6b3b` | qat-int4 (mlx-vlm 0.6.6) |
| Post-traitement (distant, texte uniquement) | `gpt-5.6-sol` via le serveur d’application Codex | gérée par le service | s.o. |

Qwen3 ASR/ForcedAligner et DiCoW sont des candidats de recherche. La compatibilité avec les environnements d’exécution Apple, la parité de conversion et les gains de qualité pour le produit restent à établir.

## Résultats mesurés

Tous les résultats proviennent de jeux de test publics ou synthétiques ; les identifiants d’évaluation et les empreintes des artefacts sont consignés dans [docs/](docs/).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/benchmarks-dark.svg">
  <img src="docs/assets/benchmarks-light.svg" alt="Diagrammes en barres : CER et WER par jeu de test (dialogue coréen 0.081/0.141, deux locuteurs italiens 0.033/0.085), rappel des termes du glossaire (0.95 et 0.778 par rapport au seuil de 0.75) et taux d'erreur de diarisation (0.048 synthétique, 0.152 VoxConverse)" width="100%">
</picture>

| Jeu de test | Modèle | CER | WER | Rappel des termes | Omissions | DER |
|---|---|---:|---:|---:|---:|---:|
| Dialogue coréen, glossaire de 20 termes | VibeVoice | 0.081 | 0.141 | 0.95 | 0 | — |
| Synthèse italienne à 2 locuteurs (10 min), glossaire de 9 termes | MOSS | 0.033 | 0.085 | 0.78 | 0 | 0.048 |
| Échantillon VoxConverse (78 min) | VibeVoice + Pyannote | — | — | — | — | 0.152 |

Le coréen et l’italien sont les deux premiers profils de langue. HiKE, FLEURS et AMI sont des fixtures de recherche réservées aux contrôles de transport, de notation et de parité de conversion. Elles ne peuvent pas justifier la promotion d’un modèle sans prouver d’abord leur absence de ses données d’entraînement et mesurer séparément la parole superposée.

Stabilité des locuteurs aux frontières des fragments sur l’échantillon de 78 minutes : 1.0 pour les deux locuteurs de référence. Une matrice fixe de 600 secondes a montré que les feuilles MOSS de plus de 120 s perdent entièrement la structure des horodatages. C’est pourquoi la limite de production est fixée à 120 s ; les détails figurent dans [docs/moss-long-audio-verdict.md](docs/moss-long-audio-verdict.md).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/leaf-cap-dark.svg">
  <img src="docs/assets/leaf-cap-light.svg" alt="Diagramme en barres : sur la même entrée de 600 secondes, les feuilles de 120 s produisent 5 feuilles canoniques avec fin de séquence (réussite), celles de 240 et 300 s produisent 0 feuille valide (échecs typés invalid_eos_output), et la récupération forcée depuis des parents de 240 s produit 5 enfants valides de 120 s" width="100%">
</picture>

Les gains de la correction sont mesurés par un banc à quatre états qui compare la sortie brute et corrigée à une même référence, avec et sans glossaire au décodage, et compte chaque changement qui éloigne un segment de celle-ci. `maccheroni postprocess` et l’application peuvent dériver de nouveaux ensembles de correction ou de traduction à partir des segments scellés sans réexécuter l’ASR ; chaque enregistrement du glossaire conserve une révision adressée par contenu afin de réutiliser les octets exacts consignés par l’exécution d’origine.

## Installation

Il n’existe pas encore de version empaquetée : compilez depuis les sources.

Prérequis : Mac Apple Silicon, macOS 26, Xcode 26, [uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/gigio1023/maccheroni.git
cd maccheroni
swift build && swift test
zsh scripts/build-app.zsh          # builds and codesigns Maccheroni.app
```

La suite par défaut `swift test` utilise des fixtures incluses ou générées. Elle n’accède ni au cache de modèles d’un utilisateur, ni à des exécutions de benchmark externes, ni à un environnement Python de modèles préparé par l’utilisateur, et n’exécute aucune inférence réelle. Le script de provisionnement installe l’environnement `ko-meeting` entièrement épinglé, avec VibeVoice ASR, Silero VAD et la diarisation Community-1. Il télécharge aussi les fichiers du tokenizer `Qwen/Qwen2.5-7B` dont VibeVoice dépend indirectement ; ce chemin n’utilise aucun poids d’inférence Qwen.

Provisionnez le cache épinglé et exécutez explicitement l’intégration des modèles comme suit :

```bash
cache_root="${MACCHERONI_BENCHMARK_CACHE:-$HOME/Library/Caches/Maccheroni/benchmarks}"
MACCHERONI_BENCHMARK_CACHE="$cache_root" zsh scripts/setup-transcription-runtime.zsh --profile ko-meeting
MACCHERONI_RUN_MODEL_INTEGRATION=1 MACCHERONI_BENCHMARK_CACHE="$cache_root" MACCHERONI_HF_HOME="$cache_root/models/huggingface" swift test --filter MaccheroniModelIntegrationTests
```

La suite activée explicitement vérifie uniquement VibeVoice, Silero et Community-1. Si des prérequis épinglés manquent ou sont incomplets, elle échoue avant le lancement d’un backend avec une erreur de prérequis claire.

L’application affiche le chemin de son bundle lorsque la compilation, l’inventaire des ressources autorisées et les contrôles stricts de signature du code réussissent. L’exécutable n’inclut ni poids de modèles ni environnements Python, mais inclut les définitions des profils `ko-meeting` et `it-dialogue`.

L’exécutable propose ces commandes du produit :

```bash
.build/debug/maccheroni help [help|run|postprocess|doctor|capabilities]
.build/debug/maccheroni run recording.wav --profile it-dialogue
.build/debug/maccheroni postprocess Runs/meeting --profile ko-meeting
.build/debug/maccheroni doctor [--profile NAME] [--profiles PATH] [--json]
.build/debug/maccheroni capabilities [--json]
```

Utilisez `maccheroni help`, `maccheroni doctor --json` et `maccheroni capabilities --json` pour consulter l’aide et obtenir une sortie structurée. Le [guide CLI](docs/cli-guide.md) concis décrit les contrats des commandes et des sorties. La transcription et la séparation des locuteurs s’exécutent sur ce Mac, donc l’audio reste local.

Pour le modèle facultatif de post-traitement local, exécutez `zsh scripts/setup-postprocess-runtime.zsh`.

## Confidentialité

<p align="center">
  <img src="docs/assets/screenshots/capture.png" alt="Vue de capture de Maccheroni : sélecteur de profil avec métriques mesurées, choix de post-traitement entre Codex, Local et None, et l'avis que l'audio ne quitte jamais ce Mac" width="100%">
</p>

- La transcription, la VAD et la diarisation s’exécutent entièrement en local. Les octets audio n’empruntent jamais de chemin réseau ; des tests l’imposent, pas une simple règle.
- Le chemin facultatif de post-traitement Codex n’envoie que du texte et nécessite une activation pour chaque exécution. Il ouvre une session `codex app-server` à un seul tour avec la connexion d’abonnement ChatGPT enregistrée. Le fil est éphémère et en lecture seule, les serveurs MCP et les outils facultatifs sont désactivés et les demandes d’approbation sont refusées. Le prompt contient le texte des segments, le glossaire actif et des instructions. Ce chemin n’accepte pas l’authentification par clé API. Choisir le modèle MLX local conserve même le texte sur l’appareil.
- Les messages d’échec du chemin Codex sont limités en longueur et leurs chemins sont masqués avant leur inscription dans les manifestes d’exécution.

## Limites

- Apple Silicon + macOS 26 uniquement. Pas d’Intel, d’iOS, de Windows ni de Linux.
- Traitement après transcription uniquement : aucun sous-titrage en direct, choix délibéré qui privilégie la qualité.
- La qualité multilingue est vérifiée sur des jeux de test, pas encore sur plusieurs mois de réunions réelles.
- Le chemin Codex requiert votre propre connexion à Codex CLI et le quota de votre abonnement.
- L’interface est en anglais par défaut avec 10 localisations ; les chaînes ko/it restent signalées pour une révision humaine.

## Contribuer

Les signalements de problèmes et les pull requests ciblées sont les bienvenus. Les commandes de compilation et de test, la norme de vérification qui sous-tend les affirmations de ce README, les règles de commit et les conventions applicables aux issues et aux PR figurent dans [CONTRIBUTING.md](CONTRIBUTING.md).

## Structure du dépôt

| Chemin | Contenu |
|---|---|
| `Sources/` | Package Swift : Core, Preprocess, ASR, Diarize, Merge, Postprocess, CLI, App |
| `Tests/` | Tests fondés sur des fixtures |
| `benchmarks/scripts/` | Outils d’exécution et de notation et le banc de comparaison des chemins de correction, avec verdicts dérivés et tests négatifs |
| `docs/` | Synthèse de recherche, audits des sources, politique de contraintes, contrats (schémas JSON), conception de l’interface |
| `scripts/` | Compilation du bundle de l’application, configuration des environnements de transcription et de post-traitement, compilation des bancs de benchmark |
| [PROJECT.md](PROJECT.md) | Hiérarchie d’intention : piliers, non-objectifs, règles de décision et journal de décisions en ajout seul |
| [AGENTS.md](AGENTS.md) | Conventions de travail de ce dépôt |

Chaque affirmation d’achèvement dans les documents comporte la commande qui l’a produite et sa sortie observée.

## Licence et remerciements

MIT. Ce projet s’appuie sur [speech-swift](https://github.com/soniqo/speech-swift) (environnements d’exécution vocaux MLX/CoreML), les auteurs des modèles MOSS, VibeVoice, Silero et pyannote, ainsi que [mlx](https://github.com/ml-explore/mlx). L’audit du code source des projets de référence dans `docs/` cite les projets open source dont les choix de conception, bons comme mauvais, ont façonné celui-ci.
