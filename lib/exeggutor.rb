require 'open3'
require 'shellwords'

class ProcessResult
  attr_reader :stdout, :stderr, :exit_code

  def initialize(stdout:, stderr:, exit_code:)
    @stdout = stdout
    @stderr = stderr
    @exit_code = exit_code
  end

  def success?
    exit_code == 0
  end
end

class ProcessError < StandardError
  attr_reader :result

  def initialize(result)
    @result = result
  end
end

def run_popen3(args, env)
  if env
    Open3.popen3(env, [args[0], args[0]], *args)
  else
    Open3.popen3([args[0], args[0]], *args)
  end
end

# Executes a command with the provided arguments and options
#
# @param args [Array<String>] The command and its arguments as an array.
# @param can_fail [Boolean] If false, raises a ProcessError on failure.
# @param show_stdout [Boolean] If true, prints stdout to the console in real-time.
# @param show_stderr [Boolean] If true, prints stderr to the console in real-time.
# @param cwd [String, nil] The working directory to run the command in. If nil, uses the current working directory.
# @param stdin_data [String, nil] Input data to pass to the command's stdin. If nil, doesn't pass any data to stdin.
#
# @return [ProcessResult] An object containing process info such as stdout, stderr, and exit code. Waits for the command to complete to return.
#
# @raise [ProcessError] If the command fails and `can_fail` is false.
def run!(args, can_fail: false, show_stdout: false, show_stderr: false, env: nil, cwd: nil, stdin_data: nil)
  # TODO: expand "~"? popen3 doesn't expand it by default
  if cwd
    stdin_stream, stdout_stream, stderr_stream, wait_thread = Dir.chdir(cwd) { run_popen3(args, env) }
  else
    stdin_stream, stdout_stream, stderr_stream, wait_thread = run_popen3(args, env)
  end

  stdin_stream.write(stdin_data) if stdin_data
  stdin_stream.close

  stderr_stream.sync = true # Match terminals more closely

  stdout_str = +''  # Using unfrozen string
  stderr_str = +''

  # Start readers for both stdout and stderr
  stdout_thread = Thread.new do
    while (line = stdout_stream.gets)
      stdout_str << line
      print line if show_stdout
    end
  end

  stderr_thread = Thread.new do
    while (line = stderr_stream.gets)
      stderr_str << line
      warn line if show_stderr
    end
  end

  # Wait for process completion
  exit_status = wait_thread.value

  # Ensure all IO is complete
  stdout_thread.join
  stderr_thread.join

  # Close open pipes
  stdout_stream.close
  stderr_stream.close

  result = ProcessResult.new(
    stdout: stdout_str.force_encoding('UTF-8'),
    stderr: stderr_str.force_encoding('UTF-8'),
    exit_code: exit_status.exitstatus
  )

  if !can_fail && !result.success?
    error_str = <<~ERROR_STR
      Command failed: #{args.shelljoin}
      Exit code: #{result.exit_code}
      stdout: #{result.stdout}
      stderr: #{result.stderr}
    ERROR_STR
    raise ProcessError.new(result), error_str
  end

  result
end
