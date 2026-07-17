#!/usr/bin/env ruby
require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)

class SketchupBatchHostContractTest < Minitest::Test
  def source
    File.read(
      File.join(REPO_ROOT, 'tools', 'sketchup_batch_import.rb'),
      :encoding => 'UTF-8'
    )
  end

  def test_runner_uses_one_job_argument_and_never_blocks_on_messagebox
    assert_includes source, 'SketchupHostJob.load(ARGV[0])'
    assert_includes source, "'host_acceptance.json'"
    assert_includes source, 'rescue Exception => error'
    assert_includes source, 'Sketchup.quit'
    assert_includes source, 'model.save(job[:model_path])'
    assert_includes source, 'File.file?(job[:model_path])'
    assert_includes source, 'importer.method(:run_pipeline).source_location'
    assert_includes source, "'source_root_verified' => true"
    refute_includes source, 'UI.messagebox'
    refute_match(/ARGV\[1\]/, source)
  end

  def test_runner_maps_requested_modes_without_substitution
    assert_includes source, 'opts[:text_mode] = job[:text_mode]'
    assert_includes source,
                    'opts[:force_raster] = (job[:text_mode] == :raster)'
    assert_includes source,
                    'opts[:import_text] = (job[:text_mode] != :raster)'
    assert_includes source,
                    "'requested_text_mode' => job[:text_mode].to_s"
  end

  def test_runner_preserves_complete_evidence_and_source_provenance
    assert_includes source,
                    'SketchupHostEvidence.verify_delivery_evidence!'
    assert_includes source,
                    "'representation_fidelity' => stats[:representation_fidelity]"
    assert_includes source,
                    "'import_contract_ready' => stats[:import_contract_ready]"
    assert_includes source,
                    "'terminal_text_delivery_records' =>"
    assert_includes source,
                    "'page_representation_fallbacks' =>"
    assert_includes source,
                    "'source_glyph_physical_deliveries' =>"
    assert_includes source,
                    "'text_renderers' => Array(stats[:text_renderers])"
    assert_includes source, "'worktree_metadata_version' =>"
    assert_includes source, "'loaded_importer_version' =>"
    assert_includes source, "'source_locations' => source_locations"
    assert_includes source,
                    'importer::CairoGlyphSource.method(:render_page_svg).source_location'
    assert_includes source,
                    'importer.method(:verified_item_raster_entity!).source_location'
  end
end
