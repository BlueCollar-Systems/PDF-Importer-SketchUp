#!/usr/bin/env ruby

# RED: the SketchUp 2017 launcher changes the 2017 plugin preference and is the
# Ruby-2.2 acceptance host, so a different major host must not certify a run.
require_relative 'sketchup_host_launcher_test'

class SketchupHostLauncherTest < Minitest::Test
  def test_red_su2017_launcher_rejects_a_different_host_major
    Dir.mktmpdir('su-launch-major') do |dir|
      job_path, result_path, _pdf = write_job(dir)
      guard = FakePluginStateGuard.new
      backend = FakeBackend.new([
        { :state => :exited, :exit_code => 0 }
      ]) do |process|
        write_complete_result(process, result_path)
        result = JSON.parse(File.read(result_path))
        report_path = result['import_report_path']
        report = JSON.parse(File.read(report_path))
        report['host']['version'] = '24.0.594'
        File.write(report_path, JSON.generate(report))
        result['host_version'] = '24.0.594'
        result['import_report_sha256'] =
          Digest::SHA256.file(report_path).hexdigest
        File.write(result_path, JSON.generate(result))
      end

      result = run_launcher(job_path, backend, guard)

      assert_equal 'ERROR', result['status']
      assert_match(/host.*version|SketchUp 2017/i, result['error'].to_s)
    end
  end


  def test_red_su2017_launcher_requires_exact_ruby22_gate_identity
    Dir.mktmpdir('su-launch-ruby-gate') do |dir|
      job_path, result_path, _pdf = write_job(dir)
      guard = FakePluginStateGuard.new
      backend = FakeBackend.new([
        { :state => :exited, :exit_code => 0 }
      ]) do |process|
        write_complete_result(process, result_path)
        result = JSON.parse(File.read(result_path))
        result['ruby_gate_identity'] = {
          'engine' => 'ruby', 'version' => '3.4.4', 'patchlevel' => 0,
          'target' => 'sketchup-2017-ruby-2.2.4-p230', 'verified' => true
        }
        File.write(result_path, JSON.generate(result))
      end

      result = run_launcher(job_path, backend, guard)

      assert_equal 'ERROR', result['status']
      assert_match(/Ruby 2\.2|ruby.*gate|2\.2\.4/i, result['error'].to_s)
    end
  end
end
