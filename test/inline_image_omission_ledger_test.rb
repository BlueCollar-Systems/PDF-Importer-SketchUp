#!/usr/bin/env ruby
# A page that keeps its vectors but does not deliver its inline images
# (BI/ID/EI pictures are only counted today) must be accounted as an
# OMISSION, never as delivered geometry. Both ledgers - the QA report's and
# the batch harness's - balance only when every detected inline instance is
# in a page Raster fallback or a recorded omission. A silent drop cannot
# balance, and a record that calls the drop "editable_geometry" is refused.

require 'minitest/autorun'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'
require_relative '../tools/sketchup_host_evidence'

class InlineImageOmissionLedgerTest < Minitest::Test
  QA = BlueCollarSystems::PDFVectorImporter::QAReport

  def omission(page = 5, count = 2175, path_count = 15_012, delivery = :inline_images_omitted)
    {
      :page => page, :inline_image_instance_count => count,
      :vector_path_count => path_count, :delivery => delivery,
      :reason => 'inline image extraction is not implemented; the inline picture was not placed'
    }
  end

  # A page whose inline images were composited into PLACED native images.
  def composite(page = 5, count = 2175, regions = 1, overrides = {})
    per_region = count / regions
    artifacts = (1..regions).map do |index|
      last = index == regions
      { :kind => 'composite', :file_path => "C:/assets/page_%03d_inline_composite_%03d.png" % [page, index],
        :sha256 => 'b' * 64, :source_sha256 => 'c' * 64,
        :instance_count => last ? count - per_region * (regions - 1) : per_region,
        :pixel_width => 1979, :pixel_height => 622,
        :region_box_pts => [2720.5, 1393.1, 2934.3, 1467.7],
        :downsampled => false, :coverage => 0.388, :member_sequences => [1, count] }
    end
    {
      :page => page, :inline_image_instance_count => count, :vector_path_count => 15_012,
      :delivery => :inline_images_composited, :placed => true, :region_count => regions,
      :resulting_entity_ids => (1..regions).map { |index| "persistent_id:#{page * 100 + index}" },
      :artifacts => artifacts
    }.merge(overrides)
  end

  # ---- QA report ledger ---------------------------------------------------

  def test_qa_ledger_balances_composites_with_omissions_and_page_rasters
    stats = { :inline_images_detected => 4350, :inline_image_page_raster_fallbacks => [],
              :inline_image_vector_retentions => [],
              :inline_image_composites => [composite(5), composite(6, 2175, 2)] }
    assert QA.send(:fidelity_inline_image_ledger_valid?, stats)
    partly = { :inline_images_detected => 4350, :inline_image_page_raster_fallbacks => [],
               :inline_image_vector_retentions => [omission(5, 175)],
               :inline_image_composites => [composite(5, 2000), composite(6)] }
    assert QA.send(:fidelity_inline_image_ledger_valid?, partly), 'a page may be partly composited, partly omitted'
  end

  def test_qa_ledger_refuses_unplaced_short_or_unproven_composites
    base = { :inline_images_detected => 2175, :inline_image_page_raster_fallbacks => [],
             :inline_image_vector_retentions => [] }
    refute QA.send(:fidelity_inline_image_ledger_valid?, base.merge(:inline_image_composites => [composite(5, 2175, 1, :placed => false)]))
    refute QA.send(:fidelity_inline_image_ledger_valid?, base.merge(:inline_image_composites => [composite(5, 2175, 1, :delivery => :editable_geometry)]))
    refute QA.send(:fidelity_inline_image_ledger_valid?, base.merge(:inline_image_composites => [composite(5, 2000)])), 'short count'
    short_artifact = composite(5)
    short_artifact[:artifacts][0][:instance_count] = 2000
    refute QA.send(:fidelity_inline_image_ledger_valid?, base.merge(:inline_image_composites => [short_artifact])), 'artifact instances must add up'
    no_sha = composite(5)
    no_sha[:artifacts][0][:sha256] = ''
    refute QA.send(:fidelity_inline_image_ledger_valid?, base.merge(:inline_image_composites => [no_sha]))
    refute QA.send(:fidelity_inline_image_ledger_valid?, base.merge(:inline_image_composites => [composite(5, 2000), composite(5, 175)])), 'one composite record per page'
    raster_page = { :inline_images_detected => 2176, :inline_image_vector_retentions => [],
                    :inline_image_page_raster_fallbacks => [{ :page => 5, :inline_image_instance_count => 1 }],
                    :inline_image_composites => [composite(5)] }
    refute QA.send(:fidelity_inline_image_ledger_valid?, raster_page), 'a page is never both composited and page-rastered'
  end

  def test_qa_report_exports_the_composites
    src = File.read(File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report.rb', __dir__))
    assert_includes src, 'inline_image_composites:'
    assert_includes src, 'Array(stats[:inline_image_composites])'
  end

  def test_qa_ledger_balances_detected_against_recorded_omissions
    stats = { :inline_images_detected => 4350, :inline_image_page_raster_fallbacks => [],
              :inline_image_vector_retentions => [omission(5), omission(6, 2175, 10_949)] }
    assert QA.send(:fidelity_inline_image_ledger_valid?, stats)
  end

  def test_qa_ledger_refuses_a_drop_described_as_delivered_geometry
    stats = { :inline_images_detected => 2175, :inline_image_page_raster_fallbacks => [],
              :inline_image_vector_retentions => [omission(5, 2175, 15_012, :editable_geometry)] }
    refute QA.send(:fidelity_inline_image_ledger_valid?, stats)
  end

  def test_qa_ledger_refuses_an_unbalanced_or_double_counted_page
    short = { :inline_images_detected => 2175, :inline_image_page_raster_fallbacks => [],
              :inline_image_vector_retentions => [omission(5, 2000)] }
    refute QA.send(:fidelity_inline_image_ledger_valid?, short)
    silent = { :inline_images_detected => 2175, :inline_image_page_raster_fallbacks => [],
               :inline_image_vector_retentions => [] }
    refute QA.send(:fidelity_inline_image_ledger_valid?, silent), 'a silent drop must not balance'
  end

  def test_qa_report_exports_the_omissions
    src = File.read(File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report.rb', __dir__))
    assert_includes src, 'inline_image_omissions:'
    assert_includes src, 'Array(stats[:inline_image_vector_retentions])'
  end

  # ---- batch harness ledger (tools/sketchup_host_evidence.rb) --------------

  def lineage
    {
      'original_pdf_path' => 'C:/fixtures/source.pdf', 'original_pdf_sha256' => 'a' * 64,
      'immutable_pdf_path' => 'C:/fixtures/source.pdf', 'immutable_pdf_sha256' => 'a' * 64,
      'normalized_pdf_path' => 'C:/fixtures/source.pdf', 'normalized_pdf_sha256' => 'a' * 64,
      'salvage_note' => nil
    }
  end

  def harness_stats(detected, retentions, composites = [])
    {
      :original_pdf_path => lineage['original_pdf_path'], :original_pdf_sha256 => lineage['original_pdf_sha256'],
      :immutable_pdf_path => lineage['immutable_pdf_path'], :immutable_pdf_sha256 => lineage['immutable_pdf_sha256'],
      :normalized_pdf_path => lineage['normalized_pdf_path'], :normalized_pdf_sha256 => lineage['normalized_pdf_sha256'],
      :salvage_note => nil, :inline_images_detected => detected,
      :inline_image_page_raster_fallbacks => [], :inline_image_vector_retentions => retentions,
      :inline_image_composites => composites
    }
  end

  def test_harness_accepts_placed_composites_and_balances_them_with_omissions
    assert SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!,
                                     harness_stats(4350, [], [composite(5), composite(6, 2175, 3)]))
    assert SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!,
                                     harness_stats(4350, [omission(5, 175)], [composite(5, 2000), composite(6)]))
  end

  def test_harness_refuses_unplaced_unproven_or_short_composites
    error = assert_raises(StandardError) do
      SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!,
                                harness_stats(2175, [], [composite(5, 2175, 1, :placed => false)]))
    end
    assert_match(/placed inline_images_composited/, error.message)
    short_artifact = composite(5)
    short_artifact[:artifacts][0][:instance_count] = 2000
    error = assert_raises(StandardError) do
      SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!, harness_stats(2175, [], [short_artifact]))
    end
    assert_match(/artifact instance counts/, error.message)
    error = assert_raises(StandardError) do
      SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!, harness_stats(2175, [], [composite(5, 2000)]))
    end
    assert_match(/plus composites plus recorded omissions/, error.message)
    missing_entity = composite(5, 2175, 2, :resulting_entity_ids => ['persistent_id:1'])
    error = assert_raises(StandardError) do
      SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!, harness_stats(2175, [], [missing_entity]))
    end
    assert_match(/region entity proof/, error.message)
    error = assert_raises(StandardError) do
      SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!,
                                harness_stats(2175, [], [composite(5, 2000), composite(5, 175)]))
    end
    assert_match(/is repeated/, error.message)
  end

  def test_batch_tool_serializes_the_composites_for_the_harness
    src = File.read(File.expand_path('../tools/sketchup_batch_import.rb', __dir__))
    assert_includes src, "'inline_image_composites' =>"
  end

  def test_harness_accepts_recorded_omissions_that_balance_the_detection_total
    assert SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!,
                                     harness_stats(4350, [omission(5), omission(6, 2175, 10_949)]))
  end

  def test_harness_refuses_a_silent_drop_and_a_mislabelled_record
    error = assert_raises(StandardError) do
      SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!, harness_stats(2175, []))
    end
    assert_match(/plus recorded omissions/, error.message)
    error = assert_raises(StandardError) do
      SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!,
                                harness_stats(2175, [omission(5, 2175, 15_012, :editable_geometry)]))
    end
    assert_match(/inline_images_omitted/, error.message)
  end

  def test_harness_refuses_an_omission_without_vector_paths_or_with_a_short_count
    assert_raises(StandardError) do
      SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!,
                                harness_stats(2175, [omission(5, 2175, 0)]))
    end
    assert_raises(StandardError) do
      SketchupHostEvidence.send(:verify_inline_image_page_raster_fallbacks!,
                                harness_stats(2175, [omission(5, 2000)]))
    end
  end

  def test_batch_tool_serializes_the_omissions_for_the_harness
    src = File.read(File.expand_path('../tools/sketchup_batch_import.rb', __dir__))
    assert_includes src, "'inline_image_vector_retentions' =>"
  end
end
