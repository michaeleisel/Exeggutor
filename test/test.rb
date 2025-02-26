require "minitest/autorun"
require_relative "../lib/exeggutor"
require 'pry-byebug'

class TestYourGem < Minitest::Test
  def test_various
    result = exeg(%W[echo hi])
    assert_equal "hi\n", result.stdout
    script = 'warn "this is stderr"; puts "this is stdout"; exit 1'

    error = assert_raises(Exeggutor::ProcessError) do
      exeg(%W[ruby -e #{script}])
    end
    assert_equal "this is stderr\n", error.result.stderr
    assert_equal "this is stdout\n", error.result.stdout

    result = exeg(%W[ruby -e #{script}], can_fail: true)
    assert_equal "this is stderr\n", error.result.stderr
    assert_equal "this is stdout\n", error.result.stdout

    result = exeg(%W[cat], stdin: "hi")
    assert_equal "hi", result.stdout

  end

  def test_async
    return if ENV["EXEG_SKIP_ASYNC"] == "1"

    handle = exeg_async(%W[ruby -e] + ["puts 'foo' ; sleep 2 ; warn 'bar' ; sleep 2 ; puts 'done'"])
    sleep 1
    stdout_calls = 0
    handle.on_stdout do |str|
      if stdout_calls == 0
        assert_equal("foo\n", str)
      elsif stdout_calls == 1
        assert_equal("done\n", str)
      else
        raise
      end
      stdout_calls += 1
    end

    stderr_calls = 0
    handle.on_stderr do |str|
      assert_equal(stderr_calls, 0)
      assert_equal("bar\n", str)
      stderr_calls += 1
    end
    result = handle.result
    assert_equal(result.stdout, "foo\ndone\n")
    assert_equal(result.stderr, "bar\n")
    assert_equal(result.exit_code, 0)
  end

  def test_chdir
    handle = exeg_async(%W[false])
    assert_equal(handle.result.exit_code, 1)

    Dir.mktmpdir do |dir|
      assert_equal(exeg(%W[pwd], chdir: dir).stdout, "#{File.realpath(dir)}\n")
    end
  end
end
