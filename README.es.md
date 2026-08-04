<p align="center">
  <img src="docs/assets/banner.png" alt="Maccheroni: una forma de onda entrelazada con macarrones y dos líneas de hablantes que se entrecruzan" width="100%">
</p>

<h1 align="center">Maccheroni</h1>

<p align="center">
  Transcripción local de conversaciones multilingües en Apple Silicon.<br>
  Inyección de glosario durante la decodificación · diarización de hablantes del archivo completo · el audio nunca sale de tu Mac.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%20(arm64)-black" alt="plataforma">
  <img src="https://img.shields.io/badge/swift-6-F05138" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="licencia">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.de.md">Deutsch</a> · <b>Español</b> · <a href="README.fr.md">Français</a> · <a href="README.it.md">Italiano</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.pt.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.zh-Hans.md">简体中文</a>
</p>

---

**Maccheroni** (de *macaronic speech*, es decir, enunciados que mezclan idiomas) transcribe las conversaciones que muchas aplicaciones interpretan mal sin avisar: reuniones en coreano con nombres de productos en inglés en cada frase, clases de idiomas y llamadas multilingües. Todo se ejecuta en el dispositivo con modelos MLX/CoreML fijados a versiones concretas.

Así se ve una exportación (muestra ilustrativa, no es una salida del modelo):

```markdown
**Hablante 1** [00:04] ¿Pasaron los smoke tests en staging antes de fusionar la PR?
**Hablante 2** [00:09] Sí, y el rollout de Kubernetes salió bien. [UNCERTAIN] Pero
                      todavía hay un pico de [CONFLICT: latencia|la tenencia]
                      en el dashboard.
**Hablante 1** [00:17] Perfecto, entonces mantenemos la ventana de despliegue prevista.
```

Las correcciones dudosas se marcan y nunca se sustituyen de forma silenciosa. Las etiquetas de los hablantes proceden de una única diarización del archivo completo, por lo que se mantienen coherentes durante una grabación de dos horas.

<p align="center">
  <img src="docs/assets/screenshots/transcript.png" alt="Vista de transcripción de Maccheroni: dos hablantes con etiquetas globales y chips de evidencia por segmento, junto a un inspector que muestra el estado de la ejecución, las revisiones fijadas de los modelos y el registro del glosario" width="100%">
</p>
<p align="center"><em>Cada ejecución conserva su evidencia: el inspector muestra los modelos fijados exactos, el estado de la ejecución y si el glosario llegó al decodificador.</em></p>

## Por qué existe

El 2 de agosto de 2026 auditamos a nivel de código fuente siete aplicaciones macOS de transcripción local. Ninguna ofrecía la combinación que necesitan las reuniones realmente multilingües:

- Las aplicaciones con diarización local no entregaban el glosario al modelo ASR: recurrían a sustituciones de cadenas posteriores, parámetros SDK inactivos o diccionarios disponibles solo en la nube.
- La aplicación con el glosario más limpio a nivel de modelo no tenía diarización.
- «Compatibilidad multilingüe» casi siempre significa *un idioma por sesión*, justo lo contrario de una conversación que mezcla idiomas.

Todas las piezas existen en la capa de bibliotecas. La combinación no existía en la capa de aplicación. Este repositorio la construye y conserva la auditoría en [docs/reference-project-source-audit.md](docs/reference-project-source-audit.md).

## Qué lo hace diferente

1. **Glosario durante la decodificación.** Los nombres y los términos técnicos entran en el contexto del modelo antes de decodificar, porque un error de ASR destruye la evidencia acústica en el momento en que ocurre. El posprocesamiento puede pulir el texto, pero no recuperar lo que el decodificador nunca escribió. La carga del glosario de cada segmento final queda sellada mediante hash en el manifiesto de ejecución.
2. **Una sola diarización asigna los hablantes.** El archivo completo se diariza una vez y esa línea temporal es la única autoridad sobre los hablantes. El ASR trabaja con segmentos de tamaño limitado y los une por marca de tiempo: las estimaciones locales de un segmento nunca pueden cambiar una etiqueta al cruzar un límite.
3. **Nunca hay pérdida silenciosa de datos.** Las entradas que superan el límite de un backend fallan de forma explícita o producen un plan de división. Una salida truncada del modelo es un error tipado (`invalid_eos_output`), no una transcripción más corta. Los originales y las transcripciones sin procesar son inmutables; las correcciones y las traducciones son artefactos separados y de solo creación.

