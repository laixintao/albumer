#!/bin/bash
set -euo pipefail

app_path="${1:?Usage: open-dev-app.sh /absolute/path/to/Albumer.app}"

# Restart only this checkout's development app, so LaunchServices cannot reuse
# an older process or redirect to an installed release with the same bundle ID.
/usr/bin/osascript -l JavaScript - "$app_path" <<'JXA'
ObjC.import('AppKit');
function run(argv) {
    const apps = $.NSWorkspace.sharedWorkspace.runningApplications;
    for (let i = 0; i < apps.count; i++) {
        const app = apps.objectAtIndex(i);
        if (!app.bundleURL || ObjC.unwrap(app.bundleURL.path) !== argv[0]) continue;
        if (!app.terminate) throw new Error('Could not quit the previous development app.');
        for (let attempt = 0; attempt < 100 && !app.isTerminated; attempt++) {
            // NSRunningApplication refreshes its state through the current run loop.
            $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.05));
        }
        if (!app.isTerminated) throw new Error('The previous development app has not quit yet.');
    }
}
JXA

/usr/bin/open -n "$app_path"
