#!/usr/bin/env bash
# Validate correlated M5 traces; Python 3 uses only its standard library.
set -euo pipefail
harness_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--self-test" && $# -eq 1 ]]; then
    exec python3 -B "$harness_dir/test_m5_trace.py"
fi
exec python3 -B "$harness_dir/assert_m5_trace.py" "$@"
