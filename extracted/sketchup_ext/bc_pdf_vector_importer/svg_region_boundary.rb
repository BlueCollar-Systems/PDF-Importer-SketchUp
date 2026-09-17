# Filled-region boundary proof only. No host entities or source coordinates change.
# Exact rational predicates distinguish a redundant seam from a genuine counter;
# Cairo's coordinate tolerance belongs to the caller's later boundary comparison.
module BlueCollarSystems
  module PDFVectorImporter
    module SvgRegionBoundary
      MAX_INPUT_EDGES = 2048
      MAX_ATOMIC_EDGES = 8192
      MAX_PROBE_HALVINGS = 2048

      # :native_union treats each record as one actual face: first loop outer,
      # remaining loops holes. :svg applies each record's declared fill rule.
      # Returns filled-left loops (CCW outer / CW hole), without duplicate closing
      # vertices, or nil when the bounded topology proof cannot be completed.
      def self.normalize(regions, rule)
        return nil unless [:native_union, :svg].include?(rule)
        prepared = prepare_regions(regions, rule)
        return nil unless prepared
        edges = prepared.flat_map do |region|
          region[:loops].flat_map do |loop|
            loop.each_index.map { |index| [loop[index], loop[(index + 1) % loop.length]] }
          end
        end
        return [] if edges.empty?
        return nil if edges.length > MAX_INPUT_EDGES
        atoms = split_edges(edges)
        return nil unless atoms
        boundary = []
        atoms.each do |edge|
          sides = side_points(edge, edges)
          return nil unless sides
          left, right = sides.map { |point| filled?(prepared, rule, point) }
          next if left == right
          boundary << (left ? edge : edge.reverse)
        end
        loops = closed_loops(boundary)
        return nil unless loops
        # A new rational intersection can be smaller than the host's Float
        # coordinate representation. Reject a collapsed topology instead of
        # snapping or silently losing the feature in the returned proof loops.
        points = loops.flatten(1).uniq
        mapped = points.map { |p| [p[0].to_f, p[1].to_f, 0.0] }
        return nil unless mapped.all? { |p| p.all?(&:finite?) } && mapped.uniq.length == points.length
        lookup = {}
        points.each_with_index { |point, index| lookup[point] = mapped[index] }
        loops.map { |loop| loop.map { |point| lookup[point] } }
      rescue ArgumentError, TypeError, ZeroDivisionError, RangeError
        nil
      end

      def self.prepare_regions(regions, rule)
        return nil unless regions.is_a?(Array)
        result = []
        regions.each do |region|
          return nil unless region.is_a?(Hash) && region[:loops].is_a?(Array)
          fill_rule = region[:fill_rule].to_s
          return nil if rule == :svg && !['nonzero', 'evenodd'].include?(fill_rule)
          loops = []
          region[:loops].each do |raw|
            return nil unless raw.is_a?(Array)
            points = []
            raw.each do |point|
              return nil unless point.is_a?(Array) && (point.length == 2 || point.length == 3)
              return nil unless point.all? { |value| value.is_a?(Numeric) && value.to_f.finite? }
              return nil if point.length == 3 && point[2].to_f.abs > 1.0e-7
              converted = [point[0].to_r, point[1].to_r]
              points << converted unless points.last == converted
            end
            points.pop while points.length > 1 && points.first == points.last
            return nil unless points.length >= 3
            loops << points
          end
          result << { :loops => loops, :fill_rule => fill_rule }
        end
        result
      end

      def self.minus(a, b); [a[0] - b[0], a[1] - b[1]]; end
      def self.cross(a, b); a[0] * b[1] - a[1] * b[0]; end
      def self.dot(a, b); a[0] * b[0] + a[1] * b[1]; end

      def self.on_segment?(point, a, b)
        cross(minus(point, a), minus(b, a)) == 0 &&
          point[0] >= [a[0], b[0]].min && point[0] <= [a[0], b[0]].max &&
          point[1] >= [a[1], b[1]].min && point[1] <= [a[1], b[1]].max
      end

      def self.boxes_overlap?(first, second)
        [0, 1].all? do |axis|
          [first[0][axis], first[1][axis]].max >= [second[0][axis], second[1][axis]].min &&
            [second[0][axis], second[1][axis]].max >= [first[0][axis], first[1][axis]].min
        end
      end

      def self.split_edges(edges)
        splits = edges.map(&:dup)
        edges.each_with_index do |first, i|
          ((i + 1)...edges.length).each do |j|
            second = edges[j]
            next unless boxes_overlap?(first, second)
            a, b = first
            c, d = second
            r, s, q = minus(b, a), minus(d, c), minus(c, a)
            denominator = cross(r, s)
            if denominator == 0
              next unless cross(q, r) == 0
              [c, d].each { |point| splits[i] << point if on_segment?(point, a, b) }
              [a, b].each { |point| splits[j] << point if on_segment?(point, c, d) }
            else
              t, u = cross(q, s) / denominator, cross(q, r) / denominator
              next unless t >= 0 && t <= 1 && u >= 0 && u <= 1
              point = [a[0] + t * r[0], a[1] + t * r[1]]
              splits[i] << point
              splits[j] << point
            end
          end
        end
        unique = {}
        edges.each_with_index do |edge, index|
          direction = minus(edge[1], edge[0])
          points = splits[index].uniq.sort_by { |point| dot(minus(point, edge[0]), direction) }
          points.each_cons(2) do |a, b|
            next if a == b
            key = [a, b].sort
            unique[key] ||= [a, b]
            return nil if unique.length > MAX_ATOMIC_EDGES
          end
        end
        unique.values
      end

      def self.distance_squared(point, edge)
        a, b = edge
        direction = minus(b, a)
        length2 = dot(direction, direction)
        t = dot(minus(point, a), direction) / length2
        t = [[t, 0].max, 1].min
        delta = [point[0] - a[0] - t * direction[0], point[1] - a[1] - t * direction[1]]
        dot(delta, delta)
      end

      def self.side_points(edge, original_edges)
        a, b = edge
        direction = minus(b, a)
        length2 = dot(direction, direction)
        midpoint = [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]
        nearest = nil
        original_edges.each do |other|
          distance2 = distance_squared(midpoint, other)
          if distance2 == 0
            # Noncollinear intersections must have split this edge already.
            return nil unless cross(direction, minus(other[1], other[0])) == 0
          else
            nearest = distance2 if nearest.nil? || distance2 < nearest
          end
        end
        multiplier = Rational(1, 16)
        iterations = 0
        while nearest && length2 * multiplier * multiplier * 16 >= nearest
          multiplier /= 2
          iterations += 1
          return nil if iterations > MAX_PROBE_HALVINGS
        end
        offset = [-direction[1] * multiplier, direction[0] * multiplier]
        [[midpoint[0] + offset[0], midpoint[1] + offset[1]],
         [midpoint[0] - offset[0], midpoint[1] - offset[1]]]
      end

      def self.winding(point, loop)
        count = 0
        previous = loop[-1]
        loop.each do |current|
          side = cross(minus(current, previous), minus(point, previous))
          count += 1 if previous[1] <= point[1] && current[1] > point[1] && side > 0
          count -= 1 if previous[1] > point[1] && current[1] <= point[1] && side < 0
          previous = current
        end
        count
      end

      def self.filled?(regions, rule, point)
        regions.any? do |region|
          counts = region[:loops].map { |loop| winding(point, loop) }
          if rule == :native_union
            !counts.empty? && counts[0] != 0 && counts.drop(1).all? { |count| count == 0 }
          else
            total = counts.inject(0, :+)
            region[:fill_rule] == 'evenodd' ? total.abs.odd? : total != 0
          end
        end
      end

      def self.signed_area2(loop)
        points = loop.map { |point| [point[0].to_r, point[1].to_r] }
        points.each_index.inject(0) { |sum, index| sum + cross(points[index], points[(index + 1) % points.length]) }
      end

      def self.closed_loops(edges)
        outgoing, incoming = {}, {}
        edges.each do |a, b|
          # Point-touching/branched arrangements need a richer topology model;
          # do not silently join separate components or a counter at a vertex.
          return nil if outgoing.key?(a) || incoming.key?(b)
          outgoing[a], incoming[b] = b, a
        end
        return nil unless outgoing.keys.sort == incoming.keys.sort
        remaining = outgoing.dup
        loops = []
        until remaining.empty?
          start = remaining.keys.min
          point, loop = start, []
          loop do
            return nil unless remaining.key?(point)
            loop << point
            point = remaining.delete(point)
            break if point == start
          end
          return nil if loop.length < 3 || signed_area2(loop) == 0
          loops << loop
        end
        loops.sort_by { |loop| [signed_area2(loop) > 0 ? 0 : 1, loop.min] }
      end
    end
  end
end
