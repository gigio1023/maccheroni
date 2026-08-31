"""Immutable pins and enumerations for the DiCoW evidence lane.

This module intentionally contains data only.  Runtime code must not substitute a
newer model, revision, executable, or threshold when one of these pins is missing.
"""

from __future__ import annotations


REQUIRED_FRONTIER_FAMILIES = (
    "qwen",
    "vibevoice",
    "voxtral",
    "omnilingual_asr",
    "sam_audio",
    "nemotron",
    "dicow",
    "se_dicow",
    "ps4",
    "dave_tiger_m",
    "mossformer2",
    "cohere_transcribe",
    "glm_asr",
    "mimo",
    "kimi_audio",
    "step_audio",
)

QWEN_BRANCH_KINDS = ("asr", "audio", "omni")
QWEN_SEED_NAMES = (
    "Qwen3-ASR-0.6B",
    "Qwen3-ASR-1.7B",
    "Qwen3-ForcedAligner-0.6B",
    "Qwen3-Omni-30B-A3B-Instruct",
    "Qwen-Audio-3.0-ASR-Flash",
    "Qwen3.5-Omni",
)
QWEN_SEED_STATUSES = ("current", "superseded", "withdrawn", "service_only")

EVIDENCE_OUTCOMES = (
    "supported",
    "not_supported",
    "evidence_blocker",
    "unresolved",
)
BRANCH_VERDICTS = ("proceed", "closeout", "revise", "retarget", "stop")
TASK_STATES = ("pending", "active", "done", "blocked")
BRANCH_DISPOSITIONS = ("executed", "skipped")
MAX_FRONTIER_CAPTURE_AGE_SECONDS = 21_600

MODEL_PINS = {
    "dicow": {
        "model_id": "BUT-FIT/DiCoW_v3_MLC",
        "revision": "99c64e8dc409a158816e808a1ee556cdfd0af51c",
        "model_file": {
            "path": "model.safetensors",
            "bytes": 3_833_628_952,
            "sha256": "bc3ff21a41ebdb9dbe637815740c4edcf77bfbfe962c601ca33071340fd77bd9",
            "tensor_count": 862,
            "parameter_count": 958_382_080,
            "dtype": "float32",
        },
        "license_status": "conflicting_cc_by_4_0_and_apache_2_0_fields",
    },
    "dicow_comparison_source": {
        "repository": "BUTSpeechFIT/DiCoW",
        "revision": "801e2130d00142a7da5845754f87b97550053a75",
    },
    "transformers_comparison": {
        "version": "4.42.0",
        "revision": "6c1d0b069de22d7ed8aa83f733c25045eea0585d",
    },
    "vanilla_control": {
        "model_id": "openai/whisper-large-v3-turbo",
        "revision": "41f01f3fe87f28c78e2fbf8b568835947dd65ed9",
        "license": "MIT",
    },
    "reference_aligner": {
        "model_id": "Qwen/Qwen3-ForcedAligner-0.6B",
        "revision": "c7cbfc2048c462b0d63a45797104fc9db3ad62b7",
        "license": "Apache-2.0",
        "runtime": {"mlx-audio": "0.4.6", "mlx": "0.32.0"},
    },
    "conditional_mlx_source": {
        "repository": "Blaizzy/mlx-audio",
        "revision": "9cef816508e4fbdc35b4011bbfe1fc512b889701",
    },
    "diarizer": {
        "model_id": "aufklarer/Pyannote-Community-1-CoreML",
        "revision": "a14e6c420d56e8472850649b016a486fd0acbe81",
        "license": "CC-BY-4.0",
        "speech_tag_revision": "f9af2f34d196eacca85d13fe508d8ed71919671f",
        "archive": {
            "name": "speech-macos-arm64.tar.gz",
            "bytes": 99_757_415,
            "sha256": "94070b67d2a357332f02f6286f1372279aca5a0173ea84706dba6fbada7b86eb",
        },
    },
    "fleurs": {
        "model_id": "google/fleurs",
        "revision": "70bb2e84b976b7e960aa89f1c648e09c59f894dd",
        "license": "CC-BY-4.0",
    },
    "hike": {
        "model_id": "thetaone-ai/HiKE",
        "revision": "255609b24005e1fcce3f8b3a452260aaf2872cc9",
        "license": "Apache-2.0",
    },
    "shipped_korean": {
        "model_id": "mlx-community/VibeVoice-ASR-8bit",
        "revision": "725c72e54d6ef875472c27fbc50fab470a960940",
    },
    "shipped_italian": {
        "model_id": "aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8",
        "revision": "90aa65287111a327db98eb83e325bd5332945edd",
    },
}