## Cómo funciona

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/pipeline-dark.drawio.svg">
  <img src="docs/assets/pipeline-light.drawio.svg" alt="Diagrama del pipeline: en el Mac, la captura alimenta la diarización de archivo completo y los segmentos ASR de 120 segundos con inyección de glosario por segmento; la fusión por marcas de tiempo, donde la línea de tiempo decide los hablantes, alimenta el posprocesamiento opcional en el dispositivo; lo único que sale del Mac es el carril opcional de posprocesamiento remoto hacia un proveedor externo mediante el inicio de sesión de Codex, solo texto" width="100%">
</picture>

Los segmentos fallidos se vuelven a dividir dentro de límites tipados (mínimo 30 s, profundidad 3). Solo se incorporan a la transcripción canónica las salidas con fin de secuencia. La vía opcional de Codex envía, mediante tu propia suscripción de ChatGPT/Codex, texto de la transcripción en bloques limitados, el glosario activo e instrucciones: nunca audio ni rutas de archivos.

## Modelos

Cada modelo se fija mediante ID de Hugging Face + revisión + cuantización y queda registrado en el manifiesto de cada ejecución.

| Función | Modelo | Revisión | Cuantización |
|---|---|---|---|
| ASR (italiano / mixto) | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | `90aa6528` | int8-decoder + fp16-audio-vq-kv |
| ASR (coreano) | `mlx-community/VibeVoice-ASR-8bit` | `725c72e5` | int8 |
| VAD | `aufklarer/Silero-VAD-v6.2.1-CoreML` | `52387654` | coreml-float16 |
| Diarización | `aufklarer/Pyannote-Community-1-CoreML` | `a14e6c42` | coreml-fp32 |
| Posprocesamiento (local) | `mlx-community/gemma-4-12B-it-qat-4bit` | `e70c6b3b` | qat-int4 (mlx-vlm 0.6.6) |
| Posprocesamiento (remoto, solo texto) | `gpt-5.6-sol` mediante el servidor de aplicaciones de Codex | gestionado por el servicio | n/a |

## Resultados medidos

Todos proceden de fixtures públicas o sintéticas. Los ID de evaluación y los hashes de los artefactos están registrados en [docs/](docs/).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/benchmarks-dark.svg">
  <img src="docs/assets/benchmarks-light.svg" alt="Gráficos de barras: CER y WER por fixture (diálogo coreano 0.081/0.128, dos hablantes en italiano 0.033/0.081), recuperación de términos del glosario (0.95 y 0.778 frente al umbral de 0.75) y tasa de error de diarización (0.048 sintético, 0.152 VoxConverse)" width="100%">
</picture>

| Fixture | Modelo | CER | WER | Recuperación de términos | Omisiones | DER |
|---|---|---:|---:|---:|---:|---:|
| Diálogo en coreano, glosario de 20 términos | VibeVoice | 0.081 | 0.128 | 0.95 | 0 | — |
| Conversación sintética en italiano con 2 hablantes (10 min), glosario de 9 términos | MOSS | 0.033 | 0.081 | 0.78 | 0 | 0.048 |
| Muestra de VoxConverse (78 min) | VibeVoice + Pyannote | — | — | — | — | 0.152 |

El coreano y el italiano son los dos primeros perfiles de idioma; nuevos fixtures de idiomas se añaden a esta tabla a medida que se miden.

La estabilidad de los hablantes en los límites de los segmentos de la muestra de 78 minutos fue de 1.0 para ambos hablantes de referencia. Una matriz fija de 600 segundos demostró que los segmentos MOSS de más de 120 s pierden por completo la estructura de marcas de tiempo. Por eso, el límite de producción es de 120 s; los detalles están en [docs/moss-long-audio-verdict.md](docs/moss-long-audio-verdict.md).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/leaf-cap-dark.svg">
  <img src="docs/assets/leaf-cap-light.svg" alt="Gráfico de barras: con la misma entrada de 600 segundos, los segmentos de 120 s producen 5 hojas canónicas con fin de secuencia (aprobado), los de 240 y 300 s producen 0 hojas válidas (fallos tipados invalid_eos_output) y la recuperación forzada desde padres de 240 s produce 5 hijos válidos de 120 s" width="100%">
</picture>

## Instalación

Todavía no hay versiones empaquetadas: debes compilar el proyecto desde el código fuente.

