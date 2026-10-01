# Exact, bounded planar cells for native white-mask composition.
# All topology stays Rational until the caller constructs host points.
require File.join(File.dirname(__FILE__), 'svg_region_boundary')

module BlueCollarSystems
  module PDFVectorImporter
    module PlanarRegionPartition
      class Error < StandardError; end

      LIMITS = {
        :input_edges => 2048, :atomic_edges => 8192, :slabs => 8192,
        :cells => 32768, :predicate_edges => 40_000_000
      }.freeze

      # Each result is a convex triangle/trapezoid inside the original white
      # union, classified as :white or :ink. Ink cells remain in the partition
      # until the caller has verified complete native white-area coverage.
      def self.partition(white, ink, requested_limits = {})
        limits = {}
        LIMITS.each do |key, maximum|
          value = requested_limits.fetch(key, maximum)
          raise Error, 'invalid planar partition budget' unless value.is_a?(Integer) && value > 0
          limits[key] = [value, maximum].min
        end
        boundary = SvgRegionBoundary
        prepared_white = boundary.prepare_regions(white, :native_union)
        prepared_ink = boundary.prepare_regions(ink, :native_union)
        unless prepared_white && prepared_ink
          raise Error, 'invalid source contours for exact planar partition'
        end
        prepared_white = with_exact_loop_bounds(prepared_white)
        prepared_ink = with_exact_loop_bounds(prepared_ink)
        edges = (prepared_white + prepared_ink).flat_map do |region|
          region[:loops].flat_map do |loop|
            loop.each_index.map { |i| [loop[i], loop[(i + 1) % loop.length]] }
          end
        end
        return [] if edges.empty?
        raise Error, 'exact planar partition input-edge budget exceeded' if edges.length > limits[:input_edges]
        atoms = boundary.split_edges(edges)
        unless atoms && atoms.length <= limits[:atomic_edges]
          raise Error, 'exact planar partition atomic-edge budget exceeded'
        end
        cuts = atoms.flat_map { |edge| edge.map { |point| point[0] } }.uniq.sort
        raise Error, 'exact planar partition slab budget exceeded' if cuts.length - 1 > limits[:slabs]
        cells = []
        predicates = 0
        cuts.each_cons(2) do |left, right|
          middle = (left + right) / 2
          # Vertical edges belong to slab boundaries. Every crossing or vertex
          # is an x cut, so edge order is constant throughout the open slab.
          lines = {}
          atoms.each do |edge|
            a, b = edge
            next unless [a[0], b[0]].min < middle && middle < [a[0], b[0]].max
            lines[y_at(edge, middle)] ||= edge
          end
          levels = lines.keys.sort
          levels.each_cons(2) do |lower, upper|
            predicates += edges.length
            if predicates > limits[:predicate_edges]
              raise Error, 'exact planar partition predicate budget exceeded'
            end
            probe = [middle, (lower + upper) / 2]
            next unless filled_with_bounds?(prepared_white, probe)
            region = filled_with_bounds?(prepared_ink, probe) ? :ink : :white
            low_edge, high_edge = lines[lower], lines[upper]
            points = [[left, y_at(low_edge, left)], [right, y_at(low_edge, right)],
                      [right, y_at(high_edge, right)], [left, y_at(high_edge, left)]]
            loop = []
            points.each { |point| loop << point unless loop.last == point }
            loop.pop while loop.length > 1 && loop.first == loop.last
            area2 = boundary.signed_area2(loop)
            raise Error, 'exact planar partition produced an inverted cell' if area2 < 0
            next if area2 == 0
            raise Error, 'exact planar partition produced a degenerate cell' unless loop.length >= 3
            cells << { :region => region, :loop => loop.map { |p| [p[0], p[1], 0.to_r] },
                       :area => area2 / 2 }
            raise Error, 'exact planar partition cell budget exceeded' if cells.length > limits[:cells]
          end
        end
        cells
      rescue ArgumentError, TypeError, ZeroDivisionError, RangeError => error
        raise Error, 'invalid arithmetic in exact planar partition: ' + error.class.to_s
      end

      # These contours are fresh Rational copies made by prepare_regions. Keep
      # their bounds local to this partition and freeze both together, so a
      # cached box can never describe a subsequently changed loop.
      def self.with_exact_loop_bounds(regions)
        regions.each do |region|
          region[:loop_bounds] = region[:loops].map do |loop|
            loop.each(&:freeze)
            loop.freeze
            [loop.map { |p| p[0] }.min, loop.map { |p| p[1] }.min,
             loop.map { |p| p[0] }.max, loop.map { |p| p[1] }.max].freeze
          end.freeze
          region[:loops].freeze
          region.freeze
        end.freeze
      end

      # A point strictly outside a closed contour's exact bounds has winding
      # zero. Boundary and interior points retain the original winding test;
      # no Float box, tolerance, hole shortcut or source edge is substituted.
      def self.filled_with_bounds?(regions, point)
        regions.any? do |region|
          counts = region[:loops].each_with_index.map do |loop, index|
            box = region[:loop_bounds][index]
            if point[0] < box[0] || point[0] > box[2] ||
               point[1] < box[1] || point[1] > box[3]
              0
            else
              SvgRegionBoundary.winding(point, loop)
            end
          end
          !counts.empty? && counts[0] != 0 && counts.drop(1).all? { |count| count == 0 }
        end
      end

      def self.y_at(edge, x)
        a, b = edge
        a[1] + (x - a[0]) * (b[1] - a[1]) / (b[0] - a[0])
      end
    end
  end
end
