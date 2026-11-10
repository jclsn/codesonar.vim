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

# A CodeSonar installation: the fake command with a template.conf next to
# its bin directory.
const INSTALL = tempname()
mkdir(INSTALL .. '/bin', 'p')
filecopy($'{helpers.DIR}/fake_codesonar.sh', INSTALL .. '/bin/codesonar')
setfperm(INSTALL .. '/bin/codesonar', 'rwx------')
writefile(['# CodeSonar template'], INSTALL .. '/template.conf')
mkdir(INSTALL .. '/presets')
writefile(['# CERT rules'], INSTALL .. '/presets/cert.conf')
writefile(['# MISRA C:2025 rules'], INSTALL .. '/presets/misrac2025.conf')

const HUB = helpers.StartHub($'{helpers.FIXTURES}/test_project.sarif', WORKSPACE)

$FAKE_CODESONAR_LOG = LOG
$FAKE_BROWSER_LOG = LOG .. '.browser'
g:codesonar = {
  path: $CODESONAR_LSP,
  browser: $'{helpers.DIR}/fake_browser.sh',
  hub: {url: HUB, username: 'lspuser', password: 'secret', project: 'test_project'},
  pathMappings: [{from: '/build/test_project', to: WORKSPACE}],
  stateDir: WORKSPACE .. '/.state',
  analyze: {command: INSTALL .. '/bin/codesonar', buildCommand: 'make'},
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
  assert_equal('- local was defined at main.c:16.', lines[4], 'one paragraph per sentence')
  assert_equal('CodeSonarExplainLocation', SyntaxAt(id, 5, 'main.c:16'))

  # Without titles from the hub, the rules are listed by id.
  var rules = lines->index('Rules')
  assert_match('^  MisraC2025:18.6, MisraC2023:18.6, .*CWE:562, ', lines[rules + 1])
  assert_equal(-1, lines->match('](http'), 'no Markdown links')

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

def g:Test_6a_explains_events_and_rules()
  Open('main.c')
  cursor(37, 1)

  codesonar.Explain()

  var lines = PopupLines(ExplanationPopup())
  assert_equal('Double Free', lines[0])

  var events = lines->index('Events')
  assert_equal('  1  main.c:27  Skipping "if".  argc > 1 evaluates to false.', lines[events + 1])
  assert_equal('     main.c:34  Calling procedure duplicate.', lines[events + 2])
  assert_equal('  2    utils.c:13  malloc() returns the address of a new object.', lines[events + 3])
  assert_match('^  8  main.c:37  dup, which evaluates to malloc(strlen(text) + 1) (utils.c:13), is',
    lines[lines->index('May violate') - 2])

  # The hub knows the titles of the rules and how they relate.
  var violated = lines->index('May violate')
  assert_equal(['  MisraC2025:D.4.1  Run-time failures shall be minimized',
    '  CWE:415           Double Free'], lines[violated + 1 : violated + 2])

  var symptom = lines->index('May be a symptom of an earlier violation of')
  assert_equal('  CERT-CPP:OOP54-CPP  Gracefully handle self-copy assignment', lines[symptom + 1])
  assert_match('^Documentation  http://nas.fritz.box:7340/install/codesonar/doc/html/', lines[symptom + 3])
  popup_clear()
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

def g:Test_7a_chooses_presets()
  Open('main.c')
  assert_equal(['misrac2025'], getcompletion('CodeSonarPresets m', 'cmdline'))

  var shown = Status()

  CodeSonarPresets
  var id = Popup()
  assert_equal(['[ ] cert        CERT rules', '[ ] misrac2025  MISRA C:2025 rules'], PopupLines(id))
  # Only the names are highlighted, ticked ones differently.
  var props = prop_list(1, {bufnr: winbufnr(id)})
  assert_equal([{col: 5, length: 4, type: 'CodeSonarPresetName'}],
    props->mapnew((_, p) => ({col: p.col, length: p.length, type: p.type})))

  feedkeys("j ", 'xt')

  assert_equal('[x] misrac2025  MISRA C:2025 rules', PopupLines(id)[1])
  assert_equal(['CodeSonarPresetTicked'], prop_list(2, {bufnr: winbufnr(id)})->mapnew((_, p) => p.type))
  feedkeys("\<CR>", 'xt')
  assert_equal(['misrac2025'], g:codesonar.analyze.presets)
  assert_match('Analyses use the presets misrac2025', execute('messages'))

  CodeSonarPresets cert misrac2025
  assert_equal(['cert', 'misrac2025'], g:codesonar.analyze.presets)
  sleep 200m
  assert_true(Status() is shown, 'the analysis is not loaded again')
enddef

def g:Test_7b_shows_the_status()
  Open('main.c')
  popup_create('other', {})

  CodeSonarStatus

  helpers.WaitFor(() => popup_list()->len() == 1 && PopupLines(popup_list()[0])[0] ==# 'CodeSonar')
  var id = popup_list()[0]
  var lines = PopupLines(id)

  assert_equal('Analysis    test_project initial  #3', lines[2])
  assert_equal($'Hub         {HUB}  project test_project', lines[3])
  assert_equal($'Page        {HUB}/analysis/3.html', lines[4])
  assert_equal('Warnings    13 of 13 shown', lines[6])
  assert_equal('            13 unchanged', lines[7])
  assert_equal('Presets     cert, misrac2025', lines[9])
  assert_equal('o open in hub  ·  q close', lines[-1])

  var Types = (lnum) => prop_list(lnum, {bufnr: winbufnr(id)})->mapnew((_, p) => p.type)
  assert_equal(['CodeSonarStatusLabel', 'CodeSonarStatusPreset', 'CodeSonarStatusPreset'], Types(10))
  assert_equal(['CodeSonarStatusLabel', 'CodeSonarStatusUnchanged'], Types(8))

  delete($FAKE_BROWSER_LOG)
  feedkeys('o', 'xt')

  helpers.WaitFor(() => filereadable($FAKE_BROWSER_LOG))
  assert_equal([$'{HUB}/analysis/3.html'], readfile($FAKE_BROWSER_LOG))
  assert_equal([], popup_list())
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
  assert_equal(['-preset', 'cert', '-preset', 'misrac2025'],
    args[args->index('-preset') : args->index('-preset') + 3])
  assert_equal([HUB, 'make'], args[-2 :])

  helpers.WaitFor(() => filereadable(LOG .. '.pw'))
  assert_equal(['secret'], readfile(LOG .. '.pw'))
  assert_equal(['600'], readfile(LOG .. '.mode'))
  assert_equal([WORKSPACE], readfile(LOG .. '.cwd'))

  helpers.WaitFor(() => Status()->get('hubId', '') ==# '4')
  assert_false(codesonar.IsAnalyzing())
enddef

def g:Test_8a_opens_the_configuration()
  Open('main.c')
  CodeSonarConf
  helpers.WaitFor(() => expand('%:p') ==# $'{WORKSPACE}/.codesonar/project.conf')
  assert_equal(2, winnr('$'))
  assert_equal(['# CodeSonar template'], getline(1, '$'))
  assert_match('Created .*/project.conf from the CodeSonar template', execute('messages'))
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
