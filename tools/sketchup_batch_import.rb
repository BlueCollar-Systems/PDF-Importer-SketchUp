#!/usr/bin/env ruby
# SketchUp -RubyStartup entry for one fail-closed real-host acceptance job.

require 'fileutils'
require 'json'
require 'tmpdir'
require File.expand_path('sketchup_host_job', __dir__)
require File.expand_path('sketchup_host_evidence', __dir__)

job = nil

def write_host_result(path, payload)
  FileUtils.mkdir_p(File.dirname(path))
  File.open(path, 'w') do |file|
    file.write(JSON.pretty_generate(payload))
    file.write("\n")
  end
end

begin
  raise 'SketchUp host is required' unless defined?(Sketchup)

  job = SketchupHostJob.load(ARGV[0])
  FileUtils.mkdir_p(job[:output_dir])
  write_host_result(job[:result_path], 'status' => 'STARTED')

  plugin_root = File.expand_path('../extracted/sketchup_ext', __dir__)
  load File.join(plugin_root, 'bc_pdf_vector_importer', 'main.rb')
  importer = BlueCollarSystems::PDFVectorImporter

  pipeline_source = importer.method(:run_pipeline).source_location
  source_locations = {
    'run_pipeline' => pipeline_source,
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
  expected_source_root = File.expand_path(plugin_root)
  SketchupHostEvidence.verify_source_locations!(
    expected_source_root, source_locations
  )

  metadata_path = File.join(
    plugin_root, 'bc_pdf_vector_importer', 'metadata.rb'
  )
  metadata_source = File.read(metadata_path, :encoding => 'UTF-8')
  worktree_metadata_version = metadata_source[
    /^\s*VERSION\s*=\s*['"]([^'"]+)['"]/, 1
  ]
  if worktree_metadata_version.to_s.empty?
    raise 'worktree metadata version is missing'
  end
  loaded_importer_version = importer::VERSION.to_s
  unless loaded_importer_version == worktree_metadata_version
    raise "loaded importer version #{loaded_importer_version} does not match " \
          "worktree metadata version #{worktree_metadata_version}"
  end

  gate = importer.handle_open_gate(job[:pdf_path], {}, :show_ui => false)
  raise "open gate refused: #{gate[:reason]}" if gate

  model = Sketchup.active_model
  opts = importer::ImportConfig.auto.to_opts
  opts[:pages] = job[:pages]
  opts[:import_mode] = job[:import_mode]
  opts[:text_mode] = job[:text_mode]
  opts[:force_raster] = (job[:text_mode] == :raster)
  opts[:import_text] = (job[:text_mode] != :raster)
  opts[:use_3d_text] = (job[:text_mode] == :text3d)
  opts[:group_per_page] = true

  pre_import_entity_ids = model.active_entities.to_a.map do |entity|
    entity.entityID
  end
  stats = importer.run_pipeline(model, job[:pdf_path], opts)
  raise 'run_pipeline returned nil' unless stats

  raise 'model save failed' unless model.save(job[:model_path])
  raise 'saved model missing' unless File.file?(job[:model_path])

  report_source = stats[:import_report_path]
  unless report_source && File.file?(report_source)
    raise 'production import report missing'
  end
  report_copy = File.join(job[:output_dir], 'import_report.json')
  source_key = File.expand_path(report_source).tr('\\', '/').downcase
  copy_key = File.expand_path(report_copy).tr('\\', '/').downcase
  FileUtils.cp(report_source, report_copy) unless source_key == copy_key
  raise 'copied import report missing' unless File.file?(report_copy)

  imported_roots = model.active_entities.to_a.reject do |entity|
    pre_import_entity_ids.include?(entity.entityID)
  end
  entity_manifest = SketchupHostEvidence.snapshot_entities(imported_roots)
  raise 'no imported host entities found' if entity_manifest.empty?
  manifest_path = File.join(job[:output_dir], 'entity_manifest.json')
  write_host_result(manifest_path, {
    'requested_text_mode' => job[:text_mode].to_s,
    'entities' => entity_manifest
  })
  raise 'entity manifest missing' unless File.file?(manifest_path)

  SketchupHostEvidence.verify_delivery_evidence!(stats, entity_manifest)

  write_host_result(job[:result_path], {
    'status' => 'OK',
    'source_root_verified' => true,
    'source_root' => expected_source_root,
    'source_locations' => source_locations,
    'pipeline_source_location' => pipeline_source,
    'worktree_metadata_version' => worktree_metadata_version,
    'loaded_importer_version' => loaded_importer_version,
    'requested_text_mode' => job[:text_mode].to_s,
    'delivery_summary_mode' => stats[:text_mode].to_s,
    'model_path' => job[:model_path],
    'import_report_path' => report_copy,
    'entity_manifest_path' => manifest_path,
    'text_entities' => stats[:text].to_i,
    'text_renderers' => Array(stats[:text_renderers]),
    'text_attempts' => Array(stats[:text_attempts]),
    'page_text_delivery_records' =>
      Array(stats[:page_text_delivery_records]),
    'terminal_text_delivery_records' =>
      Array(stats[:terminal_text_delivery_records]),
    'terminal_cleanup_events' => Array(stats[:terminal_cleanup_events]),
    'fallback_transitions' => Array(stats[:fallback_transitions]),
    'page_representation_fallbacks' =>
      Array(stats[:page_representation_fallbacks]),
    'raster_delivery_records' => Array(stats[:raster_delivery_records]),
    'source_glyph_physical_deliveries' =>
      Array(stats[:source_glyph_physical_deliveries]),
    'representation_fidelity' => stats[:representation_fidelity],
    'import_contract_ready' => stats[:import_contract_ready]
  })
  raise 'host acceptance result missing' unless File.file?(job[:result_path])
rescue Exception => error
  result_path = job && job[:result_path]
  result_path ||= File.join(Dir.tmpdir, 'host_acceptance.json')
  write_host_result(result_path, {
    'status' => 'ERROR',
    'error' => "#{error.class}: #{error.message}",
    'backtrace' => Array(error.backtrace)
  })
ensure
  if defined?(UI) && defined?(Sketchup)
    UI.start_timer(0.5, false) { Sketchup.quit }
  end
end
