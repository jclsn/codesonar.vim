vim9script
# Shows the progress in the status line of vim-airline.

import autoload 'codesonar.vim'

const AIRLINE = $AIRLINE_PLUGIN
const HAS_AIRLINE = !AIRLINE->empty() && isdirectory(AIRLINE)

def Skip()
  if !HAS_AIRLINE
    throw $'Skipped: no vim-airline in $AIRLINE_PLUGIN ({AIRLINE})'
  endif
enddef

if HAS_AIRLINE
  execute 'set runtimepath+=' .. fnameescape(AIRLINE)
  set laststatus=2
  runtime plugin/airline.vim
endif

g:codesonar = {path: $CODESONAR_LSP}
runtime plugin/codesonar.vim
doautocmd VimEnter

def g:Test_1_adds_the_progress_to_section_c()
  Skip()

  assert_match('codesonar#Progress()', g:airline_section_c)
  assert_match('codesonar#Progress()', airline#statusline(1))
enddef

def g:Test_2_shows_the_progress()
  Skip()

  g:LspProgress = {'codesonar/1': {
    title: 'CodeSonar', message: 'Downloading 4.2 MB', percentage: -1, serverName: 'codesonar'}}
  doautocmd <nomodeline> User LspProgressUpdate

  assert_match('^CodeSonar \S Downloading 4.2 MB$', airline#util#wrap(codesonar.Progress(), 0))

  g:LspProgress = {}
  doautocmd <nomodeline> User LspProgressUpdate

  assert_equal('', airline#util#wrap(codesonar.Progress(), 0))
enddef
