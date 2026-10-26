#!/bin/bash
# Lists a reusable 100k-file fixture and prints listing/sort timings.
# Usage: Scripts/benchmark.sh [count]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift run -c release OpenLiftBench "${1:-100000}"
