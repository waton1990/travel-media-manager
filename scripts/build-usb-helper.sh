#!/bin/bash
set -euo pipefail
travel_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$travel_project_dir"
travel_helper_dir="$travel_project_dir/work/usb-helper"
travel_uv="${TRAVEL_UV:-$(command -v uv || true)}"
if [[ -z "$travel_uv" ]]; then
  printf '构建手机组件需要 uv；应用运行时不需要 uv 或 Python。\n' >&2
  exit 1
fi
mkdir -p "$travel_helper_dir"
if [[ ! -x "$travel_helper_dir/venv/bin/python" ]]; then
  "$travel_uv" venv --python 3.12 "$travel_helper_dir/venv"
fi
"$travel_uv" pip install --python "$travel_helper_dir/venv/bin/python" \
  --requirement "$travel_project_dir/scripts/usb-helper-requirements.lock"
"$travel_helper_dir/venv/bin/python" -m PyInstaller \
  --noconfirm --clean --onedir --name iphone-usb-helper \
  --distpath "$travel_helper_dir/dist" --workpath "$travel_helper_dir/build" \
  --specpath "$travel_helper_dir" --copy-metadata pymobiledevice3 \
  --collect-data certifi --collect-data tzdata \
  "$travel_project_dir/scripts/iphone_usb_helper.py"
"$travel_helper_dir/venv/bin/python" "$travel_project_dir/scripts/collect-helper-licenses.py" \
  "$travel_helper_dir/dist/iphone-usb-helper/ThirdParty"
