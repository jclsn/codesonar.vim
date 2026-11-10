vim9script
# Builds the server configuration for setups that register their servers
# with g:LspAddServer() themselves.

import autoload 'codesonar.vim'

var added: list<dict<any>> = []

def! g:LspAddServer(servers: list<dict<any>>)
  added += servers
enddef

def g:Test_1_builds_the_server_configuration()
  var config = codesonar.Server({
    path: '/bin/codesonar-lsp',
    filetypes: ['cpp'],
    browser: 'firefox',
    hub: {url: 'http://hub:7340'},
  })
  assert_equal('codesonar', config.name)
  assert_equal('/bin/codesonar-lsp', config.path)
  assert_equal(['cpp'], config.filetype)
  # The settings of the plugin are not sent to the server.
  assert_equal({hub: {url: 'http://hub:7340'}}, config.initializationOptions)
  assert_equal(v:t_func, type(config.customNotificationHandlers['codesonar/loaded']))
  assert_equal(v:t_func, type(config.customRequestHandlers['window/showDocument']))
  assert_equal('firefox', g:codesonar.browser)
enddef

def g:Test_2_does_not_register_it_again()
  codesonar.Register()

  assert_equal([], added)
enddef
