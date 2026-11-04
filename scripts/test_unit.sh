#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
tmp="$(mktemp -d "${TMPDIR:-/private/tmp}/iland-unit-tests.XXXXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cache="$root/.build/test-module-cache"
mkdir -p "$cache"

run_test() {
    local name="$1"; shift
    printf "\n==> %s\n" "$name"
    swiftc -module-cache-path "$cache" -parse-as-library "$@" -o "$tmp/$name"
    "$tmp/$name"
}

run_test test_nowplaying "$root/Sources/iLand/NowPlayingTrack.swift" "$root/Tests/Unit/test_nowplaying.swift"
run_test test_activity "$root/Sources/iLand/ActivityLog.swift" "$root/Tests/Unit/test_activity.swift"
run_test test_alerts "$root/Sources/iLand/AlertEngine.swift" "$root/Tests/Unit/test_alerts.swift"
run_test test_clickup "$root/Sources/iLand/SuspectTracker.swift" "$root/Sources/iLand/ClickUp.swift" "$root/Sources/iLand/Prefs.swift" "$root/Tests/Unit/test_clickup.swift"
run_test test_clipboard "$root/Sources/iLand/Clipboard.swift" "$root/Tests/Unit/test_clipboard.swift"
run_test test_history "$root/Sources/iLand/SuspectTracker.swift" "$root/Sources/iLand/History.swift" "$root/Tests/Unit/test_history.swift"
run_test test_ears "$root/Sources/iLand/EarDials.swift" "$root/Tests/Unit/test_ears.swift"
run_test test_machines "$root/Sources/iLand/Machines.swift" "$root/Tests/Unit/test_machines.swift"
run_test test_opener "$root/Sources/iLand/ProjectOpener.swift" "$root/Sources/iLand/Profile.swift" "$root/Sources/iLand/Prefs.swift" "$root/Sources/iLand/Projects.swift" "$root/Sources/iLand/SuspectTracker.swift" "$root/Tests/Unit/test_opener.swift"
run_test test_pomodoro "$root/Sources/iLand/Pomodoro.swift" "$root/Sources/iLand/SwipeTracker.swift" "$root/Tests/Unit/test_pomodoro.swift"
run_test test_ports "$root/Sources/iLand/SuspectTracker.swift" "$root/Sources/iLand/PortScanner.swift" "$root/Tests/Unit/test_ports.swift"
run_test test_prefs "$root/Sources/iLand/Prefs.swift" "$root/Tests/Unit/test_prefs.swift"
run_test test_privacy "$root/Sources/iLand/SuspectTracker.swift" "$root/Sources/iLand/Privacy.swift" "$root/Tests/Unit/test_privacy.swift"
run_test test_projects "$root/Sources/iLand/SuspectTracker.swift" "$root/Sources/iLand/Projects.swift" "$root/Sources/iLand/Prefs.swift" "$root/Tests/Unit/test_projects.swift"
run_test test_resume "$root/Sources/iLand/SuspectTracker.swift" "$root/Sources/iLand/Projects.swift" "$root/Sources/iLand/Prefs.swift" "$root/Sources/iLand/Resume.swift" "$root/Tests/Unit/test_resume.swift"
run_test test_s3 "$root/Sources/iLand/S3.swift" "$root/Tests/Unit/test_s3.swift"
run_test test_screentools "$root/Sources/iLand/ScreenTools.swift" "$root/Sources/iLand/Notes.swift" "$root/Tests/Unit/test_screentools.swift"
run_test test_sensor "$root/Sources/iLand/SensorExecutable.swift" "$root/Tests/Unit/test_sensor.swift"
run_test test_share "$root/Sources/iLand/Updater.swift" "$root/Sources/iLand/Energy.swift" "$root/Sources/iLand/AlertEngine.swift" "$root/Sources/iLand/History.swift" "$root/Sources/iLand/Providers.swift" "$root/Sources/iLand/ClaudeChat.swift" "$root/Sources/iLand/Prefs.swift" "$root/Sources/iLand/Projects.swift" "$root/Sources/iLand/SuspectTracker.swift" "$root/Tests/Unit/test_share.swift"
run_test test_shelf "$root/Sources/iLand/Shelf.swift" "$root/Sources/iLand/Providers.swift" "$root/Sources/iLand/ClaudeChat.swift" "$root/Sources/iLand/Prefs.swift" "$root/Sources/iLand/Projects.swift" "$root/Sources/iLand/SuspectTracker.swift" "$root/Tests/Unit/test_shelf.swift"
run_test test_summary "$root/Sources/iLand/SuspectTracker.swift" "$root/Sources/iLand/ActivityLog.swift" "$root/Sources/iLand/Projects.swift" "$root/Sources/iLand/Prefs.swift" "$root/Sources/iLand/Resume.swift" "$root/Sources/iLand/DailySummary.swift" "$root/Tests/Unit/test_summary.swift"
run_test test_supervisor "$root/Sources/iLand/SuspectTracker.swift" "$root/Tests/Unit/test_supervisor.swift"
run_test test_thread "$root/Sources/iLand/AgentThread.swift" "$root/Tests/Unit/test_thread.swift"
run_test test_timer "$root/Sources/iLand/ActivityLog.swift" "$root/Sources/iLand/TimerRules.swift" "$root/Tests/Unit/test_timer.swift"
run_test test_tunnels "$root/Sources/iLand/Tunnels.swift" "$root/Tests/Unit/test_tunnels.swift"
run_test test_usage "$root/Sources/iLand/UsageFetcher.swift" "$root/Sources/iLand/Providers.swift" "$root/Sources/iLand/ClaudeChat.swift" "$root/Sources/iLand/Prefs.swift" "$root/Sources/iLand/Projects.swift" "$root/Sources/iLand/SuspectTracker.swift" "$root/Tests/Unit/test_usage.swift"

printf "\nAll unit tests passed.\n"
