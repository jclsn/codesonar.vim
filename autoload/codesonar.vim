vim9script
# Registers codesonar-lsp with yegappan/lsp and builds views on the
# commands of the server. All CodeSonar logic lives in the server.

const NAME = 'codesonar'
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

# The server entry of yegappan/lsp in g:codesonar. Besides its keys, it
# has the settings of the plugin, e.g. browser.
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

# The settings of the server: the initializationOptions of g:codesonar.
export def ServerSettings(): dict<any>
  return Settings()->get('initializationOptions', {})
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

const SPINNER = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
var spinner_timer = 0
var spinner_frame = 0

# What the server is busy with, for the status line, e.g.
# "CodeSonar ⠹ Downloading 4.2 MB". Empty when it is idle.
export def Progress(): string
  for info in g:->get('LspProgress', {})->values()
    if info.serverName != ServerName()
      continue
    endif

    var parts = [info.title, SPINNER[spinner_frame]]

    if !info.message->empty()
      parts->add(info.message)
    endif

    if info.percentage >= 0
      parts->add($'{info.percentage}%')
    endif

    return parts->join(' ')
  endfor

  return ''
enddef

# Turns the spinner while the server is busy.
export def ProgressUpdated()
  var busy = !Progress()->empty()

  if busy && spinner_timer == 0
    spinner_timer = timer_start(100, (_) => Spin(), {repeat: -1})
  elseif !busy && spinner_timer != 0
    timer_stop(spinner_timer)
    spinner_timer = 0
  endif

  redrawstatus!
enddef

def Spin()
  spinner_frame = (spinner_frame + 1) % len(SPINNER)
  ProgressUpdated()
enddef

def ShowsProgress(): bool
  return Settings()->get('statusline', true) != false
enddef

# Adds the progress to section c of vim-airline, next to its own progress.
export def AirlineInit()
  if !ShowsProgress()
    return
  endif

  airline#parts#define_function('codesonar', 'codesonar#Progress')
  airline#parts#define_accent('codesonar', 'bold')
  g:airline_section_c ..= airline#section#create([' ', 'codesonar'])
enddef

# Adds the progress to the right of the active status line of lightline,
# unless the configuration has it already.
export def LightlineInit()
  if !ShowsProgress()
    return
  endif

  g:lightline = g:->get('lightline', {})
  var components = g:lightline->get('component_function', {})
  if components->has_key('codesonar')
    return
  endif

  g:lightline.component_function = components->extend({codesonar: 'codesonar#Progress'})
  g:lightline.component_function_visible_condition =
    g:lightline->get('component_function_visible_condition', {})
    ->extend({codesonar: '!empty(codesonar#Progress())'})
  var active = g:lightline->get('active', {})
  var right = active->get('right', [['lineinfo'], ['percent'], ['fileformat', 'fileencoding', 'filetype']])
  g:lightline.active = active->extend({right: right + [['codesonar']]})
  lightline#init()
  lightline#update()
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

# Whether the server configuration was handed out to be registered.
# Completes a server entry of yegappan/lsp with what the plugin needs:
# its handlers and defaults for the keys that are not set.
export def Complete(entry: dict<any>): dict<any>
  entry->extend({
    name: NAME,
    filetype: ['c', 'cpp'],
    path: 'codesonar-lsp',
    initializationOptions: {},
    rootSearch: ['codesonar.conf', '.codesonar', '.git'],
    features: {completion: false},
  }, 'keep')
  entry.customNotificationHandlers = entry->get('customNotificationHandlers', {})
    ->extend({'codesonar/loading': Loading, 'codesonar/loaded': Loaded})
  entry.customRequestHandlers = entry->get('customRequestHandlers', {})
    ->extend({'window/showDocument': ShowDocument})
  return entry
enddef

# Completes the server entry in g:codesonar, before yegappan/lsp registers
# it with the other servers of the vimrc, e.g. in ~/.vim/lsp/codesonar.vim: >
#   let codesonar = #{
#         \ name: 'codesonar',
#         \ path: 'codesonar-lsp',
#         \ initializationOptions: #{hub: #{url: 'http://hub:7340'}},
#         \ }
#   call LspAddServer([codesonar])
export def Prepare()
  if type(get(g:, 'codesonar', v:none)) == v:t_dict
    Complete(g:codesonar)
  endif
