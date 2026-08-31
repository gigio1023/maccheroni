#!/usr/bin/env python3
"""Fail-closed E0 inspection for the pinned DiCoW experiment.

The inspector deliberately does not import checkpoint Python.  Configuration,
Python source, safetensors headers, archives, and prepared manifests are treated
as hostile input and are inspected with standard-library readers.  The two
``prepare-*`` commands create immutable audit trees; ``verify*`` commands are
read-only replays.
"""

from __future__ import annotations

import argparse
import ast
import base64
import csv
import hashlib
import io
import json
import math
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
import unicodedata
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, Mapping, MutableMapping, Optional, Sequence, Tuple

from benchmarks.scripts.dicow.common.pins import (
    GRAPH_PINS,
    MODEL_PINS,
    R2_MODEL_PINS,
    R2_RIGHTS_ACTIONS,
    R2_RIGHTS_STATES,
)
from benchmarks.scripts.dicow.common.preflight import PreflightError


SCHEMA_VERSION = "dicow-e0-inspection-v1"
SOURCE_FILES = (
    "config.json",
    "config.py",
    "decoding.py",
    "encoder.py",
    "generation.py",
    "generation_config.json",
    "modeling_dicow.py",
    "preprocessor_config.json",
    "utils.py",
)
REUSED_MLX_SYMBOLS = (
    "ModelDimensions",
    "MultiHeadAttention",
    "ResidualAttentionBlock",
    "TextDecoder",
)
FORBIDDEN_MLX_REUSE = (
    "Model",
    "sanitize",
    "load_model",
    "decode",
    "generate",
    "log_mel_spectrogram",
    "mel_filters",
)
FLEURS_FILES = {
    "parquet-data/en_us/test-00000-of-00001.parquet": 401_722_686,
    "parquet-data/it_it/test-00000-of-00001.parquet": 806_437_035,
    "parquet-data/ko_kr/test-00000-of-00001.parquet": 291_159_866,
}
DICOW_FILES = (
    ".gitattributes", "README.md", "added_tokens.json", "config.json", "config.py",
    "decoding.py", "encoder.py", "generation.py", "generation_config.json", "merges.txt",
    "model.safetensors", "modeling_dicow.py", "normalizer.json", "preprocessor_config.json",
    "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "utils.py", "vocab.json",
)
VANILLA_FILES = (
    ".gitattributes", "README.md", "added_tokens.json", "config.json", "generation_config.json",
    "merges.txt", "model.safetensors", "normalizer.json", "preprocessor_config.json",
    "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.json",
)
ALIGNER_FILES = (
    ".gitattributes", "README.md", "chat_template.json", "config.json", "generation_config.json",
    "merges.txt", "model.safetensors", "preprocessor_config.json", "tokenizer_config.json", "vocab.json",
)
SPEECH_RELEASE_API = "https://api.github.com/repos/soniqo/speech-swift/releases/tags/v0.0.26"
SPEECH_TAG_API = "https://api.github.com/repos/soniqo/speech-swift/git/ref/tags/v0.0.26"
CONDITIONAL_MLX_ARCHIVE = "https://github.com/Blaizzy/mlx-audio/archive/{}.tar.gz".format(
    MODEL_PINS["conditional_mlx_source"]["revision"]
)
COMMUNITY_FILES = {
    ".gitattributes": (1_519, "11ad7efa24975ee4b0c3c3a38ed18737f0658a5f75a0a96787b576a78a023361"),
    "LICENSE": (404, "f712ef8373487de507ca79d42483551942da38a55faeb987ec9d7cfdc11e3ec4"),
    "README.md": (7_199, "417690835dbe8f6ff3cceb0048a3a860916c1fd7a1bc3b7a1409018a2df792b0"),
    "benchmark.json": (10_437, "2339c2da87cac7167ecd0e311b7bc21576f3bb1df52fe954f6183591977e6c02"),
    "config.json": (4_154, "6bf96d3f361ad1b5bcfbcf2bdf70a2072d211fefd875700231e1f3b2fb69e713"),
    "embedding.mlmodelc/analytics/coremldata.bin": (243, "f4b5ad2e2ea815e334acaf162fa42e999ecd9881ecac4166ff43d6bc1d9322d6"),
    "embedding.mlmodelc/coremldata.bin": (345, "3ad7a2f309143107fc5394f34592ce80482bf6dbe6831e0588cff44cbaa609e5"),
    "embedding.mlmodelc/model.mil": (76_426, "66d248aad00b3e103151097a9bbba558402933c0cf31c010f66b086ac94d7aaf"),
    "embedding.mlmodelc/weights/weight.bin": (27_430_272, "1019c1bb4472abfe705da19db3b5d0764adcb2d59dabf766fef74f0963f810f2"),
    "plda.safetensors": (199_624, "aff6294b68b66adcbc1c2a402b1379ecfdd98d8d759dc2cca62b5380babea359"),
    "segmentation.mlmodelc/analytics/coremldata.bin": (243, "44d83274cec5ccfe4a959eca359a89e4fd757b1872962449f2206784fb2031e5"),
    "segmentation.mlmodelc/coremldata.bin": (328, "5385e1af87712e3027ac96915d3b85de9450681e73ef355dfadd4b274cc9ba58"),
    "segmentation.mlmodelc/model.mil": (27_100, "8c0956cbbce7bac956cb85176fde28353a0d4a1e623f5621b6277b3d256ad0e8"),
    "segmentation.mlmodelc/weights/weight.bin": (5_960_448, "d2c1c75adec19e64ea732808839b6b8da2968a8a26b8aa3e170ef283df44a6ca"),
}
LICENSE_EVIDENCE_ROLES = (
    "dicow_model_card",
    "dicow_repository_inventory",
    "dicow_source_license",
    "mlc_slm_data_terms",
    "in1009_partition",
    "hike_release_and_training_list",
    "community1_license",
    "fleurs_license",
    "hike_license",
    "qwen_aligner_license",
    "speech_swift_tag",
    "speech_swift_release",
    "speech_swift_archive",
    "speech_swift_license",
    "community1_tree",
    "author_question_draft",
)

DTYPE_BYTES = {
    "BOOL": 1,
    "U8": 1,
    "I8": 1,
    "F8_E4M3": 1,
    "F8_E5M2": 1,
    "I16": 2,
    "U16": 2,
    "F16": 2,
    "BF16": 2,
    "I32": 4,
    "U32": 4,
    "F32": 4,
    "I64": 8,
    "U64": 8,
    "F64": 8,
}

R2_AUDIT_SCHEMA_VERSION = "dicow-r2-pre-model-audit-v1"
R2_EXACT_MODEL_IDENTITIES = {
    "dicow_mlc": {
        "model_id": "BUT-FIT/DiCoW_v3_MLC",
        "revision": "99c64e8dc409a158816e808a1ee556cdfd0af51c",
        "model_file_bytes": 3_833_628_952,
        "model_file_lfs_sha256": "bc3ff21a41ebdb9dbe637815740c4edcf77bfbfe962c601ca33071340fd77bd9",
    },
    "dicow_v3_3": {
        "model_id": "BUT-FIT/DiCoW_v3_3",
        "revision": "c34b64d9a9c5148c65fd355bb188d60343a6b44f",
        "model_file_bytes": 3_568_074_944,
        "model_file_lfs_sha256": "73dee45746bb4a6e5e99d8553f582a70b21b6f1499dea68433d6a7178eb4183b",
    },
    "qwen_asr": {
        "model_id": R2_MODEL_PINS["qwen_asr"]["model_id"],
        "revision": R2_MODEL_PINS["qwen_asr"]["revision"],
        "model_file_lfs_sha256": R2_MODEL_PINS["qwen_asr"]["weights_lfs_sha256"],
    },
    "qwen_aligner": {
        "model_id": R2_MODEL_PINS["qwen_aligner"]["model_id"],
        "revision": R2_MODEL_PINS["qwen_aligner"]["revision"],
        "model_file_lfs_sha256": R2_MODEL_PINS["qwen_aligner"]["weights_lfs_sha256"],
    },
}
R2_EXTERNAL_GRAPH_CONTRACT = {
    "sample_rate_hz": 16_000,
    "mel_bins": 128,
    "stno_channel_order": ["silence", "target", "non_target", "overlap"],
    "tokenizer_semantics": "whisper_multilingual_exact",
    "language_semantics": "explicit_request_language",
    "prompt_semantics": "decoder_prompt_prefix",
    "generation_mode": "greedy",
    "scorer_input": "speaker_attributed_words_and_text",
    "timestamp_representation": "whisper_timestamp_tokens",
}
R2_GRAPH_AST_DERIVATION = {
    "implementation": "CPython",
    "version": "3.12.13",
    "cache_tag": "cpython-312",
    "feature_version": [3, 12],
    "executable_record": {
        "bytes": 18_073_888,
        "sha256": "7b05d803bbc1bbfc81644af4faf2b88f0a37b8de96b9f42c1e08033e2cd0848a",
    },
    "ast_module_record": {
        "bytes": 64_452,
        "sha256": "b515c23dbbc459329d3b802a3aac742cc456d7472e66f7ed6e9dc97e40596d7d",
    },
    "parse": {"call": "ast.parse", "feature_version": [3, 12]},
    "dump": {"annotate_fields": True, "include_attributes": False},
}
R2_ALIGNER_BUNDLE_RECORDS: Tuple[Dict[str, Any], ...] = ()
R2_ALIGNER_BUNDLE_PATHS: Tuple[str, ...] = ()
R2_ALIGNER_LARGE_CAPTURE_RECORDS: Dict[str, Dict[str, Any]] = {}
R2_ALIGNER_SEMANTIC_STATUS = {
    "schema_version": "dicow-r2-mlx-audio-aligner-status-v1",
    "status": "semantic_authority_rejected",
    "active_bundle": None,
    "verdict": "unestablished",
    "rejected_diagnostic": {
        "identity": "semantic-v4",
        "role": "rejected_non_authoritative_diagnostic",
        "blockers": [
            "unbound_mutable_cpython_stdlib",
            "missing_mlx_dynamic_library",
            "installed_runtime_toctou",
        ],
        "forbidden_claims": [
            "new_model_code_required",
            "exact_weights_only_supported",
            "model_or_conversion_parity",
            "runtime_compatibility",
        ],
    },
}
R2_FLEURS_REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
R2_FLEURS_PARQUETS = {
    "ko": {
        "utterance_id": "fleurs-ko-2005", "locale": "ko_kr", "language": "Korean", "row_index": 37, "sentence_id": 2005,
        "audio_path": "11368863851088641817.wav", "num_samples": 74_880,
        "parquet_bytes": 291_159_866,
        "parquet_sha256": "1a8319fc61c7996e8c15acde633786de97054e28ae1e463eb13901716176a7ec",
        "wav_sha256": "936edc8491d97c6365629a35b45c6bb949358ffe056268dc7e4421ffdd6e2812",
        "pcm_sha256": "1afd0a7565da62ef08b87146e8b22d8c1293b7555e3ea715f94163056cd7244e",
        "normalized_transcription": "하지만 여전히 새에는 공룡처럼 보이게 하는 것들이 많습니다",
        "start_sample": 0, "end_sample": 74_880,
    },
    "en": {
        "utterance_id": "fleurs-en-2005", "locale": "en_us", "language": "English", "row_index": 18, "sentence_id": 2005,
        "audio_path": "10471564175308895403.wav", "num_samples": 85_760,
        "parquet_bytes": 401_722_686,
        "parquet_sha256": "6428a4d04d3aac29e16b45e039bb1470a8bd7aa334cf92f7984c9c520d1f234d",
        "wav_sha256": "5a56cbc0ec373f9873b762d79e8b6874c889ba07e2bd195c40098e84bd170f5e",
        "pcm_sha256": "c44a228aac211c33558bbb2b795b902e075a31bee217ea55d5e42fd4d82b52fa",
        "normalized_transcription": "but there are a lot of things about birds that still look like a dinosaur",
        "start_sample": 82_880, "end_sample": 168_640,
    },
    "it": {
        "utterance_id": "fleurs-it-2005", "locale": "it_it", "language": "Italian", "row_index": 357, "sentence_id": 2005,
        "audio_path": "16934193273648416040.wav", "num_samples": 101_760,
        "parquet_bytes": 806_437_035,
        "parquet_sha256": "6b648b2851cd0d0cf50254c9a7ecf8d91d7e41ecdb536f5614b10ef33b6b11a8",
        "wav_sha256": "f9ade60579b27ec7a56fcbf91cad7a2712afe437df9b43ef934dc3735ee3502c",
        "pcm_sha256": "53214109fe2d03eab7a70339fdb956a1bf59543342570d4757d24df329937b09",
        "normalized_transcription": "eppure gli uccelli hanno molte caratteristiche che li accomunano ai dinosauri",
        "start_sample": 176_640, "end_sample": 278_400,
    },
}
R2_FLEURS_JOIN_SAMPLES = 278_400
R2_FLEURS_JOIN_PCM_SHA256 = "f4962400db8efbdd264cdc1743aa2f72788f19775e876c5d98ad74c7fe4b6110"
R2_FLEURS_AUTHORITY_RECORD = {
    "relative_path": "authority.json",
    "bytes": 4_131,
    "sha256": "7ceef5d236bcf2fcdcbc9437c51b67b288cb7f3038c71598739a197b2fd4870e",
}
R2_HIKE_REVISION = "255609b24005e1fcce3f8b3a452260aaf2872cc9"
R2_HIKE_PARQUET_BYTES = 235_089_121
R2_HIKE_PARQUET_SHA256 = "cc807d5e31c92df85a46445b28df2b239f7fb33943a35502161af61c1ee8b4d0"
R2_HIKE_SELECTED_SAMPLE_IDS = (
    "0c47a000-1772-419a-b7d4-cf9178a90cc0",
    "39294b8b-2497-403d-b517-ccb1f6bb5bfa",
    "b5905871-7a2f-4e52-9236-291e781f21fd",
    "33c43069-4dcd-4e26-8ea9-6d561bff464c",
    "9ae7392c-eba8-4556-a948-6387191f3909",
    "5bb23641-691b-484a-a771-e17545b808be",
    "929e5099-e14f-4cbc-9ff2-783b230a72a4",
    "40ce5e15-ec33-43a2-9f6a-2102eb534f21",
    "ebb4c44f-7cd3-4bf1-b77c-5f6a77cd03a4",
    "7bde6c38-df44-4a62-9afc-ad5f16cf944a",
    "d1ac6ca7-4492-45a6-ab80-16de1b4a5924",
    "49672583-2c66-418a-b7b6-39bf3b9e1637",
)
R2_HIKE_TERM_EXTRACTOR = "hike_row_loanwords_english_nfkc_casefold_reference_filter_v1"
R2_HIKE_TERM_FILTER = "nfkc_casefold_positive_occurrence_latin_alnum_boundary_zero_or_more_space_underscore_hyphen"
R2_HIKE_TERMS_SHA256 = "b28d9ed33a523311bafe4414ffd311d8877b9bbdb967d7b54a2aa2cc068989b2"
R2_HIKE_AUTHORITY_RECORDS = {
    "manifest_record": {
        "relative_path": "manifest.json", "bytes": 3_490,
        "sha256": "8d01c7d70a34cb1693795431984d430a7304793b6cd43995b4dd72796a120fe1",
    },
    "parquet_record": {
        "relative_path": "sources/data/test-00000-of-00001.parquet", "bytes": R2_HIKE_PARQUET_BYTES,
        "sha256": R2_HIKE_PARQUET_SHA256,
    },
    "card_record": {
        "relative_path": "captures/README.upstream.md", "bytes": 5_095,
        "sha256": "33eadef0182e8bf18095638ab1514a75ca375b10d3b517eb10f2c68d7f681e08",
    },
    "selection_record": {
        "relative_path": "selected-sample-ids.txt", "bytes": 444,
        "sha256": "47525f6e1af650a54d951ffa18ed40051391aa35f28c0eb381e472412067d968",
    },
    "selected_rows_record": {
        "relative_path": "selected-rows.jsonl", "bytes": 3_205,
        "sha256": "7958cd587ebc80b358f97ec167f3bbd76bd4ad5be0b0fb779ae6bc5ae76daf8c",
    },
    "terms_record": {
        "relative_path": "terms.txt", "bytes": 131, "sha256": R2_HIKE_TERMS_SHA256,
    },
}
R2_REQUIRED_GENERATION_KEYS = {
    "candidate_tuple",
    "ctc_weight",
    "num_beams",
    "timestamp_mode",
    "max_new_tokens",
    "language_field",
    "prompt_field",
    "tokenizer_record",
    "generation_config_record",
}
R2_CTC_DEVIATION = {
    "method_frozen": True,
    "numeric_envelope": None,
    "measurement_state": "deferred_to_R11_pre_perturbation",
}
R2_OVERLAP_PRIOR = {
    "status": "prior_unavailable",
    "threshold_effect": "none",
    "gate_effect": "none",
    "follow_up": "run structural prevalence evidence in a separately authorized task",
}
R2_REQUIRED_AUDIT_DOCUMENTS = (
    "model-identities.json",
    "graph-contracts.json",
    "leakage-decisions.json",
    "rights-bindings.json",
    "generation-request-universe.json",
    "qwen-timestamp-contract.json",
    "qwen-term-contract.json",
    "mlx-audio-aligner-inventory.json",
    "constraint-ledger.json",
    "writer-resource-ledger.json",
    "volume-preflight.json",
    "overlap-prior.json",
    "deviations.json",
    "decision.json",
)
R2_REQUIRED_HEADER_CAPTURES = tuple(
    "headers/{}.safetensors.header".format(candidate)
    for candidate in R2_EXACT_MODEL_IDENTITIES
)
R2_REQUIRED_LFS_CAPTURES = tuple(
    "lfs/{}.tree.json".format(candidate)
    for candidate in R2_EXACT_MODEL_IDENTITIES
)
R2_FIXTURE_RIGHTS_ACTIONS = ("private_reference_evaluation", "tracked_declaration", "redistribution")
R2_FIXTURE_RIGHTS_SUBJECTS = ("hike", "fleurs", "community1")
R2_RIGHTS_ENTITIES = {
    "dicow_mlc": "BUT-FIT/DiCoW_v3_MLC",
    "dicow_v3_3": "BUT-FIT/DiCoW_v3_3",
    "qwen_asr": "Qwen/Qwen3-ASR-1.7B-hf",
    "qwen_aligner": "Qwen/Qwen3-ForcedAligner-0.6B-hf",
    "hike": "thetaone-ai/HiKE",
    "fleurs": "google/fleurs",
    "community1": "pyannote/speaker-diarization-community-1",
}
R2_WRITER_SOURCE_CANDIDATES = {
    "r3_audit_acquisition": tuple(R2_EXACT_MODEL_IDENTITIES),
    "r5_natural_pack": ("dicow_mlc", "dicow_v3_3"),
    "r7_turbo": tuple(R2_EXACT_MODEL_IDENTITIES),
    "r8_dicow_mlc": ("dicow_mlc",),
    "r9_dicow_v3_3": ("dicow_v3_3",),
    "q1_qwen_environment_source": ("qwen_asr", "qwen_aligner"),
    "q2_asr_reuse": ("qwen_asr",),
    "q2_asr_direct_conversion": ("qwen_asr",),
    "q2_aligner_conversion": ("qwen_aligner",),
    "r11_five_process_ctc_receipts": ("dicow_mlc", "dicow_v3_3"),
    "r12_dicow_mlc_bf16": ("dicow_mlc",),
    "r12_dicow_v3_3_bf16": ("dicow_v3_3",),
}


class InspectionError(RuntimeError):
    """Typed, fail-closed inspection failure."""

    def __init__(
        self,
        code: str,
        detail: str,
        evidence_outcome: str = "evidence_blocker",
        branch_verdict: str = "revise",
    ) -> None:
        super().__init__("{}: {}".format(code, detail))
        self.code = code
        self.detail = detail
        self.evidence_outcome = evidence_outcome
        self.branch_verdict = branch_verdict

    def as_dict(self) -> Dict[str, str]:
        return {
            "code": self.code,
            "detail": self.detail,
            "evidence_outcome": self.evidence_outcome,
            "branch_verdict": self.branch_verdict,
        }


def _fail(code: str, detail: str) -> None:
    raise InspectionError(code, detail)


def _reject_symlink_components(path: Path, label: str, must_exist: bool = True) -> None:
    if not path.is_absolute() or Path(os.path.normpath(str(path))) != path or path == Path(path.anchor):
        _fail("invalid_path", "{} must be an absolute normalized non-root path".format(label))
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            if must_exist:
                _fail("missing_path", "{} is missing".format(label))
            return
        if stat.S_ISLNK(info.st_mode):
            _fail("symlink_path", "{} contains a symlink component".format(label))


def _read(path: Path, label: str) -> bytes:
    _reject_symlink_components(path, label)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        _fail("read_failed", "cannot open {}: {}".format(label, error))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            _fail("not_regular_file", "{} must be a regular file".format(label))
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    final = os.lstat(path)
    identities = [
        (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns)
        for item in (before, after, final)
    ]
    if identities[0] != identities[1] or identities[1] != identities[2]:
        _fail("unstable_file", "{} changed while read".format(label))
    return b"".join(chunks)


