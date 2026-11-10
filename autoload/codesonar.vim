vim9script
# Registers codesonar-lsp with yegappan/lsp and builds views on the
# commands of the server. All CodeSonar logic lives in the server.

const NAME = 'codesonar'
# Settings of the plugin, not of the server.
const PLUGIN_KEYS = ['path', 'args', 'filetypes', 'browser']
const TYPES = {1: 'E', 2: 'W', 3: 'I', 4: 'N'}
const EXPLAIN = 'codesonar.explain'
# Highlight groups of explanations, linked to standard groups.
const HIGHLIGHTS = {
  Title: 'Title',
  Rule: 'Identifier',
  Heading: 'Statement',
  Label: 'Statement',
  Changed: 'WarningMsg',
  Separator: 'NonText',
  Hint: 'Comment',
  Url: 'Underlined',
  Function: 'Function',
  Number: 'Number',
  Quoted: 'String',
  Code: 'Special',
  Location: 'Directory',
}
# Keys that scroll the explanation popup, to the normal mode commands.
const SCROLL = {
  j: "\<C-E>", k: "\<C-Y>", "\<Down>": "\<C-E>", "\<Up>": "\<C-Y>",
  "\<C-D>": "\<C-D>", "\<C-U>": "\<C-U>", g: 'gg', G: 'G',
}
# The start of event, rule and link lines: wrapped lines are indented by it.
const LIST_PATTERN = '^\s*\%(\d\+\s\+\)\=\S\+:\S\+\s\+\|^\a\+\s\{2,}\|^-\s\+'
# The parts of explanations that are text properties, not syntax.
const PROPS = ['Title', 'Rule', 'Heading', 'Label', 'Changed', 'Separator', 'Hint']

# The server, as yegappan/lsp passes it to notification handlers.
var server: dict<any> = {}
var status: dict<any> = {loaded: false}
var analyze_job: job

def Settings(): dict<any>
  return get(g:, 'codesonar', {})
enddef

# Shows a message in the colors of yegappan/lsp.
def Message(text: string, highlight: string = 'Question')
  execute $'echohl {highlight}'
  echomsg $'CodeSonar: {text}'
  echohl None
enddef

# Shows an error. It starts with a capital letter, also if the server
# wrote it.
export def Error(text: string)
  Message(text[: 0]->toupper() .. text[1 :], 'Error')
enddef

def Ignore(_: any)
enddef

# The status of the loaded analysis, as the server sent it last.
export def Current(): dict<any>
  return status
enddef

# The settings sent to the server: g:codesonar without the plugin's keys.
export def ServerSettings(): dict<any>
  return Settings()->deepcopy()->filter((key, _) => PLUGIN_KEYS->index(key) < 0)
enddef

def Loaded(lspserver: dict<any>, notification: dict<any>)
  server = lspserver
  status = notification.params
  Message(Summary(status))
  UpdateQuickfix()
  silent doautocmd <nomodeline> User CodeSonarLoaded
enddef

def Loading(lspserver: dict<any>, notification: dict<any>)
  server = lspserver
  var params = notification.params

  if params->has_key('analysis')
    Message($'Loading analysis {params.analysis}...')
  elseif params->has_key('file')
    Message($'Loading {params.file->fnamemodify(":~:.")}...')
  elseif type(params->get('project', null)) == v:t_string
    Message($'Loading the newest analysis of {params.project}...')
  endif
enddef

def ShowDocument(lspserver: dict<any>, request: dict<any>)
  OpenUrl(request.params.uri)
  lspserver.sendResponse(request, {success: true}, {})
enddef

export def OpenUrl(url: string)
  var browser = Settings()->get('browser', '')

  if !browser->empty()
    job_start([browser, url])
  else
    execute 'Open' fnameescape(url)
  endif
enddef

