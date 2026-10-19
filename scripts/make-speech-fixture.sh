#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Tests/fixtures
say -v Tingting -r 170 -f Tests/fixtures/mandarin-diagnostic.txt -o Tests/fixtures/mandarin-diagnostic.aiff
afinfo Tests/fixtures/mandarin-diagnostic.aiff
