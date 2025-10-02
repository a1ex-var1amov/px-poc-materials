#!/usr/bin/env bash
set -euo pipefail
DIR=${1:-./results}
cd "$DIR"
echo "Serving $PWD on http://127.0.0.1:8080"
python3 -m http.server 8080

