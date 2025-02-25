require 'open3'
require 'shellwords'

module Exeggutor
  # Represents the result of a process execution.
  #
  # @attr_reader stdout [String] The standard output of the process.
  # @attr_reader stderr [String] The standard error of the process.
  # @attr_reader exit_code [Integer] The exit code of the process.
  class ProcessResult
    attr_reader :stdout, :stderr, :exit_code

    # @private
    def initialize(stdout:, stderr:, exit_code:)
      @stdout = stdout
      @stderr = stderr
      @exit_code = exit_code
    end

    # Checks if the process was successful.
    #
    # @return [Boolean] True if the exit code is 0, otherwise false.
    def success?
      exit_code == 0
    end
  end

  # Represents an error that occurs during a process execution.
  # The error contains a {ProcessResult} object with details about the process.
  #
  # @attr_reader result [ProcessResult] The result of the process execution.
  class ProcessError < StandardError
    attr_reader :result

    # @private
    def initialize(result)
      @result = result
    end
  end

  # @private
  def self.run_popen3(args, env)
    # Use this weird [args[0], args[0]] thing for the case where a command with just one arg is being run
    if env
      Open3.popen3(env, [args[0], args[0]], *args.drop(1))
    else
      Open3.popen3([args[0], args[0]], *args.drop(1))
    end
  end

  def self.run!(args, can_fail: false, show_stdout: false, show_stderr: false, env: nil, cwd: nil, stdin_data: nil)
    # TODO: expand "~"? popen3 doesn't expand it by default
    if cwd
      stdin_stream, stdout_stream, stderr_stream, wait_thread = Dir.chdir(cwd) { Exeggutor::run_popen3(args, env) }
    else
      stdin_stream, stdout_stream, stderr_stream, wait_thread = Exeggutor::run_popen3(args, env)
    end

    stdin_stream.write(stdin_data) if stdin_data
    stdin_stream.close

    # Make the streams as synchronous as possible, to minimize the possibility of a surprising lack
    # of output
    stdout_stream.sync = true
    stderr_stream.sync = true

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
end

# Executes a command with the provided arguments and options
#
# @param args [Array<String>] The command and its arguments as an array.
# @param can_fail [Boolean] If false, raises a ProcessError on failure.
# @param show_stdout [Boolean] If true, prints stdout to the console in real-time.
# @param show_stderr [Boolean] If true, prints stderr to the console in real-time.
# @param cwd [String, nil] The working directory to run the command in. If nil, uses the current working directory.
# @param stdin_data [String, nil] Input data to pass to the command's stdin. If nil, doesn't pass any data to stdin.
# @param env_vars [Hash{String => String}, nil] A hashmap containing environment variable overrides,
#        or `nil` if no overrides are desired
#
# @return [ProcessResult] An object containing process info such as stdout, stderr, and exit code. Waits for the command to complete to return.
#
# @raise [ProcessError] If the command fails and `can_fail` is false.
def run!(...)
  Exeggutor::run!(...)
end
