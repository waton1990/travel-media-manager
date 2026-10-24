#!/bin/bash
set -euo pipefail

travel_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
travel_harness_dir="$travel_project_dir/work/app-model-tests"
mkdir -p "$travel_harness_dir"
travel_core_sources=("$travel_project_dir"/Sources/TravelArchiveCore/*.swift)

# Compile production logic directly; the stand-in has no USB, network, process,
# or media implementation. This test never builds or starts USBHelperClient.
xcrun swiftc -parse-as-library -emit-module -emit-library \
  -module-name TravelArchiveCore \
  -emit-module-path "$travel_harness_dir/TravelArchiveCore.swiftmodule" \
  "${travel_core_sources[@]}" \
  -o "$travel_harness_dir/libTravelArchiveCore.dylib"
xcrun swiftc -parse-as-library \
  -I "$travel_harness_dir" -L "$travel_harness_dir" -lTravelArchiveCore \
  -Xlinker -rpath -Xlinker "$travel_harness_dir" \
  "$travel_project_dir/Sources/TravelMediaManager/AppModel.swift" \
  "$travel_project_dir/Tests/TravelMediaManagerHarness/MockIPhoneSource.swift" \
  "$travel_project_dir/Tests/TravelMediaManagerHarness/ModelChecks.swift" \
  -o "$travel_harness_dir/model-checks"
"$travel_harness_dir/model-checks" | tee "$travel_harness_dir/results.log"