# Registers the server with yegappan/lsp.
export def Register()
  if !exists('*g:LspAddServer')
    Error('The plugin yegappan/lsp is not installed')
    return
  endif

  var settings = Settings()

  g:LspAddServer([{
    name: NAME,
    filetype: settings->get('filetypes', ['c', 'cpp']),
    path: settings->get('path', 'codesonar-lsp'),
    args: settings->get('args', []),
    initializationOptions: ServerSettings(),
    rootSearch: ['codesonar.conf', '.codesonar', '.git'],
    features: {completion: false},
    customNotificationHandlers: {'codesonar/loading': Loading, 'codesonar/loaded': Loaded},
    customRequestHandlers: {'window/showDocument': ShowDocument},
  }])

  # The explain code action is shown here instead of in the server.
  if exists('*g:LspRegisterCmdHandler')
    g:LspRegisterCmdHandler(EXPLAIN, ExplainAction)
  endif
enddef

# The running server, from any buffer.
def Server(): dict<any>
  if !server->empty() && server.running
    return server
  endif

  try
    server = call('lsp#buffer#CurbufGetServerByName', [NAME])
  catch
    server = {}
  endtry

  return !server->empty() && server.running ? server : {}
enddef

# Runs a server command and calls Done with its result.
export def Execute(command: string, argument: any, Done: func(any))
  var lspserver = Server()

  if lspserver->empty()
    Error('The server is not running: open a file of the project first')
    return
  endif

  var params = {command: command, arguments: argument == null ? [] : [argument]}

  lspserver.rpc_a('workspace/executeCommand', params, (_, result, error) => {
    # yegappan/lsp reports errors itself.
    if error->empty()
      Done(result)
    endif
  })
enddef

export def Summary(info: dict<any>): string
  if !info->get('loaded', false)
    return 'No analysis loaded'
  endif

  var counts = info.counts
  var text = $'{info.name}: {info.shown} of {info.total} warnings shown'
  var details = ['unchanged', 'moved', 'changed', 'unverified']
    ->filter((_, k) => counts[k] > 0)
    ->map((_, k) => $'{counts[k]} {k}')

  return details->empty() ? text : $'{text} ({details->join(", ")})'
enddef

# Highlight groups of the status popup, linked by default to these groups.
const STATUS_HIGHLIGHTS = {
  Title: 'Title',
  Label: 'Statement',
  None: 'Comment',
  Url: 'Underlined',
  Number: 'Number',
  Unchanged: 'String',
  Moved: 'Identifier',
  Changed: 'WarningMsg',
  Unverified: 'Comment',
  Preset: 'Identifier',
  Hint: 'Comment',
}

def DefineStatusHighlights()
  for [name, group] in STATUS_HIGHLIGHTS->items()
    execute $'highlight default link CodeSonarStatus{name} {group}'

    if prop_type_get($'CodeSonarStatus{name}')->empty()
      prop_type_add($'CodeSonarStatus{name}', {highlight: $'CodeSonarStatus{name}'})
    endif
  endfor
enddef

def StatusLine(label: string, parts: list<list<string>>): dict<any>
  return Line([[printf('%-12s', label), 'Label']] + parts, 'CodeSonarStatus')
enddef

def Value(text: any, none: string): list<string>
  return type(text) == v:t_string && !text->empty() ? [text, ''] : [none, 'None']
enddef

# The lines of the status popup, see codesonar.status of the server.
export def StatusLines(info: dict<any>): list<dict<any>>
  var lines = [Line([['CodeSonar', 'Title']], 'CodeSonarStatus'), Line([])]

  if info.loaded
    var id = type(info.hubId) == v:t_string ? [['  #' .. info.hubId, 'None']] : []
    lines->add(StatusLine('Analysis', [[info.name, '']] + id))
  else
    lines->add(StatusLine('Analysis', [['none loaded', 'None']]))
  endif

  var hub: list<list<string>> = [Value(info->get('hub', null), 'none')]

  if type(info->get('project', null)) == v:t_string
    hub += [['  project ', ''], [info.project, '']]
  endif

  lines->add(StatusLine('Hub', hub))

  if info.loaded
    if type(info.url) == v:t_string
      lines->add(StatusLine('Page', [[info.url, 'Url']]))
    endif

    lines += [Line([]), StatusLine('Warnings', [[string(info.shown), 'Number'], [' of ', ''],
      [string(info.total), 'Number'], [' shown', '']])]
    var counts: list<list<string>> = []

    for kind in ['unchanged', 'moved', 'changed', 'unverified']
      if info.counts[kind] > 0
        counts += [[counts->empty() ? '' : '  ', ''], [$'{info.counts[kind]} {kind}', kind->substitute('^.', '\u&', '')]]
      endif
    endfor

    if !counts->empty()
      lines->add(StatusLine('', counts))
    endif
  endif

  var presets: list<list<string>> = []

  for preset in info->get('presets', [])
    presets += [[presets->empty() ? '' : ', ', ''], [preset, 'Preset']]
  endfor

  lines += [Line([]), StatusLine('Presets', presets->empty() ? [['none', 'None']] : presets)]

  var hints = (info->get('url', null) != null ? ['o open in hub'] : []) + ['q close']
  return lines + [Line([]), Line([[hints->join('  ·  '), 'Hint']], 'CodeSonarStatus')]
