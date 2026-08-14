# bc_pdf_vector_importer/arc_fitter.rb
# Arc reconstruction from polyline segments using Kåsa algebraic circle fit.
# Detects runs of line segments that form circular arcs and replaces them
# with true arc representations for SketchUp.
#
# Matches the FreeCAD version's _circle_fit and _polyline_edges_to_arcs.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module ArcFitter

      ZERO_TOL = 1e-9

      # ---------------------------------------------------------------
      # Kåsa algebraic circle fit — fits a circle to N >= 3 points.
      # Returns [center_x, center_y, radius, rms_error]
      # ---------------------------------------------------------------
      def self.circle_fit(points)
        n = points.length
        raise "Need >= 3 points" if n < 3

        # Neumaier-compensated accumulation, NOT plain +=. The Python shared core
        # uses math.fsum here (exactly rounded); Ruby Float summation is always
        # naive, and on ill-conditioned fits the difference is host-visible: on
        # oracle case 143 (a 163-degree arc, r~10, points centred ~4,000 units
        # away) the naive fit is off by 5.3e-2 in radius and its RMS lands on the
        # other side of the promotion tolerance, so SketchUp emitted different
        # geometry than FreeCAD/Blender/LibreCAD for the same drawing. Neumaier
        # reproduces the fsum radius bit-for-bit on that case, which meets the
        # behavioral-parity bar this port is held to.
        sx  = [0.0, 0.0]; sy  = [0.0, 0.0]; sx2 = [0.0, 0.0]; sy2 = [0.0, 0.0]
        sxy = [0.0, 0.0]; sz  = [0.0, 0.0]; sxz = [0.0, 0.0]; syz = [0.0, 0.0]

        points.each do |pt|
          x, y = pt[0].to_f, pt[1].to_f
          x2 = x * x
          y2 = y * y
          neumaier_add(sx, x);       neumaier_add(sy, y)
          neumaier_add(sx2, x2);     neumaier_add(sy2, y2)
          neumaier_add(sxy, x * y)
          z = x2 + y2
          neumaier_add(sz, z)
          neumaier_add(sxz, x * z)
          neumaier_add(syz, y * z)
        end
        sx = neumaier_value(sx);   sy = neumaier_value(sy)
        sx2 = neumaier_value(sx2); sy2 = neumaier_value(sy2)
        sxy = neumaier_value(sxy); sz = neumaier_value(sz)
        sxz = neumaier_value(sxz); syz = neumaier_value(syz)

        # Solve 3×3 system via Cramer's rule
        a = [[sx, sy, n.to_f], [sx2, sxy, sx], [sxy, sy2, sy]]
        b = [sz, sxz, syz]

        d = det3(a)
        return nil if d.abs < 1e-12

        a1 = [[b[0], a[0][1], a[0][2]], [b[1], a[1][1], a[1][2]], [b[2], a[2][1], a[2][2]]]
        a2 = [[a[0][0], b[0], a[0][2]], [a[1][0], b[1], a[1][2]], [a[2][0], b[2], a[2][2]]]
        a3 = [[a[0][0], a[0][1], b[0]], [a[1][0], a[1][1], b[1]], [a[2][0], a[2][1], b[2]]]

        va = det3(a1) / d
        vb = det3(a2) / d
        vc = det3(a3) / d

        cx = 0.5 * va
        cy = 0.5 * vb
        r_sq = vc + cx * cx + cy * cy
        r = r_sq > 0 ? Math.sqrt(r_sq) : 0.0

        # RMS error -- compensated for the same reason as the accumulators, and
        # Math.hypot to mirror the Python core's math.hypot distance exactly.
        rms_acc = [0.0, 0.0]
        points.each do |pt|
          dist = Math.hypot(pt[0] - cx, pt[1] - cy)
          neumaier_add(rms_acc, (dist - r)**2)
        end
        rms = Math.sqrt(neumaier_value(rms_acc) / n)

        [cx, cy, r, rms]
      end

      # ---------------------------------------------------------------
      # Detect runs of consecutive points that form circular arcs.
      # Returns a new list of segments where polyline arcs are replaced
      # with :arc segments.
      #
      # Input: array of [x, y] points forming a polyline
      # Output: array of hashes:
      #   { type: :line, from: [x,y], to: [x,y] }
      #   { type: :arc, center: [x,y], radius: r, points: [[x,y],...],
      #     start_pt: [x,y], mid_pt: [x,y], end_pt: [x,y] }
      # ---------------------------------------------------------------
      def self.detect_arcs_in_polyline(points, opts = {})
        # Default matches the Python hosts' arc_fit_tol_mm = 0.05, expressed in
        # this fitter's inch units. The old 0.08 default predated unit review and
        # was ~2mm if read as inches -- callers always passed an explicit value,
        # so only direct/test callers ever saw it.
        arc_tol   = opts[:arc_fit_tol] || (0.05 / 25.4)
        min_segs = opts[:min_arc_segments] || 3
        max_segs = opts[:max_arc_segments] || 64
        min_angle = opts[:min_arc_angle_deg] || 5.0

        result = []
        n = points.length
        return result if n < 2

        i = 0
        while i < n - 1
          # Try to find the longest arc starting at position i
          best_arc_end = -1
          best_arc_data = nil

          # Need at least min_segs+1 points for an arc
          j = i + min_segs + 1
          while j <= [i + max_segs + 1, n].min
            run_pts = points[i..j-1]
            next if run_pts.length < 4

            begin
              fit = circle_fit(run_pts)
              if fit
                cx, cy, r, rms = fit
                # Accept if fit is good relative to radius
                tol = [arc_tol, r * 0.005].max
                # rms <= tol mirrors Python's `if rms > tol: continue`. The radius
                # floor r > 0.01 (inches) is deliberately NOT aligned to Python's
                # 0.1mm in this pass: Python applies its floor in source-mm space
                # before host scaling, while this fitter sees post-scale inches, so
                # a faithful alignment needs a min_radius option plumbed from the
                # builder with @scale -- tracked as follow-up, not silently changed.
                if rms <= tol && r > 0.01
                  # Check arc sweep is meaningful
                  dx0 = run_pts.first[0] - cx
                  dy0 = run_pts.first[1] - cy
                  dxN = run_pts.last[0] - cx
                  dyN = run_pts.last[1] - cy
                  a0 = Math.atan2(dy0, dx0)
                  aN = Math.atan2(dyN, dxN)
                  sweep = (aN - a0)
                  while sweep <= -Math::PI; sweep += 2 * Math::PI; end
                  while sweep > Math::PI; sweep -= 2 * Math::PI; end

                  if sweep.abs * 180.0 / Math::PI >= min_angle
                    best_arc_end = j
                    mid_idx = run_pts.length / 2
                    best_arc_data = {
                      type: :arc,
                      center: [cx, cy],
                      radius: r,
                      start_pt: run_pts.first,
                      mid_pt: run_pts[mid_idx],
                      end_pt: run_pts.last,
                      points: run_pts,
                      num_replaced: j - i - 1  # number of line segments replaced
                    }
                  end
                end
              end
            rescue StandardError => e
              Logger.warn("ArcFitter", "circle_fit failed: #{e.message}")
            end
            j += 1
          end

          if best_arc_data && best_arc_end > i + min_segs
            result << best_arc_data
            i = best_arc_end - 1  # -1 because the last point is shared
          else
            # No arc — emit a line segment
            result << {
              type: :line,
              from: points[i],
              to: points[i + 1]
            }
            i += 1
          end
        end

        result
      end

      # ---------------------------------------------------------------
      # Test if a cubic Bézier is approximately a circular arc.
      # Returns { center:, radius:, start_pt:, mid_pt:, end_pt: } or nil.
      # ---------------------------------------------------------------
      def self.bezier_to_arc(p0, p1, p2, p3, opts = {})
        tol = opts[:arc_fit_tol] || (0.05 / 25.4)  # Python arc_fit_tol_mm=0.05, in inches
        n_samples = opts[:arc_samples] || 7
        n_samples = n_samples | 1  # ensure odd

        # Sample points along the Bézier
        samples = (0..n_samples).map do |i|
          t = i.to_f / n_samples
          Bezier.evaluate_cubic(p0, p1, p2, p3, t)
        end

        begin
          fit = circle_fit(samples)
          return nil unless fit
          cx, cy, r, rms = fit
          return nil if rms > tol || r < 0.01

          mid = samples[samples.length / 2]
          {
            center: [cx, cy],
            radius: r,
            start_pt: p0,
            mid_pt: mid,
            end_pt: p3
          }
        rescue StandardError => e
          Logger.warn("ArcFitter", "bezier_to_arc failed: #{e.message}")
          nil
        end
      end

      private

      # Neumaier compensated summation over a [running_sum, compensation] pair.
      # Ruby 2.2 compatible: plain module functions, mutation via Array element
      # assignment. Matches CPython 3.12+ builtin sum() term-for-term, which in
      # turn reproduces math.fsum on every case measured; see circle_fit above
      # for why plain += is not acceptable here.
      def self.neumaier_add(state, value)
        t = state[0] + value
        if state[0].abs >= value.abs
          state[1] += (state[0] - t) + value
        else
          state[1] += (value - t) + state[0]
        end
        state[0] = t
        nil
      end

      def self.neumaier_value(state)
        state[0] + state[1]
      end

      def self.det3(m)
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
        m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
        m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
      end

    end
  end
end
