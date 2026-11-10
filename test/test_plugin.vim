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

syntax on
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

def ExplanationPopup(): number
  helpers.WaitFor(() => popup_list()->len() == 1
    && getwinvar(popup_list()[0], '&filetype') ==# 'codesonarexplain')
  return popup_list()->get(0, 0)
enddef

def SyntaxAt(id: number, lnum: number, pattern: string): string
  var col = PopupLines(id)[lnum - 1]->match(pattern) + 1
  return win_execute(id, $'echon synIDattr(synID({lnum}, {col}, true), "name")')
enddef

def g:Test_6_explains_warnings()
  Open('main.c')
  cursor(16, 1)
  var other = popup_create('other', {})

  LspCodeAction Show details

  var id = ExplanationPopup()
  assert_equal([], popup_list()->filter((_, p) => p == other), 'other popups are closed')

  var lines = PopupLines(id)
  # The hub names the warning class by its id, so it is shown once.
  assert_equal('Return Pointer to Local', lines[0])

  var title = prop_list(1, {bufnr: winbufnr(id)})
  assert_equal(['CodeSonarExplainTitle'], title->mapnew((_, p) => p.type))

  assert_match('^&local is returned by get_local_address()', lines[2])
  assert_equal('CodeSonarExplainFunction', SyntaxAt(id, 3, 'get_local_address'))
  assert_equal('CodeSonarExplainLocation', SyntaxAt(id, 3, 'main.c:16'))
  var link = lines->match('^- \[CWE:562\]')
  assert_equal('CodeSonarExplainLink', SyntaxAt(id, link + 1, 'CWE'))
  assert_equal('Conceal', SyntaxAt(id, link + 1, 'https'))
  var hub = lines->match('^Hub ')
  assert_match('http://nas.fritz.box:7340/warninginstance/301.html$', lines[hub])
  assert_equal('CodeSonarExplainUrl', SyntaxAt(id, hub + 1, 'http'))

  assert_match('o open in hub  ·  .*q close$', lines[-1])

  # The same at the cursor, without the code action.
  id->popup_close()
  codesonar.Explain()

  assert_equal(lines, PopupLines(ExplanationPopup()))

  delete($FAKE_BROWSER_LOG)
  feedkeys('o', 'xt')

  helpers.WaitFor(() => filereadable($FAKE_BROWSER_LOG))
  assert_equal(['http://nas.fritz.box:7340/warninginstance/301.html'], readfile($FAKE_BROWSER_LOG))
  assert_equal([], popup_list())
enddef

def g:Test_7_highlights_code_numbers_and_links()
  var id = popup_create(['Call printf() or free(p) with 0x10, 42 and 3.5 items',
    "See https://example.com/doc?id=7 and `code`, **bold** and 'p'."], {})
  win_execute(id, 'setlocal filetype=codesonarexplain')

  assert_equal('CodeSonarExplainFunction', SyntaxAt(id, 1, 'printf'))
  assert_equal('CodeSonarExplainFunction', SyntaxAt(id, 1, '()'))
  assert_equal('CodeSonarExplainFunction', SyntaxAt(id, 1, 'free'))
  assert_equal('', SyntaxAt(id, 1, '(p)'))
  assert_equal('CodeSonarExplainNumber', SyntaxAt(id, 1, '0x10'))
  assert_equal('CodeSonarExplainNumber', SyntaxAt(id, 1, '42'))
  assert_equal('CodeSonarExplainNumber', SyntaxAt(id, 1, '3.5'))
  assert_equal('', SyntaxAt(id, 1, 'items'))

  assert_equal('CodeSonarExplainUrl', SyntaxAt(id, 2, '7 and'))
  assert_equal('CodeSonarExplainCode', SyntaxAt(id, 2, 'code'))
  assert_equal('CodeSonarExplainBold', SyntaxAt(id, 2, 'bold'))
  assert_equal('CodeSonarExplainQuoted', SyntaxAt(id, 2, "'p'"))

  id->popup_close()
enddef

def g:Test_8_runs_an_analysis_in_a_split()
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

def g:Test_9_connects_and_chooses_a_project()
  Open('main.c')

  codesonar.Connect()
  var id = Popup()
  assert_equal(['1  mixxx', '2  test_project'], PopupLines(id))
  id->popup_close(2)
  helpers.WaitFor(() => Status()->get('hubId', '') ==# '4' && Status().counts.unchanged == 0)

  helpers.StopHub()
enddef
