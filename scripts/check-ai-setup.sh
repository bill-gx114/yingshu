#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I -B Tests/AISetupChecks.py
