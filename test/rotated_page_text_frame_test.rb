#!/usr/bin/env ruby
# External text on a /Rotate page must come back to unrotated PDF space.
#
# pdftotext DECLARES a rotated page in unrotated dimensions but emits word
# boxes in DISPLAYED ones. Measured on a 792x1224 /Rotate 90 sheet:
# <page width="792" height="1224"> while the word boxes span x 0..1170.8,
# y 0..773.0 - which fit 1224x792, the displayed box, and do not fit the
# declared one at all. Flipping against the declared height and then letting
# pdf_to_su rotate the result a second time put every text item on that sheet
# somewhere the geometry was not.
#
# All fixtures are fictional.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/page_transform'

PTX = BlueCollarSystems::PDFVectorImporter::PageTransform

class RotatedPageTextFrameTest < Minitest::Test
  PORTRAIT = [0.0, 0.0, 792.0, 1224.0].freeze
  OFFSET_BOX = [10.0, 20.0, 802.0, 1244.0].freeze

  # ── the inverse is exactly the inverse ──

  def test_round_trip_is_exact_for_every_rotation
    [0, 90, 180, 270].each do |rotation|
      [[10.0, 20.0], [291.0, 184.7], [792.0, 1224.0], [0.0, 0.0]].each do |x, y|
        fx, fy = PTX.transform_point(x, y, PORTRAIT, rotation)
        bx, by = PTX.inverse_transform_point(fx, fy, PORTRAIT, rotation)

        assert_in_delta x, bx, 1e-9, "rotation #{rotation} x"
        assert_in_delta y, by, 1e-9, "rotation #{rotation} y"
      end
    end
  end

  def test_round_trip_is_exact_when_the_box_origin_is_not_zero
    [0, 90, 180, 270].each do |rotation|
      fx, fy = PTX.transform_point(300.0, 400.0, OFFSET_BOX, rotation)
      bx, by = PTX.inverse_transform_point(fx, fy, OFFSET_BOX, rotation)

      assert_in_delta 300.0, bx, 1e-9
      assert_in_delta 400.0, by, 1e-9
    end
  end

  # ── the displayed box is the one pdftotext measures against ──

  def test_a_rotated_page_swaps_the_displayed_dimensions
    assert_equal 1224.0, PTX.effective_width(PORTRAIT, 90)
    assert_equal 792.0, PTX.effective_height(PORTRAIT, 90)
    assert_equal 792.0, PTX.effective_width(PORTRAIT, 0)
    assert_equal 1224.0, PTX.effective_height(PORTRAIT, 0)
  end

  def test_a_point_at_the_far_corner_of_the_displayed_page_is_inside_the_pdf_box
    # The corner pdftotext would report last on a /Rotate 90 sheet.
    x, y = PTX.inverse_transform_point(1224.0, 792.0, PORTRAIT, 90)

    assert_operator x, :>=, 0.0
    assert_operator x, :<=, 792.0
    assert_operator y, :>=, 0.0
    assert_operator y, :<=, 1224.0
  end

  # ── an unrotated page must not move at all ──

  def test_an_unrotated_page_is_untouched_by_either_direction
    [[0.0, 0.0], [55.7, 708.7], [612.0, 792.0]].each do |x, y|
      assert_equal [x, y], PTX.transform_point(x, y, PORTRAIT, 0)
      assert_equal [x, y], PTX.inverse_transform_point(x, y, PORTRAIT, 0)
    end
  end

  # ── nothing here may raise ──

  def test_a_malformed_box_returns_the_point_unchanged
    assert_equal [5.0, 6.0], PTX.inverse_transform_point(5.0, 6.0, nil, 90)
    assert_equal [5.0, 6.0], PTX.inverse_transform_point(5.0, 6.0, [1, 2], 90)
  end

  def test_an_unknown_rotation_is_treated_as_none
    assert_equal [7.0, 8.0], PTX.inverse_transform_point(7.0, 8.0, PORTRAIT, 45)
  end

  # ── the measured regression ──

  def test_the_measured_sheet_lands_inside_the_page_instead_of_432pt_outside
    # The real failure: y was flipped against the DECLARED height (1224) while
    # the word box was measured in a 792-tall displayed frame, so the item
    # landed 432pt out and was then rotated again.
    declared_height = 1224.0
    displayed_height = PTX.effective_height(PORTRAIT, 90)
    y_max = 293.2 # a word box from the measured sheet

    wrong = declared_height - y_max
    right = displayed_height - y_max

    assert_in_delta 432.0, wrong - right, 0.001, 'the error is the box difference'

    x, y = PTX.inverse_transform_point(151.1, right, PORTRAIT, 90)
    assert_operator x, :<=, 792.0, 'must sit inside the unrotated page width'
    assert_operator y, :<=, 1224.0, 'must sit inside the unrotated page height'
  end
end
