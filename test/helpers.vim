vim9script
# Shared test helpers.

export const DIR = expand('<sfile>:p:h')
export const FIXTURES = DIR .. '/fixtures'

var hub_job: job
var hub_port_file = ''

# Starts the mock hub with the given SARIF file and returns its URL.
export def StartHub(sarif_file: string = FIXTURES .. '/codesonar.sarif', source_dir: string = ''): string
  hub_port_file = tempname()
  var command = ['python3', '-I', DIR .. '/mock_hub.py', hub_port_file, sarif_file]
  hub_job = job_start(source_dir->empty() ? command : command + [source_dir])
  WaitFor(() => hub_port_file->filereadable() && !hub_port_file->readfile()->empty())
  return 'http://127.0.0.1:' .. hub_port_file->readfile()[0]
enddef

export def StopHub()
  hub_job->job_stop()
  delete(hub_port_file)
  delete(hub_port_file .. '.log')
enddef

# The requests the mock hub received, as 'METHOD PATH AUTHORIZATION'.
export def HubLog(): list<string>
  var log = hub_port_file .. '.log'
  return log->filereadable() ? log->readfile()->mapnew((_, l) => l->trim()) : []
enddef

# Waits until Condition() is true, or fails after the timeout.
export def WaitFor(Condition: func(): bool, timeout: number = 5000)
  var waited = 0

  while !Condition()
    if waited >= timeout
      assert_report('timed out waiting')
      return
    endif

    sleep 10m
    waited += 10
  endwhile
enddef
