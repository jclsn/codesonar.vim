# codesonar.vim

CodeSonar warnings in Vim, from a CodeSonar hub or an exported SARIF file.

The work is done by the [codesonar-lsp] language server: it talks to the
hub, moves warnings along with the code while it is edited and hides
warnings whose code changed since the analysis. This plugin registers the
server with [yegappan/lsp] and adds what LSP has no counterpart for:

- choose, show, hide and delete the analyses of the hub project
- resolve warnings on the hub as fixed or as false positives, with a code
  action or `:CodeSonarResolve`
- disable the check of a warning in `codesonar.conf`, with a code action
- explain warnings in a popup, with the events that lead to them and the
  rules they may violate
- run `codesonar analyze` for the workspace, incrementally, with the hub,
  project, presets and checks of its `codesonar.conf`; `:CodeSonarConf`
  starts it, `:CodeSonarPresets` and `:CodeSonarChecks` choose presets and
  checks in a popup
- show the loading progress in the status line, also with vim-airline and
  lightline

The warnings are regular diagnostics, so the commands of yegappan/lsp work
for them, e.g. `:LspDiag next` and `:LspCodeAction`.

[codesonar-lsp]: https://github.com/jclsn/codesonar-lsp
[yegappan/lsp]: https://github.com/yegappan/lsp

## Installation

Requirements: Vim 9.1, yegappan/lsp and `codesonar-lsp` in `$PATH`
(`cargo install --path .` in its repository). `:CodeSonarAnalyze` needs the
CodeSonar command line tools.

With vim-plug:

```vim
Plug 'yegappan/lsp'
Plug '~/Workspace/codesonar.vim'
```

Configure the server in your vimrc like your other language servers of
yegappan/lsp. The plugin completes the entry in `g:codesonar` with its
handlers, and further keys like `browser` are settings of the plugin:

```vim
let codesonar = #{
      \ name: 'codesonar',
      \ path: 'codesonar-lsp',
      \ initializationOptions: #{
      \   hub: #{
      \     username: 'lspuser',
      \     passwordFile: '~/.config/codesonar/password',
      \   },
      \ },
      \ }
call LspAddServer([codesonar])
```

The hub, the project and how analyses run come from the `codesonar.conf`
of each workspace, see `:help codesonar-workspace`, and `:help codesonar`
for the commands and settings.

## Tests

```sh
test/run.sh    # needs yegappan/lsp in ~/.vim/plugged/lsp or $LSP_PLUGIN
```

The tests run `codesonar-lsp` from `$PATH`, or the one in `$CODESONAR_LSP`,
against a mock hub.
