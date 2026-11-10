vim9script
# Highlights code, links and numbers in CodeSonar explanations. Titles,
# headings and labels are text properties, see autoload/codesonar.vim.

if exists('b:current_syntax')
  finish
endif

syntax match CodeSonarExplainNumber /\<\%(0[xX]\x\+\|\d\+\%(\.\d\+\)\=\)[uUlLfF]*\>/
syntax match CodeSonarExplainQuoted /\%(^\|[^[:alnum:]]\)\zs'[^' ]\+'/
syntax match CodeSonarExplainFunction /\<\h\w*\ze(/
syntax match CodeSonarExplainFunction /\<\h\w*()/
syntax match CodeSonarExplainLocation /\<[[:alnum:]_.\/-]\+\.\a\+:\d\+\>/
syntax region CodeSonarExplainCode matchgroup=Conceal start=/`/ end=/`/ concealends oneline
syntax region CodeSonarExplainBold matchgroup=Conceal start=/\*\*/ end=/\*\*/ concealends oneline
syntax match CodeSonarExplainUrl /\<\%(https\=\|ftp\|file\):\/\/[^[:space:]<>"`)\]]\+/
# Markdown links show their text only.
syntax region CodeSonarExplainLink matchgroup=Conceal start=/\[\ze[^]]\+](/ end=/](\%([^()]\|([^()]*)\)*)/ concealends oneline

b:current_syntax = 'codesonarexplain'
