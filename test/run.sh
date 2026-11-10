#!/bin/sh
# Runs the tests in a headless Vim: test/run.sh [test/test_name.vim ...]
#
# Needs yegappan/lsp in $LSP_PLUGIN (default ~/.vim/plugged/lsp) and
# codesonar-lsp in $CODESONAR_LSP, by default the one in $PATH.

cd "$(dirname "$0")/.." || exit 1
mkdir -p test/results

: "${LSP_PLUGIN:=$HOME/.vim/plugged/lsp}"
: "${CODESONAR_LSP:=$(command -v codesonar-lsp)}"
[ -x "$CODESONAR_LSP" ] || { echo "codesonar-lsp not found, set CODESONAR_LSP" >&2; exit 1; }
export CODESONAR_LSP
[ $# -gt 0 ] || set -- test/test_*.vim
status=0

for file in "$@"; do
  log="test/results/$(basename "$file" .vim).log"
  rm -f "$log"
  timeout 120 vim -Nu NONE -i NONE -n -es --not-a-term \
    --cmd "set runtimepath^=$PWD,$LSP_PLUGIN" \
    --cmd "let g:test_file = '$file' | let g:test_log = '$log'" \
    -S test/runner.vim
  result=$?
  [ -f "$log" ] && cat "$log" || echo "FAILED  $file did not finish"
  [ $result -eq 0 ] || status=1
done

exit $status
