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
        white_edges = region_edges(prepared_white)
        ink_edges = region_edges(prepared_ink)
        input_edge_count = white_edges.length + ink_edges.length
        return [] if input_edge_count == 0
        raise Error, 'exact planar partition input-edge budget exceeded' if input_edge_count > limits[:input_edges]
        # Ink outside the exact white bounding rectangle cannot change any
        # white point's classification. Clip arrangement edges only; the fill
        # oracle retains every complete original contour (including counters
        # and ink that surrounds the white area without entering its bounds).
        bounds = union_loop_bounds(prepared_white)
        clipped_ink = bounds ? ink_edges.map { |edge| clip_edge_to_bounds(edge, bounds) }.compact : ink_edges
        edges = white_edges + clipped_ink
        atoms = boundary.split_edges(edges, requested_limits)
        unless atoms && atoms.length <= limits[:atomic_edges]
          raise Error, 'exact planar partition atomic-edge budget exceeded'
        end
        cuts = atoms.flat_map { |edge| edge.map { |point| point[0] } }.uniq.sort
        raise Error, 'exact planar partition slab budget exceeded' if cuts.length - 1 > limits[:slabs]
        cells = []
        predicates = 0
        generated_cells = 0
        previous = {}
        slab_total = [cuts.length - 1, 0].max
        boundary.run_checkpoint!(requested_limits, :white_mask_partition, 0, slab_total)
        cuts.each_cons(2).with_index do |span, slab_index|
          left, right = span
          boundary.run_checkpoint!(requested_limits, :white_mask_partition, slab_index, slab_total) if slab_index % 16 == 0
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
          runs = []
          active = nil
          levels.each_cons(2).with_index do |heights, level_index|
            lower, upper = heights
            boundary.run_checkpoint!(requested_limits, :white_mask_partition, slab_index, slab_total) if level_index % 64 == 0
            # Retain the original contour weight for the existing work budget;
            # clipping must not turn expensive classification into free work.
            predicates += input_edge_count
            if predicates > limits[:predicate_edges]
              raise Error, 'exact planar partition predicate budget exceeded'
            end
            probe = [middle, (lower + upper) / 2]
            owner = filled_region_index(prepared_white, probe)
            if owner.nil?
              active = nil
              next
            end
            region = filled_with_bounds?(prepared_ink, probe) ? :ink : :white
            low_edge, high_edge = lines[lower], lines[upper]
            cell = exact_cell(region, left, right, low_edge, high_edge)
            next unless cell
            generated_cells += 1
            raise Error, 'exact planar partition cell budget exceeded' if generated_cells > limits[:cells]
            # Adjacent same-class intervals in this one slab have no semantic
            # boundary between them. Their union is one exact convex trapezoid.
            # Retain first white-face ownership so material boundaries survive.
            if active && active[:region] == region && active[:owner] == owner && active[:upper] == lower
              merged = exact_cell(region, left, right, active[:low_edge], high_edge)
              unless merged && merged[:area] == active[:cell][:area] + cell[:area]
                raise Error, 'exact planar cell coalescing changed covered area'
              end
              active[:high_edge] = high_edge
              active[:upper] = upper
              active[:cell] = merged
            else
              active = { :region => region, :owner => owner, :lower => lower,
                         :upper => upper, :low_edge => low_edge,
                         :high_edge => high_edge, :cell => cell }
              runs << active
            end
          end
          current = {}
          runs.each do |run|
            key = [run[:region], run[:owner], line_key(run[:low_edge]), line_key(run[:high_edge])]
            prior = previous[key]
            if prior && prior[:right] == left
              # Across consecutive slabs, identical exact lower/upper lines
              # share the complete vertical edge. Removing this interior seam
              # changes neither covered area nor any exterior/ink boundary.
              merged = exact_cell(run[:region], prior[:left], right,
                                  run[:low_edge], run[:high_edge])
              unless merged && merged[:area] == prior[:cell][:area] + run[:cell][:area]
                raise Error, 'exact planar cell coalescing changed covered area'
              end
              prior[:cell].replace(merged)
              prior[:right] = right
              current[key] = prior
            else
              cells << run[:cell]
              current[key] = { :cell => run[:cell], :left => left, :right => right }
            end
          end
          previous = current
        end
        boundary.run_checkpoint!(requested_limits, :white_mask_partition, slab_total, slab_total)
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
        !filled_region_index(regions, point).nil?
      end

      def self.filled_region_index(regions, point)
        regions.each_with_index do |region, region_index|
          counts = region[:loops].each_with_index.map do |loop, index|
            box = region[:loop_bounds][index]
            if point[0] < box[0] || point[0] > box[2] ||
               point[1] < box[1] || point[1] > box[3]
              0
            else
              SvgRegionBoundary.winding(point, loop)
            end
          end
          return region_index if !counts.empty? && counts[0] != 0 && counts.drop(1).all? { |count| count == 0 }
        end
        nil
      end

      def self.region_edges(regions)
        regions.flat_map do |region|
          region[:loops].flat_map do |loop|
            loop.each_index.map { |index| [loop[index], loop[(index + 1) % loop.length]] }
          end
        end
      end

      def self.union_loop_bounds(regions)
        boxes = regions.flat_map { |region| region[:loop_bounds] }
        return nil if boxes.empty?
        [boxes.map { |box| box[0] }.min, boxes.map { |box| box[1] }.min,
         boxes.map { |box| box[2] }.max, boxes.map { |box| box[3] }.max]
      end

      # Exact segment/axis-aligned rectangle intersection (Liang-Barsky).
      # Neither clipping parameters nor new vertices pass through Float.
      def self.clip_edge_to_bounds(edge, bounds)
        a, b = edge
        first = 0.to_r
        last = 1.to_r
        [0, 1].each do |axis|
          delta = b[axis] - a[axis]
          if delta == 0
            return nil if a[axis] < bounds[axis] || a[axis] > bounds[axis + 2]
            next
          end
          lower = (bounds[axis] - a[axis]) / delta
          upper = (bounds[axis + 2] - a[axis]) / delta
          lower, upper = upper, lower if lower > upper
          first = lower if lower > first
          last = upper if upper < last
          return nil if first >= last
        end
        return nil if a == b
        [[a[0] + first * (b[0] - a[0]), a[1] + first * (b[1] - a[1])],
         [a[0] + last * (b[0] - a[0]), a[1] + last * (b[1] - a[1])]]
      end

      def self.line_key(edge)
        a, b = edge
        slope = (b[1] - a[1]) / (b[0] - a[0])
        [slope, a[1] - slope * a[0]]
      end

      def self.exact_cell(region, left, right, low_edge, high_edge)
        points = [[left, y_at(low_edge, left)], [right, y_at(low_edge, right)],
                  [right, y_at(high_edge, right)], [left, y_at(high_edge, left)]]
        loop = []
        points.each { |point| loop << point unless loop.last == point }
        loop.pop while loop.length > 1 && loop.first == loop.last
        area2 = SvgRegionBoundary.signed_area2(loop)
        raise Error, 'exact planar partition produced an inverted cell' if area2 < 0
        return nil if area2 == 0
        raise Error, 'exact planar partition produced a degenerate cell' unless loop.length >= 3
        { :region => region, :loop => loop.map { |point| [point[0], point[1], 0.to_r] },
          :area => area2 / 2 }
      end

      def self.y_at(edge, x)
        a, b = edge
        a[1] + (x - a[0]) * (b[1] - a[1]) / (b[0] - a[0])
      end
    end
  end
end