def _parse_json_object(raw: bytes, label: str) -> Mapping[str, Any]:
    def reject_duplicate(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
        value: Dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                _fail("duplicate_json_key", "{} repeats key {!r}".format(label, key))
            value[key] = item
        return value

    def reject_constant(value: str) -> None:
        _fail("invalid_json", "{} contains non-finite constant {}".format(label, value))

    try:
        result = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail("invalid_json", "{}: {}".format(label, error))
    if not isinstance(result, dict):
        _fail("invalid_json_type", "{} must be an object".format(label))
    return result


def _json(path: Path, label: str) -> Mapping[str, Any]:
    return _parse_json_object(_read(path, label), label)


def _sha256(path: Path, label: str) -> str:
    return hashlib.sha256(_read(path, label)).hexdigest()


def _record(path: Path, label: str) -> Dict[str, Any]:
    raw = _read(path, label)
    return {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


def _inventory(root: Path, label: str) -> Dict[str, Dict[str, Any]]:
    _reject_symlink_components(root, label)
    if not root.is_dir():
        _fail("not_directory", "{} must be a directory".format(label))
    result: Dict[str, Dict[str, Any]] = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            _fail("symlink_inventory", "{} contains symlink {}".format(label, relative))
        if stat.S_ISREG(info.st_mode):
            result[relative] = _record(path, "{} file {}".format(label, relative))
        elif not stat.S_ISDIR(info.st_mode):
            _fail("special_inventory_entry", "{} contains special entry {}".format(label, relative))
    return result


def verify_source_metadata(source_metadata: Path) -> Dict[str, Any]:
    """Verify T2's exact nine-file source boundary and return its payload hashes."""

    manifest = _json(source_metadata / "manifest.json", "T2 source manifest")
    pin = MODEL_PINS["dicow"]
    if manifest.get("schema_version") != "dicow-source-acquisition-v1":
        _fail("source_schema", "unexpected T2 source schema")
    if manifest.get("model_id") != pin["model_id"] or manifest.get("revision") != pin["revision"]:
        _fail("source_revision", "T2 source model or revision differs from the pin")
    payloads = manifest.get("payloads")
    if not isinstance(payloads, list) or len(payloads) != len(SOURCE_FILES):
        _fail("source_allowlist", "T2 manifest must contain exactly nine payloads")
    expected_paths = {"snapshot/{}".format(name) for name in SOURCE_FILES}
    seen: Dict[str, Dict[str, Any]] = {}
    for entry in payloads:
        if not isinstance(entry, dict) or set(entry) != {"bytes", "mode", "path", "sha256"}:
            _fail("source_entry", "T2 payload entry has an unexpected shape")
        relative = entry["path"]
        if relative in seen:
            _fail("source_duplicate", "T2 repeats {}".format(relative))
        if relative not in expected_paths:
            _fail("source_allowlist", "T2 contains unapproved {}".format(relative))
        path = source_metadata / relative
        actual = _record(path, "T2 source {}".format(relative))
        if actual != {"bytes": entry["bytes"], "sha256": entry["sha256"]}:
            _fail("source_hash", "T2 source {} differs from its manifest".format(relative))
        if entry["mode"] != "0644" or stat.S_IMODE(os.lstat(path).st_mode) != 0o644:
            _fail("source_mode", "T2 source {} must have mode 0644".format(relative))
        seen[relative] = actual
    if set(seen) != expected_paths:
        _fail("source_allowlist", "T2 source allowlist is incomplete")
    snapshot_entries = set(_inventory(source_metadata / "snapshot", "T2 source snapshot"))
    if snapshot_entries != set(SOURCE_FILES):
        _fail("source_inventory", "T2 source snapshot is not exactly the nine-file allowlist")
    return {
        "model_id": pin["model_id"],
        "revision": pin["revision"],
        "payloads": {path: seen["snapshot/{}".format(path)] for path in SOURCE_FILES},
    }


def verify_full_source_matches_t2(snapshot: Path, t2_record: Mapping[str, Any]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    payloads = t2_record.get("payloads")
    if not isinstance(payloads, dict):
        _fail("source_record", "T2 record payloads are invalid")
    for name in SOURCE_FILES:
        actual = _record(snapshot / name, "full snapshot {}".format(name))
        if actual != payloads.get(name):
            _fail("source_copy_drift", "full snapshot {} differs from T2".format(name))
        result[name] = actual
    return result


def verify_configuration(snapshot: Path) -> Dict[str, Any]:
    config = _json(snapshot / "config.json", "DiCoW config")
    generation = _json(snapshot / "generation_config.json", "DiCoW generation config")
    preprocessor = _json(snapshot / "preprocessor_config.json", "DiCoW preprocessor config")
    expected = {
        "d_model": GRAPH_PINS["d_model"],
        "encoder_layers": GRAPH_PINS["encoder_blocks"],
        "decoder_layers": GRAPH_PINS["decoder_blocks"],
        "num_mel_bins": GRAPH_PINS["mel_bins"],
        "max_source_positions": GRAPH_PINS["encoder_frames"],
        "max_target_positions": GRAPH_PINS["target_positions"],
        "vocab_size": GRAPH_PINS["vocabulary"],
    }
    for key, value in expected.items():
        if config.get(key) != value:
            _fail("graph_config", "config {} is {!r}, expected {!r}".format(key, config.get(key), value))
    booleans = {
        "use_fddt": True,
        "use_initial_fddt": True,
        "fddt_is_diagonal": True,
        "fddt_bias_only": False,
        "fddt_use_silence": True,
        "fddt_use_target": True,
        "fddt_use_non_target": True,
        "fddt_use_overlap": True,
    }
    for key, value in booleans.items():
        if config.get(key) is not value:
            _fail("fddt_config", "config {} must be {!r}".format(key, value))
    if config.get("apply_fddt_to_n_layers") not in (-1, 32):
        _fail("fddt_placement", "FDDT layer count is not all 32 encoder blocks")
    if generation.get("num_beams", 1) != 1:
        _fail("beam_search", "num_beams must be one")
    if generation.get("ctc_weight") != 0:
        _fail("generation_ctc", "generation ctc_weight must be zero")
    if preprocessor.get("feature_size") != GRAPH_PINS["mel_bins"]:
        _fail("mel_contract", "preprocessor feature_size differs from 128")
    return {
        "graph": expected,
        "model_config_ctc_weight": config.get("ctc_weight"),
        "generation_config_ctc_weight": generation.get("ctc_weight"),
        "generation_num_beams": generation.get("num_beams", 1),
        "fddt": booleans,
    }


def verify_tokenizer_inventory(snapshot: Path) -> Dict[str, Any]:
    required = {
        "added_tokens.json", "merges.txt", "normalizer.json", "special_tokens_map.json",
        "tokenizer.json", "tokenizer_config.json", "vocab.json",
    }
    missing = sorted(name for name in required if not (snapshot / name).is_file())
    if missing:
        _fail("tokenizer_inventory", "missing tokenizer files: {}".format(", ".join(missing)))
    return {name: _record(snapshot / name, "tokenizer {}".format(name)) for name in sorted(required)}


def _python_ast(path: Path, label: str) -> Tuple[bytes, ast.Module]:
    raw = _read(path, label)
    try:
        text = raw.decode("utf-8")
        return raw, ast.parse(text, filename=str(path))
    except (UnicodeDecodeError, SyntaxError) as error:
        _fail("invalid_python_source", "{}: {}".format(label, error))
    raise AssertionError("unreachable")


def _node_bytes(raw: bytes, node: ast.AST) -> bytes:
    lines = raw.splitlines(keepends=True)
    if not hasattr(node, "lineno") or not hasattr(node, "end_lineno"):
        _fail("ast_positions", "Python AST lacks end positions")
    start_line = node.lineno - 1  # type: ignore[attr-defined]
    end_line = node.end_lineno - 1  # type: ignore[attr-defined]
    if start_line == end_line:
        return lines[start_line][node.col_offset : node.end_col_offset]  # type: ignore[attr-defined]
    pieces = [lines[start_line][node.col_offset :]]  # type: ignore[attr-defined]
    pieces.extend(lines[start_line + 1 : end_line])
    pieces.append(lines[end_line][: node.end_col_offset])  # type: ignore[attr-defined]
    return b"".join(pieces)


def _definitions(root: Path) -> Dict[str, Sequence[Tuple[Path, bytes]]]:
    result: MutableMapping[str, list] = {}
    files = sorted(root.rglob("*.py"))
    if not files:
        _fail("mlx_source_empty", "MLX source tree has no Python files")
    for path in files:
        raw, tree = _python_ast(path, "MLX source {}".format(path))
        for node in ast.walk(tree):
            if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                result.setdefault(node.name, []).append((path, _node_bytes(raw, node)))
    return result


def _mlx_definition_file(root: Path) -> Tuple[Path, Dict[str, Sequence[Tuple[Path, bytes]]]]:
    """Locate the sole Python file that contains all four Whisper definitions."""

    candidates = []
    for path in sorted(root.rglob("*.py")):
        raw, tree = _python_ast(path, "MLX source {}".format(path))
        found: MutableMapping[str, list] = {}
        for node in ast.walk(tree):
            if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in REUSED_MLX_SYMBOLS:
                found.setdefault(node.name, []).append((path, _node_bytes(raw, node)))
        if set(found) == set(REUSED_MLX_SYMBOLS):
            candidates.append((path, dict(found)))
    if len(candidates) != 1:
        _fail("mlx_source_file_cardinality", "exactly one source file must contain all four reused definitions")
    return candidates[0]


def compare_mlx_symbols(base_root: Path, conditional_root: Path) -> Dict[str, Any]:
    """AST-locate all four definitions and report conditional eligibility."""

    base_path, base = _mlx_definition_file(base_root)
    conditional_path, conditional = _mlx_definition_file(conditional_root)
    symbols: Dict[str, Any] = {}
    mismatches = []
    for name in REUSED_MLX_SYMBOLS:
        left = base.get(name, ())
        right = conditional.get(name, ())
        if len(left) != 1 or len(right) != 1:
            _fail("mlx_symbol_cardinality", "{} must occur exactly once in each source tree".format(name))
        identical = left[0][1] == right[0][1]
        if not identical:
            mismatches.append(name)
        symbols[name] = {
            "base_path": left[0][0].relative_to(base_root).as_posix(),
            "conditional_path": right[0][0].relative_to(conditional_root).as_posix(),
            "identical": identical,
            "base_bytes": len(left[0][1]),
            "conditional_bytes": len(right[0][1]),
            "base_sha256": hashlib.sha256(left[0][1]).hexdigest(),
            "conditional_sha256": hashlib.sha256(right[0][1]).hexdigest(),
        }
    conditional_all = _definitions(conditional_root)
    forbidden_present = sorted(name for name in FORBIDDEN_MLX_REUSE if name in conditional_all)
    return {
        "base_version": "0.4.6",
        "conditional_revision": MODEL_PINS["conditional_mlx_source"]["revision"],
        "permitted_symbols": symbols,
        "forbidden_reuse_symbols": list(FORBIDDEN_MLX_REUSE),
        "forbidden_definitions_present_but_not_reused": forbidden_present,
        "base_definition_file": base_path.relative_to(base_root).as_posix(),
        "conditional_definition_file": conditional_path.relative_to(conditional_root).as_posix(),
        "conditional_source_eligible": not mismatches,
        "conditional_source_verdict": "eligible" if not mismatches else "ineligible",
        "mismatched_symbols": mismatches,
        "conditional_ineligibility_reason": None if not mismatches else "mlx_symbol_mutation",
        "implementation_source_required": "installed_mlx_audio_0.4.6" if mismatches else "either_byte_identical_source",
        "overall_e0_axis_eligible_with_installed_source": True,
    }


def validate_mlx_source_selection(selection: str, comparison: Mapping[str, Any]) -> str:
    if selection == "mlx-audio-0.4.6":
        return selection
    if selection == "conditional-9cef816508e4fbdc35b4011bbfe1fc512b889701":
        if comparison.get("conditional_source_eligible") is not True:
            _fail("mlx_symbol_mutation", "conditional MLX source was selected despite mutated reused definitions")
        return selection
    _fail("mlx_source_selection", "implementation source is not an allowed exact source")
    raise AssertionError("unreachable")


def verify_mlx_base_install(root: Path) -> Dict[str, Any]:
    site_packages = root.parent
    distributions = list(site_packages.glob("mlx_audio-0.4.6.dist-info"))
    if len(distributions) != 1:
        _fail("mlx_base_distribution", "mlx-audio 0.4.6 dist-info is missing or ambiguous")
    metadata = _read(distributions[0] / "METADATA", "mlx-audio METADATA").decode("utf-8")
    if "Name: mlx-audio\n" not in metadata or "Version: 0.4.6\n" not in metadata:
        _fail("mlx_base_distribution", "installed MLX package metadata differs from 0.4.6")
    record_raw = _read(distributions[0] / "RECORD", "mlx-audio RECORD")
    try:
        record_rows = list(csv.reader(io.StringIO(record_raw.decode("utf-8", errors="strict"), newline="")))
    except (UnicodeDecodeError, csv.Error) as error:
        _fail("mlx_base_record", "installed MLX RECORD is invalid: {}".format(error))
    record_index: Dict[str, Tuple[str, str]] = {}
    for row in record_rows:
        if len(row) != 3 or not row[0] or row[0] in record_index:
            _fail("mlx_base_record", "installed MLX RECORD has an invalid or duplicate row")
        record_index[row[0]] = (row[1], row[2])
    source_inventory = _inventory(root, "mlx-audio 0.4.6 package")
    for relative, actual in source_inventory.items():
        record_path = "{}/{}".format(root.name, relative)
        if record_path not in record_index:
            _fail("mlx_base_record", "installed MLX source is absent from RECORD: {}".format(record_path))
        encoded_hash, encoded_size = record_index[record_path]
        if not encoded_hash.startswith("sha256=") or not encoded_size.isdigit():
            _fail("mlx_base_record", "installed MLX source has an unhashed RECORD row: {}".format(record_path))
        encoded_digest = encoded_hash[7:]
        try:
            expected_digest = base64.urlsafe_b64decode(
                encoded_digest + "=" * (-len(encoded_digest) % 4)
            ).hex()
        except (ValueError, TypeError) as error:
            _fail("mlx_base_record", "installed MLX RECORD hash is invalid: {}".format(error))
        if int(encoded_size) != actual["bytes"] or expected_digest != actual["sha256"]:
            _fail("mlx_base_record", "installed MLX source differs from RECORD: {}".format(record_path))
    inventory_sha = hashlib.sha256(
        json.dumps(source_inventory, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {
        "distribution": "mlx-audio==0.4.6",
        "metadata": _record(distributions[0] / "METADATA", "mlx-audio METADATA"),
        "record": _record(distributions[0] / "RECORD", "mlx-audio RECORD"),
        "source_file_count": len(source_inventory),
        "record_bound_source_file_count": len(source_inventory),
        "source_inventory_sha256": inventory_sha,
    }


def validate_reuse_declaration(names: Iterable[str]) -> Tuple[str, ...]:
    declared = tuple(names)
    if len(declared) != len(set(declared)):
        _fail("mlx_reuse_duplicate", "reused symbol declaration contains a duplicate")
    if set(declared) != set(REUSED_MLX_SYMBOLS):
        forbidden = sorted(set(declared).intersection(FORBIDDEN_MLX_REUSE))
        detail = "reused symbol declaration must contain exactly the four permitted names"
        if forbidden:
            detail += "; forbidden: {}".format(", ".join(forbidden))
        _fail("mlx_reuse_allowlist", detail)
    return declared


def _assignment_names(target: ast.AST) -> set[str]:
    if isinstance(target, ast.Name):
        return {target.id}
    if isinstance(target, (ast.Tuple, ast.List)):
        result: set[str] = set()
        for item in target.elts:
            result.update(_assignment_names(item))
        return result
    return set()


def _references_encoder_logits(expression: ast.AST, tainted_names: set[str]) -> bool:
    for node in ast.walk(expression):
        if isinstance(node, ast.Name) and node.id in tainted_names:
            return True
        if (
            isinstance(node, ast.Attribute)
            and node.attr == "logits"
            and isinstance(node.value, ast.Name)
            and node.value.id == "encoder_outputs"
        ):
            return True
    return False


def _decoder_dataflow_evidence(model_tree: ast.Module) -> Dict[str, Any]:
    decoder_calls = [
        node
        for node in ast.walk(model_tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == "self"
        and node.func.attr == "decoder"
    ]
    if len(decoder_calls) != 1:
        _fail("ctc_decoder_dataflow", "model source must contain exactly one self.decoder call")
    call = decoder_calls[0]
    containing_functions = [
        node
        for node in ast.walk(model_tree)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.lineno <= call.lineno <= getattr(node, "end_lineno", node.lineno)
    ]
    if not containing_functions:
        _fail("ctc_decoder_dataflow", "decoder call is not inside a function")
    function = min(containing_functions, key=lambda node: getattr(node, "end_lineno", node.lineno) - node.lineno)

    tainted_names = {"encoder_logits"}
    assignments = [
        node
        for node in ast.walk(function)
        if isinstance(node, (ast.Assign, ast.AnnAssign, ast.NamedExpr))
    ]
    changed = True
    while changed:
        changed = False
        for assignment in assignments:
            value = assignment.value
            targets = assignment.targets if isinstance(assignment, ast.Assign) else (assignment.target,)
            if _references_encoder_logits(value, tainted_names):
                for target in targets:
                    for name in _assignment_names(target):
                        if name not in tainted_names:
                            tainted_names.add(name)
                            changed = True

    if call.args:
        _fail("ctc_decoder_dataflow", "decoder call must use explicit keyword dataflow")
    keywords = {item.arg: item.value for item in call.keywords if item.arg is not None}
    if len(keywords) != len(call.keywords):
        _fail("ctc_decoder_dataflow", "decoder call may not expand unknown keyword dataflow")
    hidden = keywords.get("encoder_hidden_states")
    expected_hidden = ast.parse("encoder_outputs.hidden_states[-1]", mode="eval").body
    if hidden is None or ast.dump(hidden, include_attributes=False) != ast.dump(expected_hidden, include_attributes=False):
        _fail("ctc_decoder_dataflow", "decoder must consume the final encoder hidden state exactly")
    if "encoder_logits" in keywords or any(
        _references_encoder_logits(value, tainted_names) for value in keywords.values()
    ):
        _fail("ctc_decoder_dataflow", "decoder consumes encoder logits directly or through an alias")
    return {
        "decoder_call_count": 1,
        "explicit_keyword_dataflow": True,
        "encoder_hidden_states_expression": "encoder_outputs.hidden_states[-1]",
        "encoder_logits_tainted_argument": False,
    }


def inspect_ctc_source(snapshot: Path) -> Dict[str, Any]:
    """Record the honest static CTC picture without claiming a zero-call proof."""

    config = _json(snapshot / "config.json", "DiCoW config")
    generation = _json(snapshot / "generation_config.json", "DiCoW generation config")
    encoder = _read(snapshot / "encoder.py", "DiCoW encoder source").decode("utf-8")
    generation_source = _read(snapshot / "generation.py", "DiCoW generation source").decode("utf-8")
    _model_raw, model_tree = _python_ast(snapshot / "modeling_dicow.py", "DiCoW model source")
    static_auxiliary_executes = all(
        fragment in encoder
        for fragment in (
            "if self.ctc_weight > 0.0:",
            "self.lm_head = nn.Linear",
            "logits = self.lm_head(inter_output)",
        )
    )
    processor_guarded = all(
        fragment in generation_source
        for fragment in (
            "generation_config.ctc_weight > 0",
            "CTCRescorerLogitsProcessor(",
            "processors.append(self.ctc_rescorer)",
        )
    )
    decoder_dataflow = _decoder_dataflow_evidence(model_tree)
    model_weight = config.get("ctc_weight")
    generation_weight = generation.get("ctc_weight")
    if model_weight != 0.3 or generation_weight != 0:
        _fail("ctc_configuration", "expected separate model 0.3 and generation 0 CTC weights")
    if not static_auxiliary_executes or not processor_guarded:
        _fail("ctc_static_source", "required CTC static source structure is absent")
    return {
        "model_config_ctc_weight": model_weight,
        "generation_config_ctc_weight": generation_weight,
        "auxiliary_branch_and_lm_head_execute": True,
        "generation_processor_present_at_weight_zero": False,
        "decoder_dataflow_consumes_encoder_logits": False,
        "static_source_supports_no_decode_dataflow": True,
        "decoder_dataflow": decoder_dataflow,
        "zero_forward_calls_proven": False,
        "perturbation_bypass_proven": False,
        "omission_proof_complete": False,
        "evidence_outcome": "evidence_blocker",
        "branch_verdict": "revise",
        "blocker_code": "ctc_zero_call_rule_unsatisfied",
        "revisit_task": "T9",
        "frozen_rule": {
            "requirement": "zero_ctc_head_forward_calls",
            "satisfied": False,
            "outcome": "evidence_blocker/revise",
        },
        "amendment_ready_evidence": {
            "positive_encoder_head_execution_recorded": True,
            "generation_weight_zero": True,
            "generation_processor_absent": True,
            "static_no_decoder_logits_dataflow": True,
            "decoder_logits_perturbation_invariance": "unproven_until_T9",
            "decoder_logits_bypass_invariance": "unproven_until_T9",
            "omission_authorized": False,
        },
    }


def read_safetensors_header(path: Path) -> Dict[str, Any]:
    """Parse and validate a safetensors header without mapping tensor payloads."""

    _reject_symlink_components(path, "safetensors checkpoint")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            _fail("checkpoint_type", "checkpoint must be a regular file")
        prefix = os.read(descriptor, 8)
        if len(prefix) != 8:
            _fail("safetensors_header", "checkpoint is shorter than eight bytes")
        header_length = struct.unpack("<Q", prefix)[0]
        if header_length == 0 or header_length > 100_000_000 or 8 + header_length > info.st_size:
            _fail("safetensors_header", "invalid safetensors header length")
        header_raw = b""
        while len(header_raw) < header_length:
            chunk = os.read(descriptor, header_length - len(header_raw))
            if not chunk:
                _fail("safetensors_header", "truncated safetensors header")
            header_raw += chunk
    finally:
        os.close(descriptor)
    def reject_header_duplicates(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                _fail("safetensors_header", "duplicate header key {!r}".format(key))
            result[key] = value
        return result

    try:
        header = json.loads(header_raw.decode("utf-8"), object_pairs_hook=reject_header_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail("safetensors_header", "invalid header JSON: {}".format(error))
    if not isinstance(header, dict):
        _fail("safetensors_header", "header must be an object")
    data_start = 8 + header_length
    tensors: Dict[str, Dict[str, Any]] = {}
    intervals = []
    parameters = 0
    for name, entry in header.items():
        if name == "__metadata__":
            continue
        if not isinstance(name, str) or not isinstance(entry, dict) or set(entry) != {"dtype", "shape", "data_offsets"}:
            _fail("tensor_entry", "invalid tensor entry {!r}".format(name))
        dtype = entry["dtype"]
        shape = entry["shape"]
        offsets = entry["data_offsets"]
        if dtype not in DTYPE_BYTES or not isinstance(shape, list) or not all(isinstance(x, int) and x >= 0 for x in shape):
            _fail("tensor_metadata", "invalid dtype or shape for {}".format(name))
        if not isinstance(offsets, list) or len(offsets) != 2 or not all(isinstance(x, int) for x in offsets):
            _fail("tensor_offsets", "invalid offsets for {}".format(name))
        count = math.prod(shape)
        expected_bytes = count * DTYPE_BYTES[dtype]
        if offsets[0] < 0 or offsets[1] - offsets[0] != expected_bytes or data_start + offsets[1] > info.st_size:
            _fail("tensor_payload", "payload span is invalid for {}".format(name))
        intervals.append((offsets[0], offsets[1], name))
        parameters += count
        tensors[name] = {"dtype": dtype, "shape": shape, "data_offsets": offsets, "parameters": count}
    intervals.sort()
    cursor = 0
    for start, end, name in intervals:
        if start != cursor:
            _fail("tensor_layout", "tensor {} has a gap or overlap before it".format(name))
        cursor = end
    if data_start + cursor != info.st_size:
        _fail("tensor_layout", "tensor payloads do not cover the checkpoint exactly")
    return {
        "header_bytes": header_length,
        "data_start": data_start,
        "file_bytes": info.st_size,
        "tensor_count": len(tensors),
        "parameter_count": parameters,
        "tensors": tensors,
    }


def _payload_hash(path: Path, data_start: int, offsets: Sequence[int]) -> str:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.lseek(descriptor, data_start + offsets[0], os.SEEK_SET)
        remaining = offsets[1] - offsets[0]
        digest = hashlib.sha256()
        while remaining:
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            if not chunk:
                _fail("tensor_payload", "tensor payload ended early")
            digest.update(chunk)
            remaining -= len(chunk)
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def inspect_checkpoint(path: Path) -> Dict[str, Any]:
    pin = MODEL_PINS["dicow"]["model_file"]
    record = _record(path, "DiCoW checkpoint")
    if record != {"bytes": pin["bytes"], "sha256": pin["sha256"]}:
        _fail("checkpoint_hash", "DiCoW checkpoint size or SHA-256 differs from the pin")
    parsed = read_safetensors_header(path)
    if parsed["tensor_count"] != pin["tensor_count"] or parsed["parameter_count"] != pin["parameter_count"]:
        _fail("checkpoint_inventory", "checkpoint tensor or parameter count differs")
    tensors = parsed["tensors"]
    if any(not name.startswith("model.") for name in tensors):
        _fail("source_key_prefix", "every checkpoint key must start with model.")
    if any(entry["dtype"] != "F32" for entry in tensors.values()):
        _fail("checkpoint_dtype", "all checkpoint tensors must be FP32")

    position_pin = GRAPH_PINS["encoder_position_tensor"]
    position = tensors.get(position_pin["source_key"])
    if not position or position["shape"] != list(position_pin["shape"]) or position["dtype"] != "F32":
        _fail("position_tensor", "encoder position tensor metadata differs")
    position_bytes = position["data_offsets"][1] - position["data_offsets"][0]
    if position_bytes != position_pin["bytes"]:
        _fail("position_tensor", "encoder position payload size differs")
    position_sha = _payload_hash(path, parsed["data_start"], position["data_offsets"])
    if position_sha != position_pin["sha256"]:
        _fail("position_tensor", "encoder position payload SHA-256 differs")

    fddt_names = [name for name in tensors if ".initial_fddt." in name or ".fddts." in name]
    fddt_modules: Dict[str, set] = {}
    for name in fddt_names:
        prefix, separator, suffix = name.partition(".initial_fddt.")
        if separator:
            module = prefix + ".initial_fddt"
        else:
            before, separator, rest = name.partition(".fddts.")
            parts = rest.split(".", 1)
            if not separator or len(parts) != 2 or not parts[0].isdigit():
                _fail("fddt_key", "malformed FDDT key {}".format(name))
            module = before + ".fddts." + parts[0]
            suffix = parts[1]
        fddt_modules.setdefault(module, set()).add(suffix)
    expected_suffixes = {
        "silence_linear.weight", "silence_linear.bias",
        "target_linear.weight", "target_linear.bias",
        "non_target_linear.weight", "non_target_linear.bias",
        "overlap_linear.weight", "overlap_linear.bias",
    }
    if len(fddt_modules) != GRAPH_PINS["fddt_count"] or any(value != expected_suffixes for value in fddt_modules.values()):
        _fail("fddt_inventory", "FDDT module count or four-channel tensor layout differs")
    fddt_parameters = sum(tensors[name]["parameters"] for name in fddt_names)
    if fddt_parameters != GRAPH_PINS["fddt_parameters"]:
        _fail("fddt_parameters", "FDDT parameter total differs")

    ctc_markers = (".lm_head.", ".additional_layer.", ".additional_self_attention_layer.", ".subsample_conv")
    ctc_names = [name for name in tensors if any(marker in name for marker in ctc_markers)]
    ctc_parameters = sum(tensors[name]["parameters"] for name in ctc_names)
    if len(ctc_names) != GRAPH_PINS["ctc_tensor_count"] or ctc_parameters != GRAPH_PINS["ctc_parameters"]:
        _fail("ctc_inventory", "CTC tensor count or parameter total differs")
    return {
        "file": record,
        "tensor_count": parsed["tensor_count"],
        "parameter_count": parsed["parameter_count"],
        "dtype": "F32",
        "source_key_prefix": "model.",
        "fddt": {
            "module_count": len(fddt_modules),
            "tensor_count": len(fddt_names),
            "parameters": fddt_parameters,
            "channel_order": list(GRAPH_PINS["fddt_channel_order"]),
        },
        "ctc": {"tensor_count": len(ctc_names), "parameters": ctc_parameters, "keys": sorted(ctc_names)},
        "encoder_position_tensor": {
            "key": position_pin["source_key"],
            "shape": list(position_pin["shape"]),
            "dtype": "F32",
            "bytes": position_bytes,
            "sha256": position_sha,
        },
    }


def safe_tar_inventory(path: Path) -> Sequence[Dict[str, Any]]:
    """Return a safe archive inventory and reject extraction hazards."""

    _reject_symlink_components(path, "speech archive")
    result = []
    seen = set()
    try:
        archive = tarfile.open(path, mode="r:gz")
    except (tarfile.TarError, OSError) as error:
        _fail("archive_open", "cannot inspect speech archive: {}".format(error))
    with archive:
        for member in archive.getmembers():
            name = member.name
            pure = PurePosixPath(name)
            if not name or pure.is_absolute() or ".." in pure.parts or "" in pure.parts:
                _fail("unsafe_archive_path", "unsafe archive member {!r}".format(name))
            normalized = pure.as_posix().rstrip("/")
            if normalized in seen:
                _fail("duplicate_archive_path", "archive repeats {}".format(normalized))
            seen.add(normalized)
            if member.issym() or member.islnk() or member.isdev() or member.isfifo():
                _fail("unsafe_archive_type", "archive member {} is not a file or directory".format(normalized))
            if not member.isfile() and not member.isdir():
                _fail("unsafe_archive_type", "archive member {} has an unsupported type".format(normalized))
            result.append({
                "path": normalized,
                "type": "file" if member.isfile() else "directory",
                "bytes": member.size,
                "mode": "0{:03o}".format(member.mode & 0o777),
            })
    if not result:
        _fail("archive_empty", "speech archive is empty")
    executable_candidates = [item for item in result if item["type"] == "file" and PurePosixPath(item["path"]).name == "speech"]
    if len(executable_candidates) != 1 or int(executable_candidates[0]["mode"], 8) & 0o111 == 0:
        _fail("archive_executable", "archive must contain exactly one executable named speech")
    return result


def verify_community_inventory(root: Path) -> Dict[str, Any]:
    inventory = _inventory(root, "Community-1 snapshot")
    if set(inventory) != set(COMMUNITY_FILES):
        _fail("community_allowlist", "Community-1 snapshot is not the exact fourteen-file allowlist")
    for name, (size, digest) in COMMUNITY_FILES.items():
        if inventory[name] != {"bytes": size, "sha256": digest}:
            _fail("community_hash", "Community-1 file {} differs from the pin".format(name))
    return {"revision": MODEL_PINS["diarizer"]["revision"], "file_count": 14, "files": inventory}


def verify_fleurs_inventory(root: Path) -> Dict[str, Any]:
    inventory = _inventory(root, "FLEURS snapshot")
    if set(inventory) != set(FLEURS_FILES):
        _fail("fleurs_allowlist", "FLEURS snapshot is not the exact three-file allowlist")
    for name, size in FLEURS_FILES.items():
        if inventory[name]["bytes"] != size:
            _fail("fleurs_size", "FLEURS file {} has the wrong size".format(name))
    return {"revision": MODEL_PINS["fleurs"]["revision"], "file_count": 3, "files": inventory}


def verify_speech_archive(path: Path) -> Dict[str, Any]:
    expected = MODEL_PINS["diarizer"]["archive"]
    actual = _record(path, "speech archive")
    if actual != {"bytes": expected["bytes"], "sha256": expected["sha256"]}:
        _fail("speech_archive_hash", "speech archive size or SHA-256 differs")
    return {"file": actual, "members": safe_tar_inventory(path)}


def verify_license(run: Path) -> Dict[str, Any]:
    """Read-only verification of T12's materialized license audit."""

    manifest = _json(run / "canonical.json", "license canonical selector")
    expected_manifest_fields = {
        "schema_version",
        "model_id",
        "revision",
        "license_field_conflict",
        "repository_license_file",
        "local_derivative_allowed",
        "redistribution_or_bundling_allowed",
        "training_list_findings",
        "fixture_demotions",
        "author_question",
        "evidence",
    }
    if set(manifest) != expected_manifest_fields:
        _fail("license_schema", "license audit field set differs from the exact schema")
    if manifest.get("schema_version") != "dicow-license-audit-v1":
        _fail("license_schema", "unexpected license audit schema")
    if manifest.get("model_id") != MODEL_PINS["dicow"]["model_id"] or manifest.get("revision") != MODEL_PINS["dicow"]["revision"]:
        _fail("license_revision", "license audit is not pinned to the DiCoW revision")
    if manifest.get("license_field_conflict") != "cc_by_4_0_vs_apache_2_0":
        _fail("license_conflict", "license audit does not preserve the pinned conflicting fields")
    if manifest.get("repository_license_file") not in ("present", "absent"):
        _fail("license_presence", "repository LICENSE presence is not typed")
    decisions = ("allowed", "forbidden", "ambiguous")
    if manifest.get("local_derivative_allowed") not in decisions:
        _fail("license_decision", "license audit lacks a typed local-derivative decision")
    if manifest.get("redistribution_or_bundling_allowed") not in decisions:
        _fail("license_decision", "license audit lacks a separate redistribution-or-bundling decision")
    training = manifest.get("training_list_findings")
    if not isinstance(training, dict) or set(training) != {"mlc_slm", "in1009", "hike"}:
        _fail("training_status", "training-list finding set differs")
    if any(value not in ("excluded", "included", "unknown") for value in training.values()):
        _fail("training_status", "training-list findings must use the frozen typed values")
    demotions = manifest.get("fixture_demotions")
    if (
        not isinstance(demotions, list)
        or any(not isinstance(value, str) or not value for value in demotions)
        or len(demotions) != len(set(demotions))
    ):
        _fail("fixture_demotions", "fixture demotions must be a unique string list")
    if manifest.get("author_question") != {"drafted": True, "sent": False}:
        _fail("author_question", "the author question must be drafted and provably unsent")
    evidence = manifest.get("evidence")
    if not isinstance(evidence, list) or len(evidence) != len(LICENSE_EVIDENCE_ROLES):
        _fail("license_evidence", "license audit evidence coverage differs")
    records = []
    roles = set()
    paths = set()
    for entry in evidence:
        if not isinstance(entry, dict) or set(entry) != {"bytes", "path", "role", "sha256", "source"}:
            _fail("license_evidence", "license evidence entry has an unexpected shape")
        if entry["role"] not in LICENSE_EVIDENCE_ROLES or entry["role"] in roles:
            _fail("license_evidence", "license evidence role is missing, duplicated, or unapproved")
        if not isinstance(entry["source"], str) or not entry["source"]:
            _fail("license_evidence", "license evidence source is empty")
        if not isinstance(entry["path"], str):
            _fail("license_path", "license evidence path is not a string")
        relative = PurePosixPath(entry["path"])
        if not entry["path"] or relative.is_absolute() or ".." in relative.parts or relative.as_posix() in paths:
            _fail("license_path", "license evidence path is unsafe")
        path = run / relative.as_posix()
        actual = _record(path, "license evidence {}".format(relative))
        if actual != {"bytes": entry["bytes"], "sha256": entry["sha256"]}:
            _fail("license_hash", "license evidence {} differs".format(relative))
        roles.add(entry["role"])
        paths.add(relative.as_posix())
        records.append(dict(entry))
    if roles != set(LICENSE_EVIDENCE_ROLES):
        _fail("license_evidence", "license audit does not cover every required evidence role exactly once")
    return {
        "schema_version": manifest["schema_version"],
        "local_derivative_allowed": manifest["local_derivative_allowed"],
        "redistribution_or_bundling_allowed": manifest["redistribution_or_bundling_allowed"],
        "training_list_findings": dict(training),
        "fixture_demotions": list(demotions),
        "author_question": dict(manifest["author_question"]),
        "evidence": records,
    }


def inspect_static_sources(snapshot: Path) -> Dict[str, Any]:
    """Verify FDDT placement/order and the absence of custom feature code."""

    encoder_raw, encoder_tree = _python_ast(snapshot / "encoder.py", "DiCoW encoder source")
    encoder_text = encoder_raw.decode("utf-8")
    fddt_classes = [node for node in encoder_tree.body if isinstance(node, ast.ClassDef) and node.name == "FDDT"]
    if len(fddt_classes) != 1:
        _fail("fddt_source", "encoder source must define FDDT exactly once")
    forwards = [node for node in fddt_classes[0].body if isinstance(node, ast.FunctionDef) and node.name == "forward"]
    if len(forwards) != 1:
        _fail("fddt_source", "FDDT must define forward exactly once")
    forward_compact = b"".join(_node_bytes(encoder_raw, forwards[0]).split()).decode("utf-8")
    channel_patterns = (
        "stno_mask[:,0,...]*self.silence_linear",
        "stno_mask[:,1,...]*self.target_linear",
        "stno_mask[:,2,...]*self.non_target_linear",
        "stno_mask[:,3,...]*self.overlap_linear",
    )
    positions = [forward_compact.find(fragment) for fragment in channel_patterns]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        _fail("stno_channel_order", "FDDT source does not prove silence,target,non_target,overlap order")
    initial = encoder_text.find("inputs_embeds = self.initial_fddt(inputs_embeds, stno_mask)")
    positions_add = encoder_text.find("hidden_states = inputs_embeds + embed_pos")
    loop = encoder_text.find("for idx, encoder_layer in enumerate(self.layers):")
    per_layer = encoder_text.find("hidden_states = self.fddts[idx](hidden_states, stno_mask)")
    layer_call = encoder_text.find("layer_outputs = encoder_layer(")
    if not (0 <= initial < positions_add < loop < per_layer < layer_call):
        _fail("fddt_placement", "FDDT insertion points differ from the frozen graph")
    function_names = {
        node.name for node in ast.walk(encoder_tree)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }
    custom_features = sorted(function_names.intersection({"log_mel_spectrogram", "mel_filters", "extract_features"}))
    if custom_features:
        _fail("custom_features", "embedded checkpoint source defines custom feature extraction")
    return {
        "channel_order": list(GRAPH_PINS["fddt_channel_order"]),
        "initial_before_positions": True,
        "per_layer_before_encoder_block": True,
        "soft_mask_arithmetic": True,
        "custom_feature_functions": [],
    }


def _safe_repo_path(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if not name or path.is_absolute() or ".." in path.parts or "" in path.parts:
        _fail("unsafe_repository_path", "unsafe repository path {!r}".format(name))
    return path


def _hf_snapshot_path(hf_home: Path, repo_id: str, revision: str, repo_type: str = "model") -> Path:
    prefix = "datasets--" if repo_type == "dataset" else "models--"
    return hf_home / "hub" / (prefix + repo_id.replace("/", "--")) / "snapshots" / revision


def _download_hf_files(
    repo_id: str,
    revision: str,
    files: Sequence[str],
    target: Path,
    *,
    repo_type: str = "model",
    require_repo_exact: bool = True,
) -> Dict[str, Any]:
    try:
        from huggingface_hub import HfApi, hf_hub_download
    except ImportError as error:
        _fail("huggingface_client", "pinned Hub client unavailable: {}".format(error))
    api = HfApi(endpoint="https://huggingface.co")
    actual_files = tuple(sorted(api.list_repo_files(repo_id, revision=revision, repo_type=repo_type)))
    expected_files = tuple(sorted(files))
    if require_repo_exact and actual_files != expected_files:
        _fail("repository_allowlist", "{} revision inventory differs from the frozen allowlist".format(repo_id))
    if not require_repo_exact and not set(expected_files).issubset(actual_files):
        _fail("repository_allowlist", "{} revision lacks a frozen allowlisted file".format(repo_id))
    target.mkdir(parents=True, exist_ok=False)
    for name in expected_files:
        relative = _safe_repo_path(name)
        destination = target / relative.as_posix()
        destination.parent.mkdir(parents=True, exist_ok=True)
        downloaded = Path(hf_hub_download(
            repo_id=repo_id,
            filename=name,
            revision=revision,
            repo_type=repo_type,
            local_dir=target,
            endpoint="https://huggingface.co",
        ))
        if downloaded != destination or not destination.is_file():
            _fail("repository_download", "Hub client resolved {} to an unexpected path".format(name))
    metadata = target / ".cache" / "huggingface"
    if metadata.exists():
        try:
            metadata.relative_to(target)
        except ValueError:
            _fail("repository_metadata", "Hub metadata escaped the staged snapshot")
        shutil.rmtree(metadata)
        cache_parent = target / ".cache"
        if cache_parent.exists() and not any(cache_parent.iterdir()):
            cache_parent.rmdir()
    inventory = _inventory(target, "{} snapshot".format(repo_id))
    if set(inventory) != set(expected_files):
        _fail("repository_inventory", "{} staged snapshot contains unexpected files".format(repo_id))
    return {"repo_id": repo_id, "revision": revision, "repo_type": repo_type, "files": inventory}


def _download_url(url: str, destination: Path) -> Dict[str, Any]:
    if destination.exists() or destination.is_symlink():
        _fail("preexisting_download", "download destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "maccheroni-dicow-e0/1"})
    try:
        response = urllib.request.urlopen(request, timeout=120)
        with response, destination.open("xb") as stream:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                stream.write(chunk)
    except (OSError, urllib.error.URLError) as error:
        _fail("download_failed", "{}: {}".format(url, error))
    return _record(destination, "download {}".format(url))


def _download_json(url: str, destination: Path) -> Mapping[str, Any]:
    _download_url(url, destination)
    return _json(destination, "downloaded JSON {}".format(url))


def _extract_tar_create_only(archive_path: Path, destination: Path, *, strip_first: bool = False) -> Sequence[Dict[str, Any]]:
    if destination.exists() or destination.is_symlink():
        _fail("preexisting_extraction", "archive destination already exists")
    destination.mkdir(parents=True, exist_ok=False)
    records = []
    seen = set()
    try:
        archive = tarfile.open(archive_path, "r:gz")
    except (tarfile.TarError, OSError) as error:
        _fail("archive_open", str(error))
    with archive:
        for member in archive.getmembers():
            pure = _safe_repo_path(member.name.rstrip("/"))
            parts = pure.parts[1:] if strip_first else pure.parts
            if not parts:
                continue
            relative = PurePosixPath(*parts)
            rendered = relative.as_posix()
            if rendered in seen:
                _fail("duplicate_archive_path", "archive repeats {}".format(rendered))
            seen.add(rendered)
            if member.issym() or member.islnk() or member.isdev() or member.isfifo():
                _fail("unsafe_archive_type", "archive contains unsafe {}".format(member.name))
            target = destination / rendered
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                if not target.is_dir():
                    _fail("archive_extract", "directory target is not a directory")
                target.chmod(member.mode & 0o777)
                records.append({"path": rendered, "type": "directory", "bytes": 0})
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    _fail("archive_extract", "cannot read {}".format(member.name))
                with source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                target.chmod(member.mode & 0o777)
                records.append({"path": rendered, "type": "file", "bytes": member.size})
            else:
                _fail("unsafe_archive_type", "unsupported archive member {}".format(member.name))
    return records


def _seal_tree(root: Path) -> None:
    for path in sorted(root.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            _fail("seal_symlink", "staged materialization contains a symlink")
        if stat.S_ISDIR(info.st_mode):
            path.chmod(0o555)
        elif stat.S_ISREG(info.st_mode):
            executable = stat.S_IMODE(info.st_mode) & 0o111
            path.chmod(0o555 if executable else 0o444)
        else:
            _fail("seal_special_file", "staged materialization contains a special file")
    root.chmod(0o555)


def _source_size(api: Any, repo_id: str, revision: str, files: Sequence[str], repo_type: str = "model") -> int:
    info = api.repo_info(repo_id, revision=revision, repo_type=repo_type, files_metadata=True)
    siblings = {entry.rfilename: entry for entry in info.siblings}
    if set(siblings) != set(files):
        _fail("repository_allowlist", "{} metadata inventory differs".format(repo_id))
    total = 0
    for name in files:
        size = getattr(siblings[name], "size", None)
        if not isinstance(size, int) or size < 0:
            _fail("resource_formula_unresolved", "{} lacks an exact size for {}".format(repo_id, name))
        total += size
    return total


def _write_attempt_json(path: Path, value: Mapping[str, Any]) -> None:
    data = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o444)
    try:
        os.write(descriptor, data)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _validate_retry_root(output: Path, preflight: Any) -> None:
    info = os.lstat(output)
    if not stat.S_ISDIR(info.st_mode):
        _fail("unresolved_partial_materialization", "E0 output is not an owned directory")
    entries = {path.name: path for path in output.iterdir()}
    if "attempts" not in entries or set(entries) - {"attempts", "prepare.lock"}:
        _fail("unresolved_partial_materialization", "E0 output contains unrecognized state")
    attempts = entries["attempts"]
    attempt_info = os.lstat(attempts)
    if not stat.S_ISDIR(attempt_info.st_mode):
        _fail("unresolved_partial_materialization", "E0 attempts path is not a directory")
    if "prepare.lock" in entries and not stat.S_ISREG(os.lstat(entries["prepare.lock"]).st_mode):
        _fail("unresolved_partial_materialization", "E0 lock path is not a regular file")
    for attempt in attempts.iterdir():
        if not stat.S_ISDIR(os.lstat(attempt).st_mode):
            _fail("unresolved_partial_materialization", "E0 attempt entry is not a directory")
        journal_path = attempt / "partial_materialization.json"
        if os.path.lexists(str(journal_path)):
            journal = preflight.strict_load_json(journal_path)
            if journal.get("status") != "rolled_back":
                _fail("unresolved_partial_materialization", "a prior promotion did not roll back completely")


def _find_mlx_base_source(run_root: Path) -> Path:
    fragment = _read(run_root / "env.d" / "T2-aligner.env", "T2 aligner fragment").decode("utf-8")
    values = {}
    for line in fragment.splitlines():
        if not line or "=" not in line:
            _fail("aligner_fragment", "invalid T2 aligner fragment")
        key, value = line.split("=", 1)
        if key in values:
            _fail("aligner_fragment", "duplicate T2 aligner key")
        values[key] = value
    venv = Path(values.get("DICOW_ALIGNER_VENV", ""))
    _reject_symlink_components(venv, "aligner venv")
    candidates = list(venv.glob("lib/python*/site-packages/mlx_audio"))
    if len(candidates) != 1 or not candidates[0].is_dir():
        _fail("mlx_base_source", "cannot locate the pinned mlx-audio package source")
    return candidates[0]


def _inspection_from_paths(
    paths: Mapping[str, Path],
    reused_symbols: Iterable[str],
    implementation_source: str = "mlx-audio-0.4.6",
) -> Dict[str, Any]:
    t2 = verify_source_metadata(paths["t2_source_metadata"])
    source_match = verify_full_source_matches_t2(paths["dicow_snapshot"], t2)
    configuration = verify_configuration(paths["dicow_snapshot"])
    tokenizer = verify_tokenizer_inventory(paths["dicow_snapshot"])
    source_graph = inspect_static_sources(paths["dicow_snapshot"])
    ctc = inspect_ctc_source(paths["dicow_snapshot"])
    checkpoint = inspect_checkpoint(paths["dicow_snapshot"] / MODEL_PINS["dicow"]["model_file"]["path"])
    validate_reuse_declaration(reused_symbols)
    mlx = compare_mlx_symbols(paths["mlx_base_source"], paths["mlx_conditional_source"])
    validate_mlx_source_selection(implementation_source, mlx)
    mlx["implementation_source"] = implementation_source
    mlx["installed_source_fingerprint"] = verify_mlx_base_install(paths["mlx_base_source"])
    community = verify_community_inventory(paths["community_snapshot"])
    fleurs = verify_fleurs_inventory(paths["fleurs_snapshot"])
    speech = verify_speech_archive(paths["speech_archive"])
    return {
        "schema_version": SCHEMA_VERSION,
        "model_id": MODEL_PINS["dicow"]["model_id"],
        "revision": MODEL_PINS["dicow"]["revision"],
        "source_match": source_match,
        "configuration": configuration,
        "tokenizer": tokenizer,
        "source_graph": source_graph,
        "checkpoint": checkpoint,
        "ctc": ctc,
        "mlx": mlx,
        "community": community,
        "fleurs": fleurs,
        "speech_archive": speech,
        "evidence_outcome": "evidence_blocker",
        "branch_verdict": "revise",
        "blocker_code": "ctc_zero_call_rule_unsatisfied",
    }


def _prepared_manifest(output: Path) -> Mapping[str, Any]:
    canonical = _json(output / "canonical.json", "E0 canonical selector")
    expected_fields = {
        "schema_version", "run_id", "run_root", "attempt_fingerprint", "attempt_root",
        "paths", "mlx_reused_symbols", "mlx_implementation_source", "inspection_sha256",
        "inspection_outcome", "inspection_verdict", "inspection_blocker", "runtime_bindings",
        "resource", "resource_policy", "future_resource_ledger", "host", "acquisitions",
        "promotion_records", "promotion_final_paths", "promotion_staged_paths",
    }
    if set(canonical) != expected_fields:
        _fail("e0_schema", "E0 canonical field set differs from the exact schema")
    if canonical.get("schema_version") != "dicow-e0-preflight-v1":
        _fail("e0_schema", "unexpected E0 canonical schema")
    if (
        canonical.get("inspection_outcome") != "evidence_blocker"
        or canonical.get("inspection_verdict") != "revise"
        or canonical.get("inspection_blocker") != "ctc_zero_call_rule_unsatisfied"
    ):
        _fail("e0_schema", "E0 canonical must preserve the frozen CTC blocker")
    if canonical.get("mlx_reused_symbols") != list(REUSED_MLX_SYMBOLS):
        _fail("e0_schema", "E0 canonical MLX reused-symbol set differs")
    if canonical.get("mlx_implementation_source") != "mlx-audio-0.4.6":
        _fail("e0_schema", "E0 canonical MLX implementation source differs")
    if not isinstance(canonical.get("inspection_sha256"), str) or not re.fullmatch(
        r"[0-9a-f]{64}", canonical["inspection_sha256"]
    ):
        _fail("e0_schema", "E0 canonical inspection hash is absent or invalid")
    fingerprint = canonical.get("attempt_fingerprint")
    attempt_root = canonical.get("attempt_root")
    if (
        not isinstance(fingerprint, str)
        or not re.fullmatch(r"[0-9a-f]{64}", fingerprint)
        or not isinstance(attempt_root, str)
        or Path(attempt_root).parent != output / "attempts"
        or not re.fullmatch(re.escape(fingerprint) + r"-[0-9]{4}", Path(attempt_root).name)
    ):
        _fail("e0_schema", "E0 canonical attempt binding differs")
    return canonical


def _attempt_fingerprint_payload(
    preflight: Any,
    run_root: Path,
    runtime_roots: Mapping[str, Path],
) -> Dict[str, Any]:
    expected_runtime_names = {
        "run_root", "hf_home", "speech_cache", "speech_runtime", "cache_root", "t9_fragment"
    }
    if set(runtime_roots) != expected_runtime_names:
        _fail("attempt_fingerprint", "attempt fingerprint runtime-root set differs")
    ledger = run_root / "e0-resource-ledger.json"
    return {
        "schema_version": "dicow-e0-attempt-fingerprint-v1",
        "pins": {
            "dicow": MODEL_PINS["dicow"],
            "vanilla": MODEL_PINS["vanilla_control"],
            "aligner": MODEL_PINS["reference_aligner"],
            "conditional_mlx": MODEL_PINS["conditional_mlx_source"],
            "diarizer": MODEL_PINS["diarizer"],
            "fleurs": MODEL_PINS["fleurs"],
        },
        "runtime_roots": {name: str(runtime_roots[name]) for name in sorted(runtime_roots)},
        "inspect_sha256": _sha256(Path(__file__).resolve(), "inspect source"),
        "preflight_sha256": _sha256(Path(preflight.__file__).resolve(), "preflight source"),
        "t2_manifest_sha256": _sha256(run_root / "t2-source-metadata" / "manifest.json", "T2 source manifest"),
        "future_resource_ledger_sha256": (
            _sha256(ledger, "E0 future resource ledger") if ledger.exists() else "missing"
        ),
    }


def _attempt_fingerprint(payload: Mapping[str, Any]) -> str:
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _verify_launcher_bindings(
    preflight: Any,
    output: Path,
    canonical: Mapping[str, Any],
) -> Dict[str, Path]:
    environment_names = {
        "DICOW_RUN_ROOT": "run_root",
        "HF_HOME": "hf_home",
        "DICOW_SPEECH_CACHE": "speech_cache",
        "DICOW_SPEECH_RUNTIME_ROOT": "speech_runtime",
        "DICOW_CACHE_ROOT": "cache_root",
    }
    values = {target: os.environ.get(source) for source, target in environment_names.items()}
    if any(not value for value in values.values()):
        _fail("missing_environment", "verify requires the five launcher-fixed runtime roots")
    runtime_roots = {
        name: preflight.validate_runtime_path(
            Path(value), name, must_exist=name in {"run_root", "cache_root"}
        )
        for name, value in values.items()
    }
    runtime_roots["t9_fragment"] = preflight.validate_runtime_path(
        runtime_roots["run_root"] / "env.d" / "T9-diarizer.env",
        "t9_fragment",
        must_exist=False,
    )
    run_root = runtime_roots["run_root"]
    if output != run_root / "e0-preflight" or canonical.get("run_root") != str(run_root):
        _fail("run_binding", "canonical E0 output/run root differs from the launcher environment")
    final_paths = canonical.get("promotion_final_paths")
    expected_final_paths = {
        "hf-home": str(runtime_roots["hf_home"]),
        "speech-cache": str(runtime_roots["speech_cache"]),
        "speech-runtime": str(runtime_roots["speech_runtime"]),
        "T9-diarizer.env": str(runtime_roots["t9_fragment"]),
    }
    if final_paths != expected_final_paths:
        _fail("run_binding", "promotion final paths differ from launcher-fixed roots")
    attempt_root = Path(canonical["attempt_root"])
    expected_staged_paths = {
        name: str(attempt_root / "promotions" / name) for name in expected_final_paths
    }
    if canonical.get("promotion_staged_paths") != expected_staged_paths:
        _fail("run_binding", "promotion staged paths differ from the fingerprinted attempt")
    expected_paths = {
        "dicow_snapshot": _hf_snapshot_path(
            runtime_roots["hf_home"], MODEL_PINS["dicow"]["model_id"], MODEL_PINS["dicow"]["revision"]
        ),
        "t2_source_metadata": run_root / "t2-source-metadata",
        "mlx_base_source": _find_mlx_base_source(run_root),
        "mlx_conditional_source": attempt_root / "sources" / "mlx-audio-conditional",
        "community_snapshot": runtime_roots["speech_cache"] / "qwen3-speech" / "models" / "aufklarer" / "Pyannote-Community-1-CoreML",
        "fleurs_snapshot": _hf_snapshot_path(
            runtime_roots["hf_home"], MODEL_PINS["fleurs"]["model_id"], MODEL_PINS["fleurs"]["revision"], "dataset"
        ),
        "speech_archive": attempt_root / "evidence" / MODEL_PINS["diarizer"]["archive"]["name"],
    }
    if canonical.get("paths") != {name: str(path) for name, path in expected_paths.items()}:
        _fail("run_binding", "inspection paths differ from launcher-fixed roots and attempt")
    payload = _attempt_fingerprint_payload(preflight, run_root, runtime_roots)
    if canonical.get("attempt_fingerprint") != _attempt_fingerprint(payload):
        _fail("attempt_fingerprint", "canonical attempt fingerprint is stale or differs")
    return runtime_roots


def _resource_policy_from_spec(spec: Any) -> Any:
    from benchmarks.scripts.dicow.common import preflight
    if not isinstance(spec, dict) or set(spec) != {"components", "required_names"}:
        _fail("resource_policy_evidence", "canonical resource policy shape differs")
    rows = spec["components"]
    names = spec["required_names"]
    if not isinstance(rows, list) or not isinstance(names, list):
        _fail("resource_policy_evidence", "canonical resource policy lists are invalid")
    components = []
    for row in rows:
        if not isinstance(row, dict) or set(row) != {
            "name", "category", "declared_bytes", "final_path", "expected_record", "staging_group", "record_kind"
        }:
            _fail("resource_policy_evidence", "canonical resource component shape differs")
        components.append(preflight.ResourceComponent(
            row["name"], row["category"], row["declared_bytes"], Path(row["final_path"]),
            expected_record=row["expected_record"], staging_group=row["staging_group"],
            record_kind=row["record_kind"],
        ))
    return preflight.ResourcePolicy(tuple(components), tuple(names))


def _resource_component_evidence(component: Any) -> Dict[str, Any]:
    return {
        "name": component.name,
        "category": component.category,
        "declared_bytes": component.declared_bytes,
        "final_path": str(component.final_path),
        "expected_record": component.expected_record,
        "staging_group": component.staging_group,
        "record_kind": component.record_kind,
    }


def _future_resource_components(
    preflight: Any,
    ledger_path: Path,
    expected_ledger_record: Mapping[str, Any],
    *,
    expected_run_id: str,
    run_root: Path,
) -> Tuple[Any, ...]:
    required = {
        "mlx_environment": "environment",
        "control_named_goldens": "named_golden",
        "dicow_named_goldens": "named_golden",
    }
    ledger = _json(ledger_path, "E0 future resource ledger")
    rows = ledger.get("components") if isinstance(ledger, Mapping) else None
    if isinstance(rows, list):
        mlx_rows = [row for row in rows if isinstance(row, Mapping) and row.get("name") == "mlx_environment"]
        if len(mlx_rows) == 1 and not isinstance(mlx_rows[0].get("expected_record"), Mapping):
            _fail("working_set_unresolved", "MLX environment lacks a sealed expected record")
        expected_row_fields = {
            "name", "category", "final_path", "expected_record", "staging_group",
            "record_kind", "provenance", "derivation",
        }
        if any(not isinstance(row, Mapping) or set(row) != expected_row_fields for row in rows):
            _fail("resource_formula_unresolved", "future resource ledger contains a self-asserted or unknown field")
    try:
        mlx_environment = preflight.sealed_venv_component_from_state(
            run_root / "task-state" / "T8R.json",
            "DICOW_MLX_VENV",
            "mlx_environment",
            expected_task="T8R",
            expected_run_id=expected_run_id,
        )
        return tuple(preflight.parse_resource_ledger_v2(
            ledger_path,
            expected_ledger_record=expected_ledger_record,
            required_names=required,
            expected_final_paths={
                "mlx_environment": mlx_environment.final_path,
                "control_named_goldens": run_root / "t22-control-goldens",
                "dicow_named_goldens": run_root / "t24-dicow-goldens",
            },
            expected_task="T8R",
            expected_run_id=expected_run_id,
            expected_provenance_path=run_root / "task-state" / "T8R.json",
        ))
    except preflight.PreflightError as error:
        raise InspectionError(error.code, error.detail, error.evidence_outcome, error.branch_verdict)


def _verify_future_resource_replay(
    preflight: Any,
    output: Path,
    canonical: Mapping[str, Any],
    resource_policy: Any,
    expected_run_id: str,
) -> Dict[str, Any]:
    binding = canonical.get("future_resource_ledger")
    if not isinstance(binding, dict) or set(binding) != {"path", "record"}:
        _fail("resource_ledger_replay", "canonical future resource ledger binding is missing")
    expected_path = output.parent / "e0-resource-ledger.json"
    if binding["path"] != str(expected_path):
        _fail("resource_ledger_replay", "future resource ledger path differs from the fixed run path")
    try:
        actual_record = preflight.file_record(expected_path, immutable=True)
    except preflight.PreflightError as error:
        raise InspectionError(error.code, error.detail, error.evidence_outcome, error.branch_verdict)
    if actual_record != binding["record"]:
        _fail("resource_ledger_replay", "future resource ledger immutable record differs")
    derived = _future_resource_components(
        preflight,
        expected_path,
        actual_record,
        expected_run_id=expected_run_id,
        run_root=output.parent,
    )
    canonical_components = {item.name: item for item in resource_policy.components}
    for component in derived:
        canonical_component = canonical_components.get(component.name)
        if canonical_component is None or _resource_component_evidence(canonical_component) != _resource_component_evidence(component):
            _fail("resource_ledger_replay", "canonical resource component differs from T8R derivation: {}".format(component.name))
    return {"ledger": actual_record, "components": [_resource_component_evidence(item) for item in derived]}


def _verify_known_resource_replay(
    preflight: Any,
    output: Path,
    resource_policy: Any,
    expected_run_id: str,
) -> Dict[str, Any]:
    components = {item.name: item for item in resource_policy.components}
    source_names = {
        "dicow_snapshot", "vanilla_snapshot", "aligner_snapshot",
        "fleurs_snapshot", "community_snapshot",
    }
    for name in source_names:
        item = components.get(name)
        record = item.expected_record if item is not None else None
        expected_declared_bytes = record.get("payload_bytes") if isinstance(record, Mapping) else None
        if (
            item is None
            or item.category != "source"
            or item.record_kind != "immutable_artifact"
            or item.staging_group is not None
            or not isinstance(record, Mapping)
            or record.get("kind") != "tree"
            or item.declared_bytes != expected_declared_bytes
        ):
            _fail("resource_policy_replay", "source component is not derived from its exact tree: {}".format(name))

    cache_root_text = os.environ.get("DICOW_CACHE_ROOT")
    if not cache_root_text:
        _fail("missing_environment", "verify requires DICOW_CACHE_ROOT")
    cache_root = preflight.validate_runtime_path(Path(cache_root_text), "DICOW_CACHE_ROOT")
    reservations = cache_root / "resource-reservations" / expected_run_id
    expected = []
    for name, size in sorted(preflight.CONVERSION_PAYLOAD_BYTES.items()):
        expected.append(preflight.ResourceComponent(
            "converted_{}".format(name), "converted_output", size,
            reservations / "converted" / name,
        ))
        expected.append(preflight.ResourceComponent(
            "conversion_staging_{}".format(name), "staging", size,
            reservations / "staging" / "conversion" / name,
            staging_group="conversion_{}".format(name),
        ))
    expected.append(preflight.ResourceComponent(
        "download_staging_largest_payload",
        "staging",
        max(
            MODEL_PINS["dicow"]["model_file"]["bytes"],
            max(FLEURS_FILES.values()),
            MODEL_PINS["diarizer"]["archive"]["bytes"],
        ),
        reservations / "staging" / "download" / "largest-payload",
        staging_group="download_largest_payload",
    ))
    expected.extend((
        preflight.sealed_venv_component_from_state(
            output.parent / "task-state" / "T1.json",
            "DICOW_SCORING_VENV",
            "measured_dicow_scoring_venv",
            expected_task="T1",
            expected_run_id=expected_run_id,
        ),
        preflight.sealed_venv_component_from_state(
            output.parent / "task-state" / "T2.json",
            "DICOW_ALIGNER_VENV",
            "measured_dicow_aligner_venv",
            expected_task="T2",
            expected_run_id=expected_run_id,
        ),
        preflight.sealed_venv_component_from_state(
            output.parent / "task-state" / "T2.json",
            "DICOW_REFERENCE_VENV",
            "measured_dicow_reference_venv",
            expected_task="T2",
            expected_run_id=expected_run_id,
        ),
    ))
    for item in expected:
        canonical_item = components.get(item.name)
        if canonical_item is None or _resource_component_evidence(canonical_item) != _resource_component_evidence(item):
            _fail("resource_policy_replay", "known resource component differs: {}".format(item.name))
    expected_names = source_names | {item.name for item in expected} | {
        "mlx_environment", "control_named_goldens", "dicow_named_goldens",
    }
    if set(components) != expected_names:
        _fail("resource_policy_replay", "resource component coverage differs from the exact formula")
    return {"source_names": sorted(source_names), "derived_components": [_resource_component_evidence(item) for item in expected]}


def _probe_working_set(mlx_environment: Path) -> Dict[str, Any]:
    if not mlx_environment.is_dir():
        _fail("working_set_unresolved", "the sealed MLX environment is absent")
    python = mlx_environment / "bin" / "python"
    try:
        executable = python.resolve(strict=True)
    except OSError as error:
        _fail("working_set_unresolved", "cannot resolve MLX Python: {}".format(error))
    if not executable.is_file() or not os.access(executable, os.X_OK):
        _fail("working_set_unresolved", "MLX Python is not executable")
    probe_source = (
        "import json\n"
        "import mlx.core as mx\n"
        "print(json.dumps(mx.device_info(),sort_keys=True,separators=(',',':')))\n"
    )
    result = subprocess.run(
        [
            str(python),
            "-I",
            "-B",
            "-X",
            "pycache_prefix=/private/var/empty/maccheroni-pycache",
            "-c",
            probe_source,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/private/var/empty",
            "LC_ALL": "C",
            "PYTHONNOUSERSITE": "1",
        },
    )
    if result.returncode != 0 or result.stderr:
        _fail("working_set_probe", "pinned MLX device probe failed or wrote stderr")
    device = _parse_json_object(result.stdout, "MLX device probe")
    expected_fields = {
        "architecture",
        "device_name",
        "max_buffer_length",
        "max_recommended_working_set_size",
        "memory_size",
        "resource_limit",
    }
    if set(device) != expected_fields:
        _fail("working_set_probe", "MLX device field set differs")
    if any(not isinstance(device[name], str) or not device[name] for name in ("architecture", "device_name")):
        _fail("working_set_probe", "MLX device identity is invalid")
    for name in expected_fields - {"architecture", "device_name"}:
        if not isinstance(device[name], int) or isinstance(device[name], bool) or device[name] <= 0:
            _fail("working_set_probe", "MLX device numeric field {} is invalid".format(name))
    return dict(device)


def _host_facts(preflight: Any, mlx_environment: Path) -> Dict[str, Any]:
    memory_probe = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "hw.memsize"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
        check=False,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/private/var/empty", "LC_ALL": "C"},
    )
    if memory_probe.returncode != 0 or memory_probe.stderr or not memory_probe.stdout.strip().isdigit():
        _fail("physical_memory_probe", "cannot read hw.memsize cleanly")
    sandbox = preflight.verify_deny_network(
        Path("benchmarks/scripts/dicow/diarizer/deny-network.sb").resolve(),
        sandbox_exec=Path("/usr/bin/sandbox-exec"),
    )
    brew_path = Path("/opt/homebrew/bin/brew")
    if brew_path.is_file() and os.access(brew_path, os.X_OK):
        brew = subprocess.run(
            [str(brew_path), "list", "--versions", "speech"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
            check=False,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/private/var/empty", "LC_ALL": "C"},
        )
        brew_provenance = {
            "path": str(brew_path),
            "returncode": brew.returncode,
            "stdout": brew.stdout.strip(),
            "stderr": brew.stderr.strip(),
            "selects_runtime": False,
        }
    else:
        brew_provenance = {"path": str(brew_path), "status": "unavailable", "selects_runtime": False}
    return {
        "physical_memory_bytes": int(memory_probe.stdout.strip()),
        "concurrent_model_processes": 1,
        "mlx_device_info": _probe_working_set(mlx_environment),
        "sandbox": sandbox,
        "brew_speech_provenance": brew_provenance,
    }


def _verify_host_replay(expected: Any, actual: Mapping[str, Any]) -> None:
    if not isinstance(expected, dict) or set(expected) != set(actual):
        _fail("host_evidence", "canonical host fact set differs")
    if expected.get("mlx_device_info") != actual.get("mlx_device_info"):
        _fail("working_set_stale", "recomputed MLX device/working-set facts differ")
    if expected != actual:
        _fail("host_evidence", "recomputed physical-memory, sandbox, or brew facts differ")


def _verify_runtime_bindings(
    preflight: Any,
    bindings: Any,
    resource_policy: Any,
    promotion_final_paths: Mapping[str, Any],
) -> Dict[str, Any]:
    if not isinstance(bindings, dict) or set(bindings) != {"aligner", "community1"}:
        _fail("runtime_bindings", "runtime binding set differs")
    aligner = bindings["aligner"]
    community = bindings["community1"]
    if not isinstance(aligner, dict) or set(aligner) != {"model_id", "model_revision", "snapshot"}:
        _fail("runtime_bindings", "aligner binding shape differs")
    if not isinstance(community, dict) or set(community) != {
        "model_id", "model_revision", "binary", "model_tree", "sandbox_profile"
    }:
        _fail("runtime_bindings", "Community-1 binding shape differs")
    if (
        aligner["model_id"] != MODEL_PINS["reference_aligner"]["model_id"]
        or aligner["model_revision"] != MODEL_PINS["reference_aligner"]["revision"]
        or community["model_id"] != MODEL_PINS["diarizer"]["model_id"]
        or community["model_revision"] != MODEL_PINS["diarizer"]["revision"]
    ):
        _fail("runtime_revision", "runtime model ID or revision differs")
    named_components = {item.name: item for item in resource_policy.components}
    if "aligner_snapshot" not in named_components or "community_snapshot" not in named_components:
        _fail("runtime_bindings", "resource policy lacks runtime snapshot components")
    expected_paths = {
        "snapshot": named_components["aligner_snapshot"].final_path,
        "model_tree": named_components["community_snapshot"].final_path,
    }
    records = (("snapshot", aligner["snapshot"], True), ("model_tree", community["model_tree"], True))
    result: Dict[str, Any] = {"aligner": dict(aligner), "community1": dict(community)}
    for name, binding, immutable in records:
        if not isinstance(binding, dict) or set(binding) != {"path", "record"}:
            _fail("runtime_bindings", "{} binding shape differs".format(name))
        if not isinstance(binding["path"], str):
            _fail("runtime_path", "{} runtime path is not a string".format(name))
        path = Path(binding["path"])
        if path != expected_paths[name]:
            _fail("runtime_path", "{} runtime path differs from the resource policy".format(name))
        actual = preflight.artifact_record(path, immutable=immutable)
        if actual != binding["record"]:
            _fail("runtime_record", "{} runtime record differs".format(name))
    for name in ("binary", "sandbox_profile"):
        binding = community[name]
        if not isinstance(binding, dict) or set(binding) != {"path", "record"}:
            _fail("runtime_bindings", "{} binding shape differs".format(name))
        if not isinstance(binding["path"], str):
            _fail("runtime_path", "{} runtime path is not a string".format(name))
        path = Path(binding["path"])
        actual = preflight.artifact_record(path, immutable=name == "binary")
        if actual != binding["record"]:
            _fail("runtime_record", "{} runtime record differs".format(name))
    binary = Path(community["binary"]["path"])
    runtime_root = Path(promotion_final_paths["speech-runtime"])
    try:
        relative_binary = binary.relative_to(runtime_root)
    except ValueError:
        _fail("runtime_path", "speech binary is outside the promoted runtime")
    fragment = Path(promotion_final_paths["T9-diarizer.env"])
    expected_fragment = (
        "DICOW_SPEECH_BIN={}\nDICOW_SPEECH_BIN_RELATIVE_PATH={}\n".format(
            binary, relative_binary.as_posix()
        )
    ).encode("utf-8")
    if _read(fragment, "T9 diarizer fragment") != expected_fragment:
        _fail("runtime_fragment", "T9 diarizer fragment differs from the binary binding")
    return result


def verify(output: Path) -> Dict[str, Any]:
    """Read-only replay of a prepared E0 attempt."""

    canonical = _prepared_manifest(output)
    from benchmarks.scripts.dicow.common import preflight
    run_id = os.environ.get("DICOW_RUN_ID")
    if not run_id or canonical.get("run_id") != run_id:
        _fail("run_binding", "canonical E0 run binding differs from the launcher environment")
    try:
        _verify_launcher_bindings(preflight, output, canonical)
    except preflight.PreflightError as error:
        raise InspectionError(error.code, error.detail, error.evidence_outcome, error.branch_verdict)
    promotion_records = canonical.get("promotion_records")
    promotion_final_paths = canonical.get("promotion_final_paths")
    promotion_staged_paths = canonical.get("promotion_staged_paths")
    names = ("hf-home", "speech-cache", "speech-runtime", "T9-diarizer.env")
    if not all(isinstance(item, dict) and set(item) == set(names) for item in (promotion_records, promotion_final_paths, promotion_staged_paths)):
        _fail("promotion_evidence", "canonical promotion evidence is incomplete")
    attempt_root = Path(canonical.get("attempt_root", ""))
    promotions = tuple(
        preflight.Promotion(
            name,
            Path(promotion_staged_paths[name]),
            Path(promotion_final_paths[name]),
            promotion_records[name],
        )
        for name in names
    )
    try:
        preflight.verify_promotion(attempt_root, promotions, output / "canonical.json", canonical)
    except preflight.PreflightError as error:
        raise InspectionError(error.code, error.detail, error.evidence_outcome, error.branch_verdict)
    try:
        resource_policy = _resource_policy_from_spec(canonical.get("resource_policy"))
        future_resource_replay = _verify_future_resource_replay(
            preflight,
            output,
            canonical,
            resource_policy,
            run_id,
        )
        known_resource_replay = _verify_known_resource_replay(
            preflight,
            output,
            resource_policy,
            run_id,
        )
        resource_replay = preflight.calculate_required_free_bytes(resource_policy)
    except preflight.PreflightError as error:
        raise InspectionError(error.code, error.detail, error.evidence_outcome, error.branch_verdict)
    mlx_environments = [item for item in resource_policy.components if item.name == "mlx_environment"]
    if len(mlx_environments) != 1:
        _fail("working_set_unresolved", "resource policy does not name one sealed MLX environment")
    host_replay = _host_facts(preflight, mlx_environments[0].final_path)
    _verify_host_replay(canonical.get("host"), host_replay)
    paths = canonical.get("paths")
    if not isinstance(paths, dict):
        _fail("e0_paths", "canonical E0 paths are missing")
    required = {
        "dicow_snapshot", "t2_source_metadata", "mlx_base_source", "mlx_conditional_source",
        "community_snapshot", "fleurs_snapshot", "speech_archive",
    }
    if set(paths) != required:
        _fail("e0_paths", "canonical E0 path set differs from the allowlist")
    resolved: Dict[str, Path] = {}
    for key, value in paths.items():
        if not isinstance(value, str):
            _fail("e0_path", "{} is not a string path".format(key))
        resolved[key] = Path(value)
        _reject_symlink_components(resolved[key], key)
    try:
        runtime_replay = _verify_runtime_bindings(
            preflight,
            canonical.get("runtime_bindings"),
            resource_policy,
            promotion_final_paths,
        )
    except preflight.PreflightError as error:
        raise InspectionError(error.code, error.detail, error.evidence_outcome, error.branch_verdict)
    result = _inspection_from_paths(
        resolved,
        canonical.get("mlx_reused_symbols", ()),
        canonical.get("mlx_implementation_source", ""),
    )
    expected_sha = canonical["inspection_sha256"]
    actual_sha = hashlib.sha256(json.dumps(result, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if actual_sha != expected_sha:
        _fail("inspection_replay", "recomputed E0 inspection differs from canonical evidence")
    result["resource_replay"] = resource_replay
    result["future_resource_replay"] = future_resource_replay
    result["known_resource_replay"] = known_resource_replay
    result["host_replay"] = host_replay
    result["runtime_replay"] = runtime_replay
    return result


def prepare_e0(output: Path) -> Dict[str, Any]:
    """Acquire, inspect, seal, and promote the four E0 materializations once."""

    from benchmarks.scripts.dicow.common import preflight

    def translate(error: Exception) -> None:
        if isinstance(error, preflight.PreflightError):
            raise InspectionError(error.code, error.detail, error.evidence_outcome, error.branch_verdict)
        raise error

    try:
        output = preflight.validate_runtime_path(output, "E0 output", must_exist=False)
        run_root_text = os.environ.get("DICOW_RUN_ROOT")
        hf_home_text = os.environ.get("HF_HOME")
        speech_cache_text = os.environ.get("DICOW_SPEECH_CACHE")
        runtime_text = os.environ.get("DICOW_SPEECH_RUNTIME_ROOT")
        cache_root_text = os.environ.get("DICOW_CACHE_ROOT")
        run_id = os.environ.get("DICOW_RUN_ID")
        if not all((run_root_text, hf_home_text, speech_cache_text, runtime_text, cache_root_text, run_id)):
            _fail("missing_environment", "prepare-e0 requires the six pinned runtime values")
        run_root = preflight.validate_runtime_path(Path(run_root_text), "DICOW_RUN_ROOT")
        if output != run_root / "e0-preflight":
            _fail("output_path", "prepare-e0 output must be $DICOW_RUN_ROOT/e0-preflight")
        hf_home = preflight.validate_runtime_path(Path(hf_home_text), "HF_HOME", must_exist=False)
        speech_cache = preflight.validate_runtime_path(Path(speech_cache_text), "DICOW_SPEECH_CACHE", must_exist=False)
        runtime_root = preflight.validate_runtime_path(Path(runtime_text), "DICOW_SPEECH_RUNTIME_ROOT", must_exist=False)
        fragment = preflight.validate_runtime_path(run_root / "env.d" / "T9-diarizer.env", "T9 fragment", must_exist=False)

        output_preexisted = os.path.lexists(str(output))
        if (output / "canonical.json").exists():
            return verify(output)
        if output_preexisted:
            _validate_retry_root(output, preflight)
        for name, path in (("HF_HOME", hf_home), ("speech cache", speech_cache), ("speech runtime", runtime_root), ("T9 fragment", fragment)):
            if os.path.lexists(str(path)):
                _fail("preexisting_final", "{} already exists without a canonical E0 selector".format(name))
        if not output_preexisted:
            output.mkdir(parents=False, exist_ok=False)
        attempts = output / "attempts"
        attempts.mkdir(mode=0o700, exist_ok=True)
        runtime_roots = {
            "run_root": run_root,
            "hf_home": hf_home,
            "speech_cache": speech_cache,
            "speech_runtime": runtime_root,
            "cache_root": preflight.validate_runtime_path(Path(cache_root_text), "DICOW_CACHE_ROOT"),
            "t9_fragment": fragment,
        }
        fingerprint_payload = _attempt_fingerprint_payload(preflight, run_root, runtime_roots)
        fingerprint = _attempt_fingerprint(fingerprint_payload)
        lock_path = output / "prepare.lock"
        with preflight.SequentialProcessLock(lock_path, create=not lock_path.exists(), anchor=run_root):
            _validate_retry_root(output, preflight)
            sequence = 1
            while True:
                attempt = attempts / "{}-{:04d}".format(fingerprint, sequence)
                if not os.path.lexists(str(attempt)):
                    attempt.mkdir(mode=0o700)
                    break
                sequence += 1
            staged_hf = attempt / "promotions" / "hf-home"
            staged_speech = attempt / "promotions" / "speech-cache"
            staged_runtime = attempt / "promotions" / "speech-runtime"
            staged_fragment = attempt / "promotions" / "T9-diarizer.env"
            staged_hf.parent.mkdir(parents=True)
            staged_hf.mkdir()
            staged_speech.mkdir()

            try:
                from huggingface_hub import HfApi
            except ImportError as error:
                _fail("huggingface_client", str(error))
            api = HfApi(endpoint="https://huggingface.co")
            size_rows = {
                "dicow": _source_size(api, MODEL_PINS["dicow"]["model_id"], MODEL_PINS["dicow"]["revision"], DICOW_FILES),
                "vanilla": _source_size(api, MODEL_PINS["vanilla_control"]["model_id"], MODEL_PINS["vanilla_control"]["revision"], VANILLA_FILES),
                "aligner": _source_size(api, MODEL_PINS["reference_aligner"]["model_id"], MODEL_PINS["reference_aligner"]["revision"], ALIGNER_FILES),
                "fleurs": sum(FLEURS_FILES.values()),
                "community": sum(size for size, _ in COMMUNITY_FILES.values()),
            }
            source_components = tuple(
                preflight.ResourceComponent(name, "source", size, final)
                for name, size, final in (
                    ("dicow_snapshot", size_rows["dicow"], _hf_snapshot_path(hf_home, MODEL_PINS["dicow"]["model_id"], MODEL_PINS["dicow"]["revision"])),
                    ("vanilla_snapshot", size_rows["vanilla"], _hf_snapshot_path(hf_home, MODEL_PINS["vanilla_control"]["model_id"], MODEL_PINS["vanilla_control"]["revision"])),
                    ("aligner_snapshot", size_rows["aligner"], _hf_snapshot_path(hf_home, MODEL_PINS["reference_aligner"]["model_id"], MODEL_PINS["reference_aligner"]["revision"])),
                    ("fleurs_snapshot", size_rows["fleurs"], _hf_snapshot_path(hf_home, MODEL_PINS["fleurs"]["model_id"], MODEL_PINS["fleurs"]["revision"], "dataset")),
                    ("community_snapshot", size_rows["community"], speech_cache / "qwen3-speech" / "models" / "aufklarer" / "Pyannote-Community-1-CoreML"),
                )
            )
            cache_root = Path(cache_root_text)
            preflight.validate_runtime_path(cache_root, "DICOW_CACHE_ROOT")
            reservations = cache_root / "resource-reservations" / run_id
            conversion_facts = preflight.conversion_payload_regression()
            conversion_components = tuple(
                preflight.ResourceComponent(
                    "converted_{}".format(name), "converted_output", size,
                    reservations / "converted" / name,
                )
                for name, size in sorted(preflight.CONVERSION_PAYLOAD_BYTES.items())
            )
            conversion_staging = tuple(
                preflight.ResourceComponent(
                    "conversion_staging_{}".format(name), "staging", size,
                    reservations / "staging" / "conversion" / name,
                    staging_group="conversion_{}".format(name),
                )
                for name, size in sorted(preflight.CONVERSION_PAYLOAD_BYTES.items())
            )
            download_staging = (
                preflight.ResourceComponent(
                    "download_staging_largest_payload", "staging",
                    max(MODEL_PINS["dicow"]["model_file"]["bytes"], max(FLEURS_FILES.values()), MODEL_PINS["diarizer"]["archive"]["bytes"]),
                    reservations / "staging" / "download" / "largest-payload",
                    staging_group="download_largest_payload",
                ),
            )
            environment_components = (
                preflight.sealed_venv_component_from_state(
                    run_root / "task-state" / "T1.json",
                    "DICOW_SCORING_VENV",
                    "measured_dicow_scoring_venv",
                    expected_task="T1",
                    expected_run_id=run_id,
                ),
                preflight.sealed_venv_component_from_state(
                    run_root / "task-state" / "T2.json",
                    "DICOW_ALIGNER_VENV",
                    "measured_dicow_aligner_venv",
                    expected_task="T2",
                    expected_run_id=run_id,
                ),
                preflight.sealed_venv_component_from_state(
                    run_root / "task-state" / "T2.json",
                    "DICOW_REFERENCE_VENV",
                    "measured_dicow_reference_venv",
                    expected_task="T2",
                    expected_run_id=run_id,
                ),
            )
            known_components = source_components + conversion_components + conversion_staging + download_staging + environment_components
            known_policy = preflight.ResourcePolicy(known_components, tuple(item.name for item in known_components))
            resource_known = preflight.calculate_required_free_bytes(known_policy)
            missing_components = (
                "mlx_environment",
                "control_named_goldens",
                "dicow_named_goldens",
                "speech_runtime_extracted_payload",
            )
            future_ledger_path = run_root / "e0-resource-ledger.json"
            if not future_ledger_path.exists():
                incomplete = {
                    "schema_version": "dicow-e0-resource-incomplete-v1",
                    "known_resource_formula": resource_known,
                    "conversion_payload_regression": conversion_facts,
                    "missing_components": list(missing_components),
                    "evidence_outcome": "evidence_blocker",
                    "branch_verdict": "revise",
                    "code": "resource_formula_unresolved",
                }
                _write_attempt_json(attempt / "resource-incomplete.json", incomplete)
                _fail(
                    "resource_formula_unresolved",
                    "missing exact future component manifests: {}".format(", ".join(missing_components)),
                )
            future_ledger_record = preflight.file_record(future_ledger_path, immutable=True)
            if future_ledger_record.get("sha256") != fingerprint_payload["future_resource_ledger_sha256"]:
                _fail("resource_ledger_changed", "future resource ledger changed before the locked replay")
            future_components = _future_resource_components(
                preflight,
                future_ledger_path,
                future_ledger_record,
                expected_run_id=run_id,
                run_root=run_root,
            )
            components = known_components + future_components
            resource = preflight.calculate_required_free_bytes(
                preflight.ResourcePolicy(components, tuple(item.name for item in components))
            )
            resource["known_formula_before_future_ledger"] = resource_known
            resource["future_ledger"] = future_ledger_record
            resource["conversion_payload_regression"] = conversion_facts
            mlx_environment = next(item.final_path for item in future_components if item.name == "mlx_environment")
            host = _host_facts(preflight, mlx_environment)

            dicow_snapshot = _hf_snapshot_path(staged_hf, MODEL_PINS["dicow"]["model_id"], MODEL_PINS["dicow"]["revision"])
            vanilla_snapshot = _hf_snapshot_path(staged_hf, MODEL_PINS["vanilla_control"]["model_id"], MODEL_PINS["vanilla_control"]["revision"])
            aligner_snapshot = _hf_snapshot_path(staged_hf, MODEL_PINS["reference_aligner"]["model_id"], MODEL_PINS["reference_aligner"]["revision"])
            fleurs_snapshot = _hf_snapshot_path(staged_hf, MODEL_PINS["fleurs"]["model_id"], MODEL_PINS["fleurs"]["revision"], "dataset")
            acquisitions = {
                "dicow": _download_hf_files(MODEL_PINS["dicow"]["model_id"], MODEL_PINS["dicow"]["revision"], DICOW_FILES, dicow_snapshot),
                "vanilla": _download_hf_files(MODEL_PINS["vanilla_control"]["model_id"], MODEL_PINS["vanilla_control"]["revision"], VANILLA_FILES, vanilla_snapshot),
                "aligner": _download_hf_files(MODEL_PINS["reference_aligner"]["model_id"], MODEL_PINS["reference_aligner"]["revision"], ALIGNER_FILES, aligner_snapshot),
                "fleurs": _download_hf_files(
                    MODEL_PINS["fleurs"]["model_id"], MODEL_PINS["fleurs"]["revision"], tuple(FLEURS_FILES),
                    fleurs_snapshot, repo_type="dataset", require_repo_exact=False,
                ),
            }
            community_snapshot = staged_speech / "qwen3-speech" / "models" / "aufklarer" / "Pyannote-Community-1-CoreML"
            acquisitions["community"] = _download_hf_files(
                MODEL_PINS["diarizer"]["model_id"], MODEL_PINS["diarizer"]["revision"], tuple(COMMUNITY_FILES), community_snapshot
            )

            evidence = attempt / "evidence"
            evidence.mkdir()
            release = _download_json(SPEECH_RELEASE_API, evidence / "speech-release.json")
            tag = _download_json(SPEECH_TAG_API, evidence / "speech-tag.json")
            if (
                tag.get("ref") != "refs/tags/v0.0.26"
                or tag.get("object", {}).get("type") != "commit"
                or tag.get("object", {}).get("sha") != MODEL_PINS["diarizer"]["speech_tag_revision"]
            ):
                _fail("speech_release_revision", "speech tag does not resolve to the pinned commit")
            if release.get("tag_name") != "v0.0.26" or release.get("draft") is not False or release.get("prerelease") is not False:
                _fail("speech_release_revision", "speech release metadata does not identify the pinned final release")
            assets = [item for item in release.get("assets", []) if item.get("name") == MODEL_PINS["diarizer"]["archive"]["name"]]
            expected_asset_url = "https://github.com/soniqo/speech-swift/releases/download/v0.0.26/speech-macos-arm64.tar.gz"
            if (
                len(assets) != 1
                or assets[0].get("size") != MODEL_PINS["diarizer"]["archive"]["bytes"]
                or assets[0].get("browser_download_url") != expected_asset_url
            ):
                _fail("speech_release_asset", "speech release asset metadata differs")
            speech_archive = evidence / MODEL_PINS["diarizer"]["archive"]["name"]
            _download_url(assets[0]["browser_download_url"], speech_archive)
            verify_speech_archive(speech_archive)
            _extract_tar_create_only(speech_archive, staged_runtime)
            binary_candidates = [path for path in staged_runtime.rglob("speech") if path.is_file() and os.access(path, os.X_OK)]
            if len(binary_candidates) != 1:
                _fail("speech_binary", "extracted runtime must contain one executable speech binary")

            conditional_archive = evidence / "mlx-audio-conditional.tar.gz"
            _download_url(CONDITIONAL_MLX_ARCHIVE, conditional_archive)
            conditional_source = attempt / "sources" / "mlx-audio-conditional"
            _extract_tar_create_only(conditional_archive, conditional_source, strip_first=True)
            mlx_base = _find_mlx_base_source(run_root)
            mlx_comparison = compare_mlx_symbols(mlx_base, conditional_source)
            validate_mlx_source_selection("mlx-audio-0.4.6", mlx_comparison)

            speech_binary_relative = binary_candidates[0].relative_to(staged_runtime)
            speech_binary_final = runtime_root / speech_binary_relative
            staged_fragment.write_text(
                "DICOW_SPEECH_BIN={}\nDICOW_SPEECH_BIN_RELATIVE_PATH={}\n".format(
                    speech_binary_final,
                    speech_binary_relative.as_posix(),
                ),
                encoding="utf-8",
            )
            staged_fragment.chmod(0o444)
            for tree in (staged_hf, staged_speech, staged_runtime, evidence, conditional_source):
                _seal_tree(tree)

            staged_paths = {
                "dicow_snapshot": dicow_snapshot,
                "t2_source_metadata": run_root / "t2-source-metadata",
                "mlx_base_source": mlx_base,
                "mlx_conditional_source": conditional_source,
                "community_snapshot": community_snapshot,
                "fleurs_snapshot": fleurs_snapshot,
                "speech_archive": speech_archive,
            }
            inspection = _inspection_from_paths(staged_paths, REUSED_MLX_SYMBOLS, "mlx-audio-0.4.6")
            inspection_sha = hashlib.sha256(json.dumps(inspection, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

            records = {
                "hf-home": preflight.artifact_record(staged_hf, immutable=True),
                "speech-cache": preflight.artifact_record(staged_speech, immutable=True),
                "speech-runtime": preflight.artifact_record(staged_runtime, immutable=True),
                "T9-diarizer.env": preflight.artifact_record(staged_fragment, immutable=True),
            }
            source_expected_records = {
                "dicow_snapshot": preflight.artifact_record(dicow_snapshot, immutable=True),
                "vanilla_snapshot": preflight.artifact_record(vanilla_snapshot, immutable=True),
                "aligner_snapshot": preflight.artifact_record(aligner_snapshot, immutable=True),
                "fleurs_snapshot": preflight.artifact_record(fleurs_snapshot, immutable=True),
                "community_snapshot": preflight.artifact_record(community_snapshot, immutable=True),
                "speech_runtime": records["speech-runtime"],
            }
            resource_policy = {
                "components": [dict(
                    _resource_component_evidence(item),
                    expected_record=source_expected_records.get(item.name, item.expected_record),
                ) for item in components],
                "required_names": [item.name for item in components],
            }
            final_paths = {
                "dicow_snapshot": _hf_snapshot_path(hf_home, MODEL_PINS["dicow"]["model_id"], MODEL_PINS["dicow"]["revision"]),
                "t2_source_metadata": run_root / "t2-source-metadata",
                "mlx_base_source": mlx_base,
                "mlx_conditional_source": conditional_source,
                "community_snapshot": speech_cache / "qwen3-speech" / "models" / "aufklarer" / "Pyannote-Community-1-CoreML",
                "fleurs_snapshot": _hf_snapshot_path(hf_home, MODEL_PINS["fleurs"]["model_id"], MODEL_PINS["fleurs"]["revision"], "dataset"),
                "speech_archive": speech_archive,
            }
            canonical = {
                "schema_version": "dicow-e0-preflight-v1",
                "run_id": run_id,
                "run_root": str(run_root),
                "attempt_fingerprint": fingerprint,
                "attempt_root": str(attempt),
                "paths": {key: str(value) for key, value in final_paths.items()},
                "mlx_reused_symbols": list(REUSED_MLX_SYMBOLS),
                "mlx_implementation_source": "mlx-audio-0.4.6",
                "inspection_sha256": inspection_sha,
                "inspection_outcome": "evidence_blocker",
                "inspection_verdict": "revise",
                "inspection_blocker": "ctc_zero_call_rule_unsatisfied",
                "runtime_bindings": {
                    "aligner": {
                        "model_id": MODEL_PINS["reference_aligner"]["model_id"],
                        "model_revision": MODEL_PINS["reference_aligner"]["revision"],
                        "snapshot": {
                            "path": str(_hf_snapshot_path(
                                hf_home,
                                MODEL_PINS["reference_aligner"]["model_id"],
                                MODEL_PINS["reference_aligner"]["revision"],
                            )),
                            "record": source_expected_records["aligner_snapshot"],
                        },
                    },
                    "community1": {
                        "model_id": MODEL_PINS["diarizer"]["model_id"],
                        "model_revision": MODEL_PINS["diarizer"]["revision"],
                        "binary": {
                            "path": str(speech_binary_final),
                            "record": preflight.artifact_record(binary_candidates[0], immutable=True),
                        },
                        "model_tree": {
                            "path": str(speech_cache / "qwen3-speech" / "models" / "aufklarer" / "Pyannote-Community-1-CoreML"),
                            "record": source_expected_records["community_snapshot"],
                        },
                        "sandbox_profile": {
                            "path": str(Path("benchmarks/scripts/dicow/diarizer/deny-network.sb").resolve()),
                            "record": preflight.artifact_record(
                                Path("benchmarks/scripts/dicow/diarizer/deny-network.sb").resolve()
                            ),
                        },
                    },
                },
                "resource": resource,
                "resource_policy": resource_policy,
                "future_resource_ledger": {
                    "path": str(future_ledger_path),
                    "record": future_ledger_record,
                },
                "host": host,
                "acquisitions": acquisitions,
                "promotion_records": records,
                "promotion_final_paths": {
                    "hf-home": str(hf_home),
                    "speech-cache": str(speech_cache),
                    "speech-runtime": str(runtime_root),
                    "T9-diarizer.env": str(fragment),
                },
                "promotion_staged_paths": {
                    "hf-home": str(staged_hf),
                    "speech-cache": str(staged_speech),
                    "speech-runtime": str(staged_runtime),
                    "T9-diarizer.env": str(staged_fragment),
                },
            }
            promotions = (
                preflight.Promotion("hf-home", staged_hf, hf_home, records["hf-home"]),
                preflight.Promotion("speech-cache", staged_speech, speech_cache, records["speech-cache"]),
                preflight.Promotion("speech-runtime", staged_runtime, runtime_root, records["speech-runtime"]),
                preflight.Promotion("T9-diarizer.env", staged_fragment, fragment, records["T9-diarizer.env"]),
            )
            preflight.promote_create_only(attempt, promotions, output / "canonical.json", canonical)
            return verify(output)
    except preflight.PreflightError as error:
        translate(error)
    raise AssertionError("unreachable")


def validate_r2_model_identities(payload: Mapping[str, Any]) -> Dict[str, Any]:
    """Bind the four R3 model identities without downloading full checkpoints."""

    if not isinstance(payload, Mapping) or set(payload) != {"schema_version", "models"}:
        _fail("r2_identity_shape", "model identity envelope differs")
    if payload.get("schema_version") != "dicow-r2-model-identities-v1":
        _fail("r2_identity_shape", "model identity schema differs")
    rows = payload.get("models")
    if not isinstance(rows, list) or len(rows) != len(R2_EXACT_MODEL_IDENTITIES):
        _fail("r2_identity_coverage", "model identity coverage differs")
    normalized = {}
    for row in rows:
        expected_keys = {
            "candidate", "model_id", "revision", "model_file_bytes",
            "model_file_lfs_sha256", "content_range_total_bytes", "header_capture",
            "header_record", "header_inspection", "lfs_capture", "lfs_record",
        }
        if not isinstance(row, Mapping) or set(row) != expected_keys:
            _fail("r2_identity_shape", "model identity row shape differs")
        candidate = row.get("candidate")
        if candidate not in R2_EXACT_MODEL_IDENTITIES or candidate in normalized:
            _fail("r2_identity_coverage", "model identity is missing, extra, or duplicated")
        expected = R2_EXACT_MODEL_IDENTITIES[candidate]
        for key in ("model_id", "revision", "model_file_lfs_sha256"):
            if row.get(key) != expected[key]:
                _fail("r2_identity_drift", "{} {} differs".format(candidate, key))
        size = row.get("model_file_bytes")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 8:
            _fail("r2_identity_shape", "{} model size is invalid".format(candidate))
        if "model_file_bytes" in expected and size != expected["model_file_bytes"]:
            _fail("r2_identity_drift", "{} model payload bytes differ".format(candidate))
        if row.get("content_range_total_bytes") != size:
            _fail("r2_identity_drift", "{} Content-Range total differs".format(candidate))
        record = row.get("header_record")
        if (
            not isinstance(record, Mapping)
            or set(record) != {"bytes", "sha256"}
            or not isinstance(record.get("bytes"), int)
            or isinstance(record.get("bytes"), bool)
            or record["bytes"] <= 8
            or not isinstance(record.get("sha256"), str)
            or not re_full_sha256(record["sha256"])
        ):
            _fail("r2_identity_shape", "{} header record is invalid".format(candidate))
        if row.get("header_capture") != "headers/{}.safetensors.header".format(candidate):
            _fail("r2_identity_shape", "{} header capture path differs".format(candidate))
        inspection = row.get("header_inspection")
        if not isinstance(inspection, Mapping) or set(inspection) != {
            "header_length", "header_end", "tensor_count", "data_bytes", "tensor_signature_sha256",
        }:
            _fail("r2_identity_shape", "{} header inspection shape differs".format(candidate))
        if (
            any(not isinstance(inspection[key], int) or isinstance(inspection[key], bool) or inspection[key] <= 0 for key in ("header_length", "header_end", "tensor_count", "data_bytes"))
            or not isinstance(inspection.get("tensor_signature_sha256"), str)
            or not re_full_sha256(inspection["tensor_signature_sha256"])
        ):
            _fail("r2_identity_shape", "{} header inspection fields are invalid".format(candidate))
        if row.get("lfs_capture") != "lfs/{}.tree.json".format(candidate):
            _fail("r2_identity_shape", "{} LFS capture path differs".format(candidate))
        lfs_record = row.get("lfs_record")
        if not isinstance(lfs_record, Mapping) or set(lfs_record) != {"bytes", "sha256"} or not isinstance(lfs_record.get("bytes"), int) or lfs_record["bytes"] <= 0 or not re_full_sha256(str(lfs_record.get("sha256"))):
            _fail("r2_identity_shape", "{} LFS capture record is invalid".format(candidate))
        normalized[candidate] = dict(row)
    if set(normalized) != set(R2_EXACT_MODEL_IDENTITIES):
        _fail("r2_identity_coverage", "model identity roster differs")
    return {"schema_version": payload["schema_version"], "models": normalized}


def re_full_sha256(value: str) -> bool:
    return len(value) == 64 and all(character in "0123456789abcdef" for character in value)


def inspect_r2_safetensors_header(raw: bytes, *, total_file_bytes: int) -> Dict[str, Any]:
    """Inspect a range-fetched safetensors header and reject unsafe tensor layouts."""

    if not isinstance(raw, bytes) or len(raw) < 10:
        _fail("r2_safetensors_header", "header capture is truncated")
    if not isinstance(total_file_bytes, int) or isinstance(total_file_bytes, bool) or total_file_bytes <= len(raw):
        _fail("r2_safetensors_header", "total file size is invalid")
    header_length = struct.unpack("<Q", raw[:8])[0]
    header_end = 8 + header_length
    if header_length <= 2 or header_end != len(raw) or len(raw) > 16 * 1024 * 1024:
        _fail("r2_safetensors_header", "declared header is outside captured range")
    header = _parse_json_object(raw[8:header_end], "r2 safetensors header")
    data_bytes = total_file_bytes - header_end
    tensors = []
    names = [name for name in header if name != "__metadata__"]
    for name in names:
        row = header[name]
        if not isinstance(name, str) or not name or not isinstance(row, Mapping):
            _fail("r2_safetensors_header", "tensor entry is invalid")
        if set(row) != {"dtype", "shape", "data_offsets"}:
            _fail("r2_safetensors_header", "tensor {} fields differ".format(name))
        dtype = row.get("dtype")
        shape = row.get("shape")
        offsets = row.get("data_offsets")
        if dtype not in DTYPE_BYTES or not isinstance(shape, list) or not isinstance(offsets, list) or len(offsets) != 2:
            _fail("r2_safetensors_header", "tensor {} metadata is invalid".format(name))
        if any(not isinstance(item, int) or isinstance(item, bool) or item < 0 for item in shape + offsets):
            _fail("r2_safetensors_header", "tensor {} contains invalid integers".format(name))
        start, end = offsets
        expected_bytes = math.prod(shape) * DTYPE_BYTES[dtype]
        if end < start or end - start != expected_bytes or end > data_bytes:
            _fail("r2_safetensors_header", "tensor {} byte range differs from shape/dtype".format(name))
        tensors.append({"name": name, "dtype": dtype, "shape": shape, "start": start, "end": end})
    ordered = sorted(tensors, key=lambda item: (item["start"], item["end"], item["name"]))
    cursor = 0
    for tensor in ordered:
        if tensor["start"] != cursor:
            _fail("r2_safetensors_header", "tensor ranges overlap or leave an unauthenticated gap")
        cursor = tensor["end"]
    if cursor != data_bytes:
        _fail("r2_safetensors_header", "tensor ranges do not cover the exact file payload")
    return {
        "header_length": header_length,
        "header_end": header_end,
        "tensor_count": len(ordered),
        "data_bytes": data_bytes,
        "tensor_signature_sha256": hashlib.sha256(
            json.dumps(ordered, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
    }


def inspect_r2_hf_lfs_metadata(
    raw: bytes,
    *,
    expected_model_id: Optional[str] = None,
    expected_revision: Optional[str] = None,
) -> Dict[str, Any]:
    """Extract one model.safetensors LFS tuple from an official HF tree response."""

    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail("r2_lfs_metadata", "invalid HF tree JSON: {}".format(error))
    if expected_model_id is not None:
        if not isinstance(value, Mapping) or value.get("request_url") != "https://huggingface.co/api/models/{}/tree/{}".format(expected_model_id, expected_revision) or value.get("model_id") != expected_model_id or value.get("revision") != expected_revision or "response" not in value:
            _fail("r2_lfs_metadata", "HF tree request identity differs")
    matches = []
    def visit(item: Any) -> None:
        if isinstance(item, Mapping):
            path = item.get("path", item.get("rfilename"))
            lfs = item.get("lfs")
            if path == "model.safetensors" and isinstance(lfs, Mapping):
                oid = lfs.get("oid", lfs.get("sha256"))
                if isinstance(oid, str) and oid.startswith("sha256:"):
                    oid = oid[7:]
                size = lfs.get("size", item.get("size"))
                if isinstance(oid, str) and re_full_sha256(oid) and isinstance(size, int) and not isinstance(size, bool) and size > 8:
                    matches.append({"path": path, "sha256": oid, "size": size})
            for child in item.values():
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)
    visit(value)
    unique = {json.dumps(item, sort_keys=True) for item in matches}
    if len(unique) != 1:
        _fail("r2_lfs_metadata", "HF tree response must contain one exact model.safetensors LFS tuple")
    return json.loads(next(iter(unique)))


def validate_r2_graph_contracts(payload: Mapping[str, Any]) -> Dict[str, Any]:
    if isinstance(payload, Mapping) and payload.get("schema_version") == "dicow-r2-graph-states-v3":
        if set(payload) != {"schema_version", "ast_derivation", "candidates"}:
            _fail("r2_graph_shape", "graph state envelope differs")
        if payload.get("ast_derivation") != R2_GRAPH_AST_DERIVATION:
            _fail("r2_graph_runtime", "graph AST derivation runtime differs")
        rows = payload.get("candidates")
        if not isinstance(rows, list) or len(rows) != 2:
            _fail("r2_graph_coverage", "both DiCoW graph states are required")
        result = {}
        for row in rows:
            if not isinstance(row, Mapping) or set(row) != {
                "candidate", "state", "source_files", "source_ast_sha256",
                "established_semantics", "unestablished_semantics", "follow_up",
            }:
                _fail("r2_graph_shape", "candidate graph state shape differs")
            candidate = row.get("candidate")
            if candidate not in ("dicow_mlc", "dicow_v3_3") or candidate in result:
                _fail("r2_graph_coverage", "candidate graph state identity differs")
            if row.get("state") != "graph_equivalence_unestablished":
                _fail("r2_graph_semantics", "R3 cannot promote a DiCoW graph to comparable")
            files = row.get("source_files")
            if not isinstance(files, list) or not files:
                _fail("r2_graph_source_missing", "unestablished graph must still bind actual source tuples")
            paths = []
            for item in files:
                if (
                    not isinstance(item, Mapping) or set(item) != {"path", "bytes", "sha256"}
                    or not isinstance(item.get("path"), str)
                    or Path(item["path"]).suffix not in (".py", ".json")
                    or not isinstance(item.get("bytes"), int) or item["bytes"] <= 0
                    or not re_full_sha256(str(item.get("sha256")))
                ):
                    _fail("r2_graph_shape", "candidate source tuple is invalid")
                paths.append(item["path"])
            if len(paths) != len(set(paths)):
                _fail("r2_graph_shape", "candidate source tuples are duplicated")
            if candidate == "dicow_v3_3" and not {"FDDT.py", "layers.py"}.issubset({Path(item).name for item in paths}):
                _fail("r2_graph_source_missing", "v3.3 graph must bind FDDT.py and layers.py")
            digest = row.get("source_ast_sha256")
            if not isinstance(digest, str) or not re_full_sha256(digest):
                _fail("r2_graph_shape", "candidate source AST digest is invalid")
            if row.get("established_semantics") != {} or row.get("unestablished_semantics") != sorted(R2_EXTERNAL_GRAPH_CONTRACT):
                _fail("r2_graph_semantics", "R3 must preserve every graph semantic as unestablished")
            if not isinstance(row.get("follow_up"), str) or not row["follow_up"].strip():
                _fail("r2_graph_status", "unestablished graph must name the later cheap probe or proof")
            result[candidate] = dict(row)
        if set(result) != {"dicow_mlc", "dicow_v3_3"}:
            _fail("r2_graph_coverage", "candidate graph state roster differs")
        return {
            "schema_version": payload["schema_version"],
            "ast_derivation": dict(payload["ast_derivation"]),
            "candidates": result,
        }
    if not isinstance(payload, Mapping) or set(payload) != {"schema_version", "candidates"}:
        _fail("r2_graph_shape", "graph contract envelope differs")
    if payload.get("schema_version") != "dicow-r2-graph-contracts-v1":
        _fail("r2_graph_shape", "graph contract schema differs")
    _fail("r2_graph_semantics", "marker-derived comparable graph contracts are forbidden in R3")
    rows = payload.get("candidates")
    if not isinstance(rows, list) or len(rows) != 2:
        _fail("r2_graph_coverage", "both DiCoW candidates are required")
    result = {}
    for row in rows:
        if not isinstance(row, Mapping) or set(row) != {
            "candidate", "status", "external_contract", "source_files", "source_ast_sha256", "semantic_probes", "follow_up",
        }:
            _fail("r2_graph_shape", "candidate graph row shape differs")
        candidate = row.get("candidate")
        if candidate not in ("dicow_mlc", "dicow_v3_3") or candidate in result:
            _fail("r2_graph_coverage", "candidate graph identity differs")
        status = row.get("status")
        if status not in ("comparable", "excluded_with_named_follow_up"):
            _fail("r2_graph_status", "candidate graph status is invalid")
        if row.get("external_contract") != R2_EXTERNAL_GRAPH_CONTRACT:
            _fail("r2_graph_semantics", "{} external graph semantics differ".format(candidate))
        files = row.get("source_files")
        if not isinstance(files, list) or not files:
            _fail("r2_graph_shape", "{} graph source roster is invalid".format(candidate))
        paths = []
        for item in files:
            if (
                not isinstance(item, Mapping)
                or set(item) != {"path", "bytes", "sha256"}
                or not isinstance(item.get("path"), str)
                or Path(item["path"]).suffix not in (".py", ".json")
                or not isinstance(item.get("bytes"), int)
                or item["bytes"] <= 0
                or not re_full_sha256(str(item.get("sha256")))
            ):
                _fail("r2_graph_shape", "{} graph source tuple is invalid".format(candidate))
            paths.append(item["path"])
        if len(paths) != len(set(paths)):
            _fail("r2_graph_shape", "{} graph source roster is duplicated".format(candidate))
        if candidate == "dicow_v3_3" and not {"FDDT.py", "layers.py"}.issubset({Path(item).name for item in paths}):
            _fail("r2_graph_source_missing", "v3.3 graph must bind FDDT.py and layers.py")
        probes = row.get("semantic_probes")
        if not isinstance(probes, list) or len(probes) != len(R2_EXTERNAL_GRAPH_CONTRACT):
            _fail("r2_graph_semantics", "{} semantic probe coverage differs".format(candidate))
        probe_keys = set()
        for probe in probes:
            if not isinstance(probe, Mapping) or set(probe) != {"contract_key", "source", "json_pointer"}:
                _fail("r2_graph_semantics", "{} semantic probe shape differs".format(candidate))
            key = probe.get("contract_key")
            if key not in R2_EXTERNAL_GRAPH_CONTRACT or key in probe_keys:
                _fail("r2_graph_semantics", "{} semantic probe identity differs".format(candidate))
            probe_keys.add(key)
            if probe.get("source") not in files or not isinstance(probe.get("json_pointer"), list) or not probe["json_pointer"] or any(not isinstance(item, str) or not item for item in probe["json_pointer"]):
                _fail("r2_graph_semantics", "{} semantic probe authority differs".format(candidate))
        digest = row.get("source_ast_sha256")
        if not isinstance(digest, str) or not re_full_sha256(digest):
            _fail("r2_graph_shape", "{} source AST digest is invalid".format(candidate))
        follow_up = row.get("follow_up")
        if status == "excluded_with_named_follow_up":
            if not isinstance(follow_up, str) or not follow_up.strip():
                _fail("r2_graph_status", "excluded graph must name a follow-up")
        elif follow_up is not None:
            _fail("r2_graph_status", "comparable graph must not invent a follow-up")
        result[candidate] = dict(row)
    if set(result) != {"dicow_mlc", "dicow_v3_3"}:
        _fail("r2_graph_coverage", "candidate graph roster differs")
    return {"schema_version": payload["schema_version"], "candidates": result}


def validate_r2_leakage_decisions(payload: Mapping[str, Any]) -> Dict[str, Any]:
    """Apply one symmetric corpus exclusion rule to MLC and v3.3."""

    if isinstance(payload, Mapping) and payload.get("schema_version") == "dicow-r2-leakage-decisions-v2":
        if set(payload) != {"schema_version", "shared_base_claim_limitation", "rows", "korean_utility_basis", "claim_ceiling"}:
            _fail("r2_leakage_shape", "leakage decision envelope differs")
        limitation = payload.get("shared_base_claim_limitation")
        rows = payload.get("rows")
        required_pairs = {(candidate, corpus) for candidate in ("dicow_mlc", "dicow_v3_3") for corpus in ("hike", "fleurs_ko")}
        if not isinstance(limitation, str) or not limitation.strip() or not isinstance(rows, list) or len(rows) != 4:
            _fail("r2_leakage_shape", "leakage decision coverage differs")
        statuses = {}
        for row in rows:
            fields = {
                "candidate", "corpus", "canonical_dataset_id", "frozen_aliases", "derived_mixtures",
                "universe_kind", "disclosed_items", "generic_entries", "status", "reason",
                "base_claim_limitation", "training_evidence", "training_json_pointer", "extractor_id",
            }
            if not isinstance(row, Mapping) or set(row) != fields:
                _fail("r2_leakage_shape", "leakage row shape differs")
            pair = (row.get("candidate"), row.get("corpus"))
            if pair not in required_pairs or pair in statuses or row.get("base_claim_limitation") != limitation:
                _fail("r2_leakage_asymmetry", "leakage pair or shared limitation differs")
            if row.get("status") == "excluded":
                _fail("r2_leakage_claim", "R3 has no official complete-universe disclosure for exclusion")
            for key in ("frozen_aliases", "derived_mixtures", "disclosed_items", "generic_entries"):
                if not isinstance(row.get(key), list) or any(not isinstance(item, str) or not item.strip() for item in row[key]):
                    _fail("r2_leakage_shape", "{} must be a string list".format(key))
            evidence = row.get("training_evidence")
            pointer = row.get("training_json_pointer")
            if evidence == []:
                if pointer is not None or row.get("universe_kind") != "unavailable" or row.get("disclosed_items") or row.get("generic_entries"):
                    _fail("r2_leakage_claim", "unavailable disclosure cannot invent a universe")
            else:
                if (
                    not isinstance(evidence, list) or len(evidence) != 1
                    or not isinstance(evidence[0], Mapping) or set(evidence[0]) != {"path", "bytes", "sha256"}
                    or evidence[0].get("path") != "captures/training-{}.json".format(row["candidate"])
                    or not isinstance(pointer, list) or not pointer
                    or any(not isinstance(item, str) or not item for item in pointer)
                    or row.get("universe_kind") != "generic_or_incomplete"
                ):
                    _fail("r2_leakage_shape", "pinned incomplete disclosure evidence differs")
            if row.get("extractor_id") != "hf_pinned_card_datasets_incomplete_v1" or not isinstance(row.get("reason"), str) or not row["reason"].strip():
                _fail("r2_leakage_shape", "leakage extractor or reason differs")
            names = [row.get("canonical_dataset_id"), *row["frozen_aliases"], *row["derived_mixtures"]]
            if not all(isinstance(item, str) and item.strip() for item in names) or len(names) != len(set(names)):
                _fail("r2_leakage_shape", "corpus aliases differ")
            present = bool({item.casefold() for item in names} & {item.casefold() for item in row["disclosed_items"]})
            computed = "included" if present else "unknown"
            if row.get("status") != computed:
                _fail("r2_leakage_claim", "incomplete disclosure can establish inclusion or unknown only")
            statuses[pair] = computed
        if set(statuses) != required_pairs or payload.get("korean_utility_basis") != "unavailable" or payload.get("claim_ceiling") != "no_korean_utility_claim":
            _fail("r2_leakage_decision", "incomplete R3 disclosure must block the Korean utility basis")
        return {"statuses": statuses, "korean_utility_basis": "unavailable", "claim_ceiling": "no_korean_utility_claim"}

    if not isinstance(payload, Mapping) or set(payload) != {
        "schema_version", "shared_base_claim_limitation", "rows", "korean_utility_basis", "claim_ceiling",
    }:
        _fail("r2_leakage_shape", "leakage decision envelope differs")
    if payload.get("schema_version") != "dicow-r2-leakage-decisions-v1":
        _fail("r2_leakage_shape", "leakage decision schema differs")
    _fail("r2_leakage_claim", "v1 wrapper-declared training completeness is forbidden in R3")
    limitation = payload.get("shared_base_claim_limitation")
    if not isinstance(limitation, str) or not limitation.strip():
        _fail("r2_leakage_asymmetry", "shared Whisper-base limitation is required")
    rows = payload.get("rows")
    required_pairs = {(candidate, corpus) for candidate in ("dicow_mlc", "dicow_v3_3") for corpus in ("hike", "fleurs_ko")}
    if not isinstance(rows, list) or len(rows) != len(required_pairs):
        _fail("r2_leakage_coverage", "candidate/corpus coverage differs")
    statuses = {}
    for row in rows:
        expected = {
            "candidate", "corpus", "canonical_dataset_id", "frozen_aliases", "derived_mixtures",
            "universe_kind", "disclosed_items", "generic_entries", "status", "base_claim_limitation",
            "training_evidence", "training_json_pointer", "completeness_json_pointer", "extractor_id",
        }
        if not isinstance(row, Mapping) or set(row) != expected:
            _fail("r2_leakage_shape", "leakage row shape differs")
        pair = (row.get("candidate"), row.get("corpus"))
        if pair not in required_pairs or pair in statuses:
            _fail("r2_leakage_coverage", "leakage row is missing, extra, or duplicated")
        if row.get("base_claim_limitation") != limitation:
            _fail("r2_leakage_asymmetry", "base-pretraining limitation differs by row")
        names = [row.get("canonical_dataset_id")]
        evidence = row.get("training_evidence")
        if not isinstance(evidence, list) or len(evidence) != 1:
            _fail("r2_leakage_shape", "training evidence is required")
        for record in evidence:
            if not isinstance(record, Mapping) or set(record) != {"path", "bytes", "sha256"}:
                _fail("r2_leakage_shape", "training evidence tuple is invalid")
        if row.get("extractor_id") != "hf_pinned_model_training_disclosure_v1":
            _fail("r2_leakage_shape", "training disclosure extractor differs")
        if evidence[0].get("path") != "captures/training-{}.json".format(row["candidate"]):
            _fail("r2_leakage_shape", "training disclosure capture role differs")
        for pointer_name in ("training_json_pointer", "completeness_json_pointer"):
            pointer = row.get(pointer_name)
            if not isinstance(pointer, list) or not pointer or any(not isinstance(item, str) or not item for item in pointer):
                _fail("r2_leakage_shape", "{} is invalid".format(pointer_name))
        for key in ("frozen_aliases", "derived_mixtures", "disclosed_items", "generic_entries"):
            value = row.get(key)
            if not isinstance(value, list) or any(not isinstance(item, str) or not item.strip() for item in value):
                _fail("r2_leakage_shape", "{} must be a string list".format(key))
            if key in ("frozen_aliases", "derived_mixtures"):
                names.extend(value)
        if not isinstance(names[0], str) or not names[0].strip() or len(set(names)) != len(names):
            _fail("r2_leakage_shape", "corpus names and aliases must be complete and unique")
        normalized_names = {item.casefold() for item in names}
        disclosed = {item.casefold() for item in row["disclosed_items"]}
        present = bool(normalized_names & disclosed)
        if present:
            computed = "included"
        elif row.get("universe_kind") == "enumerated_complete" and not row["generic_entries"]:
            computed = "excluded"
        else:
            computed = "unknown"
        if row.get("status") != computed:
            _fail("r2_leakage_claim", "{} status is not supported by the disclosed universe".format(pair))
        statuses[pair] = computed
    if set(statuses) != required_pairs:
        _fail("r2_leakage_coverage", "leakage pair roster differs")
    hike_safe = all(statuses[(candidate, "hike")] == "excluded" for candidate in ("dicow_mlc", "dicow_v3_3"))
    fleurs_safe = all(statuses[(candidate, "fleurs_ko")] == "excluded" for candidate in ("dicow_mlc", "dicow_v3_3"))
    basis = "hike_pair" if hike_safe else "r2_fleurs_ko_pair" if fleurs_safe else "unavailable"
    ceiling = "mixed_language_hike" if basis == "hike_pair" else "natural_read_speech_only" if basis == "r2_fleurs_ko_pair" else "no_korean_utility_claim"
    if payload.get("korean_utility_basis") != basis or payload.get("claim_ceiling") != ceiling:
        _fail("r2_leakage_decision", "Korean utility basis or claim ceiling differs")
    return {"statuses": statuses, "korean_utility_basis": basis, "claim_ceiling": ceiling}


def validate_r2_generation_request_universe(payload: Mapping[str, Any]) -> Dict[str, Any]:
    if not isinstance(payload, Mapping) or set(payload) != {"schema_version", "requests"}:
        _fail("r2_generation_shape", "generation request envelope differs")
    if payload.get("schema_version") != "dicow-r2-generation-request-universe-v1":
        _fail("r2_generation_shape", "generation request schema differs")
    requests = payload.get("requests")
    if not isinstance(requests, list):
        _fail("r2_generation_coverage", "Phase A requests must be a list")
    result = {}
    semantic_request = None
    for request in requests:
        if not isinstance(request, Mapping) or set(request) != R2_REQUIRED_GENERATION_KEYS:
            _fail("r2_generation_shape", "generation kwargs are incomplete or extra")
        candidate_tuple = request.get("candidate_tuple")
        if not isinstance(candidate_tuple, Mapping) or set(candidate_tuple) != {"candidate", "model_id", "revision"}:
            _fail("r2_generation_shape", "candidate tuple shape differs")
        candidate = candidate_tuple.get("candidate")
        if candidate not in ("dicow_mlc", "dicow_v3_3") or candidate in result:
            _fail("r2_generation_coverage", "generation candidate differs")
        expected = R2_EXACT_MODEL_IDENTITIES[candidate]
        if candidate_tuple.get("model_id") != expected["model_id"] or candidate_tuple.get("revision") != expected["revision"]:
            _fail("r2_generation_identity", "generation request candidate tuple drifted")
        if request.get("ctc_weight") != 0 or request.get("num_beams") != 1:
            _fail("r2_generation_semantics", "Phase A must freeze generation CTC zero and greedy beam one")
        if request.get("timestamp_mode") != "whisper_timestamp_tokens":
            _fail("r2_generation_semantics", "timestamp mode differs")
        if not isinstance(request.get("max_new_tokens"), int) or isinstance(request.get("max_new_tokens"), bool) or request["max_new_tokens"] <= 0:
            _fail("r2_generation_semantics", "output cap is invalid")
        if not isinstance(request.get("language_field"), str) or not request["language_field"]:
            _fail("r2_generation_semantics", "language field is invalid")
        if not isinstance(request.get("prompt_field"), str) or not request["prompt_field"]:
            _fail("r2_generation_semantics", "prompt field is invalid")
        for key in ("tokenizer_record", "generation_config_record"):
            record = request.get(key)
            if not isinstance(record, Mapping) or set(record) != {"path", "bytes", "sha256"} or not isinstance(record.get("path"), str) or not record["path"] or not isinstance(record.get("bytes"), int) or record["bytes"] <= 0 or not re_full_sha256(str(record.get("sha256"))):
                _fail("r2_generation_shape", "{} is not a full file tuple".format(key))
        expected_path = {
            "tokenizer_record": "captures/tokenizer.json",
            "generation_config_record": "captures/generation-config.json",
        }
        for key, path in expected_path.items():
            if request[key]["path"] != path:
                _fail("r2_generation_shape", "{} evidence role differs".format(key))
        semantics = {key: request[key] for key in R2_REQUIRED_GENERATION_KEYS - {"candidate_tuple"}}
        if semantic_request is None:
            semantic_request = semantics
        elif semantics != semantic_request:
            _fail("r2_generation_semantics", "candidate request universes differ")
        result[candidate] = dict(request)
    return {"schema_version": payload["schema_version"], "requests": result}


def validate_r2_deviations(payload: Mapping[str, Any]) -> Dict[str, Any]:
    expected = {
        "schema_version": "dicow-r2-deviations-v1",
        "ctc_control_envelope": R2_CTC_DEVIATION,
    }
    if not isinstance(payload, Mapping) or set(payload) != set(expected) or payload != expected:
        _fail("r2_deviation_drift", "R3 must not fabricate a numeric CTC envelope")
    return dict(payload)


def validate_r2_overlap_prior(payload: Mapping[str, Any]) -> Dict[str, Any]:
    if not isinstance(payload, Mapping) or dict(payload) != R2_OVERLAP_PRIOR:
        _fail("r2_overlap_prior_drift", "unexecuted overlap prevalence cannot become a numeric prior")
    return dict(payload)


def _r2_external_record(root: Path, record: Any, label: str) -> Tuple[Path, bytes]:
    """Validate one immutable file below a sealed external authority root."""

    if (
        not isinstance(record, Mapping)
        or set(record) != {"relative_path", "bytes", "sha256"}
        or not isinstance(record.get("relative_path"), str)
        or PurePosixPath(record["relative_path"]).is_absolute()
        or ".." in PurePosixPath(record["relative_path"]).parts
        or not isinstance(record.get("bytes"), int) or isinstance(record["bytes"], bool) or record["bytes"] <= 0
        or not isinstance(record.get("sha256"), str) or not re_full_sha256(record["sha256"])
    ):
        _fail("r2_term_contract", "{} record differs".format(label))
    path = root.joinpath(*PurePosixPath(record["relative_path"]).parts)
    from benchmarks.scripts.dicow.common import preflight
    raw, info = preflight.stable_read(path, label)
    if stat.S_IMODE(info.st_mode) & 0o222 or {
        "relative_path": record["relative_path"],
        "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    } != dict(record):
        _fail("r2_term_contract", "{} record drifted".format(label))
    return path, raw


def _replay_r2_hike_terms(payload: Mapping[str, Any]) -> bytes:
    """Derive official English loanwords from the twelve pinned HiKE rows."""

    source = payload["source_authority"]
    if not isinstance(source.get("root_path"), str):
        _fail("r2_term_contract", "HiKE external authority path differs")
    from benchmarks.scripts.dicow.common import preflight
    root = preflight.validate_runtime_path(Path(source["root_path"]), "HiKE term authority")
    root_info = os.lstat(root)
    if not stat.S_ISDIR(root_info.st_mode) or stat.S_IMODE(root_info.st_mode) & 0o222:
        _fail("r2_term_contract", "HiKE external authority root is mutable")
    for name, expected_record in R2_HIKE_AUTHORITY_RECORDS.items():
        if source.get(name) != expected_record:
            _fail("r2_term_contract", "HiKE {} differs from the sealed authority tuple".format(name))
    _manifest_path, manifest_raw = _r2_external_record(root, source["manifest_record"], "HiKE authority manifest")
    _card_path, card_raw = _r2_external_record(root, source["card_record"], "HiKE upstream card")
    _selection_path, selection_raw = _r2_external_record(root, source["selection_record"], "HiKE selected sample IDs")
    _selected_rows_path, selected_rows_raw = _r2_external_record(
        root, source["selected_rows_record"], "HiKE selected row projection"
    )
    _terms_path, declared_terms_raw = _r2_external_record(root, source["terms_record"], "HiKE derived terms")
    manifest = _parse_json_object(manifest_raw, "HiKE authority manifest")
    manifest_parquet = manifest.get("source", {}).get("parquet", {})
    manifest_card = manifest.get("source", {}).get("readme", {})
    manifest_selection = manifest.get("selection", {})
    manifest_selected_rows = manifest.get("outputs", {}).get("selected_rows", {})
    manifest_terms = manifest.get("outputs", {}).get("terms", {})
    if (
        manifest.get("authority_kind") != "public_hike_official_row_loanwords"
        or manifest.get("claim_ceiling") != "official_loanword_term_recall_on_pinned_hike_rows"
        or manifest.get("source", {}).get("dataset_id") != "thetaone-ai/HiKE"
        or manifest.get("source", {}).get("revision") != R2_HIKE_REVISION
        or manifest_parquet.get("bundle_path") != source["parquet_record"]["relative_path"]
        or manifest_parquet.get("bytes") != source["parquet_record"]["bytes"]
        or manifest_parquet.get("sha256") != source["parquet_record"]["sha256"]
        or manifest_card.get("bundle_path") != source["card_record"]["relative_path"]
        or manifest_card.get("bytes") != source["card_record"]["bytes"]
        or manifest_card.get("sha256") != source["card_record"]["sha256"]
        or manifest_selection.get("ids_path") != source["selection_record"]["relative_path"]
        or manifest_selection.get("ids_sha256") != source["selection_record"]["sha256"]
        or manifest_selection.get("count") != len(R2_HIKE_SELECTED_SAMPLE_IDS)
        or manifest_selected_rows.get("path") != source["selected_rows_record"]["relative_path"]
        or manifest_selected_rows.get("bytes") != source["selected_rows_record"]["bytes"]
        or manifest_selected_rows.get("sha256") != source["selected_rows_record"]["sha256"]
        or manifest_terms.get("path") != source["terms_record"]["relative_path"]
        or manifest_terms.get("bytes") != source["terms_record"]["bytes"]
        or manifest_terms.get("sha256") != source["terms_record"]["sha256"]
        or manifest_terms.get("count") != 18
    ):
        _fail("r2_term_contract", "HiKE authority manifest semantics differ")
    if b"meticulously labeled all loanwords contained in our dataset" not in card_raw:
        _fail("r2_term_contract", "HiKE card does not establish official row-level loanword labels")
    expected_selection_raw = ("\n".join(R2_HIKE_SELECTED_SAMPLE_IDS) + "\n").encode("utf-8")
    if selection_raw != expected_selection_raw:
        _fail("r2_term_contract", "HiKE selected sample ID order differs")
    parquet_record = source["parquet_record"]
    if (
        parquet_record.get("relative_path") != "sources/data/test-00000-of-00001.parquet"
        or parquet_record.get("bytes") != R2_HIKE_PARQUET_BYTES
        or parquet_record.get("sha256") != R2_HIKE_PARQUET_SHA256
    ):
        _fail("r2_term_contract", "HiKE parquet tuple differs")
    parquet = root / "sources" / "data" / "test-00000-of-00001.parquet"
    try:
        import pyarrow.parquet as parquet_reader  # type: ignore[import-not-found]
    except ImportError:
        _fail("r2_term_dependency", "pyarrow is required to replay HiKE term labels")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(parquet, flags)
    except OSError as error:
        _fail("r2_term_contract", "cannot open pinned HiKE parquet: {}".format(error))
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(before.st_mode) or stat.S_IMODE(before.st_mode) & 0o222
            or before.st_size != R2_HIKE_PARQUET_BYTES
        ):
            _fail("r2_term_contract", "pinned HiKE parquet identity differs")
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        if digest.hexdigest() != R2_HIKE_PARQUET_SHA256:
            _fail("r2_term_contract", "pinned HiKE parquet hash differs")
        stream.seek(0)
        table = parquet_reader.read_table(
            stream,
            columns=["sample_id", "text_normalized", "loanwords"],
            use_threads=False,
            pre_buffer=False,
        )
        after = os.fstat(stream.fileno())
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns
        ):
            _fail("r2_term_contract", "pinned HiKE parquet changed during replay")
    by_id = {}
    for row in table.to_pylist():
        sample_id = row.get("sample_id")
        if sample_id in R2_HIKE_SELECTED_SAMPLE_IDS:
            if sample_id in by_id:
                _fail("r2_term_contract", "selected HiKE row is ambiguous")
            by_id[sample_id] = row
    if set(by_id) != set(R2_HIKE_SELECTED_SAMPLE_IDS):
        _fail("r2_term_contract", "selected HiKE row is missing")
    ordered = [by_id[sample_id] for sample_id in R2_HIKE_SELECTED_SAMPLE_IDS]
    replayed_selected_rows = b"".join(
        (
            json.dumps(
                {
                    "loanwords": row["loanwords"],
                    "sample_id": row["sample_id"],
                    "text_normalized": row["text_normalized"],
                },
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ) + "\n"
        ).encode("utf-8")
        for row in ordered
    )
    if replayed_selected_rows != selected_rows_raw:
        _fail("r2_term_contract", "HiKE selected row projection differs from the official parquet")
    reference = unicodedata.normalize(
        "NFKC", "\n".join(str(row["text_normalized"]) for row in ordered)
    ).casefold()
    first_spelling = {}
    for row in ordered:
        try:
            labels = json.loads(row["loanwords"])
        except (TypeError, json.JSONDecodeError) as error:
            _fail("r2_term_contract", "HiKE loanwords JSON differs: {}".format(error))
        if not isinstance(labels, list):
            _fail("r2_term_contract", "HiKE loanwords row is not a list")
        for label in labels:
            english = label.get("English") if isinstance(label, Mapping) else None
            if not isinstance(english, str) or not english.strip():
                continue
            spelling = english.strip()
            normalized = unicodedata.normalize("NFKC", spelling).casefold()
            pieces = [re.escape(piece) for piece in re.split(r"[\s_-]+", normalized) if piece]
            pattern = r"(?<![A-Za-z0-9])" + r"[\s_-]*".join(pieces) + r"(?![A-Za-z0-9])"
            if pieces and re.search(pattern, reference):
                first_spelling.setdefault(normalized, spelling)
    terms = [first_spelling[key] for key in sorted(first_spelling)]
    replayed_terms = ("\n".join(terms) + "\n").encode("utf-8")
    if replayed_terms != declared_terms_raw:
        _fail("r2_term_contract", "HiKE term bytes differ from the official selected rows")
    return replayed_terms


def validate_r2_term_contract(payload: Mapping[str, Any]) -> Dict[str, Any]:
    fixed = {
        "schema_version": "dicow-r2-term-contract-v2",
        "normalized_transcript_edit_tolerance": 0,
        "hike_term_metric": "official_loanword_recall",
        "hike_term_source": "public_hike_official_row_loanwords",
        "hike_term_claim_ceiling": "official_loanword_term_recall_on_pinned_hike_rows",
        "dataset_id": "thetaone-ai/HiKE",
        "revision": R2_HIKE_REVISION,
        "selected_sample_ids": list(R2_HIKE_SELECTED_SAMPLE_IDS),
        "extractor_id": R2_HIKE_TERM_EXTRACTOR,
        "filter_contract": R2_HIKE_TERM_FILTER,
        "derived_term_count": 18,
        "derived_terms_sha256": R2_HIKE_TERMS_SHA256,
        "fleurs_it": "term_metric_not_applicable",
        "fleurs_en": "term_metric_not_applicable",
    }
    if not isinstance(payload, Mapping) or set(payload) != {*fixed, "source_authority"}:
        _fail("r2_term_contract", "term/transcript contract shape differs")
    if any(payload.get(key) != value for key, value in fixed.items()):
        _fail("r2_term_contract", "HiKE row-label term contract differs")
    source = payload.get("source_authority")
    if not isinstance(source, Mapping) or set(source) != {
        "root_path", "manifest_record", "parquet_record", "card_record",
        "selection_record", "selected_rows_record", "terms_record",
    }:
        _fail("r2_term_contract", "HiKE external authority binding differs")
    for name, expected_record in R2_HIKE_AUTHORITY_RECORDS.items():
        if source.get(name) != expected_record:
            _fail("r2_term_contract", "HiKE {} differs from the sealed authority tuple".format(name))
    return dict(payload)


def validate_r2_aligner_inventory(payload: Mapping[str, Any]) -> Dict[str, Any]:
    if payload != R2_ALIGNER_SEMANTIC_STATUS:
        _fail(
            "r2_aligner_inventory",
            "aligner semantic status must remain rejected with no active bundle",
        )
    return dict(payload)


def validate_r2_rights_bindings(payload: Mapping[str, Any]) -> Dict[str, Any]:
    subjects = tuple(R2_EXACT_MODEL_IDENTITIES)
    required = (
        {(subject, action) for subject in subjects for action in R2_RIGHTS_ACTIONS}
        | {(subject, action) for subject in R2_FIXTURE_RIGHTS_SUBJECTS for action in R2_FIXTURE_RIGHTS_ACTIONS}
    )
    if not isinstance(payload, Mapping) or set(payload) != {"schema_version", "rows"}:
        _fail("r2_rights_binding", "rights binding envelope differs")
    if payload.get("schema_version") != "dicow-r2-rights-bindings-v1":
        _fail("r2_rights_binding", "rights binding schema differs")
    rows = payload.get("rows")
    if not isinstance(rows, list) or len(rows) != len(required):
        _fail("r2_rights_binding", "rights action coverage differs")
    result = {}
    for row in rows:
        if not isinstance(row, Mapping) or set(row) != {"subject", "action", "state", "evidence"}:
            _fail("r2_rights_binding", "rights row shape differs")
        pair = (row.get("subject"), row.get("action"))
        if pair not in required or pair in result or row.get("state") not in R2_RIGHTS_STATES:
            _fail("r2_rights_binding", "rights row identity/state differs")
        evidence = row.get("evidence")
        if not isinstance(evidence, list) or len(evidence) != 1:
            _fail("r2_rights_binding", "every action-specific right requires evidence")
        for record in evidence:
            if (
                not isinstance(record, Mapping)
                or set(record) != {"path", "bytes", "sha256"}
                or not isinstance(record.get("path"), str)
                or not record["path"]
                or not isinstance(record.get("bytes"), int)
                or record["bytes"] <= 0
                or not re_full_sha256(str(record.get("sha256")))
            ):
                _fail("r2_rights_binding", "rights evidence tuple is invalid")
            if record["path"] != "frontier/rights-matrix.json":
                _fail("r2_rights_binding", "rights must derive from the canonical frontier matrix")
        result[pair] = dict(row)
    if set(result) != required:
        _fail("r2_rights_binding", "rights action roster differs")
    return {"schema_version": payload["schema_version"], "rows": result}


def _r2_component_rights_state(rights: Mapping[str, Any], subject: str) -> str:
    states = [rights["rows"][(subject, action)]["state"] for action in (
        "private_reference_evaluation", "private_local_derivative",
    )]
    if all(state == "allowed" for state in states):
        return "implementation_ready"
    if "forbidden" in states:
        return "conversion_not_supported"
    return "evidence_blocker"


def _reject_r2_audit_payloads(value: Any, path: str = "$") -> None:
    """Reject model output and embedded full-checkpoint content from an R3 spec."""

    forbidden_keys = {
        "model_output", "raw_output", "transcript", "decoded_text", "hypothesis",
        "hypotheses", "generated_tokens", "token_ids", "audio_payload", "checkpoint_payload",
    }
    if isinstance(value, Mapping):
        for key, item in value.items():
            if key in forbidden_keys:
                _fail("r2_audit_contains_model_output", "forbidden field {}.{}".format(path, key))
            _reject_r2_audit_payloads(item, path + "." + str(key))
    elif isinstance(value, list):
        if len(value) > 10_000:
            _fail("r2_audit_contains_checkpoint", "oversized list is forbidden at {}".format(path))
        for index, item in enumerate(value):
            _reject_r2_audit_payloads(item, "{}[{}]".format(path, index))
    elif isinstance(value, (bytes, bytearray)):
        _fail("r2_audit_contains_checkpoint", "binary payload is forbidden at {}".format(path))
    elif isinstance(value, str) and len(value.encode("utf-8")) > 256 * 1024:
        _fail("r2_audit_contains_checkpoint", "oversized embedded payload is forbidden at {}".format(path))


def _validate_r2_resource_identity_bindings(
    ledger: Mapping[str, Any], identities: Mapping[str, Any]
) -> None:
    """Bind every planned writer byte source to an authenticated model tuple."""

    rows = ledger.get("writers") if isinstance(ledger, Mapping) else None
    if not isinstance(rows, list):
        _fail("r2_resource_shape", "writer source bindings are missing")
    for row in rows:
        if not isinstance(row, Mapping) or not isinstance(row.get("sources"), list):
            _fail("r2_resource_shape", "writer source bindings are missing")
        writer = row.get("writer")
        expected_candidates = R2_WRITER_SOURCE_CANDIDATES.get(writer)
        candidates = [source.get("candidate") if isinstance(source, Mapping) else None for source in row["sources"]]
        if expected_candidates is None or candidates != list(expected_candidates):
            _fail("r2_resource_formula_mismatch", "writer source candidate branch differs")
        for source in row["sources"]:
            candidate = source.get("candidate") if isinstance(source, Mapping) else None
            identity = identities["models"].get(candidate)
            if identity is None:
                _fail("r2_resource_formula_mismatch", "writer source candidate is unauthenticated")
            expected = {
                "candidate": candidate,
                "model_id": identity["model_id"],
                "revision": identity["revision"],
                "model_file_bytes": identity["model_file_bytes"],
                "model_file_lfs_sha256": identity["model_file_lfs_sha256"],
                "header_record": identity["header_record"],
                "lfs_record": identity["lfs_record"],
            }
            if dict(source) != expected:
                _fail("r2_resource_formula_mismatch", "writer source tuple differs from model evidence")


def validate_r2_audit_documents(
    documents: Mapping[str, Any],
    *,
    require_current_volume_snapshot: bool = True,
) -> Dict[str, Any]:
    """Validate the decision-bearing R3 documents before create-only materialization."""

    if not isinstance(documents, Mapping) or set(documents) != set(R2_REQUIRED_AUDIT_DOCUMENTS):
        _fail("r2_audit_document_coverage", "R3 audit document roster differs")
    _reject_r2_audit_payloads(documents)
    identities = validate_r2_model_identities(documents["model-identities.json"])
    graphs = validate_r2_graph_contracts(documents["graph-contracts.json"])
    leakage = validate_r2_leakage_decisions(documents["leakage-decisions.json"])
    generation = validate_r2_generation_request_universe(documents["generation-request-universe.json"])
    from benchmarks.scripts.dicow.common import preflight
    timestamp = preflight.validate_r2_timestamp_contract(documents["qwen-timestamp-contract.json"])
    terms = validate_r2_term_contract(documents["qwen-term-contract.json"])
    aligner = validate_r2_aligner_inventory(documents["mlx-audio-aligner-inventory.json"])
    _validate_r2_resource_identity_bindings(documents["writer-resource-ledger.json"], identities)
    sealed_volume = documents["volume-preflight.json"]
    resources = preflight.calculate_r2_writer_resource_ledger(
        documents["writer-resource-ledger.json"], sealed_snapshot=sealed_volume,
    )
    if sealed_volume != resources or resources.get("resource_gate_state") != "sufficient":
        _fail("r2_resource_formula_mismatch", "volume snapshot must replay source-derived bounds exactly")
    if require_current_volume_snapshot:
        current_resources = preflight.calculate_r2_writer_resource_ledger(
            documents["writer-resource-ledger.json"]
        )
        if current_resources.get("resource_gate_state") != "sufficient":
            _fail("r2_operational_resource_blocker", "current writer destination volume is insufficient")
    validate_r2_deviations(documents["deviations.json"])
    validate_r2_overlap_prior(documents["overlap-prior.json"])
    constraints = preflight.validate_r2_candidate_constraint_ledger(documents["constraint-ledger.json"])
    rights = validate_r2_rights_bindings(documents["rights-bindings.json"])
    decision = documents["decision.json"]
    if not isinstance(decision, Mapping) or set(decision) != {
        "schema_version", "dicow_scope", "qwen_asr_scope", "qwen_aligner_scope", "resource_scope",
    }:
        _fail("r2_decision_shape", "R3 decision shape differs")
    fixture_rights_ready = all(
        rights["rows"][(subject, action)]["state"] == "allowed"
        for subject in R2_FIXTURE_RIGHTS_SUBJECTS
        for action in ("private_reference_evaluation", "tracked_declaration")
    )
    comparable_candidates = {
        name for name, row in graphs["candidates"].items() if row.get("state") == "comparable"
    }
    comparable_rights_ready = bool(comparable_candidates) and all(
        _r2_component_rights_state(rights, candidate) == "implementation_ready"
        for candidate in comparable_candidates
    )
    expected_dicow = (
        "proceed"
        if leakage["korean_utility_basis"] != "unavailable" and fixture_rights_ready and comparable_rights_ready
        else "evidence_blocker"
    )
    if decision.get("schema_version") != "dicow-r2-pre-model-decision-v1" or decision.get("dicow_scope") != expected_dicow:
        _fail("r2_decision_semantics", "DiCoW decision does not follow leakage evidence")
    if decision.get("qwen_asr_scope") != _r2_component_rights_state(rights, "qwen_asr"):
        _fail("r2_decision_semantics", "Qwen ASR scope does not follow action-specific rights")
    if decision.get("qwen_aligner_scope") != _r2_component_rights_state(rights, "qwen_aligner"):
        _fail("r2_decision_semantics", "Qwen aligner scope does not follow action-specific rights")
    if decision.get("resource_scope") != "source_bounds_sufficient_receipts_deferred":
        _fail("r2_decision_semantics", "R3 resource scope must bind planned bounds and defer actual receipts")
    comparable = comparable_candidates
    if set(generation["requests"]) != comparable:
        _fail("r2_generation_coverage", "generation requests must exactly cover comparable candidates")
    return {
        "model_candidates": sorted(identities["models"]),
        "comparable_dicow_candidates": sorted(comparable),
        "korean_utility_basis": leakage["korean_utility_basis"],
        "timestamp_contract": timestamp,
        "term_contract": terms,
        "aligner_disposition": aligner["verdict"],
        "resource_formula": resources["formula"],
        "constraint_paths": sorted(constraints["paths"]),
        "rights_rows": len(rights["rows"]),
        "decision": dict(decision),
    }


def _r2_create_json(path: Path, value: Any) -> Dict[str, Any]:
    raw = (json.dumps(value, allow_nan=False, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    if len(raw) > 4 * 1024 * 1024:
        _fail("r2_audit_contains_checkpoint", "audit JSON exceeds the 4 MiB document ceiling")
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o444)
    except OSError as error:
        _fail("r2_create_only", "cannot create {}: {}".format(path, error))
    try:
        offset = 0
        while offset < len(raw):
            written = os.write(descriptor, raw[offset:])
            if written <= 0:
                _fail("r2_create_only", "short write while creating {}".format(path))
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


def _r2_file_tuple(path: Path, label: str) -> Dict[str, Any]:
    from benchmarks.scripts.dicow.common import preflight
    raw, info = preflight.stable_read(path, label)
    if stat.S_IMODE(info.st_mode) & 0o222:
        _fail("r2_audit_verify", "{} is writable".format(label))
    return {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


def _r2_capture_rows(captures: Any) -> Dict[str, Mapping[str, Any]]:
    required_captures = set(R2_REQUIRED_HEADER_CAPTURES) | set(R2_REQUIRED_LFS_CAPTURES)
    if not isinstance(captures, list) or len(captures) < len(required_captures) or len(captures) > 128:
        _fail("r2_capture_coverage", "four safetensors headers, four LFS responses, and named evidence captures are required")
    result = {}
    for row in captures:
        if not isinstance(row, Mapping) or set(row) != {"name", "kind", "source_path", "record", "total_file_bytes"}:
            _fail("r2_capture_shape", "header capture row shape differs")
        name = row.get("name")
        if not isinstance(name, str) or not name or name in result or PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts:
            _fail("r2_capture_shape", "header capture name is unsafe")
        kind = row.get("kind")
        if kind not in ("safetensors_header", "hf_lfs_metadata", "evidence"):
            _fail("r2_capture_shape", "capture kind differs")
        if name in R2_REQUIRED_HEADER_CAPTURES and kind != "safetensors_header":
            _fail("r2_capture_shape", "required header has the wrong capture kind")
        if name in R2_REQUIRED_LFS_CAPTURES and kind != "hf_lfs_metadata":
            _fail("r2_capture_shape", "required LFS response has the wrong capture kind")
        if name not in required_captures and kind != "evidence":
            _fail("r2_capture_shape", "only fixed names may use model metadata capture kinds")
        aligner_relative = name.removeprefix("mlx-aligner/") if name.startswith("mlx-aligner/") else None
        if kind == "evidence" and PurePosixPath(name).suffix.lower() not in {
            ".json", ".md", ".txt", ".py", ".toml", ".lock", ".html", ".xml", ".headers", ".pcm",
            ".whl", ".jinja",
        } and aligner_relative not in R2_ALIGNER_BUNDLE_PATHS:
            _fail("r2_capture_shape", "evidence capture file type is not permitted")
        if not isinstance(row.get("source_path"), str):
            _fail("r2_capture_shape", "header source path is invalid")
        record = row.get("record")
        if not isinstance(record, Mapping) or set(record) != {"bytes", "sha256"} or not isinstance(record.get("bytes"), int) or record["bytes"] <= 8 or not re_full_sha256(str(record.get("sha256"))):
            _fail("r2_capture_shape", "header capture tuple is invalid")
        if kind == "safetensors_header":
            if not isinstance(row.get("total_file_bytes"), int) or isinstance(row.get("total_file_bytes"), bool) or row["total_file_bytes"] <= record["bytes"]:
                _fail("r2_capture_shape", "header total file bytes are invalid")
        elif row.get("total_file_bytes") is not None:
            _fail("r2_capture_shape", "ordinary evidence must not claim checkpoint bytes")
        result[name] = row
    if not required_captures.issubset(result):
        _fail("r2_capture_coverage", "header/LFS capture roster differs")
    if sum(int(row["record"]["bytes"]) for row in result.values()) > 64 * 1024 * 1024:
        _fail("r2_audit_contains_checkpoint", "all R3 captures together exceed 64 MiB")
    return result


def _r2_referenced_capture_names(documents: Mapping[str, Any]) -> set[str]:
    result = set(R2_REQUIRED_HEADER_CAPTURES) | set(R2_REQUIRED_LFS_CAPTURES)
    def visit(value: Any) -> None:
        if isinstance(value, Mapping):
            if set(value) == {"path", "bytes", "sha256"} and isinstance(value.get("path"), str):
                pure = PurePosixPath(value["path"])
                if len(pure.parts) >= 2 and pure.parts[0] == "captures":
                    result.add(PurePosixPath(*pure.parts[1:]).as_posix())
            for item in value.values():
                visit(item)
        elif isinstance(value, list):
            for item in value:
                visit(item)
    visit(documents)
    return result


def _r2_resolve_evidence_path(path: str, frontier: Path, capture_root: Path) -> Path:
    pure = PurePosixPath(path)
    if pure.is_absolute() or ".." in pure.parts or len(pure.parts) < 2:
        _fail("r2_evidence_reference", "evidence path is unsafe")
    if pure.parts[0] == "frontier":
        root = frontier
    elif pure.parts[0] == "captures":
        root = capture_root
    else:
        _fail("r2_evidence_reference", "evidence must use frontier/ or captures/ namespace")
    resolved = root.joinpath(*pure.parts[1:])
    try:
        resolved.relative_to(root)
    except ValueError:
        _fail("r2_evidence_reference", "evidence path escapes its authority root")
    return resolved


def _derive_r2_resource_bytes(authority: Mapping[str, Any], writer: str, phase: str) -> Dict[str, int]:
    """Apply the one R3 writer formula to raw payload/copy primitives."""

    if not isinstance(authority, Mapping) or set(authority) != {"schema_version", "writers"} or authority.get("schema_version") != "dicow-r2-resource-primitives-v1":
        _fail("r2_resource_formula_mismatch", "resource primitive envelope differs")
    try:
        raw = authority["writers"][writer]["phases"][phase]
    except (KeyError, TypeError):
        _fail("r2_resource_formula_mismatch", "resource primitive pointer is unresolved")
    keys = {
        "payload_bytes", "final_copies", "staging_copies", "retained_failure_copies",
        "retry_copies", "serializer_buffer_bytes", "prior_output_bytes",
    }
    if not isinstance(raw, Mapping) or set(raw) != keys:
        _fail("r2_resource_formula_mismatch", "resource primitive shape differs")
    for key in keys:
        value = raw[key]
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            _fail("r2_resource_formula_mismatch", "resource primitive {} is invalid".format(key))
    payload = raw["payload_bytes"]
    return {
        "final_bytes": payload * raw["final_copies"],
        "staging_bytes": payload * raw["staging_copies"],
        "retained_failure_bytes": payload * raw["retained_failure_copies"],
        "retry_bytes": payload * raw["retry_copies"],
        "serializer_bytes": raw["serializer_buffer_bytes"],
        "simultaneously_retained_prior_outputs": raw["prior_output_bytes"],
    }


def _derive_r2_constraint(authority: Mapping[str, Any], path_name: str, constraint_id: str) -> Dict[str, Any]:
    """Apply the exact hard-duration formula to a pinned source limit and reserve."""

    if not isinstance(authority, Mapping) or set(authority) != {"schema_version", "paths"} or authority.get("schema_version") != "dicow-r2-constraint-primitives-v1":
        _fail("r2_constraint_invalid", "constraint primitive envelope differs")
    try:
        raw = authority["paths"][path_name][constraint_id]
    except (KeyError, TypeError):
        _fail("r2_constraint_invalid", "constraint primitive pointer is unresolved")
    keys = {
        "variable", "unit", "scope", "kind", "source_limit_seconds",
        "reserved_headroom_seconds", "observed_range", "failure_mode", "telemetry", "review_trigger",
    }
    if not isinstance(raw, Mapping) or set(raw) != keys:
        _fail("r2_constraint_invalid", "constraint primitive shape differs")
    source_limit = raw["source_limit_seconds"]
    reserve = raw["reserved_headroom_seconds"]
    if (
        not isinstance(source_limit, int) or isinstance(source_limit, bool) or source_limit <= 0
        or not isinstance(reserve, int) or isinstance(reserve, bool) or reserve < 0 or reserve >= source_limit
    ):
        _fail("r2_constraint_invalid", "constraint duration primitives are invalid")
    return {
        "variable": raw["variable"],
        "unit": raw["unit"],
        "scope": raw["scope"],
        "kind": raw["kind"],
        "formula": "r2_hard_duration_limit_v1",
        "headroom": "{} seconds reserved from source limit".format(reserve),
        "observed_range": raw["observed_range"],
        "maximum_duration_seconds": source_limit - reserve,
        "failure_mode": raw["failure_mode"],
        "telemetry": raw["telemetry"],
        "review_trigger": raw["review_trigger"],
    }


def _extract_r2_training_disclosure(raw: bytes, row: Mapping[str, Any]) -> Tuple[list[str], list[str], str]:
    """Extract pinned card datasets without upgrading them to a complete universe."""

    parsed: Any = _parse_json_object(raw, "raw official training disclosure")
    identity = R2_EXACT_MODEL_IDENTITIES[row["candidate"]]
    expected_url = "https://huggingface.co/api/models/{}/revision/{}".format(
        identity["model_id"], identity["revision"]
    )
    if (
        set(parsed) != {"request_url", "model_id", "revision", "response"}
        or parsed.get("request_url") != expected_url
        or parsed.get("model_id") != identity["model_id"]
        or parsed.get("revision") != identity["revision"]
        or not isinstance(parsed.get("response"), Mapping)
    ):
        _fail("r2_leakage_evidence", "training disclosure is not bound to the pinned official response")
    disclosed: Any = parsed
    for component in row["training_json_pointer"]:
        if not isinstance(disclosed, Mapping) or component not in disclosed:
            _fail("r2_leakage_evidence", "training disclosure pointer is unresolved")
        disclosed = disclosed[component]
    if not isinstance(disclosed, list) or any(not isinstance(item, str) for item in disclosed):
        _fail("r2_leakage_evidence", "training disclosure values are invalid")
    generic = [item for item in disclosed if item.casefold() in {"other data", "other datasets", "multilingual data"}]
    return disclosed, generic, "generic_or_incomplete"


def _r2_float_wav_to_pcm16(raw: bytes, expected_samples: int) -> bytes:
    """Decode the pinned FLEURS mono float32 WAV representation to PCM16."""

    if len(raw) < 12 or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        _fail("r2_timestamp_contract", "FLEURS audio is not a RIFF/WAVE payload")
    offset = 12
    fmt = None
    data = None
    while offset + 8 <= len(raw):
        kind = raw[offset:offset + 4]
        size = struct.unpack("<I", raw[offset + 4:offset + 8])[0]
        start = offset + 8
        end = start + size
        if end > len(raw):
            _fail("r2_timestamp_contract", "FLEURS WAV chunk is truncated")
        if kind == b"fmt ":
            fmt = raw[start:end]
        elif kind == b"data":
            data = raw[start:end]
        offset = end + (size % 2)
    if fmt is None or data is None or len(fmt) < 16:
        _fail("r2_timestamp_contract", "FLEURS WAV lacks fmt or data")
    format_code, channels, sample_rate, _byte_rate, block_align, bits = struct.unpack("<HHIIHH", fmt[:16])
    if (format_code, channels, sample_rate, block_align, bits) != (3, 1, 16_000, 4, 32) or len(data) != expected_samples * 4:
        _fail("r2_timestamp_contract", "FLEURS WAV format or sample count differs")
    result = bytearray(expected_samples * 2)
    for index, (sample,) in enumerate(struct.iter_unpack("<f", data)):
        clipped = min(1.0, max(-1.0, float(sample)))
        value = max(-32768, min(32767, round(clipped * 32767.0)))
        struct.pack_into("<h", result, index * 2, value)
    return bytes(result)


def _r2_read_fleurs_pcm(parquet: Path, authority: Mapping[str, Any]) -> bytes:
    """Read one exact public FLEURS row from one stable, immutable descriptor."""

    try:
        import pyarrow.parquet as parquet_reader  # type: ignore[import-not-found]
    except ImportError:
        _fail("r2_timestamp_dependency", "pyarrow is required to replay the pinned FLEURS rows")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(parquet, flags)
    except OSError as error:
        _fail("r2_timestamp_contract", "cannot open pinned FLEURS parquet: {}".format(error))
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(before.st_mode)
            or stat.S_IMODE(before.st_mode) & 0o222
            or before.st_size != authority["parquet_bytes"]
        ):
            _fail("r2_timestamp_contract", "pinned FLEURS parquet identity differs")
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        if digest.hexdigest() != authority["parquet_sha256"]:
            _fail("r2_timestamp_contract", "pinned FLEURS parquet hash differs")
        stream.seek(0)
        table = parquet_reader.read_table(
            stream,
            columns=["id", "num_samples", "path", "audio", "transcription", "language"],
            filters=[("id", "=", authority["sentence_id"])],
            use_threads=False,
            pre_buffer=False,
        )
        after = os.fstat(stream.fileno())
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns
        ):
            _fail("r2_timestamp_contract", "pinned FLEURS parquet changed during replay")
    matches = [
        row for row in table.to_pylist()
        if row.get("id") == authority["sentence_id"]
        and Path(str(row.get("path", ""))).name == authority["audio_path"]
    ]
    if len(matches) != 1:
        _fail("r2_timestamp_contract", "pinned FLEURS row identity is missing or ambiguous")
    row = matches[0]
    audio = row.get("audio")
    if (
        row.get("num_samples") != authority["num_samples"]
        or row.get("transcription") != authority["normalized_transcription"]
        or row.get("language") != authority["language"]
        or not isinstance(audio, Mapping)
        or Path(str(audio.get("path", ""))).name != authority["audio_path"]
        or not isinstance(audio.get("bytes"), bytes)
    ):
        _fail("r2_timestamp_contract", "pinned FLEURS row fields differ")
    wav = audio["bytes"]
    if hashlib.sha256(wav).hexdigest() != authority["wav_sha256"]:
        _fail("r2_timestamp_contract", "pinned FLEURS WAV hash differs")
    pcm = _r2_float_wav_to_pcm16(wav, authority["num_samples"])
    if hashlib.sha256(pcm).hexdigest() != authority["pcm_sha256"]:
        _fail("r2_timestamp_contract", "pinned FLEURS PCM hash differs")
    return pcm


def _generate_r2_timestamp_pcm(join: Mapping[str, Any]) -> bytes:
    """Replay the public FLEURS row-2005 concatenation with exact zero gaps."""

    expected = {
        "schema_version", "dataset_id", "revision", "license", "sample_rate_hz",
        "sample_width_bytes", "channels", "annotation_resolution_samples", "gap_samples",
        "frame_count", "pcm_sha256", "coverage_locales", "utterances", "source_authority",
    }
    if (
        not isinstance(join, Mapping) or set(join) != expected
        or join.get("schema_version") != "dicow-r2-fleurs-timestamp-join-v1"
        or join.get("dataset_id") != "google/fleurs"
        or join.get("revision") != R2_FLEURS_REVISION
        or join.get("license") != "CC-BY-4.0"
        or join.get("sample_rate_hz") != 16_000
        or join.get("sample_width_bytes") != 2
        or join.get("channels") != 1
        or join.get("annotation_resolution_samples") != 1
        or join.get("gap_samples") != 8_000
        or join.get("frame_count") != R2_FLEURS_JOIN_SAMPLES
        or join.get("pcm_sha256") != R2_FLEURS_JOIN_PCM_SHA256
        or join.get("coverage_locales") != ["ko", "en", "it"]
        or join.get("utterances") != [dict(R2_FLEURS_PARQUETS[key]) for key in ("ko", "en", "it")]
    ):
        _fail("r2_timestamp_contract", "timestamp join differs from the frozen public FLEURS authority")
    source = join.get("source_authority")
    if (
        not isinstance(source, Mapping)
        or set(source) != {"root_path", "authority_record"}
        or not isinstance(source.get("root_path"), str)
    ):
        _fail("r2_timestamp_contract", "external FLEURS authority binding is missing")
    from benchmarks.scripts.dicow.common import preflight
    root = preflight.validate_runtime_path(Path(source["root_path"]), "FLEURS timestamp authority")
    root_info = os.lstat(root)
    if not stat.S_ISDIR(root_info.st_mode) or stat.S_IMODE(root_info.st_mode) & 0o222:
        _fail("r2_timestamp_contract", "external FLEURS authority root is mutable")
    record = source.get("authority_record")
    if (
        not isinstance(record, Mapping)
        or set(record) != {"relative_path", "bytes", "sha256"}
        or record.get("relative_path") != "authority.json"
        or not isinstance(record.get("bytes"), int) or isinstance(record["bytes"], bool) or record["bytes"] <= 0
        or not isinstance(record.get("sha256"), str) or not re_full_sha256(record["sha256"])
    ):
        _fail("r2_timestamp_contract", "external FLEURS authority record differs")
    authority_raw, authority_info = preflight.stable_read(root / "authority.json", "FLEURS timestamp authority record")
    if stat.S_IMODE(authority_info.st_mode) & 0o222 or {
        "relative_path": "authority.json",
        "bytes": len(authority_raw),
        "sha256": hashlib.sha256(authority_raw).hexdigest(),
    } != dict(record):
        _fail("r2_timestamp_contract", "external FLEURS authority record drifted")
    authority_document = _parse_json_object(authority_raw, "FLEURS timestamp authority record")
    if (
        authority_document.get("schema_version") != "dicow-r2-fleurs-timestamp-authority-v1"
        or authority_document.get("dataset") != {
            "id": "google/fleurs", "license": "CC-BY-4.0", "revision": R2_FLEURS_REVISION,
        }
        or not isinstance(authority_document.get("utterances"), list)
        or authority_document.get("join", {}).get("sha256") != R2_FLEURS_JOIN_PCM_SHA256
        or authority_document.get("join", {}).get("frame_count") != R2_FLEURS_JOIN_SAMPLES
    ):
        _fail("r2_timestamp_contract", "external FLEURS authority semantics differ")
    projected_authority = []
    for key, authority in R2_FLEURS_PARQUETS.items():
        projected_authority.append({
            "locale": key,
            "source_locale": authority["locale"],
            "row_index": authority["row_index"],
            "sentence_id": authority["sentence_id"],
            "audio_path": authority["audio_path"],
            "num_samples": authority["num_samples"],
            "parquet_bytes": authority["parquet_bytes"],
            "parquet_sha256": authority["parquet_sha256"],
            "wav_sha256": authority["wav_sha256"],
            "pcm_sha256": authority["pcm_sha256"],
            "normalized_transcription": authority["normalized_transcription"],
            "language": authority["language"],
            "start_sample": authority["start_sample"],
            "end_sample": authority["end_sample"],
        })
    authority_rows = []
    for row in authority_document["utterances"]:
        if not isinstance(row, Mapping):
            _fail("r2_timestamp_contract", "external FLEURS authority utterance differs")
        authority_rows.append({key: row.get(key) for key in projected_authority[0]})
    if authority_rows != projected_authority:
        _fail("r2_timestamp_contract", "external FLEURS authority rows differ")
    output = bytearray(R2_FLEURS_JOIN_SAMPLES * 2)
    for key in ("ko", "en", "it"):
        authority = R2_FLEURS_PARQUETS[key]
        parquet = root / "source" / "parquet-data" / authority["locale"] / "test-00000-of-00001.parquet"
        pcm = _r2_read_fleurs_pcm(parquet, authority)
        output[authority["start_sample"] * 2:authority["end_sample"] * 2] = pcm
    result = bytes(output)
    if hashlib.sha256(result).hexdigest() != R2_FLEURS_JOIN_PCM_SHA256:
        _fail("r2_timestamp_contract", "public FLEURS concatenation PCM hash differs")
    return result


def _verify_r2_graph_runtime(ast_derivation: Mapping[str, Any]) -> None:
    """Require the one CPython build that defines the sealed graph AST bytes."""

    from benchmarks.scripts.dicow.common import preflight
    if (
        ast_derivation != R2_GRAPH_AST_DERIVATION
        or sys.implementation.name != "cpython"
        or list(sys.version_info[:3]) != [3, 12, 13]
        or sys.implementation.cache_tag != "cpython-312"
    ):
        _fail("r2_graph_runtime", "graph AST runtime differs from the pinned derivation")
    for role, runtime_path in (
        ("executable_record", Path(sys.executable).resolve()),
        ("ast_module_record", Path(ast.__file__).resolve()),
    ):
        record = ast_derivation[role]
        raw, _ = preflight.stable_read(runtime_path, "graph AST {}".format(role))
        if len(raw) != record["bytes"] or hashlib.sha256(raw).hexdigest() != record["sha256"]:
            _fail("r2_graph_runtime", "{} tuple differs".format(role))


def _verify_r2_aligner_evidence(inventory: Mapping[str, Any], capture_root: Path) -> None:
    """Confirm that a rejected semantic diagnostic is never executed or promoted."""

    del capture_root
    validate_r2_aligner_inventory(inventory)


def _verify_r2_document_evidence(documents: Mapping[str, Any], frontier: Path, capture_root: Path) -> None:
    """Replay every typed evidence tuple and every graph AST from immutable captures."""

    from benchmarks.scripts.dicow.common import preflight
    def visit(value: Any) -> None:
        if isinstance(value, Mapping):
            if set(value) == {"path", "bytes", "sha256"}:
                path = _r2_resolve_evidence_path(value["path"], frontier, capture_root)
                raw, info = preflight.stable_read(path, value["path"])
                if stat.S_IMODE(info.st_mode) & 0o222:
                    _fail("r2_evidence_reference", "evidence file is writable")
                actual = {"path": value["path"], "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
                if actual != dict(value):
                    _fail("r2_evidence_reference", "evidence tuple differs: {}".format(value["path"]))
            else:
                for item in value.values():
                    visit(item)
        elif isinstance(value, list):
            for item in value:
                visit(item)
    visit(documents)

    _verify_r2_graph_runtime(documents["graph-contracts.json"]["ast_derivation"])

    rights_raw, _ = preflight.stable_read(frontier / "rights-matrix.json", "frontier rights matrix")
    rights_matrix = _parse_json_object(rights_raw, "frontier rights matrix")
    if rights_matrix.get("schema_version") != "action-specific-rights-matrix-v1" or not isinstance(rights_matrix.get("rows"), list):
        _fail("r2_rights_binding", "canonical rights matrix shape differs")
    matrix_rows = {row.get("entity"): row for row in rights_matrix["rows"] if isinstance(row, Mapping)}
    model_action_map = {
        "private_reference_evaluation": "private_reference_evaluation",
        "private_local_derivative": "private_derivative_conversion",
        "converter_code_publication": "public_converter_code",
        "weight_publication": "public_weight_redistribution",
        "generated_audio": "generated_audio",
        "tracked_declaration": "tracked_metadata_or_scripts",
        "redistribution": "public_weight_redistribution",
    }
    def rights_state(value: Any) -> str:
        if not isinstance(value, str):
            return "unresolved"
        lowered = value.casefold()
        if lowered.startswith("eligible") or lowered.startswith("license_permits"):
            return "allowed"
        if lowered.startswith("not_applicable"):
            return "not_applicable"
        if "forbidden" in lowered:
            return "forbidden"
        return "unresolved"
    for row in documents["rights-bindings.json"]["rows"]:
        entity = R2_RIGHTS_ENTITIES[row["subject"]]
        matrix = matrix_rows.get(entity)
        upstream_action = model_action_map[row["action"]]
        derived = rights_state(matrix.get("actions", {}).get(upstream_action) if isinstance(matrix, Mapping) else None)
        if row["state"] != derived:
            _fail("r2_rights_binding", "{} {} state is not derived from frontier".format(row["subject"], row["action"]))

    for graph in documents["graph-contracts.json"]["candidates"]:
        ast_rows = []
        source_trees = {}
        for record in graph["source_files"]:
            path = _r2_resolve_evidence_path(record["path"], frontier, capture_root)
            raw, _ = preflight.stable_read(path, record["path"])
            if path.suffix != ".py":
                continue
            try:
                tree = ast.parse(raw.decode("utf-8"), filename=record["path"], feature_version=(3, 12))
            except (UnicodeDecodeError, SyntaxError) as error:
                _fail("r2_graph_source", "cannot parse graph source: {}".format(error))
            source_trees[record["path"]] = tree
            ast_rows.append({
                "path": record["path"],
                "ast": ast.dump(tree, annotate_fields=True, include_attributes=False),
            })
        digest = hashlib.sha256(
            json.dumps(sorted(ast_rows, key=lambda row: row["path"]), sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        if digest != graph["source_ast_sha256"]:
            _fail("r2_graph_source", "{} AST digest differs".format(graph["candidate"]))
        if graph.get("state") == "graph_equivalence_unestablished":
            continue
        probe_matches = 0
        extracted_by_path = {}
        for probe in graph["semantic_probes"]:
            source_path = probe["source"]["path"]
            tree = source_trees.get(source_path)
            if tree is None:
                _fail("r2_graph_semantics", "graph semantic probe must cite candidate Python source")
            if source_path not in extracted_by_path:
                extracted_by_path[source_path] = _extract_r2_graph_contract(tree, source_path)
            value: Any = extracted_by_path[source_path]
            for component in probe["json_pointer"]:
                if not isinstance(value, Mapping) or component not in value:
                    _fail("r2_graph_semantics", "graph semantic JSON pointer is unresolved")
                value = value[component]
            if value == R2_EXTERNAL_GRAPH_CONTRACT[probe["contract_key"]]:
                probe_matches += 1
        all_match = probe_matches == len(R2_EXTERNAL_GRAPH_CONTRACT)
        if graph["status"] == "comparable" and not all_match:
            _fail("r2_graph_semantics", "comparable graph does not satisfy the external contract")
        if graph["status"] == "excluded_with_named_follow_up" and all_match:
            _fail("r2_graph_semantics", "matching graph cannot be excluded without distinct evidence")

    for row in documents["leakage-decisions.json"]["rows"]:
        if row["training_evidence"] == []:
            continue
        record = row["training_evidence"][0]
        path = _r2_resolve_evidence_path(record["path"], frontier, capture_root)
        raw, _ = preflight.stable_read(path, record["path"])
        disclosed, generic, universe_kind = _extract_r2_training_disclosure(raw, row)
        if row["disclosed_items"] != disclosed or row["generic_entries"] != generic or row["universe_kind"] != universe_kind:
            _fail("r2_leakage_evidence", "leakage decision is not derived from raw disclosure")

    if documents["writer-resource-ledger.json"].get("schema_version") != "dicow-r2-writer-resource-plan-v2":
        _fail("r2_resource_formula_mismatch", "R3 requires the deferred writer resource plan")
    if documents["constraint-ledger.json"].get("schema_version") != "dicow-r2-candidate-constraint-plan-v2":
        _fail("r2_constraint_invalid", "R3 requires deferred one-sample boundary plans")

    timestamp = documents["qwen-timestamp-contract.json"]
    if timestamp.get("status") == "available":
        fixture_raw, _ = preflight.stable_read(capture_root / "timestamp-fixture.pcm", "timestamp fixture")
        join_raw, _ = preflight.stable_read(capture_root / "timestamp-join.json", "timestamp join")
        join = _parse_json_object(join_raw, "timestamp join")
        generated = _generate_r2_timestamp_pcm(join)
        if fixture_raw != generated:
            _fail("r2_timestamp_contract", "timestamp PCM differs from deterministic generator replay")
        replay_utterances = timestamp["attribution_replay"]["utterances"]
        projected = [
            {key: row[key] for key in ("utterance_id", "start_sample", "end_sample")}
            for row in join["utterances"]
        ]
        if projected != replay_utterances or max(row["end_sample"] for row in replay_utterances) > join["frame_count"]:
            _fail("r2_timestamp_contract", "sample-exact utterance bounds differ from fixture")

    requests = documents["generation-request-universe.json"]["requests"]
    if requests:
        tokenizer_raw, _ = preflight.stable_read(capture_root / "tokenizer.json", "tokenizer semantics")
        tokenizer = _parse_json_object(tokenizer_raw, "tokenizer semantics")
        if tokenizer != {"semantics": "whisper_multilingual_exact"}:
            _fail("r2_generation_semantics", "tokenizer semantics capture differs")
        generation_raw, _ = preflight.stable_read(capture_root / "generation-config.json", "generation config")
        generation = _parse_json_object(generation_raw, "generation config")
    for request in requests:
        expected = {key: request[key] for key in ("ctc_weight", "num_beams", "timestamp_mode")}
        if generation != expected:
            _fail("r2_generation_semantics", "generation config capture differs from request universe")
    terms = _replay_r2_hike_terms(documents["qwen-term-contract.json"])
    if len(terms.decode("utf-8").splitlines()) != 18 or hashlib.sha256(terms).hexdigest() != R2_HIKE_TERMS_SHA256:
        _fail("r2_term_contract", "HiKE derived term digest differs")
    _verify_r2_aligner_evidence(documents["mlx-audio-aligner-inventory.json"], capture_root)


def prepare_r2_audit(output: Path, frontier: Path, spec_path: Path) -> Dict[str, Any]:
    """Materialize a validated R3 audit spec without model inference or weight download."""

    from benchmarks.scripts.dicow.common import preflight
    output = preflight.validate_runtime_path(output, "r2 audit output", must_exist=False)
    frontier = preflight.validate_runtime_path(frontier, "r2 frontier")
    spec_path = preflight.validate_runtime_path(spec_path, "r2 audit spec")
    if os.path.lexists(str(output)):
        _fail("r2_create_only", "audit output already exists")
    spec = preflight.strict_load_json(spec_path, "r2 audit spec")
    if not isinstance(spec, Mapping) or set(spec) != {"schema_version", "run_id", "frontier_record", "captures", "documents"}:
        _fail("r2_audit_spec", "audit spec shape differs")
    if spec.get("schema_version") != R2_AUDIT_SCHEMA_VERSION or not isinstance(spec.get("run_id"), str) or not spec["run_id"]:
        _fail("r2_audit_spec", "audit spec identity differs")
    frontier_record = preflight.artifact_record(frontier, immutable=True)
    if spec.get("frontier_record") != frontier_record:
        _fail("r2_frontier_drift", "frontier tree differs from the spec")
    summary = validate_r2_audit_documents(spec["documents"])
    capture_rows = _r2_capture_rows(spec["captures"])
    if set(capture_rows) != _r2_referenced_capture_names(spec["documents"]):
        _fail("r2_capture_coverage", "capture roster must equal the exact referenced evidence union")
    spec_raw, _ = preflight.stable_read(spec_path, "r2 audit spec")
    fingerprint = hashlib.sha256(spec_raw + preflight.canonical_json_bytes(frontier_record)).hexdigest()
    attempt = output / "attempts" / (fingerprint[:16] + "-0001")
    audit = attempt / "audit"
    try:
        audit.mkdir(parents=True, mode=0o755)
    except OSError as error:
        _fail("r2_create_only", "cannot create audit attempt: {}".format(error))
    records = {}
    capture_records = {}
    identity_rows = {row["candidate"]: row for row in spec["documents"]["model-identities.json"]["models"]}
    for name in sorted(capture_rows):
        row = capture_rows[name]
        source = preflight.validate_runtime_path(Path(row["source_path"]), name + " source")
        raw, info = preflight.stable_read(source, name + " source")
        if stat.S_IMODE(info.st_mode) & 0o222:
            _fail("r2_capture_mutable", "header source is writable: {}".format(name))
        observed = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
        large_aligner = R2_ALIGNER_LARGE_CAPTURE_RECORDS.get(name)
        if (
            row["kind"] != "safetensors_header"
            and len(raw) > 4 * 1024 * 1024
            and large_aligner != observed
        ):
            _fail("r2_audit_contains_checkpoint", "non-header capture exceeds 4 MiB")
        if observed != row["record"]:
            _fail("r2_capture_drift", "header source tuple differs: {}".format(name))
        if row["kind"] == "safetensors_header":
            candidate = PurePosixPath(name).name.removesuffix(".safetensors.header")
            identity = identity_rows[candidate]
            if identity["header_record"] != observed or identity["model_file_bytes"] != row["total_file_bytes"]:
                _fail("r2_capture_drift", "header/model identity binding differs: {}".format(name))
            inspected = inspect_r2_safetensors_header(raw, total_file_bytes=row["total_file_bytes"])
            if identity["header_inspection"] != inspected:
                _fail("r2_capture_drift", "header inspection differs: {}".format(name))
        elif row["kind"] == "hf_lfs_metadata":
            candidate = PurePosixPath(name).name.removesuffix(".tree.json")
            identity = identity_rows[candidate]
            if identity["lfs_record"] != observed:
                _fail("r2_capture_drift", "LFS response/model identity binding differs: {}".format(name))
            lfs = inspect_r2_hf_lfs_metadata(
                raw, expected_model_id=identity["model_id"], expected_revision=identity["revision"]
            )
            if lfs["size"] != identity["model_file_bytes"] or lfs["sha256"] != identity["model_file_lfs_sha256"]:
                _fail("r2_identity_drift", "official LFS size or SHA differs: {}".format(candidate))
        destination = attempt / "source-captures" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o444)
        except OSError as error:
            _fail("r2_create_only", "cannot create header capture {}: {}".format(name, error))
        try:
            view = memoryview(raw)
            offset = 0
            while offset < len(view):
                written = os.write(descriptor, view[offset:])
                if written <= 0:
                    _fail("r2_create_only", "short write while creating capture {}".format(name))
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        capture_records[name] = observed
    aligner_root = attempt / "source-captures" / "mlx-aligner"
    if aligner_root.exists():
        for directory in sorted((path for path in aligner_root.rglob("*") if path.is_dir()), reverse=True):
            os.chmod(directory, 0o555)
        os.chmod(aligner_root, 0o555)
    _verify_r2_document_evidence(spec["documents"], frontier, attempt / "source-captures")
    for name in R2_REQUIRED_AUDIT_DOCUMENTS:
        records[name] = _r2_create_json(audit / name, spec["documents"][name])
    manifest = {
        "schema_version": "dicow-r2-pre-model-audit-manifest-v1",
        "run_id": spec["run_id"],
        "fingerprint": fingerprint,
        "frontier": {"path": str(frontier), "record": frontier_record},
        "spec_record": {"bytes": len(spec_raw), "sha256": hashlib.sha256(spec_raw).hexdigest()},
        "documents": records,
        "source_captures": capture_records,
        "validation_summary": summary,
        "contains_model_output": False,
        "contains_full_checkpoint": False,
    }
    manifest_record = _r2_create_json(attempt / "manifest.json", manifest)
    canonical = {
        "schema_version": "dicow-r2-pre-model-audit-canonical-v1",
        "run_id": spec["run_id"],
        "attempt": str(attempt),
        "manifest_record": manifest_record,
    }
    _r2_create_json(output / "canonical.json", canonical)
    for parent, directories, files in os.walk(str(output), topdown=False):
        for name in files:
            os.chmod(str(Path(parent) / name), 0o444)
        for name in directories:
            os.chmod(str(Path(parent) / name), 0o555)
    os.chmod(str(output), 0o555)
    return verify_r2_audit(output)


def verify_r2_audit(output: Path) -> Dict[str, Any]:
    """Offline replay of a create-only R3 pre-model audit."""

    from benchmarks.scripts.dicow.common import preflight
    output = preflight.validate_runtime_path(output, "r2 audit output")
    output_info = os.lstat(output)
    if not stat.S_ISDIR(output_info.st_mode) or stat.S_IMODE(output_info.st_mode) & 0o222:
        _fail("r2_audit_verify", "audit output must be an immutable directory")
    _r2_file_tuple(output / "canonical.json", "r2 audit canonical")
    canonical = preflight.strict_load_json(output / "canonical.json", "r2 audit canonical")
    if not isinstance(canonical, Mapping) or set(canonical) != {"schema_version", "run_id", "attempt", "manifest_record"}:
        _fail("r2_audit_verify", "canonical selector shape differs")
    if canonical.get("schema_version") != "dicow-r2-pre-model-audit-canonical-v1":
        _fail("r2_audit_verify", "canonical selector schema differs")
    attempt = preflight.validate_runtime_path(Path(canonical["attempt"]), "r2 audit attempt")
    try:
        attempt.relative_to(output / "attempts")
    except ValueError:
        _fail("r2_audit_verify", "canonical attempt escapes output")
    for directory, label in ((output / "attempts", "attempts root"), (attempt, "canonical attempt")):
        info = os.lstat(directory)
        if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o222:
            _fail("r2_audit_verify", "{} must be immutable".format(label))
    manifest_path = attempt / "manifest.json"
    if _r2_file_tuple(manifest_path, "r2 audit manifest") != canonical["manifest_record"]:
        _fail("r2_audit_verify", "manifest tuple differs")
    manifest = preflight.strict_load_json(manifest_path, "r2 audit manifest")
    if (
        not isinstance(manifest, Mapping)
        or manifest.get("schema_version") != "dicow-r2-pre-model-audit-manifest-v1"
        or manifest.get("run_id") != canonical.get("run_id")
        or manifest.get("contains_model_output") is not False
        or manifest.get("contains_full_checkpoint") is not False
    ):
        _fail("r2_audit_verify", "manifest semantics differ")
    frontier = manifest.get("frontier")
    if not isinstance(frontier, Mapping) or set(frontier) != {"path", "record"}:
        _fail("r2_audit_verify", "frontier binding differs")
    frontier_path = preflight.validate_runtime_path(Path(frontier["path"]), "r2 audit frontier")
    if preflight.artifact_record(frontier_path, immutable=True) != frontier["record"]:
        _fail("r2_frontier_drift", "bound frontier tree drifted")
    records = manifest.get("documents")
    if not isinstance(records, Mapping) or set(records) != set(R2_REQUIRED_AUDIT_DOCUMENTS):
        _fail("r2_audit_document_coverage", "manifest document roster differs")
    documents = {}
    for name in R2_REQUIRED_AUDIT_DOCUMENTS:
        path = attempt / "audit" / name
        if _r2_file_tuple(path, name) != records[name]:
            _fail("r2_audit_verify", "{} tuple differs".format(name))
        documents[name] = preflight.strict_load_json(path, name)
    capture_records = manifest.get("source_captures")
    if not isinstance(capture_records, Mapping) or not (set(R2_REQUIRED_HEADER_CAPTURES) | set(R2_REQUIRED_LFS_CAPTURES)).issubset(capture_records):
        _fail("r2_capture_coverage", "manifest header capture roster differs")
    if set(capture_records) != _r2_referenced_capture_names(documents):
        _fail("r2_capture_coverage", "materialized capture roster differs from referenced evidence")
    identity_rows = {row["candidate"]: row for row in documents["model-identities.json"]["models"]}
    for name in sorted(capture_records):
        path = attempt / "source-captures" / name
        raw, info = preflight.stable_read(path, name)
        if stat.S_IMODE(info.st_mode) & 0o222:
            _fail("r2_capture_mutable", "materialized header capture is writable")
        observed = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
        if observed != capture_records[name]:
            _fail("r2_capture_drift", "materialized header capture differs")
        if name in R2_REQUIRED_HEADER_CAPTURES:
            candidate = PurePosixPath(name).name.removesuffix(".safetensors.header")
            identity = identity_rows[candidate]
            if identity["header_record"] != observed:
                _fail("r2_capture_drift", "identity/header record differs")
            if inspect_r2_safetensors_header(raw, total_file_bytes=identity["model_file_bytes"]) != identity["header_inspection"]:
                _fail("r2_capture_drift", "identity/header inspection differs")
        elif name in R2_REQUIRED_LFS_CAPTURES:
            candidate = PurePosixPath(name).name.removesuffix(".tree.json")
            identity = identity_rows[candidate]
            if identity["lfs_record"] != observed:
                _fail("r2_capture_drift", "identity/LFS response record differs")
            lfs = inspect_r2_hf_lfs_metadata(
                raw, expected_model_id=identity["model_id"], expected_revision=identity["revision"]
            )
            if lfs["size"] != identity["model_file_bytes"] or lfs["sha256"] != identity["model_file_lfs_sha256"]:
                _fail("r2_identity_drift", "official LFS replay differs")
    _verify_r2_document_evidence(documents, frontier_path, attempt / "source-captures")
    summary = validate_r2_audit_documents(documents, require_current_volume_snapshot=False)
    if manifest.get("validation_summary") != summary:
        _fail("r2_audit_verify", "validation summary differs")
    expected_files = {
        "manifest.json",
        *("audit/" + name for name in R2_REQUIRED_AUDIT_DOCUMENTS),
        *("source-captures/" + name for name in capture_records),
    }
    expected_directories = {"audit", "source-captures"}
    for name in capture_records:
        parent = PurePosixPath(name).parent
        while str(parent) != ".":
            expected_directories.add("source-captures/" + parent.as_posix())
            parent = parent.parent
    actual_files = set()
    actual_directories = set()
    for path in attempt.rglob("*"):
        relative = path.relative_to(attempt).as_posix()
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            _fail("r2_audit_verify", "attempt contains a symlink")
        if stat.S_ISREG(info.st_mode):
            if stat.S_IMODE(info.st_mode) & 0o222:
                _fail("r2_audit_verify", "attempt contains a writable file")
            actual_files.add(relative)
        elif stat.S_ISDIR(info.st_mode):
            if stat.S_IMODE(info.st_mode) & 0o222:
                _fail("r2_audit_verify", "attempt contains a writable directory")
            actual_directories.add(relative)
        else:
            _fail("r2_audit_verify", "attempt contains an unsupported filesystem entry")
    if actual_files != expected_files:
        _fail("r2_audit_verify", "attempt contains unmanifested files")
    if actual_directories != expected_directories:
        _fail("r2_audit_verify", "attempt contains unmanifested directories")
    output_entries = {path.name for path in output.iterdir()}
    if output_entries != {"attempts", "canonical.json"}:
        _fail("r2_audit_verify", "audit root contains unmanifested entries")
    attempts = list((output / "attempts").iterdir())
    if attempts != [attempt]:
        _fail("r2_audit_verify", "audit root must contain exactly the canonical attempt")
    return {"status": "verified", "run_id": canonical["run_id"], "summary": summary}


def _write_stdout(payload: Mapping[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare = subparsers.add_parser("prepare-e0")
    prepare.add_argument("--output", required=True, type=Path)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--output", required=True, type=Path)
    license_parser = subparsers.add_parser("verify-license")
    license_parser.add_argument("--run", required=True, type=Path)
    prepare_r2 = subparsers.add_parser("prepare-r2-audit")
    prepare_r2.add_argument("--output", required=True, type=Path)
    prepare_r2.add_argument("--frontier", required=True, type=Path)
    prepare_r2.add_argument("--spec", required=True, type=Path)
    verify_r2 = subparsers.add_parser("verify-r2-audit")
    verify_r2.add_argument("--output", required=True, type=Path)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "prepare-e0":
            result = prepare_e0(args.output)
        elif args.command == "verify":
            result = verify(args.output)
        elif args.command == "verify-license":
            result = verify_license(args.run)
        elif args.command == "prepare-r2-audit":
            result = prepare_r2_audit(args.output, args.frontier, args.spec)
        else:
            result = verify_r2_audit(args.output)
    except (InspectionError, PreflightError) as error:
        record = error.as_dict() if isinstance(error, InspectionError) else error.as_record()
        _write_stdout({"ok": False, "error": record})
        return 2
    _write_stdout({"ok": True, "result": result})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
