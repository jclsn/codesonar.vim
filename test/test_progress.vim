vim9script
# Shows the progress of the server in the status line.

import autoload 'codesonar.vim'
import './helpers.vim'

runtime plugin/codesonar.vim

def g:Test_1_is_empty_while_the_server_is_idle()
  g:LspProgress = {1: {title: 'Indexing', message: '', percentage: -1, serverName: 'clangd'}}
  doautocmd <nomodeline> User LspProgressUpdate

  assert_equal('', codesonar.Progress())
enddef

def g:Test_2_spins_while_downloading()
  g:LspProgress['codesonar/1'] = {
    title: 'CodeSonar', message: 'Downloading 4.2 MB', percentage: -1, serverName: 'codesonar'}
  doautocmd <nomodeline> User LspProgressUpdate

  var first = codesonar.Progress()
  assert_match('^CodeSonar \S Downloading 4.2 MB$', first)

  helpers.WaitFor(() => codesonar.Progress() != first)

  assert_match('^CodeSonar \S Downloading 4.2 MB$', codesonar.Progress())
enddef

def g:Test_3_shows_the_percentage_if_known()
  g:LspProgress['codesonar/1'].percentage = 25

  assert_match('^CodeSonar \S Downloading 4.2 MB 25%$', codesonar.Progress())
enddef

def g:Test_4_stops_when_done()
  remove(g:LspProgress, 'codesonar/1')
  doautocmd <nomodeline> User LspProgressUpdate

  assert_equal('', codesonar.Progress())
  assert_equal([], timer_info()->filter((_, timer) => timer.repeat != 0))
enddef