# Shared execution evidence is pinned once per runtime role.  Per-arm records
# consume one of these roles and carry an exact argv plus raw stdout/stderr.
EXECUTION_PROVENANCE_PINS = {
    "dicow": {
        "model_id": MODEL_PINS["dicow"]["model_id"],
        "model_revision": MODEL_PINS["dicow"]["revision"],
        "runner_artifact_key": "run-reference-dicow",
        "lock_path": "benchmarks/env/dicow-reference/uv.lock",
        "lock_artifact_key": "reference-lock",
        "model_asset_key": "DICOW_MODEL_FILE",
    },
    "turbo": {
        "model_id": MODEL_PINS["vanilla_control"]["model_id"],
        "model_revision": MODEL_PINS["vanilla_control"]["revision"],
        "runner_artifact_key": "run-reference-turbo",
        "lock_path": "benchmarks/env/dicow-reference/uv.lock",
        "lock_artifact_key": "reference-lock",
        "model_asset_key": "TURBO_SNAPSHOT",
    },
    "shipped_ko": {
        "model_id": MODEL_PINS["shipped_korean"]["model_id"],
        "model_revision": MODEL_PINS["shipped_korean"]["revision"],
        "runner_artifact_key": "run-shipped-ko",
        "lock_path": "benchmarks/env/dicow-reference/uv.lock",
        "lock_artifact_key": "reference-lock",
        "model_asset_key": "SHIPPED_KO_SNAPSHOT",
    },
    "shipped_it": {
        "model_id": MODEL_PINS["shipped_italian"]["model_id"],
        "model_revision": MODEL_PINS["shipped_italian"]["revision"],
        "runner_artifact_key": "run-shipped-it",
        "lock_path": "benchmarks/env/dicow-reference/uv.lock",
        "lock_artifact_key": "reference-lock",
        "model_asset_key": "SHIPPED_IT_SNAPSHOT",
    },
}

GRAPH_PINS = {
    "d_model": 1280,
    "encoder_blocks": 32,
    "decoder_blocks": 4,
    "mel_bins": 128,
    "encoder_frames": 1500,
    "target_positions": 448,
    "vocabulary": 51_866,
    "fddt_count": 33,
    "fddt_channel_order": ("silence", "target", "non_target", "overlap"),
    "fddt_parameters": 337_920,
    "ctc_tensor_count": 10,
    "ctc_parameters": 82_777_600,
    "model_config_ctc_weight": 0.3,
    "generation_config_ctc_weight": 0.0,
    "ctc_tensor_names": (
        "model.encoder.additional_self_attention_layer.k_proj.weight",
        "model.encoder.additional_self_attention_layer.out_proj.bias",
        "model.encoder.additional_self_attention_layer.out_proj.weight",
        "model.encoder.additional_self_attention_layer.q_proj.bias",
        "model.encoder.additional_self_attention_layer.q_proj.weight",
        "model.encoder.additional_self_attention_layer.v_proj.bias",
        "model.encoder.additional_self_attention_layer.v_proj.weight",
        "model.encoder.lm_head.weight",
        "model.encoder.subsample_conv1.weight",
        "model.encoder.subsample_conv2.weight",
    ),
    "encoder_position_tensor": {
        "source_key": "model.encoder.embed_positions.weight",
        "shape": (1500, 1280),
        "dtype": "float32",
        "bytes": 7_680_000,
        "sha256": "7fcead7802b150ff12af4af39e6f2c472feacebbc40b9b3f38ef5cd85cd2c5d2",
    },
}

EXPERIMENT_PINS = {
    "pack_id": "overlap-pack-v1",
    "window_seconds": 30,
    "audio_samples": 480_000,
    "sample_rate_hz": 16_000,
    "mask_frames": 1_500,
    "mask_rate_hz": 50,
    "decoder_context_tokens": 448,
    "upstream_prompt_cutoff_tokens": 223,
    "bootstrap_seed": 20_260_830,
    "bootstrap_resamples": 10_000,
    "bootstrap_cluster_unit": "constructed_window",
    "bootstrap_strata": ("fixture_family", "language"),
    "concurrent_model_processes": 1,
}

