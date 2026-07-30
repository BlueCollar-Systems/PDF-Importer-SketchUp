#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'json'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/import_dialog'
require 'bc_pdf_vector_importer/representation_fidelity'
require File.join(REPO_ROOT, 'tools', 'sketchup_host_job')

module Sketchup
  def self.version
    '17.2.2555'
  end unless respond_to?(:version)

  class Entities
    def add_text(*_args); end
    def add_3d_text(*_args); end
  end unless const_defined?(:Entities)

  class Text
    def text; end
    def point; end
    def vector; end
    def display_leader?; end
  end unless const_defined?(:Text)
end

class TextRepresentationDistinctionTest < Minitest::Test
  ImportDialog = BlueCollarSystems::PDFVectorImporter::ImportDialog
  Fidelity = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity

  SourceItem = Struct.new(
    :text, :bbox_x0, :bbox_y0, :bbox_x1, :bbox_y1, :source_span_id
  )

  def source_item
    SourceItem.new('WELD', 10.25, 20.5, 42.75, 31.0, 'text_span:1:0')
  end

  def test_text_and_labels_are_distinct_requested_representations
    assert_equal :text, Fidelity.normalize_mode('Text')
    assert_equal :labels, Fidelity.normalize_mode('Labels')
    refute_equal Fidelity.normalize_mode('Text'), Fidelity.normalize_mode('Labels')
    assert_includes Fidelity::MODES, :text
  end

  def test_text_ladder_preserves_request_before_adjacent_fallbacks
    assert_equal [:text, :text3d, :glyphs, :geometry, :raster],
                 Fidelity.ladder_for(:text)
    assert_equal [:labels, :text3d, :glyphs, :geometry, :raster],
                 Fidelity.ladder_for(:labels)
  end

  def test_dialog_exposes_text_without_aliasing_it_to_labels
    assert_equal ['Text', 'Labels', '3D Text', 'Glyphs', 'Geometry', 'Raster'],
                 ImportDialog::TEXT_MODE_CHOICES

    text_opts = ImportDialog.send(
      :build_opts,
      import_mode: 'auto', import_text: 'Yes', text_mode: 'Text'
    )
    label_opts = ImportDialog.send(
      :build_opts,
      import_mode: 'auto', import_text: 'Yes', text_mode: 'Labels'
    )
    assert_equal :text, text_opts[:text_mode]
    assert_equal :labels, label_opts[:text_mode]
  end

  def test_host_job_preserves_text_request_identity
    Dir.mktmpdir('su-native-text-job') do |dir|
      pdf = File.join(dir, 'drawing.pdf')
      File.binwrite(pdf, "%PDF-1.4\n%%EOF\n")
      job_path = File.join(dir, 'job.json')
      File.write(job_path, JSON.generate(
        'pdf_path' => pdf,
        'output_dir' => dir,
        'text_mode' => 'text',
        'import_mode' => 'vector',
        'pages' => [1]
      ))

      job = SketchupHostJob.load(job_path)
      assert_equal :text, job[:text_mode]
      assert_equal File.join(dir, 'drawing-text.skp'), job[:model_path]
    end
  end

  def test_text_to_exact_text3d_requires_observed_host_capability_proof
    proof = Fidelity.flat_editable_text_impossibility_proof(source_item)
    controller = Fidelity::FallbackController.new(:text, source_item.source_span_id)

    controller.advance!(proof)

    assert_equal :text3d, controller.current_mode
    assert_equal :text, proof[:requested_mode]
    assert_equal Digest::SHA256.hexdigest('WELD'),
                 proof[:evidence][:source_text_sha256]
    assert_equal [10.25, 20.5, 42.75, 31.0],
                 proof[:evidence][:source_bbox_pdf]
    assert_equal true, proof[:evidence][:entities_add_text_observed]
    assert_equal true, proof[:evidence][:sketchup_text_annotation_api_observed]
    assert_equal false,
                 proof[:evidence][:native_flat_editable_text_available]
    assert_equal [], proof[:created_entity_ids]
  end

  def test_text_capability_proof_rejects_bbox_or_digest_tampering
    proof = Fidelity.flat_editable_text_impossibility_proof(source_item)
    proof[:evidence][:source_bbox_pdf][0] = 999.0
    controller = Fidelity::FallbackController.new(:text, source_item.source_span_id)

    error = assert_raises(Fidelity::ContractError) do
      controller.advance!(proof)
    end
    assert_match(/digest|evidence/i, error.message)

    proof = Fidelity.flat_editable_text_impossibility_proof(source_item)
    proof[:evidence][:native_flat_editable_text_available] = true
    unsigned = proof[:evidence].dup
    unsigned.delete(:evidence_sha256)
    proof[:evidence][:evidence_sha256] = Fidelity.canonical_sha256(unsigned)
    controller = Fidelity::FallbackController.new(:text, source_item.source_span_id)
    assert_raises(Fidelity::ContractError) { controller.advance!(proof) }
  end

  def test_text_controller_refuses_unverifiable_label_transition
    proof = Fidelity.flat_editable_text_impossibility_proof(source_item)
    proof[:to_mode] = :labels
    controller = Fidelity::FallbackController.new(:text, source_item.source_span_id)

    assert_raises(Fidelity::ContractError) { controller.advance!(proof) }
  end

  def test_active_guidance_preserves_six_modes_and_exact_finite_ladders
    active_guidance = [
      'README.md',
      'AGENTS.md',
      'HOST_COMPATIBILITY.md',
      File.join('.cursor', 'rules', 'text-mode-fidelity.mdc')
    ]
    ladders = [
      'Text → 3D Text → Glyphs → Geometry → item Raster',
      'Labels → 3D Text → Glyphs → Geometry → item Raster',
      '3D Text → Glyphs → Geometry → item Raster',
      'Glyphs → Geometry → item Raster',
      'Geometry → item Raster'
    ]

    active_guidance.each do |relative_path|
      body = File.read(File.join(REPO_ROOT, relative_path), :encoding => 'UTF-8')
      normalized = body.gsub(/\s+/, ' ')
      ladders.each do |ladder|
        assert_includes normalized, ladder, "#{relative_path} omits #{ladder}"
      end
      assert_includes normalized, 'Raster has no next rung'
      assert_match(/Terminal Raster can still fail verification/i, normalized)
    end

    readme = File.read(File.join(REPO_ROOT, 'README.md'), :encoding => 'UTF-8')
    assert_includes readme, '6 Text Rendering Options'
    refute_includes readme, '4 Text Rendering Options'
    refute_includes readme, 'Requested Raster renders all selected pages directly'

    checklist = File.read(
      File.join(REPO_ROOT, 'HUMAN_CONFIRMATION.md'), :encoding => 'UTF-8'
    )
    ['Text', 'Labels', '3D Text', 'Glyphs', 'Geometry', 'Raster'].each do |mode|
      assert_match(/\*\*#{Regexp.escape(mode)}\*\*/, checklist)
    end
  end
end
