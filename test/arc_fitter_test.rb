# test/arc_fitter_test.rb
# Unit tests for ArcFitter circle fitting.
# Ruby 2.2 compatible — no &., #sum, #filter, #then, etc.

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/arc_fitter'

class ArcFitterTest < Minitest::Test

  AF = BlueCollarSystems::PDFVectorImporter::ArcFitter

  # ------------------------------------------------------------------
  # Helper: generate N points on a circle centered at (cx, cy) with
  # radius r, evenly spaced from angle a0 to a1 (radians).
  # ------------------------------------------------------------------
  def circle_points(cx, cy, r, n, a0 = 0.0, a1 = 2.0 * Math::PI)
    step = (a1 - a0) / n.to_f
    (0...n).map do |i|
      angle = a0 + i * step
      [cx + r * Math.cos(angle), cy + r * Math.sin(angle)]
    end
  end

  # ------------------------------------------------------------------
  # Kasa fit on 4 points of a unit circle at the origin.
  # ------------------------------------------------------------------
  def test_unit_circle_four_points
    pts = circle_points(0.0, 0.0, 1.0, 4)
    cx, cy, r, rms = AF.circle_fit(pts)

    assert_in_delta 0.0, cx,  1e-6, "center x should be ~0"
    assert_in_delta 0.0, cy,  1e-6, "center y should be ~0"
    assert_in_delta 1.0, r,   1e-6, "radius should be ~1"
    assert rms < 1e-6, "RMS error should be negligible"
  end

  # ------------------------------------------------------------------
  # Minimum 3 points — equilateral triangle on circle r=5 at (3, 4).
  # ------------------------------------------------------------------
  def test_three_points_minimum
    pts = circle_points(3.0, 4.0, 5.0, 3)
    cx, cy, r, rms = AF.circle_fit(pts)

    assert_in_delta 3.0, cx,  1e-4, "center x should be ~3"
    assert_in_delta 4.0, cy,  1e-4, "center y should be ~4"
    assert_in_delta 5.0, r,   1e-4, "radius should be ~5"
    assert rms < 1e-4, "RMS error should be small"
  end

  # ------------------------------------------------------------------
  # Many points (12) on a large circle — should still fit well.
  # ------------------------------------------------------------------
  def test_twelve_points_large_circle
    pts = circle_points(100.0, -50.0, 200.0, 12)
    cx, cy, r, rms = AF.circle_fit(pts)

    assert_in_delta 100.0,  cx, 1e-3
    assert_in_delta(-50.0,  cy, 1e-3)
    assert_in_delta 200.0,  r,  1e-3
    assert rms < 1e-3
  end

  # ------------------------------------------------------------------
  # Collinear points — the determinant should be ~0 and fit returns nil.
  # ------------------------------------------------------------------
  def test_collinear_points_returns_nil
    pts = [[0.0, 0.0], [1.0, 1.0], [2.0, 2.0], [3.0, 3.0]]
    result = AF.circle_fit(pts)
    assert_nil result, "Collinear points should return nil"
  end

  # ------------------------------------------------------------------
  # Very large coordinates (> 100 000) — numeric stability.
  # ------------------------------------------------------------------
  def test_large_coordinates
    cx_exp = 150000.0
    cy_exp = 200000.0
    r_exp  = 500.0
    pts = circle_points(cx_exp, cy_exp, r_exp, 8)
    cx, cy, r, rms = AF.circle_fit(pts)

    # Kasa fit is fast but not numerically perfect at very large coordinates.
    # Keep this test tolerant enough to avoid false negatives across runtimes.
    assert_in_delta cx_exp, cx, 2.0, "center x with large coords"
    assert_in_delta cy_exp, cy, 2.0, "center y with large coords"
    assert_in_delta r_exp,  r,  2.0, "radius with large coords"
    assert rms < 2.0, "RMS should remain reasonably small with large coords"
  end

  # ------------------------------------------------------------------
  # Fewer than 3 points raises an error.
  # ------------------------------------------------------------------
  def test_fewer_than_three_points_raises
    assert_raises(RuntimeError) { AF.circle_fit([[0, 0], [1, 1]]) }
  end

  # ------------------------------------------------------------------
  # detect_arcs_in_polyline returns line segments for a straight run.
  # ------------------------------------------------------------------
  def test_detect_arcs_straight_line
    pts = (0..5).map { |i| [i.to_f, 0.0] }
    result = AF.detect_arcs_in_polyline(pts)
    result.each do |seg|
      assert_equal :line, seg[:type], "Straight run should yield only :line"
    end
  end

end
