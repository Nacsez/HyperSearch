#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[hypersearch] creating virtual environment"
python3 -m venv "${ROOT_DIR}/.venv"
source "${ROOT_DIR}/.venv/bin/activate"

echo "[hypersearch] installing api dependencies"
pip install --upgrade pip
pip install -e "${ROOT_DIR}/apps/api[all]"

echo "[hypersearch] installing ui dependencies"
cd "${ROOT_DIR}/apps/ui"
npm install
npm run build

echo "[hypersearch] done"

