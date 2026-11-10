#!/bin/sh
# Stands in for a browser: records the opened URL.
printf '%s\n' "$1" > "$FAKE_BROWSER_LOG"