enddef

# Registers a server entry with yegappan/lsp if the vimrc has none.
export def Register()
  if !exists('*g:LspAddServer')
    Error('The plugin yegappan/lsp is not installed')
    return
  endif

  if !exists('g:codesonar')
    g:codesonar = Complete({})
    g:LspAddServer([g:codesonar])
  endif

  # The explain code action is shown here instead of in the server.
  if exists('*g:LspRegisterCmdHandler')
    g:LspRegisterCmdHandler(EXPLAIN, ExplainAction)
  endif
enddef

def ServerName(): string
  return Settings()->get('name', NAME)
enddef

# The running server, from any buffer.
def Running(): dict<any>
  if !server->empty() && server.running
    return server
  endif

  try
    server = call('lsp#buffer#CurbufGetServerByName', [ServerName()])
  catch
    server = {}
  endtry

  return !server->empty() && server.running ? server : {}
enddef

# Runs a server command and calls Done with its result.
export def Execute(command: string, argument: any, Done: func(any),
    Failed: func() = null_function)
  var lspserver = Running()

  if lspserver->empty()
    Error('The server is not running: open a file of the project first')
    return
  endif

  var params = {command: command, arguments: argument == null ? [] : [argument]}

  lspserver.rpc_a('workspace/executeCommand', params, (_, result, error) => {
    # yegappan/lsp reports errors itself.
    if error->empty()
      Done(result)
    elseif Failed != null_function
      Failed()
    endif
  })
enddef

export def Summary(info: dict<any>): string
  if info->get('hidden', false)
    return 'Hiding the analysis...'
  endif

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

# Turns the shown analysis off, or the hidden one on again.
export def Toggle()
  Execute('codesonar.toggle', null, Ignore)
enddef

# Keys of menus, which items skips: the 1-based line or 0.
const MENU_MOVES = {
  j: 1, "\<Down>": 1, "\<C-N>": 1, "\<Tab>": 1,
  k: -1, "\<Up>": -1, "\<C-P>": -1, "\<S-Tab>": -1,
}

# The filter of menus whose first items lines can be chosen, or all lines
# if items is 0. Keys has the functions of further keys, which close the
# menu, actions those of keys that keep it open.
def MenuFilter(keys: dict<func(number)>, actions: dict<func(number, number)>,
    items: number, winid: number, key: string): bool
  var line = line('.', winid)

  if key ==# "\<Esc>" || key ==# "\<C-C>" || key ==# 'q'
    winid->popup_close(-1)
  elseif actions->has_key(key)
    actions[key](winid, line)
  elseif keys->has_key(key)
    winid->popup_close(-1)
    # The handler may open popups, which a filter must not.
    timer_start(0, (_) => keys[key](line))
  elseif items == 0
    return popup_filter_menu(winid, key)
  elseif MENU_MOVES->has_key(key)
    var next = (line - 1 + MENU_MOVES[key] + items) % items + 1
    win_execute(winid, $'normal! {next}G')
  elseif key ==# "\<CR>" || key ==# ' '
    winid->popup_close(line)
  else
    return popup_filter_menu(winid, key)
  endif

  return true
enddef

def PopupAttrs(attrs: dict<any>): dict<any>
  try
    return call('lsp#options#PopupConfigure', ['CodeAction', attrs])
  catch
    return attrs->extend({border: []})
  endtry
enddef

const MENU_HIGHLIGHTS = {Key: 'Special', Hint: 'Comment'}

def DefineMenuHighlights()
  for [name, group] in MENU_HIGHLIGHTS->items()
    execute $'highlight default link CodeSonarMenu{name} {group}'

    if prop_type_get($'CodeSonarMenu{name}')->empty()
      prop_type_add($'CodeSonarMenu{name}', {highlight: $'CodeSonarMenu{name}'})
    endif
  endfor
enddef

