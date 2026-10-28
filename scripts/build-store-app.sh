#!/bin/bash
# Local Developer ID sandbox candidate only; this is not a Store distribution signature.
set -euo pipefail
travel_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$travel_project_dir"
travel_signing_identity="${TRAVEL_STORE_LOCAL_SIGNING_IDENTITY:-}"
if [[ -z "$travel_signing_identity" || "$travel_signing_identity" == '-' ]]; then
  printf '请设置 TRAVEL_STORE_LOCAL_SIGNING_IDENTITY 为本机 Developer ID Application 身份。\n' >&2
  printf '沙盒候选包的主程序及 Python 组件需要同团队签名，以通过 hardened runtime 的库验证；此脚本不生成商店分发签名。\n' >&2
  exit 1
fi
travel_app_entitlements="${TRAVEL_STORE_APP_ENTITLEMENTS:-$travel_project_dir/packaging/store-app.entitlements}"
travel_app_entitlements="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve(strict=True))' "$travel_app_entitlements")"
travel_output_dir="$travel_project_dir/outputs/app-store"
mkdir -p "$travel_output_dir"
travel_staging_dir="$(mktemp -d "$travel_output_dir/.build.XXXXXX")"
trap 'rm -rf "$travel_staging_dir"' EXIT

# Always rebuild the locked helper. Never silently reuse a different release's binary.
TRAVEL_SIGNING_IDENTITY= bash scripts/build-usb-helper.sh
# PyInstaller's BUNDLE splits code and data into the standard macOS locations.
# Keep EXE(console=True) so our existing stdin/stdout protocol stays unchanged.
cp work/usb-helper/iphone-usb-helper.spec work/usb-helper/store-usb-helper.spec
python3 - <<'PY'
from pathlib import Path
import plistlib
with Path('packaging/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
helper_info = {'LSUIElement': True, 'CFBundleVersion': info['CFBundleVersion'],
               'LSMinimumSystemVersion': info['LSMinimumSystemVersion']}
with Path('work/usb-helper/store-usb-helper.spec').open('a') as stream:
    stream.write('\napp = BUNDLE(coll, name="USBHelper.app", '
                 'bundle_identifier="io.github.waton1990.travel-media-manager.usb-helper", '
                 f'version={info["CFBundleShortVersionString"]!r}, info_plist={helper_info!r})\n')
PY
work/usb-helper/venv/bin/python -m PyInstaller --noconfirm \
  --distpath work/usb-helper/store-dist --workpath work/usb-helper/build \
  work/usb-helper/store-usb-helper.spec
swift build --configuration release --product TravelMediaManager
travel_binary_dir="$(swift build --configuration release --show-bin-path)"
travel_app="$travel_staging_dir/旅行素材管家.app"
mkdir -p "$travel_app/Contents/MacOS" "$travel_app/Contents/Helpers" "$travel_app/Contents/Resources/Licenses"
ditto "$travel_project_dir/work/usb-helper/store-dist/USBHelper.app" "$travel_app/Contents/Helpers/USBHelper.app"
cp "$travel_binary_dir/TravelMediaManager" "$travel_app/Contents/MacOS/TravelMediaManager"
cp "$travel_project_dir/packaging/Info.plist" "$travel_app/Contents/Info.plist"
cp "$travel_project_dir/packaging/PrivacyInfo.xcprivacy" "$travel_app/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$travel_app_entitlements" "$travel_app/Contents/Resources/StoreBuildEntitlements.plist"
if [[ -f "$travel_project_dir/packaging/AppIcon.icns" ]]; then
  cp "$travel_project_dir/packaging/AppIcon.icns" "$travel_app/Contents/Resources/AppIcon.icns"
fi
for travel_license in LICENSE NOTICE THIRD_PARTY_NOTICES.md; do
  cp "$travel_project_dir/$travel_license" "$travel_app/Contents/Resources/Licenses/$travel_license"
done
ditto "$travel_project_dir/third-party" "$travel_app/Contents/Resources/Licenses/third-party"

# Sign from the inside out. Only the launched helper receives inheritance keys;
# shared libraries and Python extension modules do not receive process entitlements.
python3 - "$travel_app" "$travel_project_dir" "$travel_signing_identity" <<'PY'
import importlib.util
from pathlib import Path
import subprocess
import sys
app, project = map(Path, sys.argv[1:3])
signing_identity = sys.argv[3]
signing = ["/usr/bin/codesign", "--force", "--sign", signing_identity, "--options", "runtime", "--timestamp"]
spec = importlib.util.spec_from_file_location("store_verifier", project / "scripts/verify-store-app.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
main = app / "Contents/MacOS/TravelMediaManager"
helper_bundle = app / "Contents/Helpers/USBHelper.app"
helper = helper_bundle / "Contents/MacOS/iphone-usb-helper"
for path in module.macho_files(app):
    if path in (main, helper):
        continue
    subprocess.run([*signing, str(path)], check=True)
for framework in sorted(app.rglob("*.framework"), key=lambda item: len(item.parts), reverse=True):
    if not framework.is_symlink():
        subprocess.run([*signing, str(framework)], check=True)
subprocess.run([*signing,
                "--entitlements", str(project / "packaging/store-helper.entitlements"), str(helper_bundle)], check=True)
PY
codesign --force --sign "$travel_signing_identity" --options runtime --timestamp \
  --entitlements "$travel_app_entitlements" "$travel_app"
python3 scripts/verify-store-app.py "$travel_app" --entitlements "$travel_app_entitlements"

travel_final_app="$travel_output_dir/旅行素材管家.app"
travel_previous_dir=""
if [[ -e "$travel_final_app" || -L "$travel_final_app" ]]; then
  travel_previous_dir="$(mktemp -d "$travel_output_dir/previous-build.XXXXXX")"
  mv "$travel_final_app" "$travel_previous_dir/旅行素材管家.app"
fi
if ! mv "$travel_app" "$travel_final_app"; then
  if [[ -n "$travel_previous_dir" ]]; then
    mv "$travel_previous_dir/旅行素材管家.app" "$travel_final_app"
  fi
  exit 1
fi
printf '本地商店沙盒候选包已生成：%s\n' "$travel_final_app"
printf '签名用途：Developer ID 本机沙盒验收（非 Mac App Store 分发签名）。\n'
printf '尚未完成商店分发签名、App Store 上传或审核。\n'
