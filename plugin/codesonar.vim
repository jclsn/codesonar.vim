vim9script
# CodeSonar warnings in Vim, from the codesonar-lsp language server.

if exists('g:loaded_codesonar')
  finish
endif

g:loaded_codesonar = true

import autoload 'codesonar.vim'

command! -nargs=? -complete=file CodeSonarLoad codesonar.Load(<q-args>)
command! CodeSonarAnalyses codesonar.Analyses()
command! CodeSonarExplain codesonar.Explain()
command! -nargs=? CodeSonarAnalyze codesonar.Analyze(<q-args>)
command! CodeSonarConf codesonar.Conf()
command! -nargs=* CodeSonarConnect codesonar.Connect(<f-args>)
command! CodeSonarDiagnostics codesonar.Diagnostics()
command! -nargs=* -complete=customlist,codesonar#CompletePresets CodeSonarPresets codesonar.Presets(<f-args>)
command! CodeSonarProjects codesonar.Projects()
command! CodeSonarOpenHub codesonar.OpenHub()
command! CodeSonarRefresh codesonar.Refresh()
command! CodeSonarStatus codesonar.Status()
command! CodeSonarToggle codesonar.Toggle()

def Init()
  codesonar.Register()

  if exists('g:loaded_lightline')
    codesonar.LightlineInit()
  endif
enddef

# The vimrc defines the server entry, yegappan/lsp registers it on
# VimEnter.
codesonar.Prepare()

augroup CodeSonar
  autocmd!
  autocmd User LspProgressUpdate codesonar.ProgressUpdated()
  autocmd User AirlineAfterInit codesonar.AirlineInit()

  if v:vim_did_enter
    Init()
  else
    autocmd VimEnter * Init()
  endif
augroup END

# vim-airline started before this plugin.
if v:vim_did_enter && exists('g:airline_section_c')
  codesonar.AirlineInit()
  silent! AirlineRefresh
endif
