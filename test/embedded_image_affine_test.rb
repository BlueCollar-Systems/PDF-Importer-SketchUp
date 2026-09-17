require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/embedded_image_placement'

class EmbeddedImageAffineTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::EmbeddedImagePlacement
  UNIT = [[0, 0], [1, 0], [1, 1], [0, 1]].freeze

  def pdf_point(matrix, u, v)
    [matrix[0] * u + matrix[2] * v + matrix[4],
     matrix[1] * u + matrix[3] * v + matrix[5]]
  end

  def mapped(matrix, point)
    [matrix[0] * point[0] + matrix[4] * point[1] + matrix[12],
     matrix[1] * point[0] + matrix[5] * point[1] + matrix[13],
     matrix[2] * point[0] + matrix[6] * point[1] + matrix[14]]
  end

  def test_asymmetric_corner_and_pixel_positions_preserve_every_affine_direction
    # Unequal width/height and off-center pixels detect a wrong Y flip or an
    # axis-aligned-bounds substitute even when the enclosing rectangle matches.
    ctms = [[144, 0, 0, 72, 55, 91], [144, 0, 0, -72, 55, 91],
            [-144, 0, 0, 72, 55, 91], [-144, 0, 0, -72, 55, 91],
            [0, 144, -72, 0, 55, 91], [144, 31, 19, 72, 55, 91],
            [-144, 31, 19, 72, 55, 91]]
    box = [11, 23, 731, 383]
    ctms.each do |ctm|
      corners = UNIT.map { |uv| pdf_point(ctm, *uv) }
      [0, 90, 180, 270].each do |rotation|
        plan = Subject.affine(corners, box, 2.5, -17, rotation)
        (UNIT + [[0.17, 0.81], [0.74, 0.23]]).each do |uv|
          x, y = pdf_point(ctm, *uv)
          x -= 11; y -= 23
          displayed = case rotation
                      when 90 then [y, 720 - x]
                      when 180 then [720 - x, 360 - y]
                      when 270 then [360 - y, x]
                      else [x, y]
                      end
          expected = [displayed[0] * 2.5 / 72, displayed[1] * 2.5 / 72 - 17, 0]
          mapped(plan[:matrix], uv).zip(expected).each { |a, b| assert_in_delta b, a, 1.0e-12 }
        end
      end
    end
  end

  def test_negative_y_image_keeps_decoded_top_row_on_source_negative_y_side
    corners = UNIT.map { |uv| pdf_point([144, 0, 0, -72, 300, 200], *uv) }
    plan = Subject.affine(corners, [0, 0, 720, 360], 1, 0, 0)
    assert_operator mapped(plan[:matrix], [0, 1])[1], :<, mapped(plan[:matrix], [0, 0])[1]
    assert_equal corners, UNIT.map { |uv| pdf_point([144, 0, 0, -72, 300, 200], *uv) }
  end

  def test_rejects_invalid_affine_instead_of_using_a_bbox
    corners = [[0, 0], [100, 0], [100, 50], [0, 50]]
    bad = corners.map(&:dup); bad[2][0] += 0.01
    assert_raises(ArgumentError) { Subject.affine(bad, [0, 0, 720, 360], 1, 0, 0) }
    assert_raises(ArgumentError) { Subject.affine(corners.first(3), [0, 0, 720, 360], 1, 0, 0) }
    assert_raises(ArgumentError) { Subject.affine(corners, [0, 0, 720, 360], Float::NAN, 0, 0) }
    assert_raises(ArgumentError) { Subject.affine(corners, [0, 0, 720, 360], 0, 0, 0) }
    assert_raises(ArgumentError) { Subject.affine([[0,0],[1,0],[2,0],[1,0]], [0,0,720,360], 1, 0, 0) }
  end

  def test_native_transform_comparison_detects_missing_reflection
    plan = Subject.affine([[0,0],[2,0],[2,-1],[0,-1]], [0,0,720,360], 1, 0, 0)
    assert Subject.same_matrix?(plan[:matrix], plan[:matrix].dup)
    lost = plan[:matrix].dup; lost[5] = lost[5].abs
    refute Subject.same_matrix?(lost, plan[:matrix])
  end
end
