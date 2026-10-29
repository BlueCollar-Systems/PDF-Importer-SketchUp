require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/command_runner'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control'

class CommandRunnerLegacyCaptureTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::CommandRunner
  Temp = BlueCollarSystems::PDFVectorImporter::SafeTemp
  Control = BlueCollarSystems::PDFVectorImporter::ImportRunControl

  def setup
    @parent = Dir.mktmpdir('legacy-command-test-')
    @prior_temp = ENV['BC_PDF_TEMP_DIR']
    ENV['BC_PDF_TEMP_DIR'] = @parent
    Temp.reset!
  end

  def teardown
    ENV['BC_PDF_TEMP_DIR'] = @prior_temp
    Temp.reset!
    if File.directory?(@parent)
      raise 'Unexpected test cleanup path' unless File.dirname(File.realpath(@parent)) == File.realpath(Dir.tmpdir) && File.basename(@parent).start_with?('legacy-command-test-')
      FileUtils.remove_entry(@parent)
    end
  end

  def run_child(code, args = [], opts = {})
    Subject.stub(:legacy_bundled_capture?, true) do
      Subject.run([RbConfig.ruby, '--disable-gems', '-e', code] + args, opts)
    end
  end

  def assert_capture_removed
    assert_equal [], Dir.entries(@parent) - ['.', '..']
  end

  def test_separate_binary_stdout_stderr_exceed_pipe_capacity_without_threads
    code = "STDOUT.binmode; STDERR.binmode; STDOUT.write([0,255,10,13].pack('C*')*40000); STDERR.write([255,0,13,10].pack('C*')*40000)"
    value = run_child(code)
    assert value[:ok], value.inspect
    assert_equal [0,255,10,13].pack('C*')*40000, value[:stdout]
    assert_equal [255,0,13,10].pack('C*')*40000, value[:stderr]
    assert_nil value[:error]
    assert_capture_removed
  end

  def test_stdin_is_eof_and_empty_stdout_is_preserved
    value = run_child("STDOUT.write(STDIN.read); STDERR.write('eof')")
    assert value[:ok], value.inspect
    assert_equal '', value[:stdout]
    assert_equal 'eof', value[:stderr]
    assert_capture_removed
  end

  def test_arguments_remain_literal_and_nonzero_exit_keeps_both_streams
    args = ['one two', 'a&b', '$(literal)', 'quote"inside']
    value = run_child("STDOUT.binmode; STDOUT.write(ARGV.join(0.chr)); STDERR.write('expected failure'); exit 7", args)
    refute value[:ok]
    refute value[:timed_out]
    assert_equal 7, value[:exitstatus]
    assert_equal args.join(0.chr), value[:stdout]
    assert_equal 'expected failure', value[:stderr]
    assert_nil value[:error]
    assert_capture_removed
  end

  def test_environment_overrides_are_child_scoped_and_nil_removes_a_key
    name = 'BC_LEGACY_CAPTURE_ENV_FIXTURE'
    previous = ENV[name]
    ENV[name] = 'parent'
    code = "STDOUT.write(ENV[#{name.inspect}].inspect)"
    assert_equal 'child'.inspect, run_child(code, [], :env => {name => 'child'})[:stdout]
    assert_equal 'nil', run_child(code, [], :env => {name => nil})[:stdout]
    assert_equal 'parent'.inspect, run_child(code)[:stdout]
    assert_equal 'parent', ENV[name]
    assert_capture_removed
  ensure
    ENV[name] = previous
  end

  def test_timeout_reaps_only_its_child_and_cleans_capture_files
    observed_pid = nil
    original_spawn = Process.method(:spawn)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    value = Process.stub(:spawn, lambda { |*args| observed_pid = original_spawn.call(*args) }) do
      run_child('sleep 10', [], :timeout_s => 0.2)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    refute value[:ok]
    assert value[:timed_out], value.inspect
    assert_operator elapsed, :<, 3.0
    assert_raises(Errno::ECHILD) { Process.waitpid2(observed_pid, Process::WNOHANG) }
    assert_capture_removed
  end

  def test_launch_failure_leaves_no_capture_files
    value = Subject.stub(:legacy_bundled_capture?, true) do
      Subject.run([File.join(@parent, 'missing-native-helper.exe'), '-v'])
    end
    refute value[:ok]
    assert value[:error]
    assert_nil value[:exitstatus]
    assert_capture_removed
  end

  def test_exact_bundled_cli_selector_accepts_all_three_and_rejects_wrappers_and_siblings
    root = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/Library/bin', File.dirname(__FILE__))
    Subject.stub(:legacy_native_runtime?, true) do
      %w[pdftotext.exe pdffonts.exe pdftocairo.exe].each do |name|
        path = File.join(root, name)
        assert Subject.send(:legacy_bundled_capture?, [path]), path
        fake = File.join(@parent, name)
        File.open(fake, 'wb') { |file| file.write('fixture, never executed') }
        refute Subject.send(:legacy_bundled_capture?, [fake]), fake
      end
      refute Subject.send(:legacy_bundled_capture?, [File.join(root, 'pdftotext.cmd')])
      refute Subject.send(:legacy_bundled_capture?, [File.join(root, 'pdftotext.exe.wrapper')])
      refute Subject.send(:legacy_bundled_capture?, [File.join(root, '..', 'pdftotext.exe')])
    end
    refute Subject.send(:legacy_bundled_capture?, [File.join(root, 'pdftotext.exe')]) unless defined?(Sketchup)
  end

  def test_reaped_child_is_never_terminated
    Process.stub(:kill, lambda { |*_| flunk 'Successful reaped child must not be terminated' }) do
      assert run_child('exit 0')[:ok]
    end
    assert_capture_removed
  end

  def test_real_heartbeat_is_pulsed_during_file_capture_wait
    peeks = []
    heartbeat = Control::UiHeartbeat.new(:peek => lambda { peeks << true }, :interval => 0.001)
    value = Control.with_ui_heartbeat(heartbeat) { run_child("sleep 0.12; STDOUT.write('done')") }
    assert value[:ok], value.inspect
    assert_equal 'done', value[:stdout]
    assert_operator peeks.length, :>, 1
    assert_capture_removed
  end

  def test_cancel_propagates_after_bounded_reap_and_file_cleanup
    failure = Control::ImportCancelled.new([], 1, {})
    observed_pid = nil
    original_spawn = Process.method(:spawn)
    raised = Process.stub(:spawn, lambda { |*args| observed_pid = original_spawn.call(*args) }) do
      Control.stub(:heartbeat!, lambda { |*_| raise failure }) do
        assert_raises(Control::ImportCancelled) { run_child('sleep 10') }
      end
    end
    assert_same failure, raised
    assert_raises(Errno::ECHILD) { Process.waitpid2(observed_pid, Process::WNOHANG) }
    assert_capture_removed
  end

  def test_lost_wait_record_never_kills_or_reads_potentially_active_capture_files
    original_wait = Process.method(:waitpid2)
    lost_waiter = lambda do |pid, flags|
      value = original_wait.call(pid, flags)
      raise Errno::EINVAL, 'simulated child-record loss after a competing reap' if value
      nil
    end
    value = Process.stub(:waitpid2, lost_waiter) do
      Process.stub(:kill, lambda { |*_| flunk 'Uncertain child record must never be killed' }) do
        File.stub(:binread, lambda { |*_| flunk 'Uncertain active capture must never be read' }) do
          run_child('exit 0')
        end
      end
    end
    refute value[:ok]
    assert_match(/child wait is unverified/, value[:error])
    assert_match(/capture files retained/, value[:error])
    assert_equal '', value[:stdout]
    assert_equal '', value[:stderr]
    assert_equal 1, Dir.glob(File.join(@parent, 'bc-command-*')).length
  end

  def test_nonfinite_timeout_is_normalized_before_launch
    value = run_child("STDOUT.write('finite')", [], :timeout_s => Float::NAN)
    assert value[:ok], value.inspect
    assert_equal 'finite', value[:stdout]
    assert_capture_removed
  end

  def test_nonzero_utf8_and_invalid_stderr_bytes_keep_raw_result_and_safe_log_text
    [[195,169], [255,254]].each do |bytes|
      messages = []
      value = Subject.stub(:safe_warn, lambda { |_context, message| messages << message }) do
        run_child("STDERR.binmode; STDERR.write(#{bytes.inspect}.pack('C*')); exit 7")
      end
      refute value[:ok]
      assert_equal 7, value[:exitstatus]
      assert_equal bytes.pack('C*'), value[:stderr]
      assert_nil value[:error]
      assert_equal 1, messages.length
      assert messages.first.valid_encoding?
      assert_equal Encoding::UTF_8, messages.first.encoding
      assert_capture_removed
    end
  end
end
