vim9script
# Registers codesonar-lsp with yegappan/lsp and builds views on the
# commands of the server. All CodeSonar logic lives in the server.

const NAME = 'codesonar'
# Settings of the plugin, not of the server.
const PLUGIN_KEYS = ['path', 'args', 'filetypes', 'browser']
const TYPES = {1: 'E', 2: 'W', 3: 'I', 4: 'N'}

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
    customNotificationHandlers: {'codesonar/loaded': Loaded},
    customRequestHandlers: {'window/showDocument': ShowDocument},
  }])
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

export def Status()
  Execute('codesonar.status', null, (result) => Message(Summary(result)))
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

  Message($'Loading analysis {analysis.id}...')
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
