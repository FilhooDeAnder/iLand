#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/scripts/test_unit.sh"
"$root/scripts/test_capture.sh"
