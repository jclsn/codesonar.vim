vim9script
# Runs the plugin with the server, yegappan/lsp and a mock hub. The tests
# share one server and run in the order of their names.

import autoload 'codesonar.vim'
import './helpers.vim'

const WORKSPACE = tempname()
const LOG = tempname()

mkdir(WORKSPACE .. '/.git', 'p')

for name in ['main.c', 'utils.c', 'utils.h']
  writefile(readfile($'{helpers.FIXTURES}/test_project/{name}'), $'{WORKSPACE}/{name}')
endfor

const HUB = helpers.StartHub($'{helpers.FIXTURES}/test_project.sarif', WORKSPACE)

$FAKE_CODESONAR_LOG = LOG
$FAKE_BROWSER_LOG = LOG .. '.browser'
g:codesonar = {
  path: $CODESONAR_LSP,
  browser: $'{helpers.DIR}/fake_browser.sh',
  hub: {url: HUB, username: 'lspuser', password: 'secret', project: 'test_project'},
  pathMappings: [{from: '/build/test_project', to: WORKSPACE}],
  stateDir: WORKSPACE .. '/.state',
  analyze: {command: $'{helpers.DIR}/fake_codesonar.sh', buildCommand: 'make'},
}

runtime plugin/codesonar.vim
doautocmd VimEnter

def Status(): dict<any>
  return codesonar.Current()
enddef

def Open(name: string)
  execute 'edit' fnameescape($'{WORKSPACE}/{name}')
enddef

def Popup(): number
  helpers.WaitFor(() => !popup_list()->empty())
  return popup_list()->get(0, 0)
enddef

def PopupLines(id: number): list<string>
  return id->winbufnr()->getbufline(1, '$')
enddef

def DiagCount(): number
  return call('lsp#lsp#ErrorCount', [])->values()->reduce((a, b) => a + b, 0)
enddef

def g:Test_1_loads_the_newest_finished_analysis()
  Open('main.c')
  helpers.WaitFor(() => Status()->get('loaded', false) == true)

  assert_equal('4', Status().hubId)
  assert_equal('test_project fixes', Status().name)
  assert_equal(13, Status().total)
  assert_match('CodeSonar: test_project fixes: 13 of 13 warnings shown', execute('messages'))
enddef

def g:Test_2_chooses_an_analysis()
  Open('main.c')

  codesonar.Analyses()

  var id = Popup()
  var lines = PopupLines(id)
  assert_equal(3, lines->len())
  assert_match('^  \+5  test_project running .*\[ANALYZING\]$', lines[0])
  assert_match('^\*  \+4  test_project fixes', lines[1])
  assert_match('^  \+3  test_project initial', lines[2])

  id->popup_close(3)
  helpers.WaitFor(() => Status()->get('hubId', '') ==# '3' && Status().counts.unverified < 13)
  # The hub keeps the analyzed sources of analysis 3.
  assert_equal(13, Status().counts.unchanged)
  helpers.WaitFor(() => DiagCount() == 8)
enddef

def g:Test_3_fills_the_quickfix_list()
  Open('main.c')

  codesonar.Diagnostics()

  helpers.WaitFor(() => getqflist()->len() == 13)
  assert_equal('CodeSonar: test_project initial', getqflist({title: 0}).title)

  var item = getqflist()->filter((_, i) => i.text =~# 'Division By Zero')[0]
  assert_equal(WORKSPACE .. '/main.c', item.bufnr->bufname()->fnamemodify(':p'))
  assert_equal(9, item.lnum)
  assert_equal('E', item.type)
enddef

def g:Test_4_hides_fixed_warnings()
  Open('main.c')
  helpers.WaitFor(() => DiagCount() == 8)

  setline(9, getline(9) .. ' /* fixed */')
  # Without a screen, Vim calls listeners only when asked to.
  listener_flush()

  helpers.WaitFor(() => DiagCount() == 7)

  codesonar.Diagnostics()

  helpers.WaitFor(() => getqflist()->len() == 12)

  set nomodified
enddef

def g:Test_5_opens_warnings_on_the_hub()
  Open('main.c')
  cursor(16, 1)

  codesonar.OpenHub()

  helpers.WaitFor(() => filereadable($FAKE_BROWSER_LOG))
  assert_equal(['http://nas.fritz.box:7340/warninginstance/301.html'], readfile($FAKE_BROWSER_LOG))
enddef

def g:Test_6_runs_an_analysis_in_a_split()
  Open('main.c')
  codesonar.Analyze('from vim')

  helpers.WaitFor(() => filereadable(LOG .. '.cwd'))
  assert_equal(2, winnr('$'))
  assert_equal('main.c', expand('%:t'), 'the cursor stays in the code')

  var args = readfile(LOG)
  assert_equal(['analyze', $'{WORKSPACE}/.codesonar/project', '-foreground'], args[: 2])
  assert_true(args->index('from vim') > 0)
  assert_equal([HUB, 'make'], args[-2 :])
  helpers.WaitFor(() => filereadable(LOG .. '.pw'))
  assert_equal(['secret'], readfile(LOG .. '.pw'))
  assert_equal(['600'], readfile(LOG .. '.mode'))
  assert_equal([WORKSPACE], readfile(LOG .. '.cwd'))

  helpers.WaitFor(() => Status()->get('hubId', '') ==# '4')
  assert_false(codesonar.IsAnalyzing())
enddef

def g:Test_7_connects_and_chooses_a_project()
  Open('main.c')
  codesonar.Connect()
  var id = Popup()
  assert_equal(['1  mixxx', '2  test_project'], PopupLines(id))
  id->popup_close(2)
  helpers.WaitFor(() => Status()->get('hubId', '') ==# '4' && Status().counts.unchanged == 0)

  helpers.StopHub()
enddef
