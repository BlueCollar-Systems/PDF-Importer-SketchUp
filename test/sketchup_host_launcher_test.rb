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

  def setup
    Object.send(:remove_const, :SketchupHostLauncher) if
      defined?(SketchupHostLauncher)
    load File.join(REPO_ROOT, 'tools', 'sketchup_host_launcher.rb')
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
        assert_equal 1, backend.spawned_command.count { |arg| arg == '-RubyStartupArg' }
        refute_equal job_path, backend.spawned_command.last
        refute_includes backend.spawned_command, paid_plugin
      end
    end
  end

  def test_timeout_restores_preference_writes_error_and_kills_only_child
    Dir.mktmpdir('su-launch') do |dir|
      job_path, result_path, _pdf = write_job(dir)
      guard = FakePluginStateGuard.new
      backend = FakeBackend.new([
        { :state => :running }, { :state => :running }
      ])
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
      assert_equal [4242], backend.killed
      assert_equal [:suppress, :restore], guard.calls
      assert_equal result, JSON.parse(File.read(result_path))
    end
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

  private

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
        'import_session_id' => 'session-1',
        'source_lineage' => lineage,
        'source_provenance' => {
          'schema' => 'bcs.source_provenance/1.0',
          'import_session_id' => 'session-1',
          'object_count' => 1,
          'objects' => [{
            'span_id' => 'p1:s1',
            'resulting_entity_ids' => ['entity_id:13']
          }]
        },
        'representation_fidelity' => { 'ready' => true },
        'import_contract_ready' => { 'ready' => true }
      }
    }
    File.write(report_path, JSON.generate(report))
    manifest = binding.merge(
      'requested_text_mode' => 'labels',
      'source_pdf_path' => pdf,
      'source_pdf_sha256' => digest,
      'source_lineage' => lineage,
      'import_session_id' => 'session-1',
      'same_session_entities' => [{
        'entity_id' => 13, 'persistent_id' => 7013,
        'typename' => 'Text', 'children' => []
      }],
      'post_import_entities' => [{
        'entity_id' => 13, 'persistent_id' => 7013,
        'typename' => 'Text', 'children' => []
      }],
      'reopened_entities' => [{
        'entity_id' => 91, 'persistent_id' => 7013,
        'typename' => 'Text', 'children' => []
      }],
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
      'requested_text_mode' => 'labels',
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
      'reopen_persistent_id_verified' => true,
      'text_source_span_ids' => ['p1:s1'],
      'text_attempts' => [{
        'source_span_id' => 'p1:s1',
        'resulting_entity_ids' => ['entity_id:13']
      }],
      'source_provenance' => {
        'schema' => 'bcs.source_provenance/1.0',
        'import_session_id' => 'session-1',
        'objects' => [{
          'span_id' => 'p1:s1',
          'resulting_entity_ids' => ['entity_id:13']
        }]
      },
      'page_text_delivery_records' => [],
      'terminal_text_delivery_records' => [],
      'terminal_cleanup_events' => [],
      'fallback_transitions' => [],
      'page_representation_fallbacks' => [],
      'raster_delivery_records' => [],
      'empty_page_source_inspections' => [],
      'source_glyph_physical_deliveries' => [],
      'representation_fidelity' => { 'ready' => true },
      'import_contract_ready' => { 'ready' => true }
    )
    SketchupHostLauncher.atomic_write_json(result_path, result)
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