PROMPT_BUDGET_PINS = {
    "context_tokens": 448,
    "generated_p99_method": "nearest_rank",
    "generated_headroom_multiplier": "1.5",
    "terminal_reserve_tokens": 1,
    "pass_order": ("prompt_off_complete", "freeze_budget", "preflight_prompts", "prompt_on"),
    "formula": "448-init_tokens-ceil(1.5*p99_generated_tokens_per_window)-1",
    "overflow_outcome": "not_supported/stop",
    "missing_count_outcome": "evidence_blocker/revise",
}

PHASE_A_THRESHOLDS = {
    "intervals": {
        "bootstrap_resamples": 10_000,
        "bootstrap_seed": 20_260_830,
        "cluster_unit": "constructed_window",
        "strata": ("fixture_family", "language"),
        "confidence": "95_percent_percentile",
    },
    "S0": {"reference_repetitions": 2, "requirement": "bitwise_identical"},
    "S3": {"shipped_korean_overlap_penalty_max": "0.05", "role": "informational"},
    "S4": {
        "stress_mean_D_turbo_O": ">0",
        "stress_lower_bound": ">0",
        "mean_G_oracle_O_min": "0.10",
        "G_oracle_lower_bound": ">0",
        "positive_target_proportion_min": "0.70",
        "P_q_N_point_max": "0.02",
        "P_q_N_one_sided_upper_max": "0.02",
        "target_character_preservation_oracle_point_min": "0.75",
        "target_character_preservation_oracle_lower_min": "0.75",
    },
    "S5": {
        "swap_cer_margin_min": "0.20",
        "swap_target_proportion_min": "0.90",
        "mean_G_community1_O": ">0",
        "G_community1_lower_bound": ">0",
        "half_oracle_margin_mean": ">=0",
        "half_oracle_margin_lower_bound": ">0",
        "spurious_target_empty_proportion_min": "0.80",
        "target_character_preservation_community1_point_min": "0.75",
        "target_character_preservation_community1_lower_min": "0.75",
    },
    "S6": {"dicow_minus_turbo_single_cer_max": "0.02"},
    "S7": {"term_recall_gain_min": "0.10", "absent_term_insertions": 0},
    "S7b": {"term_recall_point_difference": ">=0", "lower_bound": ">-0.02"},
    "S8": {"warm_order_token_ids": "identical"},
    "S9": {
        "dicow_cer_advantage_min": "0.05",
        "shipped_cache_degraded_delta": ">0.10",
    },
    "E3": {"private_overlap_correction_burden_stop_below": "0.05"},
    "resource": {"peak_vs_control_max": "2.0", "rtf_vs_control_max": "1.5"},
}

PHASE_B_THRESHOLDS = {
    "G3": {"dicow_fp32_error_max": "2*E_impl", "bounded_repair_limit": 1},
    "G4": {"dicow_bf16_error_max": "2*E_prec", "miss_outcome": "unresolved"},
    "G5": {
        "mask_sensitivity_ratio_min": "0.5",
        "mask_sensitivity_ratio_max": "2.0",
        "mask_distance_vs_parity_noise_min": "10.0",
        "bounded_repair_limit": 1,
    },
    "G6": {
        "semantic_fields": ("text_tokens", "timestamp_tokens", "segments", "boundaries"),
        "bounded_repair_limit": 1,
    },
    "G7": {"peak_vs_vanilla_max": "2.0"},
    "G8": {"rtf_vs_vanilla_max": "1.5"},
    "G9": {
        "forbidden_runtime_shapes": (
            "cpu_fallback",
            "python_per_frame_hot_loop",
            "ctc_prefix_scoring",
            "new_hand_written_kernel",
        )
    },
    "topology": {"resident_worker_load_ratio_screen": "0.25"},
}

FABLE_COMMAND = (
    "claude",
    "-p",
    "--model",
    "fable",
    "--effort",
    "max",
    "--output-format",
    "json",
)
FABLE_ACTUAL_MODEL = "claude-fable-5"
J1_REQUIRED_INPUT_KEYS = (
    "query_manifest", "frontier_ledger", "source_capture_manifest", "frontier_delta",
    "run_manifest", "plan_contract", "t0_initial_fable_inputs", "t0_state", "t1_state",
    "t1_contract_amendment_1", "t2_state", "t3_state", "t4_state", "t5_state",
    "t6_state", "t7_state", "advisory_ctc_value", "advisory_target_recovery",
    "advisory_qwen3tts_value", "experiment_schema", "gate_schema", "pins", "manifest",
    "test_contract", "conversion_lane", "run_with_env", "test_run_with_env",
    "speaker_attributed", "test_speaker_attributed", "ctc_invariance",
    "test_ctc_invariance", "j1_readiness",
)