# The line of key hints below menus, e.g. "<CR> show  d delete".
export def HintLine(hints: list<list<string>>): dict<any>
  var parts: list<list<string>> = []

  for [key, action] in hints
    if !parts->empty()
      parts->add(['   ', ''])
    endif

    parts += [[key, 'Key'], [' ' .. action, 'Hint']]
  endfor

  return Line(parts, 'CodeSonarMenu')
enddef

const MENU_HINTS = [['<CR>', 'choose'], ['q', 'close']]

# The lines of a menu: its items and the hints of its keys.
def MenuLines(items: list<string>, hints: list<list<string>>): list<dict<any>>
  return items->mapnew((_, item) => ({text: item})) + [{text: ''}, HintLine(hints)]
enddef

# Shows other items in the menu winid, if it is still open.
export def SetMenuItems(winid: number, items: list<string>, hints: list<list<string>>)
  if !popup_getpos(winid)->empty()
    winid->popup_settext(MenuLines(items, hints))
  endif
enddef

# A popup menu in the style of yegappan/lsp, with hints of its keys below
# the items. Callback gets the 1-based choice, or -1 if cancelled. Options:
#   keys	functions of further keys, which get the 1-based line after
#		the menu was closed
#   actions	functions of keys that keep the menu open, which get the
#		menu and the 1-based line
#   line	the item shown first
#   hints	the keys and what they do
export def Menu(items: list<string>, title: string, Callback: func(number),
    options: dict<any> = {}): number
  DefineMenuHighlights()
  var keys: dict<func(number)> = options->get('keys', {})
  var actions: dict<func(number, number)> = options->get('actions', {})
  var hints: list<list<string>> = options->get('hints', MENU_HINTS)
  var id = popup_create(MenuLines(items, hints), PopupAttrs({
    title: $' {title} ',
    zindex: 1000,
    cursorline: true,
    mapping: false,
    wrap: false,
    padding: [0, 1, 0, 1],
    callback: (_, result) => Callback(result),
    filter: (winid, key) => MenuFilter(keys, actions, len(items), winid, key),
  }))
  win_execute(id, $'normal! {min([options->get('line', 1), len(items)])}G')
  return id
enddef

# Asks a yes/no question in a popup. Callback gets true for yes.
export def Confirm(question: string, Callback: func(bool)): number
  return popup_dialog([question, '', '(y)es  (n)o'], PopupAttrs({
    title: ' CodeSonar ',
    zindex: 1100,
    padding: [0, 1, 0, 1],
    highlight: 'WarningMsg',
    filter: 'popup_filter_yesno',
    callback: (_, result) => Callback(result == 1),
  }))
enddef

# The lines of the analysis menu. The shown analysis is marked with "*",
# one that is loading with "~". Cached ones show up quickly.
export def AnalysisLines(analyses: list<dict<any>>): list<string>
  return analyses->mapnew((_, a) => printf('%s %4d  %s  %s%s%s',
    a.current ? '*' : a->get('loading', false) ? '~' : ' ', a.id,
    a.name, a.started, a.finished ? '' : $'  [{a.state}]',
    a->get('cached', false) ? '  [cached]' : ''))
enddef

const ANALYSIS_HINTS = [['<CR>', 'show'], ['<Space>', 'show/hide'], ['x', 'delete locally'],
  ['d', 'delete on hub'], ['q', 'close']]

# Takes over which analyses are cached from the analyses of the server.
def UpdateCached(analyses: list<dict<any>>, result: dict<any>)
  var cached = result.analyses->filter((_, a) => a.cached)->mapnew((_, a) => a.id)

  for a in analyses
    a.cached = cached->index(a.id) >= 0
  endfor
enddef

export def Analyses()
  Execute('codesonar.analyses', null, (result) => ShowAnalyses(result))
enddef