enddef

def StatusFilter(info: dict<any>, winid: number, key: string): bool
  if key ==# "\<Esc>" || key ==# 'q'
    winid->popup_close()
  elseif key ==# 'o' && type(info->get('url', null)) == v:t_string
    winid->popup_close()
    OpenUrl(info.url)
  else
    return false
  endif

  return true
enddef

def ShowStatus(info: dict<any>)
  popup_clear()
  DefineStatusHighlights()

  var attrs: dict<any> = {
    moved: 'any',
    wrap: true,
    maxwidth: min([100, &columns - 4]),
    padding: [0, 1, 0, 1],
    mapping: false,
    filter: function(StatusFilter, [info]),
  }

  try
    attrs = call('lsp#options#PopupConfigure', ['Hover', attrs])
  catch
    attrs.border = []
  endtry

  popup_create(StatusLines(info), attrs)
enddef

# Shows the status in a popup: the analysis, its warnings and how analyses
# are run.
export def Status()
  Execute('codesonar.status', null, ShowStatus)
enddef

export def Load(file: string = '')
  var argument = file->empty() ? null : {file: file->fnamemodify(':p')}

  Execute('codesonar.load', argument, Ignore)
enddef

export def Refresh()
  Execute('codesonar.refresh', null, Ignore)
enddef

def MenuFilter(winid: number, key: string): bool
  if key ==# "\<Esc>" || key ==# "\<C-C>" || key ==# 'q'
    winid->popup_close(-1)
    return true
  endif

  return popup_filter_menu(winid, key)
enddef

# A popup menu in the style of yegappan/lsp. Callback gets the 1-based
# choice, or -1 if cancelled.
export def Menu(lines: list<string>, title: string, Callback: func(number)): number
  var attrs: dict<any> = {
    title: $' {title} ',
    zindex: 1000,
    cursorline: true,
    mapping: false,
    wrap: false,
    padding: [0, 1, 0, 1],
    callback: (_, result) => Callback(result),
    filter: MenuFilter,
  }

  try
    attrs = call('lsp#options#PopupConfigure', ['CodeAction', attrs])
  catch
    attrs.border = []
  endtry

  return popup_create(lines, attrs)
enddef

export def AnalysisLines(analyses: list<dict<any>>): list<string>
  return analyses->mapnew((_, a) => printf('%s %4d  %s  %s%s', a.current ? '*' : ' ', a.id,
    a.name, a.started, a.finished ? '' : $'  [{a.state}]'))
enddef

export def Analyses()
  Execute('codesonar.analyses', null, (result) => {
    var analyses = result.analyses

    if analyses->empty()
      Error($'No analyses in hub project {result.project}')
      return
    endif

    Menu(AnalysisLines(analyses), $'CodeSonar analyses of {result.project}',
      (choice) => ChooseAnalysis(analyses, choice))
  })
enddef

def ChooseAnalysis(analyses: list<dict<any>>, choice: number)
  if choice < 1
    return
  endif

  var analysis = analyses[choice - 1]

  if !analysis.finished
    Error($'Analysis {analysis.id} is not finished yet')
    return
  endif

  Execute('codesonar.load', {analysis: analysis.id}, Ignore)
enddef

def ChooseProject(projects: list<dict<any>>)
  if projects->empty()
    Error('The hub has no projects')
    return
  endif

  Menu(projects->mapnew((_, p) => $'{p.id}  {p.name}'), 'CodeSonar projects', (choice) => {
    if choice > 0
      Execute('codesonar.connect', {project: projects[choice - 1].name}, Ignore)
    endif
  })