J1_STATE_REPO_ARTIFACT_PATHS = {
    "T1-contract-amendment-1": (
        "docs/contracts/dicow-experiment.schema.json",
        "docs/contracts/dicow-gate.schema.json",
        "docs/dicow-conversion-lane.md",
        "benchmarks/scripts/dicow/run_with_env.py",
        "benchmarks/scripts/dicow/common/pins.py",
        "benchmarks/scripts/dicow/common/manifest.py",
        "benchmarks/scripts/dicow/tests/test_run_with_env.py",
        "benchmarks/scripts/dicow/tests/test_contract.py",
        "benchmarks/scripts/dicow/reference/ctc_invariance.py",
        "benchmarks/scripts/dicow/tests/test_ctc_invariance.py",
    ),
    "T2": (
        "benchmarks/env/dicow-aligner/pyproject.toml",
        "benchmarks/env/dicow-aligner/uv.lock",
        "benchmarks/env/dicow-aligner/README.md",
        "benchmarks/env/dicow-reference/pyproject.toml",
        "benchmarks/env/dicow-reference/uv.lock",
        "benchmarks/env/dicow-reference/README.md",
        "benchmarks/scripts/dicow/reference/acquire_source.py",
        "benchmarks/scripts/dicow/tests/test_source_acquisition.py",
    ),
    "T3": ("docs/research-digest.md",),
    "T4": (
        "benchmarks/datasets/overlap-pack-v1.json",
        "benchmarks/datasets/overlap-pack-v1.md",
        "benchmarks/datasets/prepare-overlap-pack-v1.py",
        "benchmarks/datasets/build-overlap-pack-v1.zsh",
        "benchmarks/datasets/verify-overlap-pack-v1.py",
        "benchmarks/datasets/tests/test_overlap_pack.py",
        "benchmarks/scripts/dicow/common/fixtures.py",
        "benchmarks/scripts/dicow/common/stno.py",
        "benchmarks/scripts/dicow/diarizer/community1_reference.py",
        "benchmarks/scripts/dicow/diarizer/deny-network.sb",
        "benchmarks/scripts/dicow/aligner/qwen_reference.py",
        "benchmarks/scripts/dicow/tests/test_stno.py",
        "benchmarks/scripts/dicow/tests/test_community1_reference.py",
        "benchmarks/scripts/dicow/tests/test_reference_aligner.py",
    ),
    "T5": (
        "benchmarks/scripts/scoring/speaker_attributed.py",
        "benchmarks/scripts/scoring/tests/test_speaker_attributed.py",
    ),
    "T6": (
        "benchmarks/scripts/dicow/reference/inspect.py",
        "benchmarks/scripts/dicow/common/preflight.py",
        "benchmarks/scripts/dicow/tests/test_inspect.py",
        "benchmarks/scripts/dicow/tests/test_preflight.py",
    ),
    "T7": (
        "benchmarks/scripts/dicow/reference/zero_cost.py",
        "benchmarks/scripts/dicow/tests/test_zero_cost.py",
    ),
}

# Exact dependency names accepted from every state that participates in J1.
# Values are authenticated separately; closing the key set prevents a state
# from smuggling an unreviewed dependency into the readiness decision.
J1_STATE_SOURCE_KEYS = {
    "T0": (
        "PROJECT.md", "docs/dicow-conversion-lane.md", "docs/research-digest.md",
        "host_hf", "plan_contract", "scoring_uv_lock",
    ),
    "T1": ("J0_gate", "T0_state", "plan_contract", "run_manifest", "scoring_uv_lock"),
    "T1-contract-amendment-1": (
        "T1_state", "plan_contract", "run_manifest", "advisory_ctc_value",
        "advisory_target_recovery", "advisory_qwen3tts_value",
    ),
    "T2": (
        "T1_state", "aligner_uv_lock", "plan_contract", "reference_uv_lock",
        "run_manifest", "source_manifest",
    ),
    "T3": ("T1_state", "docs/research-digest.md", "plan_contract"),
    "T4": ("T1_contract_amendment_1", "T2_state"),
    "T5": ("T1_contract_amendment_1",),
    "T6": ("T1_contract_amendment_1", "T2_state"),
    "T7": ("T1_contract_amendment_1",),
}

