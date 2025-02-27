require 'open3'
require 'shellwords'

module Exeggutor
  # A handle to a process, with IO handles to communicate with it
  # and a {ProcessResult} object when it's done
  class ProcessHandle
    # @private
    def initialize(args, env: nil, chdir: nil)
      @stdin_io, @stdout_io, @stderr_io, @wait_thread = Exeggutor::run_popen3(args, env, chdir)

      # Make the streams as synchronous as possible, to minimize the possibility of a surprising lack
      # of output
      @stdout_io.sync = true
      @stderr_io.sync = true

      @stdout_str = +''  # Using unfrozen strings
      @stderr_str = +''
      @unread_stdout = +''
      @unread_stderr = +''

      @stdout_queue = Queue.new
      @stderr_queue = Queue.new

      # popen3 can deadlock if one stream is written to too much without being read,
      # so it's important to continuously read from both streams. This is why
      # we can't just let the user call .gets on the streams themselves
      @read_thread = Thread.new do
        remaining_ios = [@stdout_io, @stderr_io]
        while remaining_ios.size > 0
          readable_ios, = IO.select(remaining_ios)
          for readable_io in readable_ios
            begin
              data = readable_io.read_nonblock(100_000)
              if readable_io == @stdout_io
                handle_new_data(data, @unread_stdout, @stdout_queue)
              else
                handle_new_data(data, @unread_stderr, @stderr_queue)
              end
            rescue IO::WaitReadable
              # Shouldn't usually happen because IO.select indicated data is ready, but maybe due to EINTR or something
              next
            rescue EOFError
              remaining_ios.delete(readable_io)
            end
          end
        end
      end
    end

    # @private
    def handle_new_data(new_data, unread_data, queue)
      unread_data << new_data
      loop do
        index = unread_data.index("\n")
        break if !index
        queue.push(unread_data.slice!(0, index))
      end
    end

    def stdout_gets
      @stdout_mutex.synchronize do
        loop do
          index = @unread_stdout.index("\n")
          return @unread_stdout.slice!(0, index) if index
          @cond.wait(@stdout_mutex)
        end
      end
    end

    def stderr_gets
      @stderr_mutex.synchronize do
      end
    end

    # Writes data to stdin
    #
    # @param data [String] The data to write to stdin
    def write_to_stdin(data)
      @stdin_io.write(data)
    end

    # Closes stdin. Calling this after the stream is already closed is a no-op.
    def close_stdin
      @stdin_io.close if !@stdin_io.closed?
    end

    def pid
      @wait_thread.pid
    end

    # Waits for the process to complete, if necessary, and then returns a {ProcessResult}
    # object with the results
    def result
      return if @result

      @stdin_io.close if !@stdin_io.closed?

      exit_status = @wait_thread.value

      # Ensure all IO is complete
      @stdout_thread.join
      @stderr_thread.join

      # Close open pipes
      @stdout_io.close
      @stderr_io.close

      @result = ProcessResult.new(
        stdout: @stdout_str,
        stderr: @stderr_str,
        exit_code: exit_status.exitstatus
        pid: self.pid
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
    attr_reader :stdout, :stderr, :exit_code, :pid

    # @private
    def initialize(stdout:, stderr:, exit_code:, pid:)
      @stdout = stdout
      @stderr = stderr
      @exit_code = exit_code
      @pid = pid
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
  def self.exeg(args, can_fail: false, show_stdout: false, show_stderr: false, env: nil, chdir: nil, stdin_data: nil)
    raise "args.size must be >= 1" if args.empty?
    handle = ProcessHandle.new(args, env: env, chdir: chdir)
    handle.stdin_io.write(stdin_data) if stdin_data
    handle.stdin_io.close

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
        pid: #{result.pid}
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
