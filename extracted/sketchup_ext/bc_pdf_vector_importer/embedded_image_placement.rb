# Preserve the PDF image unit square, including reflection and shear.
# Pixel rows remain untouched: PDF CTM direction is part of image placement.
require_relative 'page_transform'

module BlueCollarSystems
  module PDFVectorImporter
    module EmbeddedImagePlacement
      module_function

      def affine(corners, media_box, scale, y_offset, rotation)
        unless corners.is_a?(Array) && corners.length == 4 &&
               corners.all? { |p| p.is_a?(Array) && p.length >= 2 }
          raise ArgumentError, 'embedded image requires four ordered PDF corners'
        end
        raw = corners.map { |p| p.first(2).map { |n| finite(n) } }
        box = Array(media_box).map { |n| finite(n) }
        unless box.length == 4 && box[2] > box[0] && box[3] > box[1]
          raise ArgumentError, 'embedded image page box is invalid'
        end
        factor = finite(scale) / 72.0
        raise ArgumentError, 'embedded image scale must be positive' unless factor > 0.0
        offset = finite(y_offset)
        points = raw.map do |p|
          x, y = PageTransform.transform_point(p[0], p[1], box, rotation)
          [finite(x * factor), finite(y * factor + offset), 0.0]
        end
        origin = points[0]
        x_axis = 3.times.map { |i| points[1][i] - origin[i] }
        y_axis = 3.times.map { |i| points[3][i] - origin[i] }
        tolerance = [points.flatten.map { |n| n.abs }.max, 1.0].max * Float::EPSILON * 64.0
        unless 3.times.all? { |i| (points[2][i] - origin[i] - x_axis[i] - y_axis[i]).abs <= tolerance }
          raise ArgumentError, 'embedded image corners are not one affine unit square'
        end
        determinant = x_axis[0] * y_axis[1] - x_axis[1] * y_axis[0]
        unless determinant.finite? && determinant != 0.0
          raise ArgumentError, 'embedded image placement is singular'
        end
        {
          :corners => points,
          :matrix => x_axis + [0.0] + y_axis + [0.0] +
                     [0.0, 0.0, determinant < 0.0 ? -1.0 : 1.0, 0.0] + origin + [1.0]
        }
      end

      def finite(value)
        number = Float(value)
        raise ArgumentError, 'embedded image placement is not finite' unless number.finite?
        number
      end

      def same_matrix?(actual, expected)
        return false unless actual.is_a?(Array) && expected.is_a?(Array) &&
                            actual.length == 16 && expected.length == 16
        actual.zip(expected).all? do |a, b|
          a = finite(a)
          b = finite(b)
          (a - b).abs <= [a.abs, b.abs, 1.0].max * Float::EPSILON * 64.0
        end
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
