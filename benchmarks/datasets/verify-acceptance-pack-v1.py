"""Read-only integrity verifier for the prepared Korean-English acceptance pack."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from acceptance_pack import (
    PackError,
    fixture_named,
    load_pack,
    verify_prepared_fixture,
    verify_source_files,
)

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = REPOSITORY_ROOT / "benchmarks/datasets/acceptance-pack-v1.json"
DEFAULT_ROOT = REPOSITORY_ROOT / "benchmarks/samples/public/acceptance-pack-v1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument(
        "--source-only",
        action="store_true",
        help="Verify pinned downloads only, without requiring prepared fixtures.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        pack = load_pack(args.manifest)
        for fixture_data in pack["fixtures"]:
            fixture = fixture_named(pack, fixture_data["fixture_id"])
            verify_source_files(args.root, fixture)
            if not args.source_only:
                verify_prepared_fixture(args.root, fixture)
            print(f"PASS {fixture['fixture_id']}: {'sources' if args.source_only else 'sources + prepared fixture'}")
    except PackError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
