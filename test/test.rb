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

    exeg(%W[ruby -e #{script}], show_stdout: true, can_fail: true)
    exeg(%W[ruby -e #{script}], show_stderr: true, can_fail: true)

    result = exeg(%W[cat], stdin_data: "hi")
    assert_equal "hi", result.stdout
    assert_equal true, result.pid > 0
  end

  def test_async
    return if ENV["EXEG_SKIP_ASYNC"] == "1"

    handle = exeg_async(%W[ruby -e] + ["puts 'foo' ; sleep 1 ; warn 'bar' ; sleep 1 ; print 'done'"])
    assert_equal(handle.stdout.gets, "foo\n")
    assert_equal(handle.stderr.gets, "bar\n")
    assert_equal(handle.stdout.gets, "done")
    assert_equal(handle.stdout.gets, nil)
    assert_equal(handle.stderr.gets, nil)
  end

  def test_chdir
    handle = exeg_async(%W[false])
    assert_equal(handle.wait_thr.value.exitstatus, 1)

    Dir.mktmpdir do |dir|
      assert_equal(exeg(%W[pwd], chdir: dir).stdout, "#{File.realpath(dir)}\n")
    end
  end
end
