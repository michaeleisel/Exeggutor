require 'open3'
require 'shellwords'

module Exeggutor
  # A handle to a process, with IO handles to communicate with it
  # and a {ProcessResult} object when it's done
  class ProcessHandle
    attr_accessor :stdin_stream

    # @private
    def initialize(args, env: nil, chdir: nil, stdin: nil)
      @stdin_stream, @stdout_stream, @stderr_stream, @wait_thread = Exeggutor::run_popen3(args, env, chdir)

      # Make the streams as synchronous as possible, to minimize the possibility of a surprising lack
      # of output
      @stdout_stream.sync = true
      @stderr_stream.sync = true

      @stdout_str = +''  # Using unfrozen strings
      @stderr_str = +''

      @stdout_subscribers = []
      @stderr_subscribers = []

      @stdout_mutex = Mutex.new
      @stderr_mutex = Mutex.new

      @stdout_thread = Thread.new do
        while (line = @stdout_stream.gets)
          @stdout_mutex.synchronize do
            @stdout_str << line
            for subscriber in @stdout_subscribers
              subscriber.call(line.dup)
            end
          end
        end
      end

      @stderr_thread = Thread.new do
        while (line = @stderr_stream.gets)
          @stderr_mutex.synchronize do
            @stderr_str << line
            for subscriber in @stderr_subscribers
              subscriber.call(line.dup)
            end
          end
        end
      end
    end

    # Returns a stream to communicate with stdin and/or close it.
    #
    # @return [IO] The stream
    def stdin_stream
      @stdin_stream
    end

    # Calls the given block each time more data from stdout has been received. If data
    # has already been written to stdout when this is called, it will immediately (synchronously)
    # call the block with all the data that has been written so far, whether or not the 
    # process has finished. In this way, no data is ever missed by the block.
    #
    # This method may be called multiple times, to allow multiple blocks to subscribe.
    def on_stdout(&block)
      @stdout_mutex.synchronize do
        if @stdout_str.size > 0
          yield(@stdout_str.dup)
        end
        @stdout_subscribers << block
      end

      nil
    end

    # Calls the given block each time more data from stderr has been received. If data
    # has already been written to stdout when this is called, it will immediately (synchronously)
    # call the block with all the data that has been written so far, whether or not the 
    # process has finished. In this way, no data is ever missed by the block.
    #
    # This method may be called multiple times, to allow multiple blocks to subscribe.
    def on_stderr(&block)
      @stderr_mutex.synchronize do
        if @stderr_str.size > 0
          yield(@stderr_str.dup)
        end
        @stderr_subscribers << block
      end

      nil
    end

    # Waits for the process to complete, if necessary, and then returns a {ProcessResult}
    # object with the results
    def result
      return if @result

      @stdin_stream.close if !@stdin_stream.closed?

      exit_status = @wait_thread.value

      # Ensure all IO is complete
      @stdout_thread.join
      @stderr_thread.join

      # Close open pipes
      @stdout_stream.close
      @stderr_stream.close

      @result = ProcessResult.new(
        stdout: @stdout_str.force_encoding('UTF-8'),
        stderr: @stderr_str.force_encoding('UTF-8'),
        exit_code: exit_status.exitstatus
      )

      @result
    end
  end

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
  def self.run_popen3(args, env, chdir)
    # Use this weird [args[0], args[0]] thing for the case where a command with just one arg is being run
    opts = {}
    opts[:chdir] = chdir if chdir
    if env
      Open3.popen3(env, [args[0], args[0]], *args.drop(1), opts)
    else
      Open3.popen3([args[0], args[0]], *args.drop(1), opts)
    end
  end

  # @private
  def self.exeg(args, can_fail: false, show_stdout: false, show_stderr: false, env: nil, chdir: nil, stdin: nil)
    raise "args.size must be >= 1" if args.empty?
    handle = ProcessHandle.new(args, env: env, chdir: chdir, stdin: stdin)
    handle.stdin_stream.write(stdin) if stdin
    handle.stdin_stream.close

    handle.on_stdout do |str|
      puts str if show_stdout
    end

    handle.on_stderr do |str|
      warn str if show_stderr
    end

    result = handle.result
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

# Executes a command with the provided arguments and options. Waits for the process to finish.
#
# @param args [Array<String>] The command and its arguments as an array.
# @param can_fail [Boolean] If false, raises a ProcessError on failure.
# @param show_stdout [Boolean] If true, prints stdout to the console in real-time.
# @param show_stderr [Boolean] If true, prints stderr to the console in real-time.
# @param chdir [String, nil] The working directory to run the command in. If nil, uses the current working directory.
# @param stdin [String, nil] Input data to pass to the command's stdin. If nil, doesn't pass any data to stdin.
# @param env [Hash{String => String}, nil] A hashmap containing environment variable overrides,
#        or `nil` if no overrides are desired
#
# @return [ProcessResult] An object containing process info such as stdout, stderr, and exit code. 
#
# @raise [ProcessError] If the command fails and `can_fail` is false.
def exeg(...)
  Exeggutor::exeg(...)
end

# Executes a command with the provided arguments and options. Does not wait for the process to finish.
#
# @param args [Array<String>] The command and its arguments as an array.
# @param chdir [String, nil] The working directory to run the command in. If nil, uses the current working directory.
# @param env [Hash{String => String}, nil] A hashmap containing environment variable overrides,
#        or `nil` if no overrides are desired
#
# @return [ProcessHandle]
#
# @raise [ProcessError] If the command fails and `can_fail` is false.
def exeg_async(...)
  Exeggutor::ProcessHandle.new(...)
end