enddef

export def Projects()
  Execute('codesonar.projects', null, (result) => ChooseProject(result))
enddef

# Signs in to a hub and chooses a project: :CodeSonarConnect [url [user]]
export def Connect(...args: list<string>)
  var argument: dict<any> = {}

  if args->len() > 0
    argument.url = args[0]
  endif

  if args->len() > 1
    argument.username = args[1]
    argument.password = inputsecret($'CodeSonar password for {args[1]}: ')
  endif

  Execute('codesonar.connect', argument, (result) => ChooseProject(result))
enddef

def UriToPath(uri: string): string
  var path = uri->substitute('^file://', '', '')

  return path->substitute('%\(\x\x\)', (m) => nr2char(str2nr(m[1], 16)), 'g')
enddef

export def QuickfixItems(warnings: list<dict<any>>): list<dict<any>>
  return warnings->mapnew((_, w) => ({
    filename: UriToPath(w.uri),
    lnum: w.range.start.line + 1,
    col: w.range.start.character + 1,
    end_lnum: w.range.end.line + 1,
    end_col: w.range.end.character + 1,
    type: TYPES->get(w.severity, 'W'),
    text: $'[{w->get("code", "")}] {w.message}',
  }))
enddef

def SetQuickfix(warnings: list<dict<any>>, action: string)
  var title = status->get('loaded', false) ? $'CodeSonar: {status.name}' : 'CodeSonar'

  setqflist([], action, {title: title, items: QuickfixItems(warnings)})
enddef

# Fills the quickfix list with the shown warnings and opens it.
export def Diagnostics()
  Execute('codesonar.warnings', null, (result) => {
    SetQuickfix(result, ' ')
    copen
  })
enddef

# Updates the quickfix list if it shows CodeSonar warnings.
def UpdateQuickfix()
  if getqflist({title: 0}).title =~# '^CodeSonar'
    Execute('codesonar.warnings', null, (result) => SetQuickfix(result, 'r'))
  endif
enddef

# Opens the warning at the cursor on the hub, or else the analysis.
export def OpenHub()
  var file = expand('%:p')
  var lnum = line('.')

  Execute('codesonar.warnings', null, (result) => {
    var here = result->copy()->filter((_, w) => UriToPath(w.uri) ==# file
      && w.range.start.line + 1 <= lnum && lnum <= w.range.end.line + 1
      && w->get('hubUri', null) != null)

    if !here->empty()
      OpenUrl(here[0].hubUri)
    elseif status->get('url', null) != null
      OpenUrl(status.url)
    else
      Error('No warning with a hub link at the cursor')
    endif
  })
enddef

export def IsAnalyzing(): bool
  return analyze_job->job_status() ==# 'run'
enddef

def StartAnalysis(command: dict<any>)
  var options = {
    cwd: command.cwd,
    vertical: true,
    term_name: 'CodeSonar analyze',
    exit_cb: (_, code) => Analyzed(code, command.temporaryFiles),
  }
  var buf = term_start(command.command, options)

  if buf > 0
    analyze_job = buf->term_getjob()
    wincmd p
  endif
enddef

def Analyzed(code: number, temporary_files: list<string>)
  for file in temporary_files
    delete(file)
  endfor

  if code != 0
    Error($'Analysis failed with exit code {code}')
    return
  endif

  Execute('codesonar.load', {latest: true}, Ignore)
enddef

# Runs an analysis in a vertical terminal split and shows it when done.
export def Analyze(name: string = '')
  if IsAnalyzing()
    Error('An analysis is already running')
    return
  endif

  var argument = name->empty() ? null : {name: name}

  Execute('codesonar.analyzeCommand', argument, StartAnalysis)
enddef

def DefineHighlights()
  for [name, group] in HIGHLIGHTS->items()
    execute $'highlight default link CodeSonarExplain{name} {group}'
  endfor

  highlight default CodeSonarExplainBold term=bold cterm=bold gui=bold

  for name in PROPS
    if prop_type_get($'CodeSonarExplain{name}')->empty()
      prop_type_add($'CodeSonarExplain{name}', {highlight: $'CodeSonarExplain{name}'})
    endif
  endfor
