vim9script
# Completes the server entry that a vimrc registers with its other servers.

import autoload 'codesonar.vim'

var added: list<dict<any>> = []

def! g:LspAddServer(servers: list<dict<any>>)
  added += servers
enddef

g:codesonar = {
  name: 'codesonar',
  path: '/bin/codesonar-lsp',
  filetype: ['cpp'],
  browser: 'firefox',
  initializationOptions: {hub: {url: 'http://hub:7340'}},
  customNotificationHandlers: {'other/notification': (_, _) => 0},
}
var entry = g:codesonar
runtime plugin/codesonar.vim

def g:Test_1_completes_the_server_entry()
  assert_true(g:codesonar is entry, 'the entry of the vimrc')
  assert_equal('/bin/codesonar-lsp', entry.path)
  assert_equal(['cpp'], entry.filetype)
  assert_equal({hub: {url: 'http://hub:7340'}}, entry.initializationOptions)
  assert_equal(['codesonar.conf', '.codesonar', '.git'], entry.rootSearch)
  assert_equal(v:t_func, type(entry.customNotificationHandlers['codesonar/loaded']))
  assert_equal(v:t_func, type(entry.customNotificationHandlers['other/notification']))
  assert_equal(v:t_func, type(entry.customRequestHandlers['window/showDocument']))
  assert_equal({hub: {url: 'http://hub:7340'}}, codesonar.ServerSettings())
enddef

def g:Test_2_does_not_register_it_again()
  codesonar.Register()

  assert_equal([], added)
enddef

def g:Test_3_registers_an_entry_without_one()
  unlet g:codesonar
  codesonar.Register()

  assert_equal(1, len(added))
  assert_equal('codesonar-lsp', added[0].path)
  assert_equal(['c', 'cpp'], added[0].filetype)
  assert_true(g:codesonar is added[0])
enddef
