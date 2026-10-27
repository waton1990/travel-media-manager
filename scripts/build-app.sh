#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
bash scripts/build-usb-helper.sh
swift build --configuration release --product TravelMediaManager
binary_dir="$(swift build --configuration release --show-bin-path)"
output_dir="$project_dir/outputs"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.travel-media-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/旅行素材管家.app"
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
verification_args=()
if [[ -n "${TRAVEL_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$TRAVEL_SIGNING_IDENTITY" --options runtime --timestamp "$app_dir"
  verification_args=(--developer-id)
else
  codesign --force --sign - "$app_dir"
fi
python3 "$project_dir/scripts/verify-app-signature.py" "$app_dir" \
  ${verification_args[@]+"${verification_args[@]}"}

# Keep the previous application until its replacement has passed verification.
final_app_dir="$output_dir/旅行素材管家.app"
previous_dir=""
if [[ -e "$final_app_dir" || -L "$final_app_dir" ]]; then
  previous_dir="$(mktemp -d "$output_dir/previous-build.XXXXXX")"
  mv "$final_app_dir" "$previous_dir/旅行素材管家.app"
fi
if ! mv "$app_dir" "$final_app_dir"; then
  if [[ -n "$previous_dir" ]]; then
    mv "$previous_dir/旅行素材管家.app" "$final_app_dir"
  fi
  printf '无法安装新构建，已尝试恢复原应用。\n' >&2
  exit 1
fi
printf '应用已生成：%s\n' "$final_app_dir"
if [[ -n "$previous_dir" ]]; then
  printf '原应用已保留：%s\n' "$previous_dir/旅行素材管家.app"
fi
