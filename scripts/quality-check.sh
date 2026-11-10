#!/bin/bash
# All checks run locally. No GitHub Actions job or provider credentials required.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
python3 scripts/check-privacy.py --self-test
python3 scripts/check-privacy.py
python3 -m unittest discover -s scripts/tests
bash scripts/test.sh
git diff --check
echo "Local automated quality checks passed. Native acceptance and signed updater installation still require their separate checks."