# The menu of the analyses: Enter shows one, Space shows or hides one and
# keeps the menu open, x deletes the local copy of one and d deletes one.
def ShowAnalyses(result: dict<any>, line: number = 1)
  var analyses = result.analyses

  if analyses->empty()
    Error($'No analyses in hub project {result.project}')
    return
  endif

  Menu(AnalysisLines(analyses), $'CodeSonar analyses of {result.project}',
    (choice) => ChooseAnalysis(analyses, choice), {
      keys: {d: (choice) => DeleteAnalysis(result, choice)},
      actions: {
        ' ': (winid, choice) => ToggleAnalysis(analyses, winid, choice),
        x: (winid, choice) => UncacheAnalysis(analyses, winid, choice),
      },
      line: line,
      hints: ANALYSIS_HINTS,
    })
enddef

# Shows the analysis, or hides it if it is shown, and marks it in the menu.
def ToggleAnalysis(analyses: list<dict<any>>, winid: number, choice: number)
  var analysis = analyses[choice - 1]
  var Update = () => SetMenuItems(winid, AnalysisLines(analyses), ANALYSIS_HINTS)

  if !analysis.finished
    Error($'Analysis {analysis.id} is not finished yet')
    return
  endif

  var Shown = (info: dict<any>) => {
    var shown = info->get('hubId', null)

    for a in analyses
      a.current = type(shown) == v:t_string && shown ==# string(a.id)
      a.loading = false
    endfor

    Update()
    # A shown analysis is cached afterwards.
    Execute('codesonar.analyses', null, (result) => {
      UpdateCached(analyses, result)
      Update()
    })
  }
  var Failed = () => {
    analysis.loading = false
    Update()
  }

  if analysis.current
    Execute('codesonar.hide', null, Shown, Failed)
    return
  endif

  analysis.loading = true
  Update()
  Execute('codesonar.load', {analysis: analysis.id}, Shown, Failed)
enddef

# Deletes the local copy of an analysis, so that it is downloaded again.
def UncacheAnalysis(analyses: list<dict<any>>, winid: number, choice: number)
  var analysis = analyses[choice - 1]

  if !analysis->get('cached', false)
    Error($'Analysis {analysis.id} has no local copy')
    return
  endif

  Execute('codesonar.uncache', {analysis: analysis.id}, (result) => {
    UpdateCached(analyses, result)
    SetMenuItems(winid, AnalysisLines(analyses), ANALYSIS_HINTS)
    Message($'Deleted the local copy of analysis {analysis.id}')
  })
enddef

def DeleteAnalysis(result: dict<any>, choice: number)
  var analysis = result.analyses[choice - 1]
  var question = $'Delete analysis {analysis.id} "{analysis.name}" of {result.project} '
    .. 'from the hub? This cannot be undone.'

  Confirm(question, (yes) => {
    if !yes
      ShowAnalyses(result, choice)
      return
    endif

    Execute('codesonar.deleteAnalysis', {analysis: analysis.id}, (remaining) => {
      if remaining.deleted
        Message($'Deleted analysis {analysis.id} "{analysis.name}"')
      else
        Error(remaining.message)
      endif

      ShowAnalyses(remaining, choice)
    })
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
  if type(project->get('workspaceConf', null)) == v:t_string
    execute 'split' fnameescape(project.workspaceConf)
    return
  endif

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

# Sends the settings of the server after a change.
def SendSettings()
  Running().sendNotification('workspace/didChangeConfiguration', {settings: {codesonar: ServerSettings()}})
enddef

def SetPresets(names: list<string>)
  var settings = ServerSettings()
  settings.analyze = settings->get('analyze', {})->extend({presets: names})
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
    return MenuFilter({}, {}, 0, winid, key)
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
    if !Running()->empty()
      SetPresets(names)
    else
      Error('The server is not running: open a file of the project first')
    endif

    return
  endif

  Execute('codesonar.presets', null, ChoosePresets)
enddef

export def CompletePresets(lead: string, _: string, _: number): list<string>
  var lspserver = Running()

  if lspserver->empty()
    return []
  endif

  var reply = lspserver.rpc('workspace/executeCommand', {command: 'codesonar.presets', arguments: []},
    {timeout: 2000})

  return reply->get('result', [])->mapnew((_, p) => p.name)->filter((_, n) => n->stridx(lead) == 0)
enddef
