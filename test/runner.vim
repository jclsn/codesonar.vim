vim9script
# Runs the Test_* functions of the file in g:test_file and writes the
# results to g:test_log. Vim exits with an error if a test failed.

var log: list<string> = []
var failed = 0

# -u NONE loads no plugins, and the tests run before VimEnter.
filetype on
runtime plugin/lsp.vim
execute 'source' fnameescape(g:test_file)

for name in getcompletion('Test_', 'function')->map((_, f) => f->substitute('()$', '', ''))
  v:errors = []
  try
    call(name, [])
  catch
    v:errors->add($'{v:exception} at {v:throwpoint}')
  endtry
  # Tests may leave windows and buffers behind.
  silent! only!
  silent! :%bwipeout!

  if v:errors->empty()
    log->add($'ok      {name}')
  else
    failed += 1
    log->add($'FAILED  {name}')
    log->extend(v:errors->mapnew((_, e) => $'          {e}'))
  endif
endfor

writefile(log, g:test_log)
if failed > 0
  cquit!
endif
qall!
