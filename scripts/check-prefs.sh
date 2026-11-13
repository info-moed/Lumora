#!/bin/bash
# Every preference read or write must go through Prefs.store, so test runs never touch (or share) the app's real
# preferences. That includes SwiftUI's @AppStorage, which needs `store: Prefs.store`.
cd "$(dirname "$0")/.." || exit 2
bad=$(grep -rn --include=*.swift -e 'UserDefaults\.standard' -e '@AppStorage(' Lumora \
      | grep -v '^Lumora/Core/Workflow/Prefs.swift:' | grep -v 'store: Prefs.store')
if [ -n "$bad" ]; then echo "Use Prefs.store instead of the standard preferences:"; echo "$bad"; exit 1; fi
echo "Preferences: OK"
