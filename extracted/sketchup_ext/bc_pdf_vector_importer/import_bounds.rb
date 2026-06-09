# import_bounds.rb — Shared import bounding boxes for autofit (Ruby parity with pdfcadcore).
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module ImportBounds
      DEFAULT_PADDING_FRACTION = 0.02
      DEFAULT_MIN_PADDING_MM = 1.0
      MM_TO_INCHES = 1.0 / 25.4

      module_function

      def padded_fit_corners(x0, y0, x1, y1, scale = 1.0)
        s = scale.to_f
        s = 1.0 if s <= 0.0
        span = [(x1 - x0).abs, (y1 - y0).abs].max
        min_pad = DEFAULT_MIN_PADDING_MM * MM_TO_INCHES * s
        pad = [span * DEFAULT_PADDING_FRACTION, min_pad].max
        [x0 - pad, y0 - pad, x1 + pad, y1 + pad]
      end

      def add_padded_corners_to_bb(target_bb, x0, y0, x1, y1, scale = 1.0)
        return unless target_bb
        px0, py0, px1, py1 = padded_fit_corners(x0, y0, x1, y1, scale)
        target_bb.add(Geom::Point3d.new(px0, py0, 0.0))
        target_bb.add(Geom::Point3d.new(px1, py1, 0.0))
      end
    end
  end
end
