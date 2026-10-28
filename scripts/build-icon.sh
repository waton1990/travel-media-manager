#!/bin/bash
# Export the approved RGBA artwork without changing its colors or composition.
set -euo pipefail

travel_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
travel_source="${1:-$travel_project_dir/assets/icon-source.png}"

if [[ ! -f "$travel_source" ]]; then
  echo "Icon source not found: $travel_source" >&2
  exit 1
fi

travel_width="$(sips -g pixelWidth "$travel_source" | awk '/pixelWidth:/ {print $2}')"
travel_height="$(sips -g pixelHeight "$travel_source" | awk '/pixelHeight:/ {print $2}')"
travel_alpha="$(sips -g hasAlpha "$travel_source" | awk '/hasAlpha:/ {print $2}')"
if [[ "$travel_width" != "$travel_height" || "$travel_width" -lt 1024 || "$travel_alpha" != yes ]]; then
  echo "Expected square RGBA PNG artwork of at least 1024 x 1024 pixels." >&2
  exit 1
fi

mkdir -p "$travel_project_dir/work"
travel_work="$(mktemp -d "$travel_project_dir/work/icon-export.XXXXXX")"
trap 'rm -rf "$travel_work"' EXIT
travel_iconset="$travel_work/AppIcon.iconset"
mkdir -p "$travel_iconset"

for travel_points in 16 32 128 256 512; do
  for travel_scale in 1 2; do
    travel_pixels=$((travel_points * travel_scale))
    travel_suffix=""
    if [[ "$travel_scale" == 2 ]]; then travel_suffix="@2x"; fi
    sips -s format png -z "$travel_pixels" "$travel_pixels" "$travel_source" \
      --out "$travel_iconset/icon_${travel_points}x${travel_points}${travel_suffix}.png" >/dev/null
  done
done

iconutil -c icns "$travel_iconset" -o "$travel_work/AppIcon.icns"
# Decode the result once before replacing the published resources.
iconutil -c iconset "$travel_work/AppIcon.icns" -o "$travel_work/verified.iconset"
cp "$travel_iconset/icon_512x512@2x.png" "$travel_project_dir/assets/icon.png"
cp "$travel_work/AppIcon.icns" "$travel_project_dir/packaging/AppIcon.icns"
echo "Exported 10 icon representations (16–1024 px), assets/icon.png, and packaging/AppIcon.icns."
