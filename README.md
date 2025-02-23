# Exeggutor 🌴

#### A Simple, Capable, and Unified Interface for Running Subprocesses in Ruby

Tired of juggling between `system(...)`, `` `...` ``, and `Open3`? Exeggutor provides one simple method that a handles many different use cases - safely spawn processes with real-time output, captured stdout/stderr, and sane error handling.

```ruby
# Copy old_file to #{new_dir}/foo, and raise an exception if it fails
cmd!(%W[cp #{old_file} #{new_dir}/foo]) # Exception raised by default on failure

# Collect stdout from a long-running build task while showing the stdout/stderr progress updates as they're printed out
output = cmd!(%W[run_build.sh], show_stdout: true, show_stderr: true).stdout

# Manual error handling - diff uses exit code 1 if files are different, and >1 if an error occurred
diff_result = cmd!(%W[diff file1 file2], can_fail: true)
if diff_result.exit_code == 0
    puts "files are identical"
elsif diff_result.exit_code == 1
    puts "Files are different, here's the diff:\n#{diff_result.stdout}"
else
    puts "Error occurred: #{diff_result.stderr}"
end
```

#### Overview

Although Ruby has many different ways of running a subprocess, they all have various drawbacks and quirks. Also, some of the most convenient ways of calling a process, e.g. with backticks, are the most dangerous, because they spawn a subshell. Here's an overview of how Exeggutor solves these shortcomings:

|Problem with Standard Ruby APIs|Exeggutor Solution|
|-|-|
|Subshells are slow to spawn, error-prone, and insecure | Exeggutor ever uses a subshell and always runs processes directly|
|Non-subshells use ugly varargs syntax (e.g. `system('cp', old, "#{new}/foo")`)        |Exeggutor encourages elegant %W syntax by taking an array for the arguments (e.g. `cmd!(%W[cp #{old} #{new}/foo])`)|
|Process failures are silent, requiring manual checks|Exeggutor raises an exception on failure by default (with rich error context)|
|No simple way to both capture stdout/stderr as strings afterwards and simultaneously printing                       them |Exeggutor always captures stdout/stderr, and can optionally print either (_while_ the program is running)|
|Different APIs for different use cases|Exeggutor consists of a single method with smart defaults and many optional named parameters|

#### Installation

```
gem install exeggutor
```

#### Full API

Exeggutor's 
