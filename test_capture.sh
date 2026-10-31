#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/private/tmp}/iland-capture-tests.XXXXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/swift-cache" "$tmp/clang-cache"
export SWIFT_MODULECACHE_PATH="$tmp/swift-cache"
export CLANG_MODULE_CACHE_PATH="$tmp/clang-cache"
export MACOSX_DEPLOYMENT_TARGET=13.0

run_test() {
    local name="$1"
    shift
    printf '\n==> Compiling %s\n' "$name"
    swiftc -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$tmp/swift-cache" "$@" -o "$tmp/$name"
    printf '==> Running %s\n' "$name"
    "$tmp/$name"
}

run_test capture_model "$root/test_capture_model.swift" "$root/Sources/iLand/Capture.swift" "$root/Sources/iLand/S3.swift" "$root/Sources/iLand/CapturePrefs.swift" "$root/Sources/iLand/ScreenCapture.swift" "$root/Sources/iLand/ScrollCapture.swift" "$root/Sources/iLand/AreaSelector.swift" "$root/Sources/iLand/Toast.swift" "$root/Sources/iLand/ScreenTools.swift" "$root/Sources/iLand/Notes.swift" "$root/Sources/iLand/CaptureLibrary.swift" "$root/Sources/iLand/DeepLink.swift" "$root/Sources/iLand/WindowBackground.swift"
run_test capture_editor "$root/test_capture_editor.swift" "$root/Sources/iLand/CaptureEditor.swift" "$root/Sources/iLand/CaptureCanvas.swift" "$root/Sources/iLand/CaptureBackdrop.swift" "$root/Sources/iLand/CaptureBackdropPanel.swift" "$root/Sources/iLand/CapturePrefs.swift" "$root/Sources/iLand/Toast.swift"
run_test capture_output "$root/test_capture_output.swift" "$root/Sources/iLand/CapturePrefs.swift" "$root/Sources/iLand/HotKey.swift" "$root/Sources/iLand/WindowBackground.swift"
run_test scroll_stitch "$root/test_scroll_stitch.swift" "$root/Sources/iLand/ScrollCapture.swift" "$root/Sources/iLand/ScreenCapture.swift" "$root/Sources/iLand/AreaSelector.swift" "$root/Sources/iLand/Toast.swift" "$root/Sources/iLand/CapturePrefs.swift" "$root/Sources/iLand/ScreenTools.swift" "$root/Sources/iLand/Notes.swift" "$root/Sources/iLand/WindowBackground.swift"
run_test s3 "$root/test_s3.swift" "$root/Sources/iLand/S3.swift"
run_test screentools "$root/test_screentools.swift" "$root/Sources/iLand/ScreenTools.swift" "$root/Sources/iLand/Notes.swift"
printf '\nAll capture tests passed.\n'
