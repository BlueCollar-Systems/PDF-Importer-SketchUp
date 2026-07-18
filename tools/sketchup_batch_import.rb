#!/usr/bin/env ruby
# SketchUp -RubyStartup entry for one isolated, fail-closed host job.

require 'json'
require 'digest'
require 'tmpdir'
require File.expand_path('sketchup_host_job', __dir__)
require File.expand_path('sketchup_host_evidence', __dir__)

module SketchupBatchImport
  class RealHostSession
    def initialize
      @model = nil
      @closed = false
    end

    def perform(job, binding)
      require_batch_environment!
      host_identity = require_su2017_ruby_identity!
      verify_plugins_disabled!
      install_modal_guard!
      plugin_root = File.expand_path('../extracted/sketchup_ext', __dir__)
      load File.join(plugin_root, 'bc_pdf_vector_importer', 'main.rb')
      importer = BlueCollarSystems::PDFVectorImporter
      expected_root = File.expand_path(plugin_root)
      source_locations = importer_source_locations(importer)
      SketchupHostEvidence.verify_source_locations!(
        expected_root, source_locations
      )

      worktree_version = metadata_version(plugin_root)
      loaded_version = importer::VERSION.to_s
      unless loaded_version == worktree_version
        raise "loaded importer version #{loaded_version} does not match " \
              "worktree metadata version #{worktree_version}"
      end

      gate = importer.handle_open_gate(job[:pdf_path], {}, :show_ui => false)
      raise "open gate refused: #{gate[:reason]}" if gate

      @model = Sketchup.active_model
      before_manifest = SketchupHostEvidence.snapshot_entities(
        @model.active_entities
      )
      stats = importer.run_pipeline(
        @model, job[:pdf_path], import_options(importer, job)
      )
      raise 'run_pipeline returned nil' unless stats.is_a?(Hash)
      source_lineage = verified_source_lineage!(stats, job)

      after_manifest = SketchupHostEvidence.snapshot_entities(
        @model.active_entities
      )
      owned_manifest = SketchupHostEvidence.owned_manifest(
        before_manifest, after_manifest
      )
      raise 'no recursively owned imported host entities found' if
        owned_manifest.empty?
      SketchupHostEvidence.verify_delivery_evidence!(
        stats, owned_manifest, job[:text_mode], job[:pages]
      )

      import_session_id = stats[:import_session_id].to_s.strip
      raise 'pipeline import_session_id is missing' if import_session_id.empty?
      provenance = {
        'schema' => 'bcs.source_provenance/1.0',
        'import_session_id' => import_session_id,
        'objects' => Array(stats[:source_provenance_objects])
      }

      raise 'model save failed' unless @model.save(job[:model_path])
      raise 'saved model missing' unless File.file?(job[:model_path])

      report_source = stats[:import_report_path]
      report_copy = File.join(job[:output_dir], 'import_report.json')
      SketchupHostEvidence.copy_verified_report!(
        report_source,
        report_copy,
        :pdf_path => job[:pdf_path],
        :requested_mode => job[:text_mode],
        :schema => importer::QAReport::SCHEMA,
        :worktree_version => worktree_version,
        :loaded_version => loaded_version,
        :host_version => Sketchup.version.to_s,
        :import_session_id => import_session_id,
        :source_provenance_objects =>
          Array(stats[:source_provenance_objects]),
        :representation_fidelity => stats[:representation_fidelity],
        :import_contract_ready => stats[:import_contract_ready],
        :source_lineage => source_lineage
      )

      manifest_path = File.join(job[:output_dir], 'entity_manifest.json')
      manifest_payload = binding.merge(
        'requested_text_mode' => job[:text_mode].to_s,
        'source_pdf_path' => job[:pdf_path],
        'source_pdf_sha256' => Digest::SHA256.file(job[:pdf_path]).hexdigest,
        'source_lineage' => source_lineage,
        'import_session_id' => import_session_id,
        'source_provenance' => provenance,
        'same_session_entities' => owned_manifest,
        'post_import_entities' => after_manifest
      )
      SketchupHostEvidence.atomic_write_json(manifest_path, manifest_payload)

      reopened_model = reopen_model!(job[:model_path])
      reopened_manifest = SketchupHostEvidence.snapshot_entities(
        reopened_model.active_entities
      )
      SketchupHostEvidence.verify_reopen_continuity!(
        after_manifest, reopened_manifest
      )
      manifest_payload['reopened_entities'] = reopened_manifest
      manifest_payload['reopen_persistent_id_verified'] = true
      SketchupHostEvidence.atomic_write_json(manifest_path, manifest_payload)

      {
        'plugins_disabled_verified' => true,
        'source_root_verified' => true,
        'source_root' => expected_root,
        'source_locations' => source_locations,
        'pipeline_source_location' => source_locations['run_pipeline'],
        'worktree_metadata_version' => worktree_version,
        'loaded_importer_version' => loaded_version,
        'report_schema' => importer::QAReport::SCHEMA,
        'host_version' => Sketchup.version.to_s,
        'ruby_gate_identity' => host_identity,
        'requested_text_mode' => job[:text_mode].to_s,
        'source_pdf_path' => job[:pdf_path],
        'source_pdf_sha256' => Digest::SHA256.file(job[:pdf_path]).hexdigest,
        'original_pdf_path' => job[:original_pdf_path],
        'original_pdf_sha256' => job[:original_pdf_sha256],
        'immutable_pdf_path' => job[:immutable_pdf_path],
        'immutable_pdf_sha256' => job[:immutable_pdf_sha256],
        'normalized_pdf_path' => source_lineage['normalized_pdf_path'],
        'normalized_pdf_sha256' => source_lineage['normalized_pdf_sha256'],
        'salvage_note' => source_lineage['salvage_note'],
        'delivery_summary_mode' => stats[:text_mode].to_s,
        'import_session_id' => import_session_id,
        'model_path' => job[:model_path],
        'model_sha256' => Digest::SHA256.file(job[:model_path]).hexdigest,
        'import_report_path' => report_copy,
        'import_report_sha256' => Digest::SHA256.file(report_copy).hexdigest,
        'entity_manifest_path' => manifest_path,
        'entity_manifest_sha256' => Digest::SHA256.file(manifest_path).hexdigest,
        'reopen_persistent_id_verified' => true,
        'text_entities' => stats[:text].to_i,
        'text_renderers' => Array(stats[:text_renderers]),
        'text_source_span_ids' => Array(stats[:text_source_span_ids]),
        'text_attempts' => Array(stats[:text_attempts]),
        'source_provenance' => provenance,
        'page_text_delivery_records' =>
          Array(stats[:page_text_delivery_records]),
        'terminal_text_delivery_records' =>
          Array(stats[:terminal_text_delivery_records]),
        'terminal_cleanup_events' => Array(stats[:terminal_cleanup_events]),
        'fallback_transitions' => Array(stats[:fallback_transitions]),
        'page_representation_fallbacks' =>
          Array(stats[:page_representation_fallbacks]),
        'raster_delivery_records' => Array(stats[:raster_delivery_records]),
        'empty_page_source_inspections' =>
          Array(stats[:empty_page_source_inspections]),
        'source_glyph_physical_deliveries' =>
          Array(stats[:source_glyph_physical_deliveries]),
        'representation_fidelity' => stats[:representation_fidelity],
        'import_contract_ready' => stats[:import_contract_ready]
      }
    end

    def require_su2017_ruby_identity!
      host_version = Sketchup.version.to_s
      host_major = host_version.split('.').first.to_i
      raise "guarded host must be SketchUp 2017 (major 17), got #{host_version}" unless
        host_major == 17
      engine = defined?(RUBY_ENGINE) ? RUBY_ENGINE.to_s : 'ruby'
      version = RUBY_VERSION.to_s
      patchlevel = defined?(RUBY_PATCHLEVEL) ? RUBY_PATCHLEVEL.to_i : -1
      verified = engine == 'ruby' && version == '2.2.4' && patchlevel == 230
      identity = {
        'engine' => engine,
        'version' => version,
        'patchlevel' => patchlevel,
        'target' => 'sketchup-2017-ruby-2.2.4-p230',
        'verified' => verified
      }
      unless verified
        raise "guarded Ruby identity must be ruby 2.2.4-p230, got " \
              "#{engine} #{version}-p#{patchlevel}"
      end
      identity
    end

    def discard!
      model = @model
      model = Sketchup.active_model if !model && defined?(Sketchup)
      return true unless model
      begin
        model.abort_operation if model.respond_to?(:abort_operation)
      rescue StandardError
        # The production pipeline may already have aborted/committed.
      end
      if model.respond_to?(:close)
        model.close(true)
        @closed = true
      end
      true
    rescue StandardError => error
      raise "failed to discard batch model: #{error.message}"
    end

    def quit!
      return true unless defined?(UI) && defined?(Sketchup)
      UI.start_timer(0.1, false) { Sketchup.quit }
      true
    end

    private

    def require_batch_environment!
      unless ENV['BC_PDF_IMPORTER_BATCH_NONINTERACTIVE'].to_s == '1'
        raise 'noninteractive batch environment is not enabled'
      end
    end

    def verify_plugins_disabled!
      unless defined?(Sketchup) && Sketchup.respond_to?(:plugins_disabled?) &&
             Sketchup.plugins_disabled? == true
        raise 'SketchUp did not confirm plugins_disabled? for this process'
      end
      true
    end

    def install_modal_guard!
      return unless defined?(UI)
      singleton = class << UI; self; end
      singleton.send(:define_method, :messagebox) do |*_arguments|
        raise RuntimeError,
              'modal UI is forbidden during noninteractive host acceptance'
      end
    end

    def metadata_version(plugin_root)
      path = File.join(plugin_root, 'bc_pdf_vector_importer', 'metadata.rb')
      source = File.read(path, :encoding => 'UTF-8')
      version = source[/^\s*VERSION\s*=\s*['"]([^'"]+)['"]/, 1]
      raise 'worktree metadata version is missing' if version.to_s.empty?
      version
    end

    def importer_source_locations(importer)
      {
        'run_pipeline' => importer.method(:run_pipeline).source_location,
        'batch_host_policy' =>
          importer::BatchHostPolicy.method(:noninteractive?).source_location,
        'representation_mode_normalizer' =>
          importer::RepresentationFidelity.method(:normalize_mode).source_location,
        'representation_fallback_controller' =>
          importer::RepresentationFidelity::FallbackController.
            instance_method(:advance!).source_location,
        'geometry_text_router' =>
          importer::GeometryBuilder.instance_method(:place_text).source_location,
        'labels_renderer' =>
          importer::GeometryBuilder.
            instance_method(:place_annotation_label).source_location,
        'native_text3d_renderer' =>
          importer::GeometryBuilder.instance_method(:place_mesh_text).source_location,
        'svg_text_source_renderer' =>
          importer::SvgTextRenderer.method(:render).source_location,
        'cairo_glyph_source_renderer' =>
          importer::CairoGlyphSource.method(:render_page_svg).source_location,
        'svg_text3d_renderer' =>
          importer::Svg3DTextRenderer.method(:render_svg).source_location,
        'svg_item_representation_renderer' =>
          importer::SvgItemRepresentationRenderer.method(:render_svg).source_location,
        'raster_renderer' =>
          importer.method(:verified_raster_entity!).source_location,
        'item_raster_renderer' =>
          importer.method(:verified_item_raster_entity!).source_location,
        'metadata_writer' => importer::Metadata.method(:attach).source_location
      }
    end

    def import_options(importer, job)
      opts = importer::ImportConfig.auto.to_opts
      opts[:pages] = job[:pages]
      opts[:import_mode] = job[:import_mode]
      opts[:text_mode] = job[:text_mode]
      opts[:force_raster] = (job[:text_mode] == :raster)
      opts[:import_text] = (job[:text_mode] != :raster)
      opts[:use_3d_text] = (job[:text_mode] == :text3d)
      opts[:group_per_page] = true
      opts[:source_lineage] = {
        :original_pdf_path => job[:original_pdf_path],
        :original_pdf_sha256 => job[:original_pdf_sha256],
        :immutable_pdf_path => job[:immutable_pdf_path],
        :immutable_pdf_sha256 => job[:immutable_pdf_sha256]
      }
      opts
    end

    def verified_source_lineage!(stats, job)
      raw = stats[:source_lineage]
      raise 'pipeline source_lineage is missing' unless raw.is_a?(Hash)
      lineage = JSON.parse(JSON.generate(raw))
      unless same_path?(lineage['original_pdf_path'], job[:original_pdf_path]) &&
             lineage['original_pdf_sha256'] == job[:original_pdf_sha256] &&
             same_path?(lineage['immutable_pdf_path'], job[:immutable_pdf_path]) &&
             lineage['immutable_pdf_sha256'] == job[:immutable_pdf_sha256]
        raise 'pipeline immutable/original source lineage mismatch'
      end
      unless !lineage['normalized_pdf_path'].to_s.strip.empty? &&
             lineage['normalized_pdf_sha256'].to_s =~ /\A[0-9a-f]{64}\z/ &&
             (lineage['salvage_note'].nil? ||
              lineage['salvage_note'].is_a?(String))
        raise 'pipeline normalized/salvage source lineage is incomplete'
      end
      lineage
    end

    def same_path?(left, right)
      File.expand_path(left.to_s).tr('\\', '/').downcase ==
        File.expand_path(right.to_s).tr('\\', '/').downcase
    end

    def reopen_model!(model_path)
      result = Sketchup.open_file(model_path)
      raise 'saved model reopen failed' if result == false
      model = Sketchup.active_model
      raise 'reopened model is unavailable' unless model
      @model = model
      model
    end
  end

  module_function

  def run_argv!(arguments, session = nil, environment = ENV)
    unless arguments.is_a?(Array) && arguments.length == 1
      raise ArgumentError, 'exactly one host job argument is required'
    end
    job = SketchupHostJob.load(arguments[0])
    job_id = environment['BC_HOST_JOB_ID'].to_s.strip
    expected_sha = environment['BC_HOST_JOB_SHA256'].to_s.strip
    unless !job_id.empty? && expected_sha =~ /\A[0-9a-f]{64}\z/ &&
           job[:job_sha256] == expected_sha
      raise ArgumentError, 'host job binding is missing or does not match job bytes'
    end
    unless environment['BC_PDF_IMPORTER_BATCH_NONINTERACTIVE'].to_s == '1'
      raise ArgumentError, 'host job must run in noninteractive batch mode'
    end
    binding = { 'job_id' => job_id, 'job_sha256' => expected_sha }
    SketchupHostEvidence.atomic_write_json(
      job[:result_path], binding.merge('status' => 'STARTED')
    )
    active_session = session || RealHostSession.new
    result = nil
    begin
      payload = active_session.perform(job, binding)
      unless payload.is_a?(Hash)
        raise 'host session returned no result payload'
      end
      result = binding.merge('status' => 'OK').merge(payload)
    rescue Exception => error
      discard_error = nil
      begin
        active_session.discard!
      rescue StandardError => cleanup_failure
        discard_error = "#{cleanup_failure.class}: #{cleanup_failure.message}"
      end
      result = binding.merge(
        'status' => 'ERROR',
        'error' => "#{error.class}: #{error.message}",
        'backtrace' => Array(error.backtrace),
        'discard_error' => discard_error
      )
    ensure
      SketchupHostEvidence.atomic_write_json(job[:result_path], result) if result
      begin
        active_session.quit!
      rescue StandardError => quit_error
        if result
          result['status'] = 'ERROR'
          result['quit_error'] = "#{quit_error.class}: #{quit_error.message}"
          SketchupHostEvidence.atomic_write_json(job[:result_path], result)
        end
      end
    end
    result
  end
end

SketchupBatchImport.run_argv!(ARGV) if defined?(Sketchup)
