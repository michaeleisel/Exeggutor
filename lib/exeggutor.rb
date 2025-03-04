require 'open3'
require 'shellwords'

module Exeggutor

  # A handle to a process, with IO handles to communicate with it
  # and a {ProcessResult} object when it's done. It's largely similar to the array
  # of 4 values return by Open3.popen3. However, it doesn't suffer from that library's
  # dead-locking issue. For example, even if lots of data has been written to stdout that hasn't been
  # read, the subprocess can still write to stdout and stderr without blocking
  class ProcessHandle
    # @private
    def initialize(args, env: nil, chdir: nil)
      @stdin_io, @stdout_io, @stderr_io, @wait_thread = Exeggutor::run_popen3(args, env, chdir)

      # Make the streams as synchronous as possible, to minimize the possibility of a surprising lack
      # of output
      @stdout_io.sync = true
      @stderr_io.sync = true

      @stdout_queue = Queue.new
      @stderr_queue = Queue.new

      @stdout_pipe_reader, @stdout_pipe_writer = IO.pipe
      @stderr_pipe_reader, @stderr_pipe_writer = IO.pipe

      @stdout_write_thread = Thread.new do
        loop do
          data = @stdout_queue.pop
          break if !data # Queue is closed
          @stdout_pipe_writer.write(data)
        end
        @stdout_pipe_writer.close
      end

      @stderr_write_thread = Thread.new do
        loop do
          data = @stderr_queue.pop
          break if !data # Queue is closed
          @stderr_pipe_writer.write(data)
        end
        @stderr_pipe_writer.close
      end

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
                @stdout_queue.push(data)
              else
                @stderr_queue.push(data)
              end
            rescue IO::WaitReadable
              # Shouldn't usually happen because IO.select indicated data is ready, but maybe due to EINTR or something
              next
            rescue EOFError
              if readable_io == @stdout_io
                @stdout_queue.close
              else
                @stderr_queue.close
              end
              remaining_ios.delete(readable_io)
            end
          end
        end
      end
    end

    # An object containing process metadata and which can be waited on to wait
    # until the subprocess ends. Identical to popen3's wait_thr
    def wait_thr
      @wait_thread
    end

    # An IO object for stdin that can be written to
    def stdin
      @stdin_io
    end

    # An IO object for stdout that can be written to
    def stdout
      @stdout_pipe_reader
    end

    # An IO object for stderr that can be written to
    def stderr
      @stderr_pipe_reader
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
  # @attr_reader result {ProcessResult} The result of the process execution.
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
# @return {ProcessResult} An object containing process info such as stdout, stderr, and exit code.
#
# @raise {ProcessError} If the command fails and `can_fail` is false.
def exeg(args, can_fail: false, show_stdout: false, show_stderr: false, env: nil, chdir: nil, stdin_data: nil)
  raise "args.size must be >= 1" if args.empty?

  stdin_io, stdout_io, stderr_io, wait_thr = Exeggutor::run_popen3(args, env, chdir)
  stdin_io.write(stdin_data) if stdin_data
  stdin_io.close

  # Make the streams as synchronous as possible, to minimize the possibility of a surprising lack
  # of output
  stdout_io.sync = true
  stderr_io.sync = true

  stdout = +''
  stderr = +''

  # Although there could be more code sharing between this and exeg_async, it would either complicate exeg_async's inner workings
  # or force us to pay the same performance cost that exeg_async does
  remaining_ios = [stdout_io, stderr_io]
  while remaining_ios.size > 0
    readable_ios, = IO.select(remaining_ios)
    for readable_io in readable_ios
      begin
        data = readable_io.read_nonblock(100_000)
        if readable_io == stdout_io
          stdout << data
          $stdout.print(data) if show_stdout
        else
          stderr << data
          $stderr.print(data) if show_stderr
        end
      rescue IO::WaitReadable
        # Shouldn't usually happen because IO.select indicated data is ready, but maybe due to EINTR or something
        next
      rescue EOFError
        remaining_ios.delete(readable_io)
      end
    end
  end

  result = Exeggutor::ProcessResult.new(
    stdout: stdout,
    stderr: stderr,
    exit_code: wait_thr.value.exitstatus,
    pid: wait_thr.pid
  )
  if !can_fail && !result.success?
    error_str = <<~ERROR_STR
      Command failed: #{args.shelljoin}
      Exit code: #{result.exit_code}
      stdout: #{result.stdout}
      stderr: #{result.stderr}
      pid: #{result.pid}
    ERROR_STR
    raise Exeggutor::ProcessError.new(result), error_str
  end

  result
end

# Executes a command with the provided arguments and options. Does not wait for the process to finish.
#
# @param args [Array<String>] The command and its arguments as an array.
# @param chdir [String, nil] The working directory to run the command in. If nil, uses the current working directory.
# @param env [Hash{String => String}, nil] A hashmap containing environment variable overrides,
#        or `nil` if no overrides are desired
#
# @return {ProcessHandle}
def exeg_async(args, env: nil, chdir: nil)
  Exeggutor::ProcessHandle.new(args, env: env, chdir: chdir)
end