Requisitos: Mac con Apple Silicon, macOS 26, Xcode 26 y [uv](https://docs.astral.sh/uv/).

```bash
git clone https://github.com/gigio1023/maccheroni.git
cd maccheroni
swift build && swift test          # 157 tests
zsh scripts/build-app.zsh          # builds and codesigns Maccheroni.app
```

La aplicación muestra la ruta de su paquete cuando la compilación, el inventario de recursos permitidos y las comprobaciones estrictas de firma de código terminan correctamente. Los pesos de los modelos se descargan con el primer uso. El ejecutable no incluye pesos de modelos ni entornos de Python; `maccheroni doctor` verifica los entornos de ejecución y las instantáneas fijadas.

El ejecutable ofrece cuatro comandos de producto:

```bash
.build/debug/maccheroni help [help|run|doctor|capabilities]
.build/debug/maccheroni run recording.wav --profile it-dialogue
.build/debug/maccheroni doctor [--profile NAME] [--profiles PATH] [--json]
.build/debug/maccheroni capabilities [--json]
```

Usa `maccheroni help`, `maccheroni doctor --json` y `maccheroni capabilities --json` para consultar la ayuda y obtener resultados estructurados. La breve [guía de la CLI](docs/cli-guide.md) describe los contratos de los comandos y la salida. La transcripción y la separación de hablantes se ejecutan en este Mac, por lo que el audio permanece en local.

Se incluyen perfiles para reuniones en coreano (`ko-meeting`, VibeVoice) y diálogos en italiano (`it-dialogue`, MOSS). Para utilizar el modelo local opcional de posprocesamiento, ejecuta `zsh scripts/setup-postprocess-runtime.zsh`.

## Privacidad

<p align="center">
  <img src="docs/assets/screenshots/capture.png" alt="Vista de captura de Maccheroni: selector de perfil con métricas medidas, elección de posprocesamiento entre Codex, Local y None, y el aviso de que el audio nunca sale de este Mac" width="100%">
</p>

- La transcripción, el VAD y la diarización se ejecutan por completo de forma local. Los bytes del audio nunca llegan a una ruta de red: lo garantizan las pruebas, no una mera política.
- La vía opcional de posprocesamiento con Codex solo envía texto y requiere consentimiento en cada ejecución. Abre una sesión de un solo turno con `codex app-server` mediante el inicio de sesión de suscripción de ChatGPT guardado. El hilo es efímero y de solo lectura, las herramientas están desactivadas y se rechazan las solicitudes de aprobación. El prompt contiene el texto de los segmentos, el glosario activo y las instrucciones. Esta vía no acepta autenticación con clave de API. Si eliges el modelo MLX local, incluso el texto permanece en el dispositivo.
- Los mensajes de error se limitan en longitud y se eliminan sus rutas antes de incorporarlos a los manifiestos de ejecución.

## Limitaciones

- Solo Apple Silicon + macOS 26. No funciona en Intel, iOS, Windows ni Linux.
- Solo después de la grabación: no ofrece subtítulos en directo para priorizar deliberadamente la calidad.
- La calidad multilingüe se ha verificado con fixtures, pero todavía no durante meses de reuniones reales.
- La vía Codex requiere tu propio inicio de sesión en la CLI de Codex y cuota de suscripción.
- La interfaz está en inglés de forma predeterminada e incluye 10 localizaciones; las cadenas ko/it siguen marcadas para revisión humana.

## Contribuir

Se aceptan issues y pull requests específicos. Los comandos de compilación y pruebas, el estándar de verificación que respalda las afirmaciones de este README, las reglas para commits y las convenciones para issues y PR se encuentran en [CONTRIBUTING.md](CONTRIBUTING.md).

## Mapa del repositorio

| Ruta | Contenido |
|---|---|
| `Sources/` | Paquete Swift: Core, Preprocess, ASR, Diarize, Merge, Postprocess, CLI, App |
| `Tests/` | 157 pruebas basadas en fixtures en 17 suites |
| `benchmarks/scripts/` | Ejecutores y evaluadores con veredictos derivados y pruebas negativas |
| `docs/` | Resumen de investigación, auditorías de código fuente, política de restricciones, contratos (esquemas JSON), diseño de interfaz |
| `scripts/` | Compilación del paquete de la aplicación, compilación del harness MOSS, configuración del entorno de posprocesamiento |
| [PROJECT.md](PROJECT.md) | Jerarquía de intenciones: pilares, objetivos excluidos, reglas de decisión y registro de decisiones de solo adición |
| [AGENTS.md](AGENTS.md) | Convenciones operativas para trabajar en este repositorio |

Cada afirmación de finalización incluida en los documentos lleva el comando que la produjo y la salida observada.

## Licencia y agradecimientos

MIT. Basado en el trabajo de [speech-swift](https://github.com/soniqo/speech-swift) (entornos de voz MLX/CoreML), los autores de los modelos MOSS, VibeVoice, Silero y pyannote, y [mlx](https://github.com/ml-explore/mlx). La auditoría del código fuente de los proyectos de referencia en `docs/` reconoce los 24 proyectos de código abierto cuyos diseños, tanto los acertados como los fallidos, dieron forma a este proyecto.
