"""Create or re-verify ignored acceptance-pack fixtures from pinned public sources."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from acceptance_pack import (
    PackError,
    create_fixture,
    fixture_named,
    load_pack,
    verify_prepared_fixture,
)

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = REPOSITORY_ROOT / "benchmarks/datasets/acceptance-pack-v1.json"
DEFAULT_ROOT = REPOSITORY_ROOT / "benchmarks/samples/public/acceptance-pack-v1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument(
        "--fixture",
        action="append",
        choices=("hike-code-switch-v1", "ami-in1009-ihm-mix-v1"),
        help="Build or re-verify one fixture; default is every fixture.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        pack = load_pack(args.manifest)
        fixture_ids = args.fixture or [fixture["fixture_id"] for fixture in pack["fixtures"]]
        for fixture_id in fixture_ids:
            fixture = fixture_named(pack, fixture_id)
            outcome = create_fixture(args.root, fixture)
            verify_prepared_fixture(args.root, fixture)
            print(f"PASS {fixture_id}: {outcome}")
    except PackError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
