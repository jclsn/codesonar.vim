vim9script
# Shows the progress in the status line of lightline.

import autoload 'codesonar.vim'

const LIGHTLINE = $LIGHTLINE_PLUGIN
const HAS_LIGHTLINE = !LIGHTLINE->empty() && isdirectory(LIGHTLINE)

def Skip()
  if !HAS_LIGHTLINE
    throw $'Skipped: no lightline in $LIGHTLINE_PLUGIN ({LIGHTLINE})'
  endif
enddef

if HAS_LIGHTLINE
  execute 'set runtimepath+=' .. fnameescape(LIGHTLINE)
  set laststatus=2
  runtime plugin/lightline.vim
endif

# A configuration of the user, which is kept.
g:lightline = {active: {left: [['mode'], ['filename']]}}
g:codesonar = {path: $CODESONAR_LSP}
runtime plugin/codesonar.vim
doautocmd VimEnter

def g:Test_1_adds_the_progress_on_the_right()
  Skip()

  assert_equal([['mode'], ['filename']], g:lightline.active.left)
  assert_equal(
    [['lineinfo'], ['percent'], ['fileformat', 'fileencoding', 'filetype'], ['codesonar']],
    g:lightline.active.right)
  assert_equal('codesonar#Progress', g:lightline.component_function.codesonar)
  assert_match('codesonar#Progress()', lightline#statusline(0))
enddef

def g:Test_2_adds_it_once()
  Skip()

  codesonar.LightlineInit()

  assert_equal(1, g:lightline.active.right->count(['codesonar']))
enddef
