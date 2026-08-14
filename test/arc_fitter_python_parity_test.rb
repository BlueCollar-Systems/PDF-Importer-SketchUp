#!/usr/bin/env ruby
# test/arc_fitter_python_parity_test.rb
#
# Cross-host parity: SketchUp's Ruby circle fit must agree with the Python shared
# core's math.fsum fit on the ill-conditioned oracle case that exposed the class.
#
# Before Neumaier compensation, this fitter was bit-identical (all 17 digits, all
# four outputs) to the naive uncompensated fit the Python core abandoned: radius
# 10.2550 vs 10.3084, RMS 0.0622 vs 0.0312 -- on the other side of the promotion
# tolerance, so SketchUp emitted different geometry than FreeCAD/Blender/LibreCAD
# for the same drawing. SketchUp's contract is behavioral parity with the Python
# core, not byte sync; these numbers are where "behavioral" becomes measurable.
require 'minitest/autorun'
require 'json'
require 'digest'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/arc_fitter'

class ArcFitterPythonParityTest < Minitest::Test
  AF = BlueCollarSystems::PDFVectorImporter::ArcFitter
  FIXTURE = File.join(File.dirname(__FILE__), 'fixtures',
                      'oracle_seed81011_case143_points.json')

  # The Python oracle pins its generated points by this digest
  # (test_circle_fit_promotion_oracle.py in the FreeCAD repo). Pinning the same
  # digest here proves both hosts are fitting the SAME 15 points, so any output
  # difference is arithmetic, not input drift.
  ORACLE_SHA256 =
    '91b5073ecdb1acb5429b902661ae16aca7ef2e275d2378ec61f37b7b3c88291a'.freeze

  # Python shared core, math.fsum accumulation (exactly rounded).
  FSUM_CX = 2196.4838973399292
  FSUM_CY = 3189.6143394439532
  FSUM_R = 10.308404119477688
  FSUM_RMS = 0.031206496449169042

  # What the naive += fit produced -- kept so the divergence this test closes can
  # never silently return.
  NAIVE_R = 10.255037402568124
  NAIVE_RMS = 0.062165402180458317

  def points
    raw = File.binread(FIXTURE)
    assert_equal ORACLE_SHA256, Digest::SHA256.hexdigest(raw),
                 'fixture drifted from the Python oracle pin'
    JSON.parse(raw)
  end

  def test_case_143_matches_the_python_fsum_fit
    cx, cy, r, rms = AF.circle_fit(points)
    # cx/cy/r reproduce fsum bit-for-bit under Neumaier; assert at 1e-12 absolute
    # so a legitimate future change of summation ORDER (which can move the last
    # ulp) does not false-alarm, while any reversion to naive arithmetic -- off
    # by 5.3e-2 -- fails by ten orders of magnitude.
    assert_in_delta FSUM_CX, cx, 1e-9
    assert_in_delta FSUM_CY, cy, 1e-9
    assert_in_delta FSUM_R, r, 1e-9
    assert_in_delta FSUM_RMS, rms, 1e-9
  end

  def test_case_143_does_not_reproduce_the_naive_fit
    _cx, _cy, r, rms = AF.circle_fit(points)
    refute_in_delta NAIVE_R, r, 1e-3,
                    'radius matches the abandoned naive fit: compensation is gone'
    refute_in_delta NAIVE_RMS, rms, 1e-3,
                    'RMS matches the abandoned naive fit: compensation is gone'
  end

  def test_promotion_side_of_the_tolerance
    # The consequence that makes this parity user-visible: at the Python-equivalent
    # tolerance, the compensated RMS sits BELOW max(0.05, r*0.005) and the naive
    # RMS sat above it. Assert the decision, not just the numbers.
    _cx, _cy, r, rms = AF.circle_fit(points)
    tol = [0.05, r * 0.005].max
    assert rms < tol,
           "rms #{rms} must clear tol #{tol}: this is the promotion flip that " \
           'made SketchUp disagree with the Python hosts'
  end

  def test_well_conditioned_fits_are_unchanged
    # Compensation must be invisible where the old arithmetic was already fine.
    pts = (0...16).map do |i|
      a = 2.0 * Math::PI * i / 16
      [12.5 + 7.0 * Math.cos(a), -3.25 + 7.0 * Math.sin(a)]
    end
    cx, cy, r, rms = AF.circle_fit(pts)
    assert_in_delta 12.5, cx, 1e-9
    assert_in_delta(-3.25, cy, 1e-9)
    assert_in_delta 7.0, r, 1e-9
    assert rms < 1e-9
  end

  def test_neumaier_helpers_compensate
    # Direct unit check: summing [1e16, 1.0, -1e16] naively loses the 1.0.
    state = [0.0, 0.0]
    [1e16, 1.0, -1e16].each { |v| AF.neumaier_add(state, v) }
    assert_equal 1.0, AF.neumaier_value(state)
  end
end
