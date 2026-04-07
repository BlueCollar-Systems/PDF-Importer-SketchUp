# bc_pdf_vector_importer/hatch_detector.rb
# Detects hatching patterns: dense clusters of parallel lines
# at regular spacing within bounded regions.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module HatchDetector

      # Minimum lines to consider a cluster as hatching
      MIN_HATCH_LINES = 6
      # Angle tolerance for "parallel" (degrees)
      ANGLE_TOL_DEG = 3.0
      # Spacing regularity tolerance (ratio: std_dev / mean)
      SPACING_REGULARITY = 0.35

      # ---------------------------------------------------------------
      # Detect hatch patterns in a list of primitives.
      # Returns array of primitive indices that are hatching.
      # ---------------------------------------------------------------
      def self.detect(primitives)
        return [] if primitives.nil? || primitives.empty?

        # Extract line segments with their angles
        lines = []
        primitives.each_with_index do |prim, idx|
          next unless prim.respond_to?(:points) && prim.points
          pts = prim.points
          next unless pts.length == 2

          x0, y0 = pts[0][0].to_f, pts[0][1].to_f
          x1, y1 = pts[1][0].to_f, pts[1][1].to_f
          dx = x1 - x0; dy = y1 - y0
          len = Math.sqrt(dx * dx + dy * dy)
          next if len < 0.5  # skip micro-segments

          # Normalize angle to 0-180 range
          angle = Math.atan2(dy, dx) * 180.0 / Math::PI
          angle += 180.0 if angle < 0

          # Midpoint for spacing calculation
          mx = (x0 + x1) / 2.0
          my = (y0 + y1) / 2.0

          lines << { idx: idx, angle: angle, len: len, mx: mx, my: my,
                     x0: x0, y0: y0, x1: x1, y1: y1 }
        end

        return [] if lines.length < MIN_HATCH_LINES

        hatch_indices = []

        # Group by angle (parallel lines)
        angle_groups = group_by_angle(lines, ANGLE_TOL_DEG)

        angle_groups.each do |group|
          next if group.length < MIN_HATCH_LINES

          # For each angle group, check if lines are regularly spaced
          # Project midpoints onto the perpendicular axis
          ref_angle = group.first[:angle] * Math::PI / 180.0
          perp_x = -Math.sin(ref_angle)
          perp_y = Math.cos(ref_angle)

          # Project each line's midpoint onto perpendicular axis
          projections = group.map { |l|
            { proj: l[:mx] * perp_x + l[:my] * perp_y, line: l }
          }.sort_by { |p| p[:proj] }

          # Check for regular spacing
          spacings = []
          (1...projections.length).each do |i|
            spacings << (projections[i][:proj] - projections[i - 1][:proj]).abs
          end

          next if spacings.empty?

          mean = spacings.inject(0.0, :+) / spacings.length
          next if mean < 0.3  # too tight — probably not hatching

          variance = spacings.inject(0.0) { |s, v| s + (v - mean) ** 2 } / spacings.length
          std_dev = Math.sqrt(variance)

          # Regular spacing = low coefficient of variation
          if mean > 0 && (std_dev / mean) < SPACING_REGULARITY
            # Also check that lines have similar lengths
            lengths = group.map { |l| l[:len] }
            mean_len = lengths.inject(0.0, :+) / lengths.length
            len_var = lengths.inject(0.0) { |s, v| s + (v - mean_len) ** 2 } / lengths.length
            len_cv = mean_len > 0 ? Math.sqrt(len_var) / mean_len : 1.0

            if len_cv < 0.5  # lengths are reasonably uniform
              group.each { |l| hatch_indices << l[:idx] }
            end
          end
        end

        hatch_indices.uniq.sort
      end

      private

      # Group lines by angle within tolerance
      def self.group_by_angle(lines, tol)
        groups = []
        used = Array.new(lines.length, false)

        lines.each_with_index do |line, i|
          next if used[i]
          group = [line]
          used[i] = true

          lines.each_with_index do |other, j|
            next if i == j || used[j]
            if angle_diff(line[:angle], other[:angle]) < tol
              group << other
              used[j] = true
            end
          end

          groups << group if group.length >= MIN_HATCH_LINES
        end

        groups
      end

      # Angular difference accounting for 0/180 wrap
      def self.angle_diff(a, b)
        d = (a - b).abs
        d = 180.0 - d if d > 90.0
        d
      end

    end
  end
end
