#!/bin/bash
set -euo pipefail

travel_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
travel_place_test_dir="$travel_project_dir/work/place-resolution-tests"
travel_place_target="$(uname -m)-apple-macosx13.0"
mkdir -p "$travel_place_test_dir"
travel_core_sources=("$travel_project_dir"/Sources/TravelArchiveCore/*.swift)

# Compile the production resolver and Core with entirely synthetic lookup and
# delay closures. No IPhoneSource, USB client, real geocoder, or media is used.
xcrun swiftc -swift-version 5 -target "$travel_place_target" \
  -parse-as-library -emit-module -emit-library -module-name TravelArchiveCore \
  -emit-module-path "$travel_place_test_dir/TravelArchiveCore.swiftmodule" \
  -Xlinker -install_name -Xlinker '@rpath/libTravelArchiveCore.dylib' \
  "${travel_core_sources[@]}" \
  -o "$travel_place_test_dir/libTravelArchiveCore.dylib"
xcrun swiftc -swift-version 5 -target "$travel_place_target" -parse-as-library \
  -I "$travel_place_test_dir" -L "$travel_place_test_dir" -lTravelArchiveCore \
  -Xlinker -rpath -Xlinker "$travel_place_test_dir" \
  "$travel_project_dir/Sources/TravelMediaManager/PlaceNameResolver.swift" \
  "$travel_project_dir/Tests/TravelMediaManagerHarness/PlaceResolutionChecks.swift" \
  -o "$travel_place_test_dir/place-resolution-checks"
"$travel_place_test_dir/place-resolution-checks" | tee "$travel_place_test_dir/results.log"
