#!/bin/sh
# Runs the tests in a headless Vim: test/run.sh [test/test_name.vim ...]
#
# Needs yegappan/lsp in $LSP_PLUGIN (default ~/.vim/plugged/lsp) and
# codesonar-lsp in $CODESONAR_LSP, by default the one in $PATH. The status
# line tests use vim-airline in $AIRLINE_PLUGIN and lightline in
# $LIGHTLINE_PLUGIN, if they exist.

cd "$(dirname "$0")/.." || exit 1
mkdir -p test/results

: "${LSP_PLUGIN:=$HOME/.vim/plugged/lsp}"
: "${AIRLINE_PLUGIN:=$HOME/.vim/plugged/vim-airline}"
: "${LIGHTLINE_PLUGIN:=$HOME/.vim/plugged/lightline.vim}"
export AIRLINE_PLUGIN LIGHTLINE_PLUGIN
: "${CODESONAR_LSP:=$(command -v codesonar-lsp)}"
[ -x "$CODESONAR_LSP" ] || { echo "codesonar-lsp not found, set CODESONAR_LSP" >&2; exit 1; }
export CODESONAR_LSP
# Keeps the downloaded analyses of the tests away from the user's.
export XDG_CACHE_HOME="$PWD/test/results/cache"
rm -rf "$XDG_CACHE_HOME"
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
