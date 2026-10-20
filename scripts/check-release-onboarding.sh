#!/bin/bash
# Disposable fixtures only: no AI download, package installation or user data writes.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -B Tests/ReleaseOnboardingChecks.py
