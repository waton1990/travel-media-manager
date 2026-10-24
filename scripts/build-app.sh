#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
bash scripts/build-usb-helper.sh
swift build --configuration release --product TravelMediaManager
binary_dir="$(swift build --configuration release --show-bin-path)"
app_dir="$project_dir/outputs/旅行素材管家.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
ditto "$project_dir/work/usb-helper/dist/iphone-usb-helper" "$app_dir/Contents/Resources/USBHelper"
cp "$binary_dir/TravelMediaManager" "$app_dir/Contents/MacOS/TravelMediaManager"
cp "$project_dir/packaging/Info.plist" "$app_dir/Contents/Info.plist"
if [ -f "$project_dir/packaging/AppIcon.icns" ]; then
  cp "$project_dir/packaging/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
fi
chmod +x "$app_dir/Contents/MacOS/TravelMediaManager"
mkdir -p "$app_dir/Contents/Resources/Licenses"
for travel_license in LICENSE NOTICE THIRD_PARTY_NOTICES.md; do
  cp "$project_dir/$travel_license" "$app_dir/Contents/Resources/Licenses/$travel_license"
done
ditto "$project_dir/third-party" "$app_dir/Contents/Resources/Licenses/third-party"
codesign --force --deep --sign - "$app_dir"
codesign --verify --strict "$app_dir"
printf '应用已生成：%s\n' "$app_dir"
