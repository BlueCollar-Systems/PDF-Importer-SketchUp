#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'rbconfig'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)

class SketchupHostLauncherTest < Minitest::Test
  class FakeBackend
    attr_reader :spawned_environment, :spawned_command, :killed

    def initialize(states, options = {}, &tick)
      @states = states.dup
      @tick = tick
      @on_spawn = options[:on_spawn]
      @killed = []
    end

    def spawn(environment, command)
      @spawned_environment = environment
      @spawned_command = command
      @on_spawn.call(environment, command) if @on_spawn
      4242
    end

    def poll(_pid)
      @tick.call(self) if @tick
      @states.shift || { :state => :running }
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

  class FakePluginStateGuard
    attr_reader :calls

    def initialize(options = {})
      @options = options
      @calls = []
    end

    def suppress!
      @calls << :suppress
      raise 'suppression readback failed' if @options[:suppress_error]
      true
    end

    def restore!
      @calls << :restore
      raise 'exact restoration failed' if @options[:restore_error]
      true
    end
  end

  class FakePreferenceBackend
    attr_reader :state

    def initialize(state)
      @state = state.dup
    end

    def capture
      @state.dup
    end

    def write(type, data)
      @state = {
        'value_exists' => true,
        'type' => type,
        'data' => data
      }
    end

    def delete
      @state = { 'value_exists' => false }
    end
  end

  class FakeCommandRunner
    attr_reader :commands

    def initialize(results)
      @results = results.dup
      @commands = []
    end

    def run(command)
      @commands << command
      @results.shift == true
    end
  end

  def setup
    Object.send(:remove_const, :SketchupHostLauncher) if
      defined?(SketchupHostLauncher)
    load File.join(REPO_ROOT, 'tools', 'sketchup_host_launcher.rb')
  end

  def test_raster_strategy_owns_the_effective_requested_representation
    assert_equal 'raster', SketchupHostLauncher.effective_requested_mode(
      :import_mode => 'raster', :text_mode => 'text3d'
    )
    assert_equal 'text3d', SketchupHostLauncher.effective_requested_mode(
      :import_mode => 'hybrid', :text_mode => 'text3d'
    )
  end

  def test_plugin_guard_restores_exact_prior_type_and_raw_value
    prior = {
      'value_exists' => true,
      'type' => 4,
      'data' => 0
    }
    backend = FakePreferenceBackend.new(prior)
    guard = SketchupHostLauncher::PluginStateGuard.new(backend, 4)

    assert guard.suppress!
    assert_equal true, backend.state['value_exists']
    assert_equal 4, backend.state['type']
    assert_equal 1, backend.state['data']
    assert guard.restore!
    assert_equal prior, backend.state
  end

  def test_launcher_preserves_real_profile_and_restores_plugin_preference
    Dir.mktmpdir('normal-su-profile') do |normal|
      paid_plugin = File.join(normal, 'PDFImport.rb')
      File.write(paid_plugin, 'must not load')
      Dir.mktmpdir('su-launch') do |dir|
        job_path, result_path, _pdf = write_job(dir)
        guard = FakePluginStateGuard.new
        backend = FakeBackend.new([
          { :state => :running },
          { :state => :exited, :exit_code => 0 }
        ]) do |_process|
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
          :plugin_state_guard => guard
        )

        assert_equal 'ERROR', result['status']
        assert_equal [:suppress, :restore], guard.calls
        assert_equal [], backend.killed
        environment = backend.spawned_environment
        %w[APPDATA LOCALAPPDATA PROGRAMDATA ALLUSERSPROFILE].each do |name|
          refute environment.key?(name), "must preserve real #{name}"
        end
        assert File.file?(paid_plugin), 'normal paid plugin must remain untouched'
        assert_equal '1', environment['BC_PDF_IMPORTER_BATCH_NONINTERACTIVE']
        assert_equal File.join(REPO_ROOT, 'extracted', 'sketchup_ext'),
                     environment['BC_SKETCHUP_IMPORTER_SOURCE_ROOT']
        assert_equal 1, backend.spawned_command.count { |arg| arg == '-RubyStartupArg' }
        refute_equal job_path, backend.spawned_command.last
        refute_includes backend.spawned_command, paid_plugin
      end
    end
  end

  def test_launcher_forwards_explicit_importer_source_root
    environment = SketchupHostLauncher.send(
      :controlled_environment,
      { 'job_id' => 'job-123', 'job_sha256' => 'a' * 64 },
      'C:/installed/SketchUp/Plugins'
    )

    assert_equal(
      File.expand_path('C:/installed/SketchUp/Plugins'),
      environment['BC_SKETCHUP_IMPORTER_SOURCE_ROOT']
    )
  end

  def test_timeout_restores_preference_writes_error_and_kills_process_tree
    Dir.mktmpdir('su-launch') do |dir|
      job_path, result_path, _pdf = write_job(dir)
      guard = FakePluginStateGuard.new
      progress_path = File.join(File.dirname(result_path), 'host_progress.json')
      backend = FakeBackend.new(
        [{ :state => :running }, { :state => :running }],
        :on_spawn => lambda do |environment, _command|
          File.write(progress_path, JSON.generate(
            'job_id' => environment['BC_HOST_JOB_ID'],
            'job_sha256' => environment['BC_HOST_JOB_SHA256'],
            'status' => 'RUNNING', 'phase' => 'model_save_started'
          ))
        end
      )
      result = SketchupHostLauncher.run(
        job_path,
        :sketchup_exe => 'SketchUp.exe',
        :backend => backend,
        :clock => FakeClock.new([0.0, 2.0]),
        :timeout_seconds => 1,
        :plugin_state_guard => guard
      )

      assert_equal 'ERROR', result['status']
      assert_match(/timeout/, result['error'])
      assert_match(/model_save_started/, result['error'])
      assert_equal [4242], backend.killed
      assert_equal [:suppress, :restore], guard.calls
      assert_equal result, JSON.parse(File.read(result_path))
    end
  end

  def test_windows_process_backend_uses_exact_pid_descendant_tree_termination
    runner = FakeCommandRunner.new([true])
    backend = SketchupHostLauncher::ProcessBackend.new(
      :windows => true, :command_runner => runner
    )

    assert backend.kill(4242)
    assert_equal [
      ['taskkill.exe', '/PID', '4242', '/T', '/F']
    ], runner.commands
  end

  def test_default_timeout_allows_large_verified_model_persistence
    assert_operator SketchupHostLauncher::DEFAULT_TIMEOUT_SECONDS, :>=, 3600.0
  end

  def test_nonzero_child_exit_rejects_even_complete_ok_and_restores_preference
    Dir.mktmpdir('su-launch') do |dir|
      job_path, result_path, _pdf = write_job(dir)
      guard = FakePluginStateGuard.new
      backend = nil
      backend = FakeBackend.new([
        { :state => :exited, :exit_code => 23 }
      ]) do |process|
        write_complete_result(process, result_path)
      end

      result = run_launcher(job_path, backend, guard)

      assert_equal 'ERROR', result['status']
      assert_match(/exit code 23/, result['error'])
      assert_equal [:suppress, :restore], guard.calls
    end
  end

  def test_nil_gui_exit_code_accepts_complete_verified_terminal_evidence
    Dir.mktmpdir('su-launch') do |dir|
      job_path, result_path, _pdf = write_job(dir)
      guard = FakePluginStateGuard.new
      backend = FakeBackend.new([
        { :state => :exited, :exit_code => nil }
      ]) do |process|
        write_complete_result(process, result_path)
      end

      result = run_launcher(job_path, backend, guard)

      assert_equal 'OK', result['status']
      assert_equal [:suppress, :restore], guard.calls
    end
  end

  def test_exit_zero_rejects_minimal_bound_ok_artifact_claim
    Dir.mktmpdir('su-launch') do |dir|
      job_path, result_path, _pdf = write_job(dir)
      guard = FakePluginStateGuard.new
      backend = FakeBackend.new([
        { :state => :exited, :exit_code => 0 }
      ]) do |_process|
        binding = JSON.parse(File.read(result_path))
        SketchupHostLauncher.atomic_write_json(
          result_path, binding.merge('status' => 'OK')
        )
      end

      result = run_launcher(job_path, backend, guard)

      assert_equal 'ERROR', result['status']
      assert_match(/terminal evidence|incomplete/, result['error'])
      assert_equal [:suppress, :restore], guard.calls
    end
  end

  def test_complete_ok_cannot_redirect_saved_model_to_unexpected_artifact
    Dir.mktmpdir('su-launch') do |dir|
      job_path, result_path, _pdf = write_job(dir)
      guard = FakePluginStateGuard.new
      backend = FakeBackend.new([
        { :state => :exited, :exit_code => 0 }
      ]) do |process|
        write_complete_result(process, result_path)
        result = JSON.parse(File.read(result_path))
        unexpected = File.join(dir, 'stale-but-hashed.skp')
        File.binwrite(unexpected, 'stale model')
        result['model_path'] = unexpected
        result['model_sha256'] = Digest::SHA256.file(unexpected).hexdigest
        SketchupHostLauncher.atomic_write_json(result_path, result)
      end

      result = run_launcher(job_path, backend, guard)

      assert_equal 'ERROR', result['status']
      assert_match(/saved model.*mismatch/, result['error'])
    end
  end

  def test_complete_ok_requires_report_and_result_provenance_to_be_identical
    Dir.mktmpdir('su-launch') do |dir|
      job_path, result_path, _pdf = write_job(dir)
      guard = FakePluginStateGuard.new
      backend = FakeBackend.new([
        { :state => :exited, :exit_code => 0 }
      ]) do |process|
        write_complete_result(process, result_path)
        result = JSON.parse(File.read(result_path))
        report_path = result['import_report_path']
        report = JSON.parse(File.read(report_path))
        report['extra']['source_provenance']['objects'][0]['span_id'] =
          'p1:wrong'
        File.write(report_path, JSON.generate(report))
        result['import_report_sha256'] =
          Digest::SHA256.file(report_path).hexdigest
        SketchupHostLauncher.atomic_write_json(result_path, result)
      end

      result = run_launcher(job_path, backend, guard)

      assert_equal 'ERROR', result['status']
      assert_match(/provenance/, result['error'])
    end
  end

  def test_original_pdf_replacement_after_snapshot_cannot_change_host_input
    Dir.mktmpdir('su-launch') do |dir|
      job_path, result_path, original = write_job(dir)
      original_bytes = File.binread(original)
      guard = FakePluginStateGuard.new
      controlled_job_path = nil
      immutable_path = nil
      replacement = "%PDF-1.4\nreplacement\n%%EOF\n"
      on_spawn = proc do |_environment, command|
        controlled_job_path = command.last
        controlled = JSON.parse(File.read(controlled_job_path))
        immutable_path = controlled['pdf_path']
        File.binwrite(original, replacement)
      end
      backend = FakeBackend.new(
        [{ :state => :exited, :exit_code => 0 }],
        :on_spawn => on_spawn
      ) do |process|
        write_complete_result(process, result_path)
      end

      result = run_launcher(job_path, backend, guard)

      assert_equal 'OK', result['status'], result['error']
      refute_equal job_path, controlled_job_path
      assert_equal original_bytes, File.binread(immutable_path)
      assert_equal replacement, File.binread(original)
      assert_equal Digest::SHA256.hexdigest(original_bytes),
                   result['original_pdf_sha256']
      assert_equal result['original_pdf_sha256'],
                   result['immutable_pdf_sha256']
      assert_equal [:suppress, :restore], guard.calls
    end
  end

  def test_controlled_job_preserves_source_tree_digest_and_verifier_rejects_drift
    Dir.mktmpdir('su-launch-source-tree') do |dir|
      job_path, _result_path, _pdf = write_job(dir)
      raw = JSON.parse(File.read(job_path))
      expected = 'c' * 64
      raw['source_tree_sha256'] = expected
      File.write(job_path, JSON.generate(raw))
      original_job = SketchupHostJob.load(job_path)
      snapshot = SketchupHostLauncher.prepare_controlled_job!(
        job_path, original_job, 'source-tree-job'
      )
      controlled = SketchupHostJob.load(snapshot.fetch('job_path'))

      assert_equal expected, controlled[:source_tree_sha256]
      assert SketchupHostLauncher.verify_source_tree_binding!(
        {
          'source_tree_sha256_before_load' => expected,
          'source_tree_sha256_after_import' => expected
        },
        controlled
      )
      error = assert_raises(StandardError) do
        SketchupHostLauncher.verify_source_tree_binding!(
          {
            'source_tree_sha256_before_load' => expected,
            'source_tree_sha256_after_import' => 'd' * 64
          },
          controlled
        )
      end
      assert_match(/source tree/i, error.message)
    end
  end

  def test_terminal_manifest_accepts_only_proven_pure_raster_lightweight_reopen
    Dir.mktmpdir('su-terminal-raster-manifest') do |directory|
      pdf = File.join(directory, 'input.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      digest = Digest::SHA256.file(pdf).hexdigest
      binding = { 'job_id' => 'job-raster', 'job_sha256' => 'a' * 64 }
      job = {
        :import_mode => 'raster', :text_mode => 'text3d', :pages => [1],
        :immutable_pdf_path => pdf
      }
      lightweight = terminal_raster_manifest_row(false)
      physical = terminal_raster_manifest_row(true)
      result = terminal_raster_result(binding, pdf, digest)
      manifest = terminal_raster_manifest(
        binding, pdf, digest, lightweight, physical
      )
      original = SketchupHostEvidence.method(:verify_delivery_evidence!)
      verified_delivery_rows = nil
      SketchupHostEvidence.define_singleton_method(
        :verify_delivery_evidence!
      ) do |_stats, rows, _mode, _pages|
        verified_delivery_rows = rows
        true
      end

      assert SketchupHostLauncher.verify_terminal_manifest!(
        manifest, result, job, binding, digest, 'raster-session'
      )
      assert_equal true,
                   verified_delivery_rows[0]['content_evidence'][
                     'host_texture_export_verified'
                   ]

      manifest['final_texture_proof_verified'] = false
      result['final_texture_proof_verified'] = false
      assert_raises(StandardError) do
        SketchupHostLauncher.verify_terminal_manifest!(
          manifest, result, job, binding, digest, 'raster-session'
        )
      end
    ensure
      SketchupHostEvidence.define_singleton_method(
        :verify_delivery_evidence!, original
      ) if original
    end
  end

  def test_non_full_page_raster_modes_keep_strict_reopen_continuity
    Dir.mktmpdir('su-non-terminal-raster-manifest') do |directory|
      pdf = File.join(directory, 'input.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      digest = Digest::SHA256.file(pdf).hexdigest
      binding = { 'job_id' => 'job-strict', 'job_sha256' => 'a' * 64 }
      lightweight = terminal_raster_manifest_row(false)
      physical = terminal_raster_manifest_row(true)
      base_result = terminal_raster_result(binding, pdf, digest)
      base_manifest = terminal_raster_manifest(
        binding, pdf, digest, lightweight, physical
      )
      cases = [
        ['vector strategy', 'vector', 'raster'],
        ['hybrid item Raster', 'hybrid', 'raster'],
        ['Geometry', 'vector', 'geometry'],
        ['Text', 'vector', 'text'],
        ['3D Text', 'vector', 'text3d']
      ]
      original = SketchupHostEvidence.method(:verify_delivery_evidence!)
      SketchupHostEvidence.define_singleton_method(
        :verify_delivery_evidence!
      ) { |_stats, _rows, _mode, _pages| true }

      cases.each do |label, import_mode, text_mode|
        job = {
          :import_mode => import_mode, :text_mode => text_mode, :pages => [1],
          :immutable_pdf_path => pdf
        }
        result = Marshal.load(Marshal.dump(base_result))
        manifest = Marshal.load(Marshal.dump(base_manifest))
        manifest['requested_text_mode'] = text_mode
        result['requested_text_mode'] = text_mode

        error = assert_raises(StandardError, label) do
          SketchupHostLauncher.verify_terminal_manifest!(
            manifest, result, job, binding, digest, 'raster-session'
          )
        end
        assert_match(/content evidence/i, error.message, label)
      end
    ensure
      SketchupHostEvidence.define_singleton_method(
        :verify_delivery_evidence!, original
      ) if original
    end
  end

  def test_full_page_raster_flags_do_not_replace_production_proof
    Dir.mktmpdir('su-unproven-terminal-raster-manifest') do |directory|
      pdf = File.join(directory, 'input.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      digest = Digest::SHA256.file(pdf).hexdigest
      binding = { 'job_id' => 'job-unproven', 'job_sha256' => 'a' * 64 }
      job = {
        :import_mode => 'raster', :text_mode => 'text3d', :pages => [1],
        :immutable_pdf_path => pdf
      }
      lightweight = terminal_raster_manifest_row(false)
      physical = terminal_raster_manifest_row(true)
      base_result = terminal_raster_result(binding, pdf, digest)
      base_manifest = terminal_raster_manifest(
        binding, pdf, digest, lightweight, physical
      )
      cases = [
        ['missing delivery ledger', lambda do |manifest, result|
          result['raster_delivery_records'] = []
        end],
        ['wrong full-page source basis', lambda do |_manifest, result|
          result['raster_delivery_records'][0]['delivery_basis'] =
            'verified_zero_canonical_text'
        end],
        ['missing reopened ownership', lambda do |manifest, _result|
          manifest['reopened_owned_entities'] = []
        end]
      ]
      original = SketchupHostEvidence.method(:verify_delivery_evidence!)
      SketchupHostEvidence.define_singleton_method(
        :verify_delivery_evidence!
      ) { |_stats, _rows, _mode, _pages| true }

      cases.each do |label, mutate|
        result = Marshal.load(Marshal.dump(base_result))
        manifest = Marshal.load(Marshal.dump(base_manifest))
        mutate.call(manifest, result)

        error = assert_raises(StandardError, label) do
          SketchupHostLauncher.verify_terminal_manifest!(
            manifest, result, job, binding, digest, 'raster-session'
          )
        end
        assert_match(/content evidence/i, error.message, label)
      end
    ensure
      SketchupHostEvidence.define_singleton_method(
        :verify_delivery_evidence!, original
      ) if original
    end
  end

  def test_restore_failure_changes_apparent_success_to_error
    Dir.mktmpdir('su-launch') do |dir|
      job_path, result_path, _pdf = write_job(dir)
      guard = FakePluginStateGuard.new(:restore_error => true)
      backend = FakeBackend.new([
        { :state => :exited, :exit_code => 0 }
      ]) do |process|
        write_complete_result(process, result_path)
      end

      result = run_launcher(job_path, backend, guard)

      assert_equal 'ERROR', result['status']
      assert_match(/restor/, result['error'])
      assert_equal [:suppress, :restore], guard.calls
    end
  end

  def test_suppression_readback_failure_prevents_host_spawn
    Dir.mktmpdir('su-launch') do |dir|
      job_path, _result_path, _pdf = write_job(dir)
      guard = FakePluginStateGuard.new(:suppress_error => true)
      backend = FakeBackend.new([])

      result = run_launcher(job_path, backend, guard)

      assert_equal 'ERROR', result['status']
      assert_match(/suppression readback failed/, result['error'])
      assert_nil backend.spawned_command
      assert_equal [:suppress], guard.calls
    end
  end

  def test_process_backend_reports_real_child_exit_code
    backend = SketchupHostLauncher::ProcessBackend.new
    pid = backend.spawn({}, [RbConfig.ruby, '-e', 'exit 7'])
    state = { :state => :running }
    100.times do
      state = backend.poll(pid)
      break unless state[:state] == :running
      sleep 0.01
    end

    assert_equal :exited, state[:state]
    assert_equal 7, state[:exit_code]
  ensure
    backend.kill(pid) if pid && state && state[:state] == :running
  end

  def test_welcome_advancer_is_exact_pid_title_scoped_and_throttled
    runner = FakeCommandRunner.new([false, true])
    advancer = SketchupHostLauncher::WelcomeWindowAdvancer.new(
      :runner => runner, :retry_seconds => 0.5
    )

    assert_equal false, advancer.advance(4242, 0.0)
    assert_equal false, advancer.advance(4242, 0.1)
    assert_equal true, advancer.advance(4242, 0.6)
    assert_equal true, advancer.advance(4242, 1.2)
    assert_equal 2, runner.commands.length
    command = runner.commands.first
    assert command.is_a?(Array)
    script = command.last
    assert_includes script, 'Get-Process -Id 4242'
    assert_includes script, "MainWindowTitle -cne 'Welcome to SketchUp'"
    assert_includes script, '$p.MainWindowHandle'
    assert_includes script, 'PostMessage'
    assert_includes script, '0x0100'
    assert_includes script, '0x0101'
    assert_includes script, '$sawWelcome'
    assert_includes script, 'while('
    assert_includes script, 'Start-Sleep -Milliseconds 250'
    assert_match(/sawWelcome.*title.*Welcome to SketchUp.*exit 0/i, script)
    refute_includes script, 'AppActivate'
    refute_includes script, 'SendKeys'
  end

  private

  def terminal_raster_manifest_row(physical)
    content = {
      'image_like' => true,
      'display_width' => 8.5,
      'display_height' => 11.0,
      'raster_visual_pixel_sha256' => 'b' * 64,
      'host_texture_export_verified' => physical,
      'host_visual_pixel_sha256' => physical ? 'b' * 64 : nil,
      'host_pixel_width' => 100,
      'host_pixel_height' => 200,
      'host_texture_export_byte_size' => physical ? 1234 : nil,
      'host_texture_load_ms' => physical ? 4.0 : 0.0,
      'host_texture_write_ms' => physical ? 5.0 : 0.0,
      'host_texture_pixel_proof_ms' => physical ? 6.0 : 0.0,
      'host_texture_proof_temp_bytes' => 0,
      'host_texture_pixel_proof_decoder_backend' =>
        physical ? 'native_zlib_stream' : nil
    }
    [{
      'entity_id' => 80,
      'persistent_id' => 7080,
      'typename' => 'Image',
      'valid' => true,
      'deleted' => false,
      'bounds' => nil,
      'transformation' => nil,
      'representation_evidence' => nil,
      'content_evidence' => content,
      'geometry_evidence' => nil,
      'style_evidence' => nil,
      'children' => []
    }]
  end

  def terminal_raster_result(binding, pdf, digest)
    page_record = {
      'page' => 1,
      'source_span_ids' => [],
      'requested_mode' => 'raster',
      'delivered_mode' => 'raster',
      'created_entity_type' => 'raster_image',
      'delivery_scope' => 'page_raster',
      'delivery_basis' => 'explicit_full_page_raster',
      'full_page_raster_request' => true,
      'semantic_text_evaluated' => false,
      'real_raster_verified' => true,
      'visual_fidelity_verified' => true,
      'cleanup_outcome' => 'not_required',
      'explicit_request' => true,
      'degraded' => false,
      'artifact_evidence' => {},
      'resulting_entity_ids' => ['persistent_id:7080']
    }
    binding.merge(
      'reopen_persistent_id_verified' => true,
      'host_heal_preservation_verified' => true,
      'host_heal_required' => false,
      'final_texture_proof_verified' => true,
      'requested_text_mode' => 'raster',
      'delivery_summary_mode' => 'raster',
      'text_entities' => 0,
      'selected_pages' => [1],
      'text_source_span_ids' => [],
      'text_attempts' => [],
      'page_text_delivery_records' => [],
      'source_glyph_physical_deliveries' => [],
      'raster_fallback_used' => false,
      'fallback_transitions' => [],
      'page_representation_fallbacks' => [],
      'inline_image_page_raster_fallbacks' => [],
      'empty_page_source_inspections' => [],
      'raster_delivery_records' => [Marshal.load(Marshal.dump(page_record))],
      'terminal_text_delivery_records' =>
        [Marshal.load(Marshal.dump(page_record))],
      'original_pdf_path' => pdf,
      'original_pdf_sha256' => digest,
      'immutable_pdf_path' => pdf,
      'immutable_pdf_sha256' => digest,
      'normalized_pdf_path' => pdf,
      'normalized_pdf_sha256' => digest,
      'salvage_note' => nil,
      'source_provenance' => { 'objects' => [] }
    )
  end

  def terminal_raster_manifest(binding, pdf, digest, lightweight, physical)
    lineage = {
      'original_pdf_path' => pdf,
      'original_pdf_sha256' => digest,
      'immutable_pdf_path' => pdf,
      'immutable_pdf_sha256' => digest,
      'normalized_pdf_path' => pdf,
      'normalized_pdf_sha256' => digest,
      'salvage_note' => nil
    }
    binding.merge(
      'requested_text_mode' => 'raster',
      'source_pdf_path' => pdf,
      'source_pdf_sha256' => digest,
      'import_session_id' => 'raster-session',
      'reopen_persistent_id_verified' => true,
      'host_heal_preservation_verified' => true,
      'host_heal_required' => false,
      'final_texture_proof_verified' => true,
      'source_lineage' => lineage,
      'same_session_entities' => Marshal.load(Marshal.dump(lightweight)),
      'stabilized_owned_entities' => Marshal.load(Marshal.dump(lightweight)),
      'post_import_entities' => Marshal.load(Marshal.dump(lightweight)),
      'reopened_entities' => Marshal.load(Marshal.dump(physical)),
      'reopened_owned_entities' => Marshal.load(Marshal.dump(physical))
    )
  end

  def run_launcher(job_path, backend, guard)
    SketchupHostLauncher.run(
      job_path,
      :sketchup_exe => 'SketchUp.exe',
      :backend => backend,
      :clock => FakeClock.new([0.0, 0.1, 0.2]),
      :timeout_seconds => 10,
      :plugin_state_guard => guard
    )
  end

  def write_complete_result(process, result_path)
    binding = JSON.parse(File.read(result_path))
    return unless binding['status'] == 'STARTED'
    job_path = process.spawned_command.last
    job = JSON.parse(File.read(job_path))
    source_tree_sha256 = job['source_tree_sha256']
    pdf = File.expand_path(job['pdf_path'])
    output = File.expand_path(job['output_dir'])
    digest = Digest::SHA256.file(pdf).hexdigest
    original_path = File.expand_path(job['original_pdf_path'])
    original_sha = job['original_pdf_sha256']
    model_path = File.join(
      output,
      "#{File.basename(pdf, File.extname(pdf))}-labels.skp"
    )
    report_path = File.join(output, 'import_report.json')
    manifest_path = File.join(output, 'entity_manifest.json')
    source_root = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
    lineage = {
      'original_pdf_path' => original_path,
      'original_pdf_sha256' => original_sha,
      'immutable_pdf_path' => pdf,
      'immutable_pdf_sha256' => digest,
      'normalized_pdf_path' => pdf,
      'normalized_pdf_sha256' => digest,
      'salvage_note' => nil
    }
    File.binwrite(model_path, 'model evidence')
    report = {
      'schema' => 'bcs.import_report/1.1',
      'host' => { 'app' => 'sketchup', 'version' => '17.3.116' },
      'importer' => { 'version' => '3.7.98' },
      'input' => { 'file' => pdf, 'sha256' => digest },
      'report_meta' => { 'host' => 'sketchup', 'semver' => '3.7.98' },
      'extra' => {
        'requested_text_mode' => 'labels',
        'source_tree_sha256_before_load' => source_tree_sha256,
        'source_tree_sha256_after_import' => source_tree_sha256,
        'import_session_id' => 'session-1',
        'source_lineage' => lineage,
        'source_provenance' => {
          'schema' => 'bcs.source_provenance/1.0',
          'import_session_id' => 'session-1',
          'object_count' => 1,
          'objects' => [{
            'span_id' => 'text_span:1:0',
            'source_text_sha256' => Digest::SHA256.hexdigest('A'),
            'resulting_entity_ids' => ['entity_id:13']
          }]
        },
        'representation_fidelity' => { 'ready' => true },
        'import_contract_ready' => { 'ready' => true }
      }
    }
    File.write(report_path, JSON.generate(report))
    same_session_entities = [{
      'entity_id' => 13, 'persistent_id' => 7013,
      'typename' => 'Text', 'valid' => true, 'deleted' => false,
      'content_evidence' => {
        'text_like' => true, 'text' => 'A',
        'text_sha256' => Digest::SHA256.hexdigest('A'),
        'anchor' => [1.0, 2.0, 0.0], 'leader_visible' => false
      },
      'children' => []
    }]
    expected_evidence = decorate_launcher_label_manifest!(
      same_session_entities
    )
    post_import_entities = Marshal.load(Marshal.dump(same_session_entities))
    stabilized_owned_entities = Marshal.load(
      Marshal.dump(same_session_entities)
    )
    reopened_entities = Marshal.load(Marshal.dump(same_session_entities))
    reopened_entities[0]['entity_id'] = 91
    manifest = binding.merge(
      'requested_text_mode' => 'labels',
      'source_pdf_path' => pdf,
      'source_pdf_sha256' => digest,
      'source_lineage' => lineage,
      'source_tree_sha256_before_load' => source_tree_sha256,
      'source_tree_sha256_after_import' => source_tree_sha256,
      'import_session_id' => 'session-1',
      'same_session_entities' => same_session_entities,
      'stabilized_owned_entities' => stabilized_owned_entities,
      'post_import_entities' => post_import_entities,
      'reopened_entities' => reopened_entities,
      'host_heal_preservation_verified' => true,
      'reopen_persistent_id_verified' => true
    )
    SketchupHostLauncher.atomic_write_json(manifest_path, manifest)
    result = binding.merge(
      'status' => 'OK',
      'plugins_disabled_verified' => true,
      'source_root_verified' => true,
      'source_root' => source_root,
      'source_locations' => {
        'run_pipeline' => [File.join(source_root, 'bc_pdf_vector_importer', 'main.rb'), 1]
      },
      'worktree_metadata_version' => '3.7.98',
      'loaded_importer_version' => '3.7.98',
      'report_schema' => 'bcs.import_report/1.1',
      'host_version' => '17.3.116',
      'ruby_gate_identity' => {
        'engine' => 'ruby', 'version' => '2.2.4', 'patchlevel' => 230,
        'target' => 'sketchup-2017-ruby-2.2.4-p230', 'verified' => true
      },
      'requested_text_mode' => 'labels',
      'source_tree_sha256_before_load' => source_tree_sha256,
      'source_tree_sha256_after_import' => source_tree_sha256,
      'source_pdf_path' => pdf,
      'source_pdf_sha256' => digest,
      'original_pdf_path' => original_path,
      'original_pdf_sha256' => original_sha,
      'immutable_pdf_path' => pdf,
      'immutable_pdf_sha256' => digest,
      'normalized_pdf_path' => pdf,
      'normalized_pdf_sha256' => digest,
      'salvage_note' => nil,
      'delivery_summary_mode' => 'labels',
      'import_session_id' => 'session-1',
      'model_path' => model_path,
      'model_sha256' => Digest::SHA256.file(model_path).hexdigest,
      'import_report_path' => report_path,
      'import_report_sha256' => Digest::SHA256.file(report_path).hexdigest,
      'entity_manifest_path' => manifest_path,
      'entity_manifest_sha256' => Digest::SHA256.file(manifest_path).hexdigest,
      'host_heal_preservation_verified' => true,
      'reopen_persistent_id_verified' => true,
      'text_source_span_ids' => ['text_span:1:0'],
      'text_attempts' => [{
        'source_span_id' => 'text_span:1:0',
        'source_text_sha256' => Digest::SHA256.hexdigest('A'),
        'requested_mode' => 'labels', 'delivered_mode' => 'labels',
        'resulting_entity_ids' => ['entity_id:13'],
        'visual_fidelity_verified' => true,
        'placement_verified' => true, 'rotation_verified' => true,
        'content_verified' => true, 'leader_verified' => true,
        'entity_type_verified' => true,
        'physical_geometry_verified' => true,
        'physical_style_verified' => true, 'transform_verified' => true,
        'expected_evidence' => expected_evidence,
        'attempt_history' => [{
          'mode' => 'labels', 'outcome' => 'complete',
          'resulting_entity_ids' => ['entity_id:13'],
          'visual_fidelity_verified' => true,
          'cleanup_outcome' => 'not_required',
          'placement_verified' => true, 'rotation_verified' => true,
          'content_verified' => true, 'leader_verified' => true,
          'entity_type_verified' => true,
          'physical_geometry_verified' => true,
          'physical_style_verified' => true, 'transform_verified' => true,
          'expected_evidence' => expected_evidence
        }]
      }],
      'source_provenance' => {
        'schema' => 'bcs.source_provenance/1.0',
        'import_session_id' => 'session-1',
        'objects' => [{
          'span_id' => 'text_span:1:0',
          'source_text_sha256' => Digest::SHA256.hexdigest('A'),
          'resulting_entity_ids' => ['entity_id:13']
        }]
      },
      'page_text_delivery_records' => [],
      'terminal_text_delivery_records' => [],
      'terminal_cleanup_events' => [],
      'fallback_transitions' => [],
      'page_representation_fallbacks' => [],
      'raster_delivery_records' => [],
      'inline_image_page_raster_fallbacks' => [],
      'inline_images_detected' => 0,
      'empty_page_source_inspections' => [],
      'source_glyph_physical_deliveries' => [],
      'representation_fidelity' => { 'ready' => true },
      'import_contract_ready' => { 'ready' => true }
    )
    SketchupHostLauncher.atomic_write_json(result_path, result)
  end

  def decorate_launcher_label_manifest!(rows)
    fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
    row = rows[0]
    geometry = [{
      :type => 'Text', :bounds => nil, :transformation => nil,
      :anchor => [1.0, 2.0, 0.0],
      :text_sha256 => Digest::SHA256.hexdigest('A'), :children => []
    }]
    style = [{
      :type => 'Text', :entity_visible => true,
      :layer_name => nil, :layer_visible => nil,
      :material => nil, :back_material => nil,
      :casts_shadows => nil, :receives_shadows => nil, :children => []
    }]
    expected = {
      'schema' => 'bcs.source_expected/1.0',
      'source_span_id' => 'text_span:1:0',
      'representation' => 'labels',
      'source_text_sha256' => Digest::SHA256.hexdigest('A'),
      'source_bbox_pdf' => [0.0, 0.0, 72.0, 72.0],
      'source_anchor' => [1.0, 2.0, 0.0],
      'source_rotation_radians' => 0.0,
      'source_font_sha256' => fidelity.canonical_sha256(
        'source' => 'launcher-fixture'
      ),
      'expected_width' => 1.0, 'expected_height' => 1.0,
      'expected_depth' => 0.0, 'expected_bounds' => nil,
      'expected_transformation' => {
        'kind' => 'native_text_anchor', 'anchor' => [1.0, 2.0, 0.0]
      },
      'physical_geometry_sha256' => fidelity.canonical_sha256(geometry),
      'physical_style_sha256' => fidelity.canonical_sha256(style),
      'physical_entity_count' => 1
    }
    expected['evidence_sha256'] = fidelity.canonical_sha256(expected)
    row['representation_evidence'] = {
      'source_span_id' => 'text_span:1:0', 'source_unit_id' => nil,
      'source_kind' => 'text_span', 'representation' => 'labels',
      'renderer' => 'sketchup_native_text',
      'source_evidence_sha256' => expected['evidence_sha256'],
      'source_text_sha256' => expected['source_text_sha256'],
      'physical_geometry_sha256' => expected['physical_geometry_sha256'],
      'physical_style_sha256' => expected['physical_style_sha256']
    }
    row['geometry_evidence'] = {
      'sha256' => fidelity.canonical_sha256(geometry), 'payload' => geometry
    }
    row['style_evidence'] = {
      'sha256' => fidelity.canonical_sha256(style), 'payload' => style,
      'layer_name' => nil, 'layer_visible' => nil,
      'entity_visible' => true, 'material' => nil, 'back_material' => nil
    }
    expected
  end

  def write_job(dir)
    pdf = File.join(dir, 'input.pdf')
    File.binwrite(pdf, "%PDF-1.4\noriginal\n%%EOF\n")
    output = File.join(dir, 'out')
    FileUtils.mkdir_p(output)
    job_path = File.join(dir, 'job.json')
    File.write(job_path, JSON.generate(
      'pdf_path' => pdf,
      'output_dir' => output,
      'text_mode' => 'labels',
      'pages' => [1]
    ))
    [job_path, File.join(output, 'host_acceptance.json'), pdf]
  end
end