TRACKED_FILE_PREDECESSORS = {
    "PROJECT.md": ("T30",),
    "docs/research-digest.md": ("T3", "T30"),
    "docs/dicow-conversion-lane.md": ("T1", "T1-contract-amendment-1", "T16", "T30"),
}
TASK_TRACKED_FILES = {
    "T1": ("docs/dicow-conversion-lane.md",),
    "T1-contract-amendment-1": ("docs/dicow-conversion-lane.md",),
    "T3": ("docs/research-digest.md",),
    "T16": ("docs/dicow-conversion-lane.md",),
    "T30": (
        "PROJECT.md",
        "docs/research-digest.md",
        "docs/dicow-conversion-lane.md",
    ),
}

# r2 is a delta over the authenticated r1 machinery.  These values describe only
# decisions that r1 did not encode; they deliberately do not duplicate the r1 gate
# thresholds above.  In particular, 0.05 remains meaningful for S3/S9/E3 but is not
# a candidate-selection margin.
R2_TASK_DEPENDENCIES = {
    "R0": (),
    "R1": ("R0",),
    "R2": ("R0", "R1"),
    "R3": ("R1", "R2"),
    "R4": ("R3",),
    "R5": ("R4",),
    "Q1": ("R4",),
    "R6": ("R4",),
    "R7": ("R5", "R6"),
    "R8": ("R7",),
    "R9": ("R8",),
    "R10": ("R8", "R9"),
    "Q2": ("Q1", "R4"),
    "R11": ("R10",),
    "R12": ("R11",),
    "R13": ("Q2", "R12"),
}
R2_TASK_IDS = tuple(R2_TASK_DEPENDENCIES)
R2_GATE_TASK_SEMANTICS = {
    ("J1-r2", "proceed_dicow_and_qwen"): {
        "next": ("R5", "Q1", "R6"), "skip": (),
    },
    ("J1-r2", "proceed_qwen_only"): {
        "next": ("Q1",),
        "skip": ("R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12"),
    },
    ("J1-r2", "revise_or_stop_all"): {
        "next": ("R13",),
        "skip": ("R5", "Q1", "R6", "R7", "R8", "R9", "R10", "Q2", "R11", "R12"),
    },
    ("J2-r2", "select_none"): {"next": ("R13",), "skip": ("R11", "R12")},
    ("J2-r2", "select_dicow_mlc"): {"next": ("R11",), "skip": ()},
    ("J2-r2", "select_dicow_v3_3"): {"next": ("R11",), "skip": ()},
    ("J2-r2", "underpowered_keep_mlc"): {"next": ("R11",), "skip": ()},
    ("J2-r2", "retarget"): {"next": ("R13",), "skip": ("R11", "R12")},
    ("FINAL-r2", "final_review"): {"next": (), "skip": ()},
}
R2_TRACKED_FILES = (
    "docs/contracts/dicow-experiment.schema.json",
    "docs/contracts/dicow-gate.schema.json",
    "docs/dicow-conversion-lane.md",
    "benchmarks/scripts/dicow/common/pins.py",
    "benchmarks/scripts/dicow/common/manifest.py",
    "benchmarks/scripts/dicow/run_with_env.py",
    "benchmarks/scripts/dicow/tests/test_contract.py",
    "benchmarks/scripts/dicow/tests/test_run_with_env.py",
)
R2_TASK_TRACKED_FILES = {
    "R1": R2_TRACKED_FILES,
    "R1-contract-amendment-1": R2_TRACKED_FILES,
    "R1-contract-amendment-2": R2_TRACKED_FILES,
    "R1-contract-amendment-3": R2_TRACKED_FILES,
    "R1-contract-amendment-4": R2_TRACKED_FILES,
    "R1-contract-amendment-5": R2_TRACKED_FILES,
    "R1-contract-amendment-6": R2_TRACKED_FILES,
    "R1-contract-amendment-7": R2_TRACKED_FILES,
    "R1-contract-amendment-8": R2_TRACKED_FILES,
    "R1-contract-amendment-9": R2_TRACKED_FILES,
    "R1-contract-amendment-10": R2_TRACKED_FILES,
    "R3": (
        "benchmarks/scripts/dicow/common/preflight.py",
        "benchmarks/scripts/dicow/reference/inspect.py",
        "benchmarks/scripts/dicow/tests/test_inspect.py",
        "benchmarks/scripts/dicow/tests/test_preflight.py",
    ),
    "R10": ("docs/dicow-conversion-lane.md",),
    "R13": ("docs/dicow-conversion-lane.md", "docs/research-digest.md"),
}
R2_R3_FIXED_SOURCE_PATHS = {
    "frontier_rights_checksums": "frontier-rights-j0/SHA256SUMS",
    "r3_source_acquisition_checksums": "r3-source-acquisition.staging/SHA256SUMS",
    "r3_safetensors_headers_checksums": "r3-safetensors-headers.staging/SHA256SUMS",
    "r3_fleurs_timestamp_checksums": "r3-fleurs-timestamp.staging/SHA256SUMS",
    "r3_hike_terms_v2_checksums": "r3-hike-terms-v2.staging/SHA256SUMS",
    "r3_runtime_checksums": "r3-runtime.staging/SHA256SUMS",
    "qwen_q1_design_v2_checksums": "qwen-q1-design-v2.staging/SHA256SUMS",
    "r3_audit_spec_v2": "r3-audit-spec-v2.staging/spec.json",
}
R2_R3_SOURCE_INPUT_KEYS = (
    "plan_contract", "run_manifest", "R1_effective_state", "R2_state",
    *R2_R3_FIXED_SOURCE_PATHS,
    "pre_model_audit_manifest",
)
R2_R3_SEALED_FRAGMENT_KEYS = ("R3-runtimes.env",)
R2_R3_SEALED_PATH_KINDS = {
    "DICOW_R2_ALIGNER_VENV": "venv",
    "DICOW_R2_REFERENCE_VENV": "venv",
    "DICOW_R2_SPEECH_BIN": "file",
}
R2_CANDIDATES = ("dicow_mlc", "dicow_v3_3")
R2_REPETITIONS = (1, 2)
R2_ABSOLUTE_FAILURE_TYPES = (
    "not_supported_point",
    "not_supported_lb_only",
)
R2_SELECTION_OUTCOMES = (
    "select_mlc_only_passer",
    "select_v3_3_only_passer",
    "select_v3_3_strict_dominance",
    "select_mlc_exact_observed_tie",
    "select_mlc_underpowered_no_decision",
    "select_none_absolute_failure",
    "select_mlc_v3_3_excluded",
)
R2_QWEN_COMPONENTS = ("asr_adapter", "aligner")
R2_QWEN_COMPONENT_STATES = (
    "implementation_ready",
    "conversion_not_supported",
    "evidence_blocker",
)
R2_QWEN_FINAL_OUTCOMES = (
    "D37_evidence_ready",
    "D37_not_met",
    "evidence_blocker",
)
R2_RIGHTS_ACTIONS = (
    "private_reference_evaluation",
    "private_local_derivative",
    "converter_code_publication",
    "weight_publication",
    "generated_audio",
)
R2_RIGHTS_STATES = ("allowed", "forbidden", "unresolved", "not_applicable")
R2_RESOURCE_WRITERS = (
    "turbo_source_acquisition",
    "dicow_mlc_source_acquisition",
    "dicow_v3_3_source_acquisition",
    "qwen_asr_official_source_acquisition",
    "qwen_asr_reuse_materialization",
    "qwen_asr_fallback_conversion",
    "qwen_aligner_source_acquisition",
    "qwen_aligner_bf16_conversion",
    "r11_receipts",
    "dicow_mlx",
    "golden_serializer",
)
R2_RESOURCE_FIELDS = (
    "volume",
    "free_bytes",
    "staging_bytes",
    "final_bytes",
    "retained_failure_bytes",
    "retry_bytes",
    "serializer_bytes",
    "simultaneously_retained_prior_outputs",
    "headroom_bytes",
    "required_free_bytes",
    "peak_resident_bytes",
    "concurrent_model_processes",
    "duration_seconds",
    "context_tokens",
    "requested_output_tokens",
    "effective_output_tokens",
    "prompt_tokens",
    "timeout_seconds",
    "maximum_attempts",
    "cancellation_contract",
)
R2_CTC_PROCESS_ROLES = ("baseline_a", "baseline_b", "zeroed", "shuffled", "bypass")
R2_CTC_DECISIONS = (
    "omit_proved_invariant_no_dataflow",
    "preserve_incomplete_invariance_no_dataflow",
    "retarget_token_change_or_decoder_dataflow",
)
R2_FABLE_CONTEXT_TOKENS = 1_000_000
R2_FABLE_USABLE_INPUT_TOKENS = 996_678
R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS = R2_FABLE_USABLE_INPUT_TOKENS - 1
R2_FABLE_ALLOWED_TERMINAL_REASON = "completed"
R2_J1_CLAUDE_CLI = "claude"
R2_J1_PACKET_MAX_UTF8_BYTES = 24_576
R2_J1_OPERATIONAL_MAX_ESTIMATED_INPUT_TOKENS = 32_768
R2_J1_ESTIMATOR_OVERHEAD = 4_096
R2_J1_REFRESH_MAX_AGE_SECONDS = 21_600
R2_J1_QWEN_CLAIM_CEILING = (
    "HiKE and FLEURS evidence may support transport, implementation, and parity "
    "diagnosis only; it may not support Qwen product-quality promotion until "
    "training-data exclusion is proven."
)
R2_J1_FORBIDDEN_PRE_VERDICT_OUTPUTS = (
    "dicow_probe",
    "server_or_persistent_worker",
    "shipped_baseline_restoration",
)
R2_J1_REVERSAL_CONDITION = (
    "Reopen the DiCoW branch only in a successor plan after a public natural "
    "Korean evaluation stratum is proven leakage-safe for both "
    "BUT-FIT/DiCoW_v3_MLC@99c64e8dc409a158816e808a1ee556cdfd0af51c and "
    "BUT-FIT/DiCoW_v3_3@c34b64d9a9c5148c65fd355bb188d60343a6b44f under "
    "the frozen corpus-and-alias exclusion rule; then run the predeclared cheap "
    "upstream-only MLC-versus-c34 probe before any DiCoW MLX conversion."
)
R2_J1_GATE_PATH = "fable-j1/gate.json"
R2_J2_GATE_PATH = "fable-j2/gate.json"
R2_FINAL_GATE_PATH = "fable-final/gate.json"
R2_J1_REFRESH_PATHS = {
    "r4_refresh_checksums": "r4-frontier-refresh.staging/SHA256SUMS",
    "r4_capture_manifest": "r4-frontier-refresh.staging/capture-manifest.json",
    "r4_frontier_delta": "r4-frontier-refresh.staging/frontier-delta.json",
    "r4_synthesis": "r4-frontier-refresh.staging/synthesis.md",
    "r4_qwen_rights_identity": (
        "r4-frontier-refresh.staging/qwen-rights-and-identity.json"
    ),
    "r4_roster": "r4-frontier-refresh.staging/roster.json",
    "r4_three_axis": "r4-frontier-refresh.staging/three-axis-candidates.json",
    "r4_verify_output": "r4-frontier-refresh.staging/verify-output.txt",
}
R2_J1_ADVISORY_PATH = (
    "fable-checkpoints/20260831T0457-r3-repair-value-boundary.md"
)
R2_MODEL_PINS = {
    "turbo": {
        "model_id": MODEL_PINS["vanilla_control"]["model_id"],
        "revision": MODEL_PINS["vanilla_control"]["revision"],
    },
    "dicow_mlc": {
        "model_id": MODEL_PINS["dicow"]["model_id"],
        "revision": MODEL_PINS["dicow"]["revision"],
    },
    "dicow_v3_3": {
        "model_id": "BUT-FIT/DiCoW_v3_3",
        "revision_authority": "R3_candidate_source_tuple",
    },
    "qwen_asr": {
        "model_id": "Qwen/Qwen3-ASR-1.7B-hf",
        "revision": "bcd2b5b7f32b480ab5790554cfa8347f246a14f3",
        "weights_lfs_sha256": "2db53c7d81bd9b8cbc6a074e89be2c968a0d373fb4ee68bb1b1e14f7042dfee1",
    },
    "qwen_aligner": {
        "model_id": "Qwen/Qwen3-ForcedAligner-0.6B-hf",
        "revision": "c07281df297b9905d24a508279258cccf987a064",
        "weights_lfs_sha256": "00568245ceca5af1991d28562a75fe1ddc9bfeb041c27fda66947ea05c47fb86",
    },
}