enddef

# A popup line, with the text properties of its parts: [[text, prop], ...]
# where an empty prop means plain text. Property types are named prefix
# and prop.
def Line(parts: list<list<string>>, prefix: string = 'CodeSonarExplain'): dict<any>
  var text = ''
  var props = []

  for [part, prop] in parts
    if !prop->empty() && !part->empty()
      props->add({col: text->len() + 1, length: part->len(), type: prefix .. prop})
    endif

    text ..= part
  endfor

  return {text: text, props: props}
enddef

def FileName(uri: string): string
  return UriToPath(uri)->fnamemodify(':t')
enddef

# The lines of one explanation, see codesonar.explain of the server.
# Markdown links as their text: CodeSonar's URLs are too long to read.
def LinkTexts(text: string): string
  return text->substitute('\[\([^]]\+\)\](\%([^()]\|([^()]*)\)*)', '\1', 'g')
enddef

def Paragraphs(text: string): list<dict<any>>
  return LinkTexts(text)->split("\n", true)->mapnew((_, l) => Line([[l, '']]))
enddef

def Section(heading: string, lines: list<dict<any>>): list<dict<any>>
  return lines->empty() ? [] : [Line([]), Line([[heading, 'Heading']])] + lines
enddef

# The events on the path to the warning, numbered as on the hub and
# indented by call depth.
def EventLines(events: list<dict<any>>): list<dict<any>>
  return events->mapnew((_, e) => Line([
    [printf('%3s  ', type(e.number) == v:t_number ? e.number : ''), ''],
    [repeat('  ', e.depth), ''],
    [$'{FileName(e.uri)}:{e.line}', ''],
    [$'  {e.message}', ''],
  ]))
enddef

# Whether the warning may be a symptom of an earlier violation of the rule.
def IsSymptom(rule: dict<any>): bool
  return type(rule.relationship) == v:t_string && rule.relationship ==# 'follows'
enddef

# The rules with titles as a table, else their ids in one line.
def RuleLines(rules: list<dict<any>>): list<dict<any>>
  if rules->empty()
    return []
  endif

  if rules->indexof((_, r) => type(r.title) == v:t_string) < 0
    var parts: list<list<string>> = [['  ', '']]

    for rule in rules
      parts += [[rule.id, 'Rule'], [rule is rules[-1] ? '' : ', ', '']]
    endfor

    return [Line(parts)]
  endif

  var width = rules->mapnew((_, r) => strdisplaywidth(r.id))->max()

  return rules->mapnew((_, r) => Line([
    ['  ', ''],
    [r.id, 'Rule'],
    [repeat(' ', width - strdisplaywidth(r.id) + 2), ''],
    [type(r.title) == v:t_string ? r.title : '', ''],
  ]))
enddef

# The lines of one explanation, see codesonar.explain of the server.
def ExplanationLines(explanation: dict<any>): list<dict<any>>
  var title: list<list<string>> = [[explanation.title, 'Title']]

  if explanation->get('ruleId', null) != null && explanation.ruleId !=# explanation.title
    title += [['  ', ''], [explanation.ruleId, 'Rule']]
  endif

  var lines = [Line(title)]

  if explanation.status ==# 'changed'
    lines->add(Line([['The code changed since the analysis, the warning may be fixed.', 'Changed']]))
  endif

  lines += [Line([])] + Paragraphs(explanation.message)

  if explanation->get('description', null) != null
    lines += [Line([])] + Paragraphs(explanation.description)
  endif

  var rules = explanation->get('rules', [])
  var symptoms = rules->copy()->filter((_, r) => IsSymptom(r))
  var violations = rules->copy()->filter((_, r) => !IsSymptom(r))

  lines += Section('Events', EventLines(explanation->get('events', [])))
  lines += Section('Related', explanation.related->mapnew((_, r) =>
    Line([[$'  {FileName(r.uri)}:{r.line}  ', ''], [r.message, '']])))
  # The relationships come from the hub.
  var known = rules->indexof((_, r) => type(r.relationship) == v:t_string) >= 0
  lines += Section(known ? 'May violate' : 'Rules', RuleLines(violations))
  lines += Section('May be a symptom of an earlier violation of', RuleLines(symptoms))

  var links = [['Documentation', 'helpUri'], ['Hub', 'hubUri']]
    ->filter((_, l) => explanation->get(l[1], null) != null)

  if !links->empty()
    lines->add(Line([]))
    lines += links->mapnew((_, l) => Line([[printf('%-15s', l[0]), 'Label'], [explanation[l[1]], '']]))
  endif

  return lines
