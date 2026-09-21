# Source-space centerline clipping. Native SketchUp edges do not model PDF
# stroke width or caps; retain those source styles and never infer paint absence
# from an empty centerline. No geometry, contour, or dash is moved to a clip edge.
module BlueCollarSystems
  module PDFVectorImporter
    module StrokeClipping
      class Unsupported < StandardError; end
      MAX_DASH_INTERVALS = 100_000
      module_function

      def rectangle(paths)
        return nil unless paths.is_a?(Array) && paths.length == 1
        sub = paths[0]
        segments = sub.segments
        return nil unless sub.closed && segments.length >= 4 && segments.length <= 5
        return nil unless segments[0].type == :move && segments[0].points.length == 1
        points = [segments[0].points[0]]
        segments.drop(1).each do |segment|
          return nil unless segment.type == :line && segment.points.length == 2 && segment.points[0] == points.last
          points << segment.points[1]
        end
        points << points.first unless points.last == points.first
        return nil unless points.length == 5 && points.first == points.last
        corners = points[0, 4]
        return nil unless corners.uniq.length == 4 && corners.all? { |point| finite_point?(point) }
        return nil unless points.each_cons(2).all? { |a, b| (a[0] == b[0]) != (a[1] == b[1]) }
        xs = corners.map { |point| point[0] }; ys = corners.map { |point| point[1] }
        box = [xs.min, ys.min, xs.max, ys.max]
        return nil unless corners.sort == [[box[0],box[1]], [box[0],box[3]], [box[2],box[1]], [box[2],box[3]]].sort
        box.freeze
      end

      def snapshot(regions, text_clip)
        return { :unsupported => 'active text clipping' }.freeze if text_clip
        rectangles = regions.map { |region| rectangle(region[:paths]) }
        return { :unsupported => 'non-rectangular source stroke clip' }.freeze if rectangles.any?(&:nil?)
        { :rectangles => rectangles.freeze }.freeze
      end

      def transform(snapshot, matrix)
        return snapshot if snapshot.nil? || snapshot[:unsupported]
        # Axis-aligned rectangles remain exact only under axis-preserving transforms.
        unless (matrix[1] == 0 && matrix[2] == 0) || (matrix[0] == 0 && matrix[3] == 0)
          return { :unsupported => 'non-axis-aligned Form stroke clip' }.freeze unless snapshot[:rectangles].empty?
        end
        rectangles = snapshot[:rectangles].map do |box|
          points = [[box[0],box[1]], [box[2],box[3]]].map do |x,y|
            [matrix[0]*x + matrix[2]*y + matrix[4], matrix[1]*x + matrix[3]*y + matrix[5]]
          end
          [points.map(&:first).min, points.map(&:last).min,
           points.map(&:first).max, points.map(&:last).max].freeze
        end
        { :rectangles => rectangles.freeze }.freeze
      end

      def effective_bounds(snapshot, page, visible_page = nil)
        raise Unsupported, snapshot[:unsupported] if snapshot && snapshot[:unsupported]
        raise Unsupported, 'invalid source page clipping bounds' unless finite_box?(page)
        box = page.dup
        ((visible_page ? [visible_page] : []) + Array(snapshot && snapshot[:rectangles])).each do |clip|
          raise Unsupported, 'invalid source stroke clipping bounds' unless finite_box?(clip)
          box = [[box[0],clip[0]].max, [box[1],clip[1]].max,
                 [box[2],clip[2]].min, [box[3],clip[3]].min]
          return :empty if box[0] >= box[2] || box[1] >= box[3]
        end
        box
      end

      def finite_point?(point)
        point.is_a?(Array) && point.length >= 2 && point[0,2].all? { |v| v.is_a?(Numeric) && v.to_f.finite? }
      end

      def finite_box?(box)
        box.is_a?(Array) && box.length == 4 && box.all? { |v| v.is_a?(Numeric) && v.to_f.finite? } && box[0] < box[2] && box[1] < box[3]
      end

      def inside?(point, box)
        box != :empty && point[0] >= box[0] && point[0] <= box[2] && point[1] >= box[1] && point[1] <= box[3]
      end

      def line(a, b, box)
        return nil if box == :empty
        raise Unsupported, 'nonfinite source stroke point' unless finite_point?(a) && finite_point?(b)
        dx = b[0] - a[0]; dy = b[1] - a[1]
        low = 0.0; high = 1.0
        [[-dx, a[0]-box[0]], [dx, box[2]-a[0]], [-dy, a[1]-box[1]], [dy, box[3]-a[1]]].each do |p,q|
          return nil if p == 0 && q < 0
          next if p == 0
          ratio = q.to_f / p
          if p < 0
            low = [low, ratio].max
          else
            high = [high, ratio].min
          end
          return nil if low > high
        end
        return nil if high <= low || (dx == 0 && dy == 0)
        [interpolate(a,b,low), interpolate(a,b,high)]
      end

      def interpolate(a,b,t)
        return a.dup if t == 0
        return b.dup if t == 1
        [a[0] + (b[0]-a[0])*t, a[1] + (b[1]-a[1])*t]
      end

      # Segment lengths for PDF dashing are measured before the path CTM. The
      # inverse linear map preserves anisotropic scaling and shear, unlike an
      # average axis scale. Phase continues across corners and clipped-away parts.
      def source_length(a, b, ctm)
        raise Unsupported, 'invalid stroke CTM for source dashing' unless ctm.is_a?(Array) && ctm.length == 6 && ctm.all? { |v| v.is_a?(Numeric) && v.to_f.finite? }
        det = ctm[0]*ctm[3] - ctm[1]*ctm[2]
        raise Unsupported, 'singular stroke CTM for source dashing' if det == 0
        dx=b[0]-a[0]; dy=b[1]-a[1]
        x=(ctm[3]*dx-ctm[2]*dy)/det; y=(-ctm[1]*dx+ctm[0]*dy)/det
        Math.sqrt(x*x+y*y)
      end

      def visible_segments(points, closed, box, dash_pattern = nil, ctm = nil)
        return [] if box == :empty
        original = points.map(&:dup)
        original << original.first if closed && original.length > 2 && original.last != original.first
        raise Unsupported, 'invalid source dash pattern' if dash_pattern && !dash_pattern.is_a?(Array)
        if dash_pattern && dash_pattern[0].is_a?(Array)
          pattern = dash_pattern[0]
          phase = dash_pattern[1]
        else
          pattern = dash_pattern
          phase = 0.0
        end
        if pattern && !pattern.empty?
          unless pattern.is_a?(Array) && pattern.all? { |v| v.is_a?(Numeric) && v.to_f.finite? && v >= 0 } && phase.is_a?(Numeric) && phase.to_f.finite?
            raise Unsupported, 'invalid source dash pattern'
          end
          pattern = pattern + pattern if pattern.length.odd?
          raise Unsupported, 'zero-length painted dash requires stroke-area rendering' if pattern.each_with_index.any? { |v,i| i.even? && v == 0 }
          cycle = pattern.inject(0.0, :+)
          raise Unsupported, 'empty source dash cycle' unless cycle > 0
        else
          pattern = nil
        end
        if pattern
          total = original.each_cons(2).inject(0.0) { |sum,pair| sum + source_length(pair[0],pair[1],ctm) }
          estimated_intervals = (total / cycle + original.length) * pattern.length
          raise Unsupported, 'source dash subdivision exceeds bounded native edge budget' if estimated_intervals > MAX_DASH_INTERVALS
        end
        result=[]; travelled=0.0
        original.each_cons(2) do |a,b|
          if pattern
            length = source_length(a,b,ctm)
            next if length == 0
            offset = (phase + travelled) % cycle
            index=0
            while offset >= pattern[index]
              offset -= pattern[index]; index=(index+1)%pattern.length
            end
            remain=pattern[index]-offset; position=0.0
            while position < length
              stop=[position+remain,length].min
              raise Unsupported, 'source dash length is below numeric resolution' if remain > 0 && stop <= position
              if index.even? && stop > position
                fragment=line(interpolate(a,b,position/length),interpolate(a,b,stop/length),box)
                result << fragment if fragment
              end
              position=stop; index=(index+1)%pattern.length; remain=pattern[index]
            end
            travelled += length
          else
            fragment=line(a,b,box)
            result << fragment if fragment
          end
        end
        result
      end
    end
  end
end
