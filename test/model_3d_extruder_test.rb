#!/usr/bin/env ruby

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/model_3d_extruder'

BlueCollarSystems::PDFVectorImporter::Logger.debug = false
M3D = BlueCollarSystems::PDFVectorImporter::Model3DExtruder

class Model3DExtruderTest < Minitest::Test
  def test_default_depth_scales_with_import_scale
    depth = M3D.resolve_depth_inches(scale: 2.0)
    expected = M3D::DEFAULT_DEPTH_MM * M3D::MM_TO_INCH * 2.0
    assert_in_delta expected, depth, 1.0e-6
  end

  def test_explicit_depth_mm_overrides_default
    depth = M3D.resolve_depth_inches(extrude_depth_mm: 10.0, scale: 48.0)
    assert_in_delta 10.0 * M3D::MM_TO_INCH, depth, 1.0e-6
  end

  def test_disabled_payload
    payload = M3D.disabled_payload('option_off')
    refute payload[:enabled]
    assert_equal 0, payload[:faces_extruded]
    assert_equal 'option_off', payload[:skipped_reason]
  end

  def test_report_payload_when_enabled
    payload = M3D.build_report_payload(true, 3.175, 12, nil)
    assert payload[:enabled]
    assert_equal 12, payload[:faces_extruded]
    assert_in_delta 3.175, payload[:depth_mm], 1.0e-4
    refute payload.key?(:skipped_reason)
  end

  def test_extrude_imported_without_model_returns_no_model
    payload = M3D.extrude_imported(nil, [], extrude_to_3d: true)
    refute payload[:enabled]
    assert_equal 'no_model', payload[:skipped_reason]
  end
end
