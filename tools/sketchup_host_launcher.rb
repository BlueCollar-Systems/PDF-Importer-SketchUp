#!/usr/bin/env ruby
# External owner for one isolated SketchUp real-host acceptance process.

require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'
require 'securerandom'
require File.expand_path('sketchup_host_job', __dir__)
require File.expand_path('sketchup_host_evidence', __dir__)

module SketchupHostLauncher
  class LaunchError < StandardError; end

  class SystemClock
    def now
      Time.now.to_f
    end

    def sleep(seconds)
      Kernel.sleep(seconds)
    end
  end

  class ProcessBackend
    def spawn(environment, command)
      Process.spawn(environment, *command)
    end

    def poll(pid)
      waited = Process.waitpid(pid, Process::WNOHANG)
      waited ? :exited : :running
    rescue Errno::ECHILD
      :exited
    end

    def kill(pid)
      Process.kill('KILL', pid)
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        # Already reaped.
      end
      true
    rescue Errno::ESRCH, Errno::ECHILD
      true
    end
  end

  module_function

  def run(job_path, options = {})
    path = File.expand_path(job_path.to_s)
    raise LaunchError, 'one JSON job path is required' unless
      File.file?(path) && File.extname(path).downcase == '.json'
    job = SketchupHostJob.load(path)
    executable = options[:sketchup_exe].to_s.strip
    executable = ENV['SKETCHUP_EXE'].to_s.strip if executable.empty?
    raise LaunchError, 'SKETCHUP_EXE is required' if executable.empty?

    backend = options[:backend] || ProcessBackend.new
    clock = options[:clock] || SystemClock.new
    timeout = options[:timeout_seconds].to_f
    timeout = 900.0 unless timeout > 0.0
    parent = options[:profile_parent]
    parent = File.expand_path(parent.to_s) unless parent.to_s.empty?
    FileUtils.mkdir_p(parent) if parent && !File.directory?(parent)

    job_sha256 = Digest::SHA256.file(path).hexdigest
    job_id = "su-host-#{SecureRandom.hex(12)}"
    binding = {
      'job_id' => job_id,
      'job_sha256' => job_sha256
    }
    atomic_write_json(job[:result_path], binding.merge('status' => 'STARTED'))

    profile = Dir.mktmpdir('bc-su-clean-profile-', parent)
    environment = controlled_environment(profile, binding)
    runner = File.expand_path('sketchup_batch_import.rb', __dir__)
    command = [
      executable,
      '-RubyStartup', runner,
      '-RubyStartupArg', path
    ]
    pid = backend.spawn(environment, command)
    process_done = false
    started_at = clock.now

    loop do
      state = backend.poll(pid)
      if state == :exited
        process_done = true
        result = read_bound_final_result(job[:result_path], binding)
        unless result
          result = binding.merge(
            'status' => 'ERROR',
            'error' => 'SketchUp exited without an atomic bound result'
          )
          atomic_write_json(job[:result_path], result)
        end
        return result
      end

      if clock.now - started_at >= timeout
        backend.kill(pid)
        process_done = true
        result = binding.merge(
          'status' => 'ERROR',
          'error' => 'SketchUp host timeout while result remained STARTED or process did not exit'
        )
        atomic_write_json(job[:result_path], result)
        return result
      end
      clock.sleep(0.1)
    end
  rescue StandardError => error
    if defined?(pid) && pid && defined?(backend) && backend &&
       (!defined?(process_done) || !process_done)
      begin
        backend.kill(pid)
      rescue StandardError
        # The only permitted kill target is the exact child PID returned by
        # this launch; a child that already exited needs no further action.
      end
    end
    if defined?(job) && job && defined?(binding) && binding
      result = binding.merge(
        'status' => 'ERROR',
        'error' => "launcher failure: #{error.class}: #{error.message}"
      )
      atomic_write_json(job[:result_path], result)
      result
    else
      raise
    end
  ensure
    if defined?(profile) && profile && File.directory?(profile)
      begin
        FileUtils.remove_entry_secure(profile)
      rescue StandardError
        # The child is already exited/killed; a locked disposable profile may
        # be removed by the next maintenance sweep without touching user data.
      end
    end
  end

  def controlled_environment(profile, binding)
    roaming = File.join(profile, 'AppData', 'Roaming')
    local = File.join(profile, 'AppData', 'Local')
    program_data = File.join(profile, 'ProgramData')
    temporary = File.join(profile, 'Temp')
    [roaming, local, program_data, temporary].each do |path|
      FileUtils.mkdir_p(path)
    end
    # Create the only user plugin search root SketchUp 2017 may inspect. It is
    # deliberately empty; the acceptance runner loads the worktree explicitly.
    FileUtils.mkdir_p(File.join(
      roaming, 'SketchUp', 'SketchUp 2017', 'SketchUp', 'Plugins'
    ))
    {
      'APPDATA' => roaming,
      'LOCALAPPDATA' => local,
      'PROGRAMDATA' => program_data,
      'ALLUSERSPROFILE' => program_data,
      'TEMP' => temporary,
      'TMP' => temporary,
      'BC_PDF_IMPORTER_BATCH_NONINTERACTIVE' => '1',
      'BC_HOST_JOB_ID' => binding['job_id'],
      'BC_HOST_JOB_SHA256' => binding['job_sha256']
    }
  end

  def read_bound_final_result(path, binding)
    return nil unless File.file?(path)
    parsed = JSON.parse(File.read(path, :encoding => 'UTF-8'))
    return nil unless parsed.is_a?(Hash)
    return nil unless parsed['job_id'] == binding['job_id'] &&
                      parsed['job_sha256'] == binding['job_sha256']
    return nil unless ['OK', 'ERROR'].include?(parsed['status'])
    parsed
  rescue StandardError
    nil
  end

  def atomic_write_json(path, payload)
    SketchupHostEvidence.atomic_write_json(path, payload)
  end
end

if __FILE__ == $PROGRAM_NAME
  unless ARGV.length == 1
    warn 'ERROR: exactly one JSON job path is required'
    exit 2
  end
  result = SketchupHostLauncher.run(ARGV[0])
  puts JSON.pretty_generate(result)
  exit(result['status'] == 'OK' ? 0 : 1)
end
