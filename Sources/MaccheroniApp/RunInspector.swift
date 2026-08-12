import MaccheroniCore
import SwiftUI

struct RunInspector: View {
    let record: LibraryRecord
    let run: LoadedRun

    var body: some View {
        Form {
            Section(run.resultOperation == nil
                ? appLocalized("Run")
                : appLocalized("Source Run"))
            {
                LabeledContent(appLocalized("Run ID"), value: run.manifest.runID)
                LabeledContent(appLocalized("Status"), value: run.manifest.status.rawValue)
                LabeledContent(appLocalized("Wall Time")) {
                    Text(Duration.seconds(run.manifest.timing.wallTimeS), format: .time(pattern: .hourMinuteSecond))
                        .monospacedDigit()
                }
                LabeledContent(appLocalized("Pipeline")) {
                    Text("\(run.manifest.backend.name) \(run.manifest.backend.version)")
                }
                LabeledContent(appLocalized("Profile")) {
                    Text(record.profileID.title)
                }
                LabeledContent(appLocalized("Post-processing")) {
                    Text(record.postprocess.title)
                }
            }

            if let operation = run.resultOperation {
                Section(appLocalized("Current Derived Result")) {
                    LabeledContent(appLocalized("Run ID"), value: run.effectiveResultID)
                    LabeledContent(appLocalized("Profile"), value: operation.profileName)
                    LabeledContent(appLocalized("Operation")) {
                        Text(PostprocessOperationChoice(operation.mode).title)
                    }
                    if let target = operation.targetLanguage {
                        LabeledContent(appLocalized("Target Language")) {
                            if let language = AppLanguage(rawValue: target) {
                                Text(language.title)
                            } else {
                                Text(verbatim: target)
                            }
                        }
                    }
                    LabeledContent(appLocalized("Glossary Semantics")) {
                        Text(verbatim: operation.glossarySemantics.rawValue)
                    }
                    LabeledContent(appLocalized("Provided")) {
                        Text(operation.glossarySHA256 == nil
                            ? appLocalized("No")
                            : appLocalized("Yes"))
                    }
                    LabeledContent(
                        appLocalized("Items"),
                        value: operation.glossaryItemCount.formatted()
                    )
                    if let hash = operation.glossarySHA256 {
                        LabeledContent(appLocalized("SHA-256")) {
                            Text(hash)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let postprocess = run.effectivePostprocess {
                PostprocessInspectorSection(
                    title: run.resultOperation == nil
                        ? appLocalized("Post-processing")
                        : appLocalized("Current Derived Post-processing"),
                    postprocess: postprocess
                )
            }

            if !run.derivedResults.isEmpty {
                Section(appLocalized("Run Output")) {
                    ForEach(run.derivedResults) { result in
                        DerivedResultInspectorRow(result: result)
                    }
                }
            }

            Section(appLocalized("Models")) {
                ForEach(Array(run.manifest.models.enumerated()), id: \.offset) { _, model in
                    ModelInspectorRow(model: model)
                }
            }

            Section(run.resultOperation == nil
                ? appLocalized("Glossary")
                : appLocalized("Source Run Glossary"))
            {
                LabeledContent(appLocalized("Provided")) {
                    Text(run.manifest.glossary.provided ? appLocalized("Yes") : appLocalized("No"))
                }
                LabeledContent(appLocalized("Applied")) {
                    Text(run.manifest.glossary.applied ? appLocalized("Yes") : appLocalized("No"))
                }
                LabeledContent(appLocalized("Injection Mode"), value: run.manifest.glossary.injectionMode.rawValue)
                LabeledContent(appLocalized("Items"), value: run.manifest.glossary.itemCount.formatted())
                if let hash = run.manifest.glossary.sha256 {
                    LabeledContent(appLocalized("SHA-256")) {
                        Text(hash)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            Section(appLocalized("Input Integrity")) {
                LabeledContent(appLocalized("Original File"), value: run.manifest.input.fileName)
                LabeledContent(appLocalized("Size")) {
                    Text(ByteCountFormatStyle(style: .file).format(Int64(run.manifest.input.sizeBytes)))
                }
                LabeledContent(appLocalized("SHA-256")) {
                    Text(run.manifest.input.sha256)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent(appLocalized("Coverage")) {
                    Text(appLocalized("\(run.manifest.coverage.chunksCompleted)/\(run.manifest.coverage.chunksPlanned) chunks"))
                }
                LabeledContent(appLocalized("Truncated")) {
                    Text(run.manifest.coverage.truncated ? appLocalized("Yes") : appLocalized("No"))
                }
            }

            Section(appLocalized("Preprocessing")) {
                LabeledContent(appLocalized("Sample Rate"), value: "\(run.manifest.preprocessing.sampleRateHz) Hz")
                LabeledContent(appLocalized("Channels"), value: run.manifest.preprocessing.channels.formatted())
                LabeledContent(appLocalized("Peak Normalization")) {
                    Text(run.manifest.preprocessing.peakNormalization ? appLocalized("On") : appLocalized("Off"))
                }
                LabeledContent(appLocalized("Voice Activity Detection")) {
                    if let backend = run.manifest.preprocessing.vad.backend {
                        Text(backend)
                    } else {
                        Text(appLocalized("Off"))
                    }
                }
                LabeledContent(appLocalized("Enhancement")) {
                    if let backend = run.manifest.preprocessing.enhancement.backend {
                        Text(backend)
                    } else {
                        Text(appLocalized("Off"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 280, ideal: 330, max: 430)
    }
}

private struct DerivedResultInspectorRow: View {
    let result: DerivedResultSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label {
                    Text(PostprocessOperationChoice(result.operation).title)
                } icon: {
                    Image(systemName: result.isCurrent ? "checkmark.circle.fill" : "circle")
                }
                Spacer()
                Text(result.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: result.id)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            if let targetLanguage = result.targetLanguage {
                if let language = AppLanguage(rawValue: targetLanguage) {
                    Text(language.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: targetLanguage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let hash = result.glossarySHA256 {
                Text(hash)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct PostprocessInspectorSection: View {
    let title: LocalizedStringResource
    let postprocess: ManifestPostprocess

    var body: some View {
        Section(title) {
            LabeledContent(appLocalized("Operation")) {
                Text(PostprocessOperationChoice(postprocess.mode).title)
            }
            if let target = postprocess.targetLanguage {
                LabeledContent(appLocalized("Target Language")) {
                    if let language = AppLanguage(rawValue: target) {
                        Text(language.title)
                    } else {
                        Text(verbatim: target)
                    }
                }
            }
            LabeledContent(appLocalized("Backend")) {
                Text(verbatim: "\(postprocess.backend.name) \(postprocess.backend.version)")
            }
            LabeledContent(appLocalized("Model ID")) {
                Text(postprocess.modelID)
                    .textSelection(.enabled)
            }
            LabeledContent(appLocalized("Input Mode")) {
                switch postprocess.inputMode {
                case .textOnly:
                    Text(appLocalized("Text only"))
                }
            }
            if let batching = postprocess.batching {
                LabeledContent(appLocalized("Prompt Limit")) {
                    Text(appLocalized("\(batching.maximumPromptUTF8Bytes) bytes"))
                        .monospacedDigit()
                }
                LabeledContent(appLocalized("Segments per Batch")) {
                    Text(batching.maximumSegmentsPerBatch.formatted())
                        .monospacedDigit()
                }
                LabeledContent(appLocalized("Output Token Limit")) {
                    if batching.outputTokenLimitStatus == .configured,
                       let tokens = batching.maximumOutputTokens
                    {
                        Text(tokens.formatted())
                            .monospacedDigit()
                    } else {
                        Text(appLocalized("Service-managed (limit unavailable)"))
                    }
                }
                LabeledContent(appLocalized("Output Planning Budget")) {
                    Text(batching.outputTokenPlanningBudget.formatted())
                        .monospacedDigit()
                }
                LabeledContent(appLocalized("Output Estimate Formula")) {
                    Text(verbatim: String(
                        format: "%.3f token/input-byte + %d + %d/segment",
                        Double(batching.outputTokensPerInputUTF8BytePermille) / 1_000,
                        batching.baseOutputTokenReserve,
                        batching.perSegmentOutputTokenReserve
                    ))
                    .monospacedDigit()
                }
                LabeledContent(appLocalized("Batches Planned")) {
                    Text(batching.batchesPlanned.formatted())
                        .monospacedDigit()
                }
                LabeledContent(appLocalized("Largest Batch Input")) {
                    Text(appLocalized("\(batching.maximumObservedInputTextUTF8Bytes) bytes"))
                        .monospacedDigit()
                }
                LabeledContent(appLocalized("Largest Batch Estimate")) {
                    Text(batching.maximumObservedEstimatedOutputTokens.formatted())
                        .monospacedDigit()
                }
                LabeledContent(appLocalized("Largest Raw Response")) {
                    Text(appLocalized("\(batching.maximumObservedResponseUTF8Bytes) bytes"))
                        .monospacedDigit()
                }
                LabeledContent(appLocalized("Largest Accepted Output Bound")) {
                    Text(batching.maximumObservedAcceptedOutputTokenUpperBound.formatted())
                        .monospacedDigit()
                }
            }
            if let hash = postprocess.sourceSegmentsSHA256 {
                LabeledContent(appLocalized("Source Segments SHA-256")) {
                    Text(hash)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct ModelInspectorRow: View {
    let model: ModelDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.role.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.hfModelID)
                .textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text(appLocalized("Revision"))
                        .foregroundStyle(.secondary)
                    Text(model.revision)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                GridRow {
                    Text(appLocalized("Quantization"))
                        .foregroundStyle(.secondary)
                    Text(model.quantization)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 3)
    }
}
