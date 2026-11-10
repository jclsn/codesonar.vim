#!/bin/sh
# Stands in for the codesonar CLI: records its arguments, the password
# file content and the working directory, then exits with $FAKE_STATUS.
out="$FAKE_CODESONAR_LOG"
printf '%s\n' "$@" > "$out"
pwfile=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-hubpwfile" ] && pwfile="$arg"
  prev="$arg"
done
[ -n "$pwfile" ] && cat "$pwfile" > "$out.pw" && stat -c %a "$pwfile" > "$out.mode"
pwd > "$out.cwd"
echo "codesonar: Analysis initialized."
exit "${FAKE_STATUS:-0}"
