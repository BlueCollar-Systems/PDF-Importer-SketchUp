#!/usr/bin/env ruby
# External owner for one fail-closed SketchUp real-host acceptance process.

require 'json'
require 'digest'
require 'fileutils'
require 'securerandom'
require 'rbconfig'
require File.expand_path('sketchup_host_job', __dir__)
require File.expand_path('sketchup_host_evidence', __dir__)

module SketchupHostLauncher
  class LaunchError < StandardError; end
  DEFAULT_TIMEOUT_SECONDS = 3600.0

  # SketchUp's documented Sketchup.plugins_disabled= preference is persisted
  # here for the next process start. The launcher changes only this value and
  # restores its exact prior existence, registry type, and decoded raw value.
  class RegistryPreferenceBackend
    KEY_PATH = 'Software\\SketchUp\\SketchUp 2017\\PREFS'.freeze
    VALUE_NAME = 'RubyManager_DisablePlugins'.freeze

    def initialize
      require 'win32/registry'
      @root = Win32::Registry::HKEY_CURRENT_USER
    end

    def dword_type
      Win32::Registry::REG_DWORD
    end

    def capture
      state = nil
      @root.open(KEY_PATH, Win32::Registry::KEY_READ) do |registry|
        type, data = registry.read(VALUE_NAME)
        state = {
          'value_exists' => true,
          'type' => type,
          'data' => data
        }
      end
      state
    rescue Win32::Registry::Error => error
      return { 'value_exists' => false } if registry_not_found?(error)
      raise
    end

    def write(type, data)
      @root.create(KEY_PATH, Win32::Registry::KEY_ALL_ACCESS) do |registry|
        registry.write(VALUE_NAME, type, data)
      end
      true
    end

    def delete
      @root.open(KEY_PATH, Win32::Registry::KEY_ALL_ACCESS) do |registry|
        registry.delete_value(VALUE_NAME)
      end
      true
    rescue Win32::Registry::Error => error
      return true if registry_not_found?(error)
      raise
    end

    private

    def registry_not_found?(error)
      error.respond_to?(:code) && error.code.to_i == 2
    end
  end

  class PluginStateGuard
    def initialize(backend = nil, dword_type = nil)
      @backend = backend || RegistryPreferenceBackend.new
      @dword_type = dword_type || @backend.dword_type
      @prior = nil
    end

    def suppress!
      raise LaunchError, 'plugin suppression guard is already active' if @prior
      @prior = @backend.capture
      begin
        @backend.write(@dword_type, 1)
        observed = @backend.capture
        unless observed['value_exists'] == true &&
               observed['type'] == @dword_type && observed['data'].to_i == 1
          raise LaunchError,
                'SketchUp plugin suppression could not be proven by readback'
        end
      rescue StandardError
        restore_prior!
        raise
      end
      true
    end

    def restore!
      raise LaunchError, 'plugin suppression guard has no captured state' unless
        @prior
      restore_prior!
      true
    end

    private

    def restore_prior!
      prior = @prior
      if prior['value_exists']
        @backend.write(prior['type'], prior['data'])
      else
        @backend.delete
      end
      observed = @backend.capture
      unless observed == prior
        raise LaunchError,
              'SketchUp plugin-disabled preference exact restoration failed'
      end
      @prior = nil
      true
    end
  end

  class SystemClock
    def now
      Time.now.to_f
    end

    def sleep(seconds)
      Kernel.sleep(seconds)
    end
  end

  class ProcessBackend
    def initialize(options = {})
      @command_runner = options[:command_runner] || SystemCommandRunner.new
      @windows = if options.key?(:windows)
                   options[:windows] == true
                 else
                   RbConfig::CONFIG['host_os'].to_s =~ /mswin|mingw|cygwin/i
                 end
    end

    def spawn(environment, command)
      Process.spawn(environment, *command)
    end

    def poll(pid)
      waited, status = Process.waitpid2(pid, Process::WNOHANG)
      return { :state => :running } unless waited
      {
        :state => :exited,
        :exit_code => status.exitstatus,
        :term_signal => status.signaled? ? status.termsig : nil
      }
    rescue Errno::ECHILD
      { :state => :exited, :exit_code => nil, :wait_error => 'ECHILD' }
    end

    def kill(pid)
      process_id = Integer(pid)
      raise LaunchError, 'process ID must be positive' unless process_id > 0
      if @windows
        command = ['taskkill.exe', '/PID', process_id.to_s, '/T', '/F']
        unless @command_runner.run(command)
          raise LaunchError,
                "failed to terminate SketchUp process tree #{process_id}"
        end
      else
        Process.kill('KILL', process_id)
      end
      begin
        Process.waitpid(process_id)
      rescue Errno::ECHILD
        # Already reaped.
      end
      true
    rescue Errno::ESRCH, Errno::ECHILD
      true
    end
  end

  class SystemCommandRunner
    def run(command)
      system(
        *Array(command),
        :out => File::NULL, :err => File::NULL
      ) == true
    rescue StandardError
      false
    end
  end

  # SketchUp Make 2017 always presents its Welcome window, even when a model
  # path and -RubyStartup are supplied. The Ruby startup callback pauses at
  # Sketchup.active_model until that window is advanced. Post Enter directly to
  # the exact spawned PID's exact legacy-title window; never activate a window,
  # synthesize global keyboard input, or target a model/unrelated process.
  class WelcomeWindowAdvancer
    def initialize(options = {})
      @runner = options[:runner] || SystemCommandRunner.new
      @retry_seconds = options[:retry_seconds].to_f
      @retry_seconds = 0.5 unless @retry_seconds > 0.0
      @last_attempt = {}
      @advanced = {}
    end

    def advance(pid, now = Time.now.to_f)
      process_id = Integer(pid)
      return false unless process_id > 0
      return true if @advanced[process_id]
      last = @last_attempt[process_id]
      return false if last && (now.to_f - last) < @retry_seconds
      @last_attempt[process_id] = now.to_f
      if @runner.run(command(process_id))
        @advanced[process_id] = true
        return true
      end
      false
    rescue StandardError
      false
    end

    private

    def command(process_id)
      system_root = ENV['SystemRoot'].to_s.strip
      executable = if system_root.empty?
                     'powershell.exe'
                   else
                     File.join(
                       system_root, 'System32', 'WindowsPowerShell',
                       'v1.0', 'powershell.exe'
                     )
                   end
      loop_body = [
        "$p=Get-Process -Id #{process_id} -ErrorAction SilentlyContinue",
        'if($null -eq $p){exit 4}',
        '$title=$p.MainWindowTitle',
        "if($title -ceq 'Welcome to SketchUp'){" \
          '$sawWelcome=$true; $handle=$p.MainWindowHandle; ' \
          'if($handle -ne [IntPtr]::Zero){' \
          '$down=[BcPdf.NativeMethods]::PostMessage($handle,0x0100,[IntPtr]0x0D,[IntPtr]::Zero); ' \
          '$up=[BcPdf.NativeMethods]::PostMessage($handle,0x0101,[IntPtr]0x0D,[IntPtr]::Zero); ' \
          'if(-not ($down -and $up)){exit 5}}}',
        "if($sawWelcome -and $p.MainWindowTitle -cne 'Welcome to SketchUp'){exit 0}",
        "if(-not $sawWelcome -and -not [String]::IsNullOrEmpty($title) -and " \
          "$title -cne 'Welcome to SketchUp'){exit 0}",
        'Start-Sleep -Milliseconds 250'
      ].join('; ')
      script = [
        "Add-Type -MemberDefinition '[System.Runtime.InteropServices.DllImport(\"user32.dll\")] public static extern bool PostMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);' -Name NativeMethods -Namespace BcPdf",
        '$deadline=[DateTime]::UtcNow.AddSeconds(45)',
        '$sawWelcome=$false',
        "while([DateTime]::UtcNow -lt $deadline){#{loop_body}}",
        'exit 3'
      ].join('; ')
      [
        executable, '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-Command', script
      ]
    end
  end

  module_function

  def effective_requested_mode(job)
    return 'raster' if job[:import_mode].to_s == 'raster'
    job[:text_mode].to_s
  end

  def run(job_path, options = {})
    path = File.expand_path(job_path.to_s)
    raise LaunchError, 'one JSON job path is required' unless
      File.file?(path) && File.extname(path).downcase == '.json'
    original_job = SketchupHostJob.load(path)
    executable = options[:sketchup_exe].to_s.strip
    executable = ENV['SKETCHUP_EXE'].to_s.strip if executable.empty?
    raise LaunchError, 'SKETCHUP_EXE is required' if executable.empty?
    source_root = options[:source_root].to_s.strip
    source_root = ENV['BC_SKETCHUP_IMPORTER_SOURCE_ROOT'].to_s.strip if
      source_root.empty?
    source_root = SketchupHostEvidence::IMPORTER_SOURCE_ROOT if
      source_root.empty?
    source_root = File.expand_path(source_root)
    source_tree_sha256 = SketchupHostEvidence.source_tree_sha256(source_root)
    recorded_source_tree = original_job[:source_tree_sha256]
    if recorded_source_tree && recorded_source_tree != source_tree_sha256
      raise LaunchError,
            'job source tree SHA256 does not match the selected importer source'
    end
    original_job = original_job.merge(
      :source_tree_sha256 => source_tree_sha256
    )

    backend = options[:backend] || ProcessBackend.new
    clock = options[:clock] || SystemClock.new
    timeout = options[:timeout_seconds].to_f
    if timeout <= 0.0
      configured = ENV['BC_SKETCHUP_HOST_TIMEOUT_SECONDS'].to_f
      timeout = configured > 0.0 ? configured : DEFAULT_TIMEOUT_SECONDS
    end
    guard = options[:plugin_state_guard] || PluginStateGuard.new
    welcome_advancer = if options.key?(:welcome_advancer)
                         options[:welcome_advancer]
                       elsif backend.is_a?(ProcessBackend)
                         WelcomeWindowAdvancer.new
                       end

    job_id = "su-host-#{SecureRandom.hex(12)}"
    snapshot = prepare_controlled_job!(path, original_job, job_id)
    controlled_path = snapshot['job_path']
    job = SketchupHostJob.load(controlled_path)
    binding = {
      'job_id' => job_id,
      'job_sha256' => Digest::SHA256.file(controlled_path).hexdigest
    }
    atomic_write_json(job[:result_path], binding.merge('status' => 'STARTED'))

    result = nil
    process_done = false
    guard_active = false
    begin
      guard.suppress!
      guard_active = true
      verify_source_unchanged_before_spawn!(snapshot)
      environment = controlled_environment(binding, source_root)
      runner = File.expand_path('sketchup_batch_import.rb', __dir__)
      command = [
        executable,
        '-RubyStartup', runner,
        '-RubyStartupArg', controlled_path
      ]
      pid = backend.spawn(environment, command)
      started_at = clock.now

      loop do
        state = backend.poll(pid)
        unless state.is_a?(Hash) && [:running, :exited].include?(state[:state])
          raise LaunchError, 'process backend returned an invalid state'
        end
        if state[:state] == :exited
          process_done = true
          candidate = read_bound_final_result(job[:result_path], binding)
          abnormal_exit = state[:term_signal] ||
            (!state[:exit_code].nil? && state[:exit_code] != 0)
          if abnormal_exit
            detail = state[:term_signal] ?
              "signal #{state[:term_signal]}" :
              "exit code #{state[:exit_code].inspect}"
            result = error_result(
              binding,
              "SketchUp exited with #{detail}"
            )
          elsif candidate.nil?
            result = error_result(
              binding, 'SketchUp exited without an atomic bound result'
            )
          elsif candidate['status'] == 'ERROR'
            result = candidate
          else
            begin
              if job[:skp_export_only]
                verify_skp_export_result!(candidate, job, binding)
              else
                verify_terminal_result!(candidate, job, binding)
              end
              result = candidate
            rescue StandardError => evidence_error
              result = error_result(
                binding,
                "terminal evidence incomplete: #{evidence_error.message}"
              )
            end
          end
          break
        end

        welcome_advancer.advance(pid, clock.now) if
          welcome_advancer && welcome_advancer.respond_to?(:advance)

        if clock.now - started_at >= timeout
          backend.kill(pid)
          process_done = true
          progress = read_bound_progress(job[:progress_path], binding)
          phase = progress && progress['phase'].to_s
          phase_detail = phase && !phase.empty? ? " during phase #{phase}" : ''
          result = error_result(
            binding,
            'SketchUp host timeout' + phase_detail +
              ' while result remained STARTED or process did not exit'
          )
          break
        end
        clock.sleep(0.1)
      end
    rescue StandardError => error
      if defined?(pid) && pid && !process_done
        begin
          backend.kill(pid)
        rescue StandardError
          # The exact spawned child may already have exited.
        end
      end
      result = error_result(
        binding, "launcher failure: #{error.class}: #{error.message}"
      )
    ensure
      if guard_active
        begin
          guard.restore!
        rescue StandardError => restore_error
          result = error_result(
            binding,
            "plugin preference restoration failure: " \
            "#{restore_error.class}: #{restore_error.message}"
          )
        end
      end
      atomic_write_json(job[:result_path], result) if result
    end
    result
  rescue StandardError => error
    if defined?(job) && job && defined?(binding) && binding
      result = error_result(
        binding, "launcher failure: #{error.class}: #{error.message}"
      )
      atomic_write_json(job[:result_path], result)
      result
    else
      raise
    end
  end

  def prepare_controlled_job!(original_job_path, original_job, job_id)
    source = File.expand_path(original_job[:pdf_path].to_s)
    bytes = File.binread(source)
    source_sha256 = Digest::SHA256.hexdigest(bytes)
    run_dir = File.join(original_job[:output_dir], '.bc_host_jobs', job_id)
    FileUtils.mkdir_p(run_dir)
    immutable_path = File.join(run_dir, File.basename(source))
    SketchupHostEvidence.atomic_write(immutable_path, bytes)
    unless File.binread(immutable_path) == bytes
      raise LaunchError, 'immutable PDF snapshot differs from original bytes'
    end
    begin
      File.chmod(0444, immutable_path)
    rescue StandardError
      # Hash verification before acceptance remains authoritative on Windows.
    end
    unless File.binread(source) == bytes
      raise LaunchError, 'original PDF changed while immutable snapshot was created'
    end

    payload = {
      'pdf_path' => immutable_path,
      'output_dir' => original_job[:output_dir],
      'text_mode' => original_job[:text_mode].to_s,
      'import_mode' => original_job[:import_mode],
      'pages' => original_job[:pages] == :all ? 'all' : original_job[:pages],
      'skp_export_only' => original_job[:skp_export_only] == true,
      'original_job_path' => File.expand_path(original_job_path),
      'original_job_sha256' => Digest::SHA256.file(original_job_path).hexdigest,
      'original_pdf_path' => source,
      'original_pdf_sha256' => source_sha256,
      'immutable_pdf_path' => immutable_path,
      'immutable_pdf_sha256' => source_sha256,
      'source_tree_sha256' => original_job[:source_tree_sha256]
    }
    controlled_path = File.join(run_dir, 'job.json')
    atomic_write_json(controlled_path, payload)
    payload.merge(
      'job_path' => controlled_path,
      'source_bytes' => bytes
    )
  end

  def verify_source_unchanged_before_spawn!(snapshot)
    source = snapshot['original_pdf_path']
    unless File.binread(source) == snapshot['source_bytes']
      raise LaunchError, 'original PDF changed before the host launch boundary'
    end
    immutable = snapshot['immutable_pdf_path']
    unless Digest::SHA256.file(immutable).hexdigest ==
           snapshot['immutable_pdf_sha256']
      raise LaunchError, 'immutable PDF snapshot changed before host launch'
    end
    true
  end

  def controlled_environment(binding, source_root = nil)
    environment = {
      'BC_PDF_IMPORTER_BATCH_NONINTERACTIVE' => '1',
      'BC_HOST_JOB_ID' => binding['job_id'],
      'BC_HOST_JOB_SHA256' => binding['job_sha256']
    }
    configured = source_root.to_s.strip
    unless configured.empty?
      environment['BC_SKETCHUP_IMPORTER_SOURCE_ROOT'] =
        File.expand_path(configured)
    end
    environment
  end

  def verify_skp_export_result!(result, job, binding)
    require_equal!(result['job_id'], binding['job_id'], 'result job ID')
    require_equal!(result['job_sha256'], binding['job_sha256'], 'result job SHA256')
    require_equal!(result['status'], 'OK', 'result status')
    require_equal!(result['skp_export_only'], true, 'SKP export-only marker')
    require_equal!(result['requested_text_mode'], effective_requested_mode(job),
                   'requested representation mode')
    verify_source_tree_binding!(result, job)
    require_path_equal!(result['model_path'], job[:model_path],
                        'saved model path')
    model_path = verified_artifact!(result['model_path'], nil, 'saved model')
    require_sha256!(result['model_sha256'], 'saved model SHA256')
    require_equal!(Digest::SHA256.file(model_path).hexdigest,
                   result['model_sha256'], 'saved model SHA256')
    require_path_equal!(result['import_report_path'],
                        File.join(job[:output_dir], 'import_report.json'),
                        'import report path')
    report_path = verified_artifact!(
      result['import_report_path'], result['import_report_sha256'],
      'import report'
    )
    report = JSON.parse(File.read(report_path, :encoding => 'UTF-8'))
    verify_source_tree_report_binding!(report, job)
    true
  end

  def verify_terminal_result!(result, job, binding)
    require_equal!(result['job_id'], binding['job_id'], 'result job ID')
    require_equal!(result['job_sha256'], binding['job_sha256'], 'result job SHA256')
    require_equal!(result['status'], 'OK', 'result status')
    require_equal!(result['plugins_disabled_verified'], true,
                   'in-host plugin-disabled API proof')
    require_equal!(result['source_root_verified'], true, 'source-root proof')
    SketchupHostEvidence.verify_source_locations!(
      result['source_root'], result['source_locations']
    )
    require_equal!(result['requested_text_mode'], effective_requested_mode(job),
                   'requested representation mode')
    verify_source_tree_binding!(result, job)
    require_equal!(result['worktree_metadata_version'],
                   result['loaded_importer_version'], 'loaded importer version')
    require_su2017_host_identity!(result)
    require_nonempty!(result['report_schema'], 'report schema')

    immutable_sha256 = Digest::SHA256.file(job[:immutable_pdf_path]).hexdigest
    require_equal!(immutable_sha256, job[:immutable_pdf_sha256],
                   'immutable job PDF SHA256')
    require_path_equal!(result['source_pdf_path'], job[:immutable_pdf_path],
                        'result source PDF')
    require_equal!(result['source_pdf_sha256'], immutable_sha256,
                   'result source PDF SHA256')
    require_path_equal!(result['original_pdf_path'], job[:original_pdf_path],
                        'original PDF lineage')
    require_equal!(result['original_pdf_sha256'], job[:original_pdf_sha256],
                   'original PDF lineage SHA256')
    require_path_equal!(result['immutable_pdf_path'], job[:immutable_pdf_path],
                        'immutable PDF lineage')
    require_equal!(result['immutable_pdf_sha256'], immutable_sha256,
                   'immutable PDF lineage SHA256')
    require_nonempty!(result['normalized_pdf_path'], 'normalized PDF lineage')
    require_sha256!(result['normalized_pdf_sha256'],
                    'normalized PDF lineage SHA256')
    unless result['salvage_note'].nil? || result['salvage_note'].is_a?(String)
      raise LaunchError, 'salvage lineage note is invalid'
    end
    if same_expanded_path?(
      result['normalized_pdf_path'], job[:immutable_pdf_path]
    )
      require_equal!(result['normalized_pdf_sha256'], immutable_sha256,
                     'unsalvaged normalized PDF SHA256')
    elsif result['salvage_note'].to_s.strip.empty?
      raise LaunchError,
            'normalized PDF differs from immutable input without salvage proof'
    end

    session_id = result['import_session_id'].to_s.strip
    raise LaunchError, 'import session is missing' if session_id.empty?
    ['representation_fidelity', 'import_contract_ready'].each do |gate|
      value = result[gate]
      unless value.is_a?(Hash) && value['ready'] == true
        raise LaunchError, "#{gate} is incomplete"
      end
    end

    require_path_equal!(result['model_path'], job[:model_path],
                        'saved model path')
    require_path_equal!(result['import_report_path'],
                        File.join(job[:output_dir], 'import_report.json'),
                        'import report path')
    require_path_equal!(result['entity_manifest_path'],
                        File.join(job[:output_dir], 'entity_manifest.json'),
                        'entity manifest path')
    model_path = verified_artifact!(result['model_path'], nil, 'saved model')
    require_sha256!(result['model_sha256'], 'saved model SHA256')
    require_equal!(Digest::SHA256.file(model_path).hexdigest,
                   result['model_sha256'], 'saved model SHA256')
    report_path = verified_artifact!(
      result['import_report_path'], result['import_report_sha256'],
      'import report'
    )
    manifest_path = verified_artifact!(
      result['entity_manifest_path'], result['entity_manifest_sha256'],
      'entity manifest'
    )
    report = JSON.parse(File.read(report_path, :encoding => 'UTF-8'))
    verify_terminal_report!(report, result, job, immutable_sha256, session_id)
    manifest = JSON.parse(File.read(manifest_path, :encoding => 'UTF-8'))
    verify_terminal_manifest!(manifest, result, job, binding, immutable_sha256,
                              session_id)
    true
  end

  def verify_source_tree_binding!(result, job)
    expected = job[:source_tree_sha256]
    return true if expected.nil?
    require_sha256!(expected, 'job source tree SHA256')
    require_equal!(result['source_tree_sha256_before_load'], expected,
                   'source tree SHA256 before load')
    require_equal!(result['source_tree_sha256_after_import'], expected,
                   'source tree SHA256 after import')
    true
  end

  def verify_terminal_report!(report, result, job, immutable_sha256, session_id)
    require_equal!(report['schema'], result['report_schema'], 'report schema')
    require_equal!(report_value(report, 'host', 'app'), 'sketchup',
                   'report host app')
    require_equal!(report_value(report, 'host', 'version'),
                   result['host_version'], 'report host version')
    require_equal!(report_value(report, 'importer', 'version'),
                   result['loaded_importer_version'], 'report importer version')
    require_equal!(report_value(report, 'report_meta', 'semver'),
                   result['loaded_importer_version'], 'report metadata version')
    require_path_equal!(report_value(report, 'input', 'file'),
                        job[:immutable_pdf_path], 'report source PDF')
    require_equal!(report_value(report, 'input', 'sha256'), immutable_sha256,
                   'report source SHA256')
    require_equal!(report_value(report, 'extra', 'requested_text_mode'),
                   effective_requested_mode(job), 'report requested mode')
    require_equal!(report_value(report, 'extra', 'import_session_id'),
                   session_id, 'report import session')
    require_equal!(report_value(report, 'extra', 'representation_fidelity', 'ready'),
                   true, 'report representation readiness')
    require_equal!(report_value(report, 'extra', 'import_contract_ready', 'ready'),
                   true, 'report import-contract readiness')
    lineage = report_value(report, 'extra', 'source_lineage')
    expected = terminal_lineage(result)
    require_equal!(lineage, expected, 'report source lineage')
    verify_source_tree_report_binding!(report, job)
    provenance = report_value(report, 'extra', 'source_provenance')
    unless provenance.is_a?(Hash) && provenance['objects'].is_a?(Array)
      raise LaunchError, 'report full source provenance is missing'
    end
    require_equal!(provenance['import_session_id'], session_id,
                   'report provenance session')
    result_provenance = result['source_provenance']
    unless result_provenance.is_a?(Hash) &&
           result_provenance['objects'].is_a?(Array)
      raise LaunchError, 'result full source provenance is missing'
    end
    require_equal!(provenance['objects'], result_provenance['objects'],
                   'report/result source provenance')
    true
  end

  def require_su2017_host_identity!(result)
    host_version = result['host_version'].to_s.strip
    unless host_version =~ /\A17(?:\.|\z)/
      raise LaunchError,
            "guarded host must be SketchUp 2017 (major 17), got #{host_version.inspect}"
    end
    identity = result['ruby_gate_identity']
    unless identity.is_a?(Hash) &&
           identity['engine'].to_s == 'ruby' &&
           identity['version'].to_s == '2.2.4' &&
           identity['patchlevel'].is_a?(Integer) &&
           identity['patchlevel'] == 230 &&
           identity['target'].to_s == 'sketchup-2017-ruby-2.2.4-p230' &&
           identity['verified'] == true
      raise LaunchError,
            'guarded host Ruby identity is not exact ruby 2.2.4-p230'
    end
    true
  end

  def verify_terminal_manifest!(manifest, result, job, binding,
                                immutable_sha256, session_id)
    require_equal!(manifest['job_id'], binding['job_id'], 'manifest job ID')
    require_equal!(manifest['job_sha256'], binding['job_sha256'],
                   'manifest job SHA256')
    require_equal!(manifest['requested_text_mode'], effective_requested_mode(job),
                   'manifest requested mode')
    require_path_equal!(manifest['source_pdf_path'], job[:immutable_pdf_path],
                        'manifest source PDF')
    require_equal!(manifest['source_pdf_sha256'], immutable_sha256,
                   'manifest source SHA256')
    require_equal!(manifest['import_session_id'], session_id,
                   'manifest import session')
    require_equal!(manifest['reopen_persistent_id_verified'], true,
                   'manifest reopen proof')
    require_equal!(result['reopen_persistent_id_verified'], true,
                   'result reopen proof')
    require_equal!(result['host_heal_preservation_verified'], true,
                   'result host-heal preservation proof')
    require_equal!(manifest['source_lineage'], terminal_lineage(result),
                   'manifest source lineage')
    verify_source_tree_manifest_binding!(manifest, job)
    owned = manifest['same_session_entities']
    stabilized_owned = manifest['stabilized_owned_entities']
    post_import = manifest['post_import_entities']
    reopened = manifest['reopened_entities']
    if !owned.is_a?(Array) || owned.empty? ||
       !stabilized_owned.is_a?(Array) || stabilized_owned.empty? ||
       !post_import.is_a?(Array) || post_import.empty? ||
       !reopened.is_a?(Array)
      raise LaunchError, 'manifest entity evidence is missing'
    end
    require_equal!(manifest['host_heal_preservation_verified'], true,
                   'manifest host-heal preservation proof')
    SketchupHostEvidence.verify_host_heal_preservation!(
      owned, stabilized_owned
    )
    SketchupHostEvidence.verify_reopen_continuity!(post_import, reopened)

    evidence = result.dup
    provenance = result['source_provenance']
    unless provenance.is_a?(Hash) && provenance['objects'].is_a?(Array)
      raise LaunchError, 'result full source provenance is missing'
    end
    evidence['source_provenance_objects'] = provenance['objects']
    SketchupHostEvidence.verify_delivery_evidence!(
      evidence, owned, effective_requested_mode(job), job[:pages]
    )
    true
  end

  def verify_source_tree_report_binding!(report, job)
    expected = job[:source_tree_sha256]
    return true if expected.nil?
    require_equal!(report_value(
      report, 'extra', 'source_tree_sha256_before_load'
    ), expected, 'report source tree SHA256 before load')
    require_equal!(report_value(
      report, 'extra', 'source_tree_sha256_after_import'
    ), expected, 'report source tree SHA256 after import')
    true
  end

  def verify_source_tree_manifest_binding!(manifest, job)
    expected = job[:source_tree_sha256]
    return true if expected.nil?
    require_equal!(manifest['source_tree_sha256_before_load'], expected,
                   'manifest source tree SHA256 before load')
    require_equal!(manifest['source_tree_sha256_after_import'], expected,
                   'manifest source tree SHA256 after import')
    true
  end

  def terminal_lineage(result)
    {
      'original_pdf_path' => result['original_pdf_path'],
      'original_pdf_sha256' => result['original_pdf_sha256'],
      'immutable_pdf_path' => result['immutable_pdf_path'],
      'immutable_pdf_sha256' => result['immutable_pdf_sha256'],
      'normalized_pdf_path' => result['normalized_pdf_path'],
      'normalized_pdf_sha256' => result['normalized_pdf_sha256'],
      'salvage_note' => result['salvage_note']
    }
  end

  def verified_artifact!(path, expected_sha256, label)
    expanded = File.expand_path(path.to_s)
    unless File.file?(expanded) && File.size(expanded).to_i > 0
      raise LaunchError, "#{label} is missing or empty"
    end
    if expected_sha256
      require_sha256!(expected_sha256, "#{label} SHA256")
      require_equal!(Digest::SHA256.file(expanded).hexdigest, expected_sha256,
                     "#{label} SHA256")
    end
    expanded
  end

  def report_value(hash, *keys)
    keys.inject(hash) do |value, key|
      value.is_a?(Hash) ? value[key] : nil
    end
  end

  def require_nonempty!(value, label)
    raise LaunchError, "#{label} is missing" if value.to_s.strip.empty?
    true
  end

  def require_sha256!(value, label)
    unless value.to_s =~ /\A[0-9a-f]{64}\z/
      raise LaunchError, "#{label} is invalid"
    end
    true
  end

  def require_equal!(actual, expected, label)
    raise LaunchError, "#{label} mismatch" unless actual == expected
    true
  end

  def require_path_equal!(actual, expected, label)
    raise LaunchError, "#{label} mismatch" unless
      same_expanded_path?(actual, expected)
    true
  end

  def same_expanded_path?(left, right)
    File.expand_path(left.to_s).tr('\\', '/').downcase ==
      File.expand_path(right.to_s).tr('\\', '/').downcase
  end

  def error_result(binding, message)
    binding.merge('status' => 'ERROR', 'error' => message.to_s)
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

  def read_bound_progress(path, binding)
    return nil unless File.file?(path)
    parsed = JSON.parse(File.read(path, :encoding => 'UTF-8'))
    return nil unless parsed.is_a?(Hash)
    return nil unless parsed['job_id'] == binding['job_id'] &&
                      parsed['job_sha256'] == binding['job_sha256']
    return nil if parsed['phase'].to_s.strip.empty?
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
