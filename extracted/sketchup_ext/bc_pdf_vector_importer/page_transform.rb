# bc_pdf_vector_importer/page_transform.rb
# Shared conversion from raw PDF page coordinates to displayed page space.
#
# PDF drawing sets often store landscape sheets as portrait MediaBox pages with
# /Rotate set. SketchUp import geometry must match the displayed sheet, not the
# unrotated storage box.

module BlueCollarSystems
  module PDFVectorImporter
    module PageTransform
      module_function

      def normalize_rotation(raw)
        rot = raw.to_i % 360
        [0, 90, 180, 270].include?(rot) ? rot : 0
      rescue StandardError
        0
      end

      def box_width(box)
        return 0.0 unless valid_box?(box)
        (box[2].to_f - box[0].to_f).abs
      end

      def box_height(box)
        return 0.0 unless valid_box?(box)
        (box[3].to_f - box[1].to_f).abs
      end

      def effective_width(box, rotation)
        rot = normalize_rotation(rotation)
        rot == 90 || rot == 270 ? box_height(box) : box_width(box)
      end

      def effective_height(box, rotation)
        rot = normalize_rotation(rotation)
        rot == 90 || rot == 270 ? box_width(box) : box_height(box)
      end

      def effective_box(box, rotation)
        [0.0, 0.0, effective_width(box, rotation), effective_height(box, rotation)]
      end

      def transform_point(x, y, box, rotation)
        return [x.to_f, y.to_f] unless valid_box?(box)

        min_x = box[0].to_f
        min_y = box[1].to_f
        w = box_width(box)
        h = box_height(box)
        lx = x.to_f - min_x
        ly = y.to_f - min_y

        case normalize_rotation(rotation)
        when 90
          [ly, w - lx]
        when 180
          [w - lx, h - ly]
        when 270
          [h - ly, lx]
        else
          [lx, ly]
        end
      rescue StandardError
        [x.to_f, y.to_f]
      end

      def transform_bbox(x0, y0, x1, y1, box, rotation)
        pts = [
          transform_point(x0, y0, box, rotation),
          transform_point(x0, y1, box, rotation),
          transform_point(x1, y0, box, rotation),
          transform_point(x1, y1, box, rotation)
        ]
        xs = pts.map { |pt| pt[0] }
        ys = pts.map { |pt| pt[1] }
        [xs.min, ys.min, xs.max, ys.max]
      end

      def transform_angle(angle_deg, rotation)
        angle = angle_deg.to_f
        angle += case normalize_rotation(rotation)
                 when 90 then -90.0
                 when 180 then 180.0
                 when 270 then 90.0
                 else 0.0
                 end
        normalize_angle(angle)
      rescue StandardError
        0.0
      end

      def normalize_angle(angle_deg)
        angle = angle_deg.to_f
        angle += 180.0 while angle <= -90.0
        angle -= 180.0 while angle > 90.0
        angle
      rescue StandardError
        0.0
      end

      def valid_box?(box)
        box.is_a?(Array) && box.length >= 4
      end
    end
  end
end
