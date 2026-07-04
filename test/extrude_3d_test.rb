#!/usr/bin/env ruby
# test/extrude_3d_test.rb
#
# Regression tests for Extrude3D module.
# Runs outside the SketchUp runtime using lightweight mock objects that
# satisfy the duck-type contract used by Extrude3D.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT  = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/extrude_3d'

BlueCollarSystems::PDFVectorImporter::Logger.debug = false

E3D = BlueCollarSystems::PDFVectorImporter::Extrude3D

# ── Mock helpers ──────────────────────────────────────────────────────────────

MockVector = Struct.new(:z)

class MockFace
  attr_reader :pushpull_calls, :area

  def initialize(normal_z: 1.0, area: 1.0, fail_pushpull: false)
    @normal      = MockVector.new(normal_z)
    @area        = area
    @fail_pushpull = fail_pushpull
    @pushpull_calls = []
  end

  def normal   = @normal
  def pushpull(depth)
    raise 'mock pushpull error' if @fail_pushpull
    @pushpull_calls << depth
  end

  # Make Extrude3D#face_instance? recognise this as a face via duck-type.
  def respond_to?(sym, *rest)
    %i[pushpull normal area].include?(sym) || super
  end
end

class MockGroup
  def initialize(faces)
    @faces = faces
  end
  def each(&block)  = @faces.each(&block)
  def class = MockGroupClass
end

MockGroupClass = Struct.new(:name) { def name = 'MockGroup' }

# ── Tests ─────────────────────────────────────────────────────────────────────

