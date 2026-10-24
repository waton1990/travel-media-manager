#!/bin/bash
set -euo pipefail

travel_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
travel_developer_dir="$(xcode-select -p)"
cd "$travel_project_dir"
mkdir -p work

# Honor an explicit Xcode selection for this invocation as xcrun does.
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  travel_developer_dir="$DEVELOPER_DIR"
  if [[ "$travel_developer_dir" == *.app ]]; then
    travel_developer_dir="$travel_developer_dir/Contents/Developer"
  fi
fi

travel_test_args=(test --disable-xctest --enable-swift-testing)
if [[ ! -d "$travel_developer_dir/Toolchains/XcodeDefault.xctoolchain" ]]; then
  # Standalone CLT ships Swift Testing outside its default SwiftPM search paths.
  # Full Xcode configures these paths itself and uses the standard invocation.
  travel_framework_dir="$travel_developer_dir/Library/Developer/Frameworks"
  travel_testing_plugin="$travel_developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
  if [[ ! -d "$travel_framework_dir/Testing.framework" || ! -f "$travel_testing_plugin" ]]; then
    printf '所选开发工具未包含可运行的 Swift Testing：%s\n' "$travel_developer_dir" >&2
    printf '请使用包含 Swift Testing 的 Xcode 或 Command Line Tools；本脚本不会安装依赖。\n' >&2
    exit 1
  fi
  travel_test_args+=(
    --build-system native
    -Xswiftc -F -Xswiftc "$travel_framework_dir"
    -Xswiftc -load-plugin-library -Xswiftc "$travel_testing_plugin"
    -Xlinker -rpath -Xlinker "$travel_framework_dir"
  )
fi

# pipefail preserves failures from swift test while retaining a readable log.
{
  printf '开发工具：%s\n' "$travel_developer_dir"
  xcrun swift --version
  xcrun swift "${travel_test_args[@]}" "$@"
} 2>&1 | tee "$travel_project_dir/work/tests.log"
