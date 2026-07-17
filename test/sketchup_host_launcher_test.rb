#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)

class SketchupHostLauncherTest < Minitest::Test
  class FakeBackend
    attr_reader :spawned_environment, :spawned_command, :killed

    def initialize(states, &tick)
      @states = states.dup
      @tick = tick
      @killed = []
    end

    def spawn(environment, command)
      @spawned_environment = environment
      @spawned_command = command
      4242
    end

    def poll(_pid)
      @tick.call if @tick
      @states.shift || :running
    end

    def kill(pid)
      @killed << pid
      true
    end
  end

  class FakeClock
    def initialize(values)
      @values = values
    end

    def now
      @values.shift || @values.last || 100.0
    end

    def sleep(_seconds); end
  end

  def setup
    load File.join(REPO_ROOT, 'tools', 'sketchup_host_launcher.rb')
  end

  def test_controlled_profile_hides_normal_user_and_machine_plugin_roots
    Dir.mktmpdir('normal-su-profile') do |normal|
      paid_plugin = File.join(normal, 'PDFImport.rb')
      File.write(paid_plugin, 'must not load')
      Dir.mktmpdir('su-launch') do |dir|
        job_path, result_path = write_job(dir)
        backend = nil
        backend = FakeBackend.new([:running, :exited]) do
          binding = JSON.parse(File.read(result_path))
          next unless binding['status'] == 'STARTED'
          SketchupHostLauncher.atomic_write_json(result_path, {
            'status' => 'ERROR',
            'job_id' => binding['job_id'],
            'job_sha256' => binding['job_sha256'],
            'error' => 'fake host failure'
          })
        end

        result = SketchupHostLauncher.run(
          job_path,
          :sketchup_exe => 'C:/Program Files/SketchUp/SketchUp 2017/SketchUp.exe',
          :backend => backend,
          :clock => FakeClock.new([0.0, 0.1, 0.2]),
          :timeout_seconds => 10,
          :profile_parent => dir
        )

        assert_equal 'ERROR', result['status']
        assert_equal [], backend.killed
        environment = backend.spawned_environment
        %w[APPDATA LOCALAPPDATA PROGRAMDATA ALLUSERSPROFILE].each do |name|
          refute_nil environment[name]
          assert environment[name].tr('\\', '/').start_with?(dir.tr('\\', '/'))
          refute_equal File.dirname(paid_plugin), environment[name]
        end
        assert File.file?(paid_plugin), 'normal paid plugin must remain untouched'
        assert_equal '1', environment['BC_PDF_IMPORTER_BATCH_NONINTERACTIVE']
        assert_equal 1, backend.spawned_command.count { |arg| arg == '-RubyStartupArg' }
        assert_equal job_path, backend.spawned_command.last
        refute_includes backend.spawned_command, paid_plugin
      end
    end
  end

  def test_timeout_overwrites_started_with_bound_error_and_kills_only_spawned_pid
    Dir.mktmpdir('su-launch') do |dir|
      job_path, result_path = write_job(dir)
      backend = FakeBackend.new([:running, :running, :running])
      result = SketchupHostLauncher.run(
        job_path,
        :sketchup_exe => 'SketchUp.exe',
        :backend => backend,
        :clock => FakeClock.new([0.0, 2.0]),
        :timeout_seconds => 1,
        :profile_parent => dir
      )

      assert_equal 'ERROR', result['status']
      assert_match(/timeout/, result['error'])
      assert_equal [4242], backend.killed
      assert_equal result, JSON.parse(File.read(result_path))
    end
  end

  def test_exited_process_cannot_reuse_stale_or_wrong_job_result
    Dir.mktmpdir('su-launch') do |dir|
      job_path, result_path = write_job(dir)
      backend = FakeBackend.new([:exited]) do
        SketchupHostLauncher.atomic_write_json(result_path, {
          'status' => 'OK',
          'job_id' => 'stale-job',
          'job_sha256' => '0' * 64
        })
      end
      result = SketchupHostLauncher.run(
        job_path,
        :sketchup_exe => 'SketchUp.exe',
        :backend => backend,
        :clock => FakeClock.new([0.0, 0.1]),
        :timeout_seconds => 10,
        :profile_parent => dir
      )
      assert_equal 'ERROR', result['status']
      assert_match(/bound result/, result['error'])
    end
  end

  private

  def write_job(dir)
    pdf = File.join(dir, 'input.pdf')
    File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
    output = File.join(dir, 'out')
    FileUtils.mkdir_p(output)
    job_path = File.join(dir, 'job.json')
    File.write(job_path, JSON.generate(
      'pdf_path' => pdf,
      'output_dir' => output,
      'text_mode' => 'labels',
      'pages' => [1]
    ))
    [job_path, File.join(output, 'host_acceptance.json')]
  end
end