class Extrude3DTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # eligible?
  # ---------------------------------------------------------------------------

  def test_eligible_flat_face_above_min_area
    face = MockFace.new(normal_z: 1.0, area: 0.5)
    assert E3D.eligible?(face)
  end

  def test_eligible_inverted_normal_also_passes
    # Face reversed by geometry_builder (face.reverse!) still has |z|=1
    face = MockFace.new(normal_z: -1.0, area: 0.5)
    assert E3D.eligible?(face)
  end

  def test_not_eligible_angled_face
    face = MockFace.new(normal_z: 0.5, area: 0.5)
    refute E3D.eligible?(face)
  end

  def test_not_eligible_vertical_face
    face = MockFace.new(normal_z: 0.0, area: 0.5)
    refute E3D.eligible?(face)
  end

  def test_not_eligible_tiny_face_below_threshold
    face = MockFace.new(normal_z: 1.0, area: 0.001)
    refute E3D.eligible?(face, E3D::DEFAULT_MIN_AREA_SQIN)
  end

  def test_eligible_face_exactly_at_threshold
    # area == min_area: guard is strict `< min_area`, so == passes.
    face = MockFace.new(normal_z: 1.0, area: E3D::DEFAULT_MIN_AREA_SQIN)
    assert E3D.eligible?(face, E3D::DEFAULT_MIN_AREA_SQIN)
  end

  # ---------------------------------------------------------------------------
  # apply — zero depth skips everything
  # ---------------------------------------------------------------------------

  def test_apply_zero_depth_skips_all
    face = MockFace.new(normal_z: 1.0, area: 1.0)
    result = E3D.apply([face], 0.0)
    assert_equal 0, result[:faces_found]
    assert_equal 0, result[:faces_extruded]
    assert_equal 0, result[:faces_skipped]
    assert_empty face.pushpull_calls
  end

  def test_apply_negative_depth_skips_all
    face = MockFace.new(normal_z: 1.0, area: 1.0)
    result = E3D.apply([face], -5.0)
    assert_equal 0, result[:faces_extruded]
    assert_empty face.pushpull_calls
  end

  # ---------------------------------------------------------------------------
  # apply — single eligible face
  # ---------------------------------------------------------------------------

  def test_apply_single_face_extruded
    face = MockFace.new(normal_z: 1.0, area: 1.0)
    result = E3D.apply([face], 4.0)
    assert_equal 1, result[:faces_found]
    assert_equal 1, result[:faces_extruded]
    assert_equal 0, result[:faces_skipped]
    assert_equal [4.0], face.pushpull_calls
  end

  def test_apply_passes_correct_depth
    face = MockFace.new(normal_z: 1.0, area: 2.0)
    E3D.apply([face], 9.5)
    assert_equal 9.5, face.pushpull_calls.first
  end

  # ---------------------------------------------------------------------------
  # apply — mixed eligible / ineligible faces
  # ---------------------------------------------------------------------------

  def test_apply_skips_angled_face
    flat   = MockFace.new(normal_z: 1.0,  area: 1.0)
    angled = MockFace.new(normal_z: 0.3,  area: 1.0)
    result = E3D.apply([flat, angled], 4.0)
    assert_equal 2, result[:faces_found]
    assert_equal 1, result[:faces_extruded]
    assert_equal 1, result[:faces_skipped]
    assert_equal [4.0], flat.pushpull_calls
    assert_empty angled.pushpull_calls
  end

  def test_apply_skips_tiny_face
    large = MockFace.new(normal_z: 1.0, area: 1.0)
    tiny  = MockFace.new(normal_z: 1.0, area: 0.001)
    result = E3D.apply([large, tiny], 4.0)
    assert_equal 1, result[:faces_extruded]
    assert_equal 1, result[:faces_skipped]
  end

  # ---------------------------------------------------------------------------
  # apply — pushpull error is caught, face counted as skipped
  # ---------------------------------------------------------------------------

  def test_apply_pushpull_error_counted_as_skipped
    face = MockFace.new(normal_z: 1.0, area: 1.0, fail_pushpull: true)
    result = E3D.apply([face], 4.0)
    assert_equal 1, result[:faces_found]
    assert_equal 0, result[:faces_extruded]
    assert_equal 1, result[:faces_skipped]
  end

  # ---------------------------------------------------------------------------
  # apply — stats hash keys always present
  # ---------------------------------------------------------------------------

  def test_apply_returns_required_keys
    result = E3D.apply([], 4.0)
    assert result.key?(:faces_found)
    assert result.key?(:faces_extruded)
    assert result.key?(:faces_skipped)
  end

  # ---------------------------------------------------------------------------
  # collect_faces — flat list
  # ---------------------------------------------------------------------------

  def test_collect_faces_from_flat_list
    f1 = MockFace.new(normal_z: 1.0, area: 1.0)
    f2 = MockFace.new(normal_z: 1.0, area: 2.0)
    faces = E3D.collect_faces([f1, f2], false)
    assert_equal 2, faces.length
    assert_includes faces, f1
    assert_includes faces, f2
  end

  def test_collect_faces_ignores_non_face_objects
    face   = MockFace.new(normal_z: 1.0, area: 1.0)
    string = 'not a face'
    faces  = E3D.collect_faces([face, string], false)
    assert_equal 1, faces.length
    assert_includes faces, face
  end

  # ---------------------------------------------------------------------------
  # ImportConfig integration — extrude_depth attribute
  # ---------------------------------------------------------------------------

  def test_import_config_extrude_depth_default
    require 'bc_pdf_vector_importer/import_config'
    cfg = BlueCollarSystems::PDFVectorImporter::ImportConfig.new
    assert_equal 0.0, cfg.extrude_depth
  end

  def test_import_config_extrude_depth_set
    require 'bc_pdf_vector_importer/import_config'
    cfg = BlueCollarSystems::PDFVectorImporter::ImportConfig.new(extrude_depth: 4.0)
    assert_equal 4.0, cfg.extrude_depth
  end

  def test_import_config_to_raw_includes_extrude_depth
    require 'bc_pdf_vector_importer/import_config'
    require 'bc_pdf_vector_importer/import_dialog'
    cfg = BlueCollarSystems::PDFVectorImporter::ImportConfig.new(extrude_depth: 8.0)
    raw = cfg.to_raw
    assert raw.key?(:extrude_depth), 'to_raw must include :extrude_depth'
    assert_equal 8.0, raw[:extrude_depth]
  end

end
