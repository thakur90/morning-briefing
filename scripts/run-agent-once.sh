#!/bin/zsh
# Starts the installed Briefing.app agent once via launchd (like the real agent,
# so macOS attributes permissions to the app) and prints its output.
# Usage: scripts/run-agent-once.sh [timeout-seconds]
set -euo pipefail

label=com.thakur90.briefing.once
log=~/Library/Logs/Briefing/agent-once.log
plist=$(mktemp -t briefing-once).plist
timeout=${1:-150}

mkdir -p ${log:h}
rm -f $log
cat > $plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>$HOME/Applications/Briefing.app/Contents/MacOS/briefing</string>
    <string>agent</string><string>--once</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict></plist>
PLIST

launchctl bootout gui/$UID/$label 2>/dev/null || true
launchctl bootstrap gui/$UID $plist
trap 'launchctl bootout gui/$UID/$label 2>/dev/null || true; rm -f $plist' EXIT

# Wait for the job to exit (it stays listed but with no PID once done).
for _ in {1..$timeout}; do
  sleep 1
  launchctl print gui/$UID/$label 2>/dev/null | grep -q 'pid = ' || break
done
cat $log