enddef

def Link(explanations: list<dict<any>>, key: string): string
  var links = explanations->mapnew((_, e) => e->get(key, null))->filter((_, l) => l != null)
  return links->empty() ? '' : links[0]
enddef

# All lines of the explanation popup.
export def ExplanationPopupLines(explanations: list<dict<any>>): list<dict<any>>
  var lines: list<dict<any>> = []

  for explanation in explanations
    if !lines->empty()
      lines += [Line([]), Line([[repeat('─', 40), 'Separator']]), Line([])]
    endif

    lines += ExplanationLines(explanation)
  endfor

  var hints = [['o', 'open in hub', 'hubUri'], ['d', 'documentation', 'helpUri']]
    ->filter((_, h) => !Link(explanations, h[2])->empty())
    ->mapnew((_, h) => $'{h[0]} {h[1]}') + ['q close']

  return lines + [Line([]), Line([[hints->join('  ·  '), 'Hint']])]
enddef

def ExplanationFilter(explanations: list<dict<any>>, winid: number, key: string): bool
  if key ==# "\<Esc>" || key ==# 'q'
    winid->popup_close()
  elseif key ==# 'o' || key ==# 'd'
    var link = Link(explanations, key ==# 'o' ? 'hubUri' : 'helpUri')

    if link->empty()
      return false
    endif

    winid->popup_close()
    OpenUrl(link)
  elseif SCROLL->has_key(key)
    win_execute(winid, $'normal! {SCROLL[key]}')
  else
    return false
  endif

  return true
enddef

# Shows explanations in a popup at the cursor. Other popups are closed, so
# that the explanation is not hidden behind them.
export def ShowExplanations(explanations: list<dict<any>>)
  if explanations->empty()
    Error('No warning in this line')
    return
  endif

  popup_clear()
  DefineHighlights()

  var attrs: dict<any> = {
    pos: 'botleft',
    line: 'cursor-1',
    col: 'cursor',
    moved: 'any',
    wrap: true,
    maxwidth: min([80, &columns - 4]),
    maxheight: max([5, &lines - 6]),
    padding: [0, 1, 0, 1],
    scrollbar: true,
    mapping: false,
    filter: function(ExplanationFilter, [explanations]),
  }

  try
    attrs = call('lsp#options#PopupConfigure', ['Hover', attrs])
  catch
    attrs.border = []
  endtry

  var winid = popup_atcursor(ExplanationPopupLines(explanations), attrs)
  win_execute(winid, 'setlocal filetype=codesonarexplain conceallevel=2 concealcursor=n')
  # Wrapped lines of events, rules and links continue below their text.
  win_execute(winid, 'setlocal linebreak breakindent breakindentopt=list:-1')
  win_execute(winid, $'setlocal formatlistpat={LIST_PATTERN->escape(' \\|')}')
enddef

def ExplainAction(command: dict<any>)
  Execute(EXPLAIN, command->get('arguments', [null])[0], ShowExplanations)
enddef

# Explains the warnings in the cursor line, like the code action.
export def Explain()
  var argument = {
    uri: call('lsp#util#LspFileToUri', [expand('%:p')]),
    range: {start: {line: line('.') - 1, character: 0}, end: {line: line('.'), character: 0}},
  }

  Execute(EXPLAIN, argument, ShowExplanations)
enddef

def OpenConf(project: dict<any>)
  execute 'split' fnameescape(project.conf)

  if project.created
    Message($'Created {project.conf} from the CodeSonar template')
  endif
enddef

# Opens the configuration file of the project, created from CodeSonar's
# template if there is none yet.
export def Conf()
  Execute('codesonar.project', {createConf: true}, OpenConf)
enddef

# Sends g:codesonar to the server after a change.
def SendSettings()
  Server().sendNotification('workspace/didChangeConfiguration', {settings: {codesonar: ServerSettings()}})
enddef

def SetPresets(names: list<string>)
  if !exists('g:codesonar')
    g:codesonar = {}
  endif

  g:codesonar.analyze = g:codesonar->get('analyze', {})->extend({presets: names})
  SendSettings()
  Message(names->empty() ? 'Analyses use no presets' : $'Analyses use the presets {names->join(", ")}')
enddef

# Highlights the names of presets, ticked ones differently.
def DefinePresetHighlights()
  highlight default link CodeSonarPresetName Identifier
  highlight default link CodeSonarPresetTicked Special

  for name in ['CodeSonarPresetName', 'CodeSonarPresetTicked']
    if prop_type_get(name)->empty()
      prop_type_add(name, {highlight: name})
    endif
  endfor
enddef

def NameWidth(presets: list<dict<any>>): number
  return presets->mapnew((_, p) => strdisplaywidth(p.name))->max()
enddef

export def PresetLines(presets: list<dict<any>>): list<dict<any>>
  var width = NameWidth(presets)

  return presets->mapnew((_, p) => Line([
    [p.selected ? '[x] ' : '[ ] ', ''],
    [p.name, p.selected ? 'Ticked' : 'Name'],
    [repeat(' ', width - strdisplaywidth(p.name)), ''],
    [type(p.description) == v:t_string ? $'  {p.description}' : '', ''],
  ], 'CodeSonarPreset'))
enddef

# <Space> ticks a preset, <C-D>, <C-U>, g and G page, <CR> uses the
# ticked presets.
def PresetFilter(presets: list<dict<any>>, winid: number, key: string): bool
  var line = line('.', winid)

  if key ==# ' '
    presets[line - 1].selected = !presets[line - 1].selected
    winid->popup_settext(PresetLines(presets))
  elseif key ==# "\<C-D>" || key ==# "\<C-U>" || key ==# 'g' || key ==# 'G'
    win_execute(winid, $'normal! {SCROLL[key]}')
  else
    return MenuFilter(winid, key)
  endif

  return true
enddef

def PresetsChosen(presets: list<dict<any>>, _: number, result: number)
  if result > 0
    SetPresets(presets->copy()->filter((_, p) => p.selected)->map((_, p) => p.name))
  endif
enddef

def ChoosePresets(presets: list<dict<any>>)
  if presets->empty()
    Error('The CodeSonar installation has no presets')
    return
  endif

  var attrs: dict<any> = {
    title: ' CodeSonar presets: <Space> tick, <CR> use ',
    zindex: 1000,
    cursorline: true,
    mapping: false,
    wrap: true,
    maxheight: max([5, &lines - 6]),
    maxwidth: min([100, &columns - 4]),
    padding: [0, 1, 0, 1],
    scrollbar: true,
    filter: function(PresetFilter, [presets]),
    callback: function(PresetsChosen, [presets]),
  }

  try
    attrs = call('lsp#options#PopupConfigure', ['CodeAction', attrs])
  catch
    attrs.border = []
  endtry

  DefinePresetHighlights()
  var winid = popup_create(PresetLines(presets), attrs)
  # Long descriptions continue below their start: after "[ ] ", the names
  # and two spaces.
  win_execute(winid, $'setlocal linebreak breakindent breakindentopt=shift:{NameWidth(presets) + 6}')
enddef

# Chooses the presets of analyses: :CodeSonarPresets [preset ...] sets
# them, without arguments a menu shows those of the installation.
export def Presets(...names: list<string>)
  if !names->empty()
    if !Server()->empty()
      SetPresets(names)
    else
      Error('The server is not running: open a file of the project first')
    endif

    return
  endif

  Execute('codesonar.presets', null, ChoosePresets)
enddef

export def CompletePresets(lead: string, _: string, _: number): list<string>
  var lspserver = Server()

  if lspserver->empty()
    return []
  endif

  var reply = lspserver.rpc('workspace/executeCommand', {command: 'codesonar.presets', arguments: []},
    {timeout: 2000})

  return reply->get('result', [])->mapnew((_, p) => p.name)->filter((_, n) => n->stridx(lead) == 0)
enddef
