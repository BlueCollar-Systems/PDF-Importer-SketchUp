# bc_pdf_vector_importer/bezier.rb
# Bézier curve utilities for approximating cubic Bézier curves
# as polyline segments suitable for SketchUp edges.
#
# Uses adaptive subdivision for accuracy: subdivides more in
# areas of high curvature, less in straight sections.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module Bezier

      # ---------------------------------------------------------------
      # Approximate a cubic Bézier curve as a polyline.
      #
      # p0, p1, p2, p3 are [x, y] control points.
      # max_segments: maximum number of line segments (quality cap)
      # tolerance: flatness tolerance for adaptive subdivision
      #
      # Returns array of [x, y] points (including p0 and p3).
      # ---------------------------------------------------------------
      def self.cubic_to_points(p0, p1, p2, p3, max_segments: 16, tolerance: 0.5)
        points = [p0]
        adaptive_subdivide(p0, p1, p2, p3, points, 0, max_segments, tolerance)
        points << p3
        points
      end

      # ---------------------------------------------------------------
      # Uniform subdivision (fallback / simple mode)
      # ---------------------------------------------------------------
      def self.cubic_uniform(p0, p1, p2, p3, segments: 12)
        points = []
        (0..segments).each do |i|
          t = i.to_f / segments
          points << evaluate_cubic(p0, p1, p2, p3, t)
        end
        points
      end

      # ---------------------------------------------------------------
      # Evaluate cubic Bézier at parameter t
      # ---------------------------------------------------------------
      def self.evaluate_cubic(p0, p1, p2, p3, t)
        t2 = t * t
        t3 = t2 * t
        mt = 1.0 - t
        mt2 = mt * mt
        mt3 = mt2 * mt

        x = mt3 * p0[0] + 3 * mt2 * t * p1[0] + 3 * mt * t2 * p2[0] + t3 * p3[0]
        y = mt3 * p0[1] + 3 * mt2 * t * p1[1] + 3 * mt * t2 * p2[1] + t3 * p3[1]
        [x, y]
      end

      private

      # ---------------------------------------------------------------
      # Adaptive subdivision using flatness test
      # ---------------------------------------------------------------
      def self.adaptive_subdivide(p0, p1, p2, p3, points, depth, max_depth, tolerance)
        if depth >= max_depth || is_flat_enough?(p0, p1, p2, p3, tolerance)
          return
        end

        # De Casteljau split at t = 0.5
        q0, q1, q2, q3, r0, r1, r2, r3 = split_cubic(p0, p1, p2, p3, 0.5)

        adaptive_subdivide(q0, q1, q2, q3, points, depth + 1, max_depth, tolerance)
        points << q3  # midpoint
        adaptive_subdivide(r0, r1, r2, r3, points, depth + 1, max_depth, tolerance)
      end

      # ---------------------------------------------------------------
      # Flatness test — checks if control points are close to the
      # chord from p0 to p3
      # ---------------------------------------------------------------
      def self.is_flat_enough?(p0, p1, p2, p3, tolerance)
        # Use the maximum distance of control points from the chord
        ux = 3.0 * p1[0] - 2.0 * p0[0] - p3[0]
        uy = 3.0 * p1[1] - 2.0 * p0[1] - p3[1]
        vx = 3.0 * p2[0] - 2.0 * p3[0] - p0[0]
        vy = 3.0 * p2[1] - 2.0 * p3[1] - p0[1]

        ux = ux * ux
        uy = uy * uy
        vx = vx * vx
        vy = vy * vy

        ux = vx if vx > ux
        uy = vy if vy > uy

        (ux + uy) <= (16.0 * tolerance * tolerance)
      end

      # ---------------------------------------------------------------
      # De Casteljau split of cubic Bézier at parameter t
      # Returns two sets of 4 control points: left curve and right curve
      # ---------------------------------------------------------------
      def self.split_cubic(p0, p1, p2, p3, t)
        mt = 1.0 - t

        # First level
        q0 = [mt * p0[0] + t * p1[0], mt * p0[1] + t * p1[1]]
        q1 = [mt * p1[0] + t * p2[0], mt * p1[1] + t * p2[1]]
        q2 = [mt * p2[0] + t * p3[0], mt * p2[1] + t * p3[1]]

        # Second level
        r0 = [mt * q0[0] + t * q1[0], mt * q0[1] + t * q1[1]]
        r1 = [mt * q1[0] + t * q2[0], mt * q1[1] + t * q2[1]]

        # Third level — the split point
        s = [mt * r0[0] + t * r1[0], mt * r0[1] + t * r1[1]]

        # Left curve: p0, q0, r0, s
        # Right curve: s, r1, q2, p3
        [p0, q0, r0, s, s, r1, q2, p3]
      end

      # ---------------------------------------------------------------
      # Arc approximation: detect if a Bézier is a circular arc
      # and return center/radius/angles if so.
      # Returns nil if not a recognizable arc.
      # ---------------------------------------------------------------
      def self.detect_arc(p0, p1, p2, p3, tolerance: 1.0)
        # Sample points along the curve
        samples = (0..8).map { |i| evaluate_cubic(p0, p1, p2, p3, i / 8.0) }

        # Try to fit a circle through first, middle, and last points
        pa = samples[0]
        pb = samples[4]
        pc = samples[8]

        center = circle_center(pa, pb, pc)
        return nil unless center

        radius = Math.sqrt((pa[0] - center[0])**2 + (pa[1] - center[1])**2)
        return nil if radius < 0.001 || radius > 1e6

        # Check if all sampled points are on this circle within tolerance
        max_err = 0
        samples.each do |pt|
          dist = Math.sqrt((pt[0] - center[0])**2 + (pt[1] - center[1])**2)
          err = (dist - radius).abs
          max_err = err if err > max_err
        end

        return nil if max_err > tolerance

        # Calculate start and end angles
        start_angle = Math.atan2(pa[1] - center[1], pa[0] - center[0])
        end_angle   = Math.atan2(pc[1] - center[1], pc[0] - center[0])

        {
          center: center,
          radius: radius,
          start_angle: start_angle,
          end_angle: end_angle
        }
      end

      # ---------------------------------------------------------------
      # Find circumcenter of three points (circle through 3 points)
      # ---------------------------------------------------------------
      def self.circle_center(a, b, c)
        ax, ay = a[0], a[1]
        bx, by = b[0], b[1]
        cx, cy = c[0], c[1]

        d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        return nil if d.abs < 1e-10

        ux = ((ax * ax + ay * ay) * (by - cy) +
              (bx * bx + by * by) * (cy - ay) +
              (cx * cx + cy * cy) * (ay - by)) / d

        uy = ((ax * ax + ay * ay) * (cx - bx) +
              (bx * bx + by * by) * (ax - cx) +
              (cx * cx + cy * cy) * (bx - ax)) / d

        [ux, uy]
      end

    end
  end
end
