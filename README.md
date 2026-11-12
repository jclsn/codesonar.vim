# codesonar.vim

CodeSonar warnings in Vim, from a CodeSonar hub or an exported SARIF file.

The work is done by the [codesonar-lsp] language server: it talks to the
hub, moves warnings along with the code while it is edited and hides
warnings whose code changed since the analysis. This plugin registers the
server with [yegappan/lsp] and adds what LSP has no counterpart for:

- choose, show, hide and delete the analyses of the hub project
- explain warnings in a popup, with the events that lead to them and the
  rules they may violate
- run `codesonar analyze` for the workspace, incrementally, with presets
  and the `codesonar.conf` of the workspace
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

Configure the hub in your vimrc:

```vim
g:codesonar = {
  hub: {
    url: 'http://nas:7340',
    username: 'lspuser',
    passwordFile: '~/.config/codesonar/password',
  },
}
```

See `:help codesonar` for the commands and settings.

## Tests

```sh
test/run.sh    # needs yegappan/lsp in ~/.vim/plugged/lsp or $LSP_PLUGIN
```

The tests run `codesonar-lsp` from `$PATH`, or the one in `$CODESONAR_LSP`,
against a mock hub.
