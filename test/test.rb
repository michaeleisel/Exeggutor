require "minitest/autorun"
require_relative "../lib/exeggutor"
require 'pry-byebug'

class TestYourGem < Minitest::Test
  def test_something
    result = run!(%W[echo hi])
    assert_equal "hi\n", result.stdout
    script = 'warn "this is stderr"; puts "this is stdout"; exit 1'

    error = assert_raises(Exeggutor::ProcessError) do
      run!(%W[ruby -e #{script}])
    end
    assert_equal "this is stderr\n", error.result.stderr
    assert_equal "this is stdout\n", error.result.stdout

    result = run!(%W[ruby -e #{script}], can_fail: true)
    assert_equal "this is stderr\n", error.result.stderr
    assert_equal "this is stdout\n", error.result.stdout
  end
end
