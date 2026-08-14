#!/usr/bin/env ruby
# test/arc_fitter_tolerance_floor_test.rb
#
# Pins the tolerance-floor parity change: SketchUp's arc promotion floor is now
# 0.05mm expressed in inches (0.05 / 25.4), matching the Python hosts' default
# arc_fit_tol_mm = 0.05 exactly. The previous floor, 0.003" (~0.0762mm), claimed
# in a geometry_builder comment to "match the Python importers' default" but was
# ~52% looser -- so for fitted radii below 15.24mm, SketchUp promoted borderline
# polylines to arcs that FreeCAD/Blender/LibreCAD left as polylines.
#
# The decisive fixture is an arc run whose whole-run RMS lands INSIDE the
# 0.05mm..0.0762mm band -- promoted under the old floor, rejected under the new
# one. The test measures the fixture's own RMS and asserts it is in the band, so
# the fixture cannot silently drift out of the region it exists to test.
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/arc_fitter'

class ArcFitterToleranceFloorTest < Minitest::Test
  AF = BlueCollarSystems::PDFVectorImporter::ArcFitter

  OLD_FLOOR = 0.003          # inches (~0.0762mm) -- the stale "matches Python" value
  NEW_FLOOR = 0.05 / 25.4    # inches (0.05mm)    -- the actual Python default

  # r = 0.2" (5.08mm): small enough that the FLOOR governs, not r*0.005
  # (r*0.005 = 0.001 < NEW_FLOOR), i.e. exactly the regime the change affects.
  def band_run
    r = 0.2
    n = 24
    (0...n).map do |i|
      angle = (Math::PI / 2.0) * i / (n - 1)
      # Deterministic radial jitter; amplitude chosen so whole-run RMS falls
      # between the two floors. sin(i * 2.7) has no period aligned with the arc.
      jitter = 0.0042 * Math.sin(i * 2.7)
      [(r + jitter) * Math.cos(angle), (r + jitter) * Math.sin(angle)]
    end
  end

  def test_fixture_rms_is_inside_the_band
    _cx, _cy, r, rms = AF.circle_fit(band_run)
    assert rms > NEW_FLOOR, "fixture RMS #{rms} fell below the new floor; it no " \
                            'longer tests the band this change closes'
    assert rms < OLD_FLOOR, "fixture RMS #{rms} rose above the old floor; it no " \
                            'longer tests the band this change closes'
    assert r * 0.005 < NEW_FLOOR, 'radius grew enough that r*0.005 governs, not the floor'
  end

  def test_band_run_promoted_under_the_old_floor
    segs = AF.detect_arcs_in_polyline(band_run, arc_fit_tol: OLD_FLOOR,
                                      min_arc_segments: 4, max_arc_segments: 64)
    arcs = segs.select { |s| s[:type] == :arc }
    refute_empty arcs, 'the old 0.003" floor should promote this borderline run -- ' \
                       'if it no longer does, the fixture is not in the band'
  end

  def test_band_run_rejected_under_the_python_equivalent_floor
    segs = AF.detect_arcs_in_polyline(band_run, arc_fit_tol: NEW_FLOOR,
                                      min_arc_segments: 4, max_arc_segments: 64)
    whole_arcs = segs.select { |s| s[:type] == :arc && s[:points].length >= 20 }
    assert_empty whole_arcs,
                 'the 0.05mm-equivalent floor must NOT promote the whole borderline ' \
                 'run: FreeCAD/Blender/LibreCAD leave it as a polyline, and this ' \
                 'floor exists so SketchUp agrees with them'
  end

  def test_default_floor_is_the_python_equivalent
    # Behavioral, not source-text: calling without arc_fit_tol must act exactly
    # like passing the Python-equivalent floor on the borderline run.
    explicit = AF.detect_arcs_in_polyline(band_run, arc_fit_tol: NEW_FLOOR,
                                          min_arc_segments: 4, max_arc_segments: 64)
    default = AF.detect_arcs_in_polyline(band_run,
                                         min_arc_segments: 4, max_arc_segments: 64)
    assert_equal explicit.map { |s| [s[:type], s[:points] ? s[:points].length : nil] },
                 default.map { |s| [s[:type], s[:points] ? s[:points].length : nil] },
                 'the default arc_fit_tol no longer equals the Python-equivalent floor'
  end

  def test_clean_arcs_still_promote_under_the_tighter_floor
    # The floor change must only affect the borderline band -- a clean arc has
    # RMS orders of magnitude below 0.05mm-equivalent and must keep promoting.
    r = 0.2
    clean = (0...24).map do |i|
      angle = (Math::PI / 2.0) * i / 23
      [r * Math.cos(angle), r * Math.sin(angle)]
    end
    segs = AF.detect_arcs_in_polyline(clean, arc_fit_tol: NEW_FLOOR,
                                      min_arc_segments: 4, max_arc_segments: 64)
    arcs = segs.select { |s| s[:type] == :arc }
    refute_empty arcs, 'a clean 90-degree arc must promote under the aligned floor'
  end

  def test_rms_equal_to_tol_promotes
    # Inequality parity: Python rejects on rms > tol, so rms == tol promotes.
    # Proven at the unit level against the gate itself rather than hunting a
    # float-exact fixture: the gate expression must be <=, not <.
    src = File.read(File.join(File.dirname(__FILE__), '..', 'extracted',
                              'sketchup_ext', 'bc_pdf_vector_importer',
                              'arc_fitter.rb'))
    assert_match(/rms <= tol/, src,
                 'promotion gate must be rms <= tol to mirror Python (rejects on rms > tol)')
    refute_match(/rms < tol(?!=)/, src,
                 'strict rms < tol survives somewhere; Python promotes at equality')
  end
end
