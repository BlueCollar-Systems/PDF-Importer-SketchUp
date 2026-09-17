# Binds physical native ink and masks to a single verified Cairo SVG paint stream.
# Binding tolerances account for Cairo's 1/256-point output grid only; no native
# coordinates, text entities, styles, or representation certificates are edited.
require File.join(File.dirname(__FILE__), 'planar_white_knockout')
require File.join(File.dirname(__FILE__), 'svg_region_boundary')

module BlueCollarSystems
  module PDFVectorImporter
    module SvgPaintBinding
      Geometry = PlanarWhiteKnockout
      SOURCE_GRID_INCHES = 1.0 / (72.0 * 128.0)

      def self.prepare(masks, roots, inventory, opts = {})
        tolerance = SOURCE_GRID_INCHES * (opts[:scale] || 1.0).to_f.abs
        tolerance = SOURCE_GRID_INCHES if tolerance <= 0.0
        source_masks = Array(inventory[:white_paths]).map { |r| geometry_record(r) }
        glyphs = Array(inventory[:glyphs]).map { |r| geometry_record(r) }
        glyphs_by_index = {}
        glyphs.each do |record|
          indices = record.key?(:placement_indices) ? record[:placement_indices] : [record[:placement_index]]
          Array(indices).each do |index|
            next unless index.is_a?(Integer) && index >= 0
            (glyphs_by_index[index] ||= []) << record
          end
        end
        ink = Geometry.collect_text_faces(roots)
        stats = { :source_white_paths => source_masks.length, :source_glyphs => glyphs.length,
                  :matched_masks => 0, :unmatched_masks => 0, :bound_ink_faces => 0,
                  :final_page_crops => 0, :unbound_ink_faces => 0 }
        bound_masks = []
        Array(masks).each do |record|
          next unless Geometry.opaque_white?(record)
          transform = record[:transformation] || record[:group].transformation
          white = Geometry.snapshots(record[:group], transform, false)
          next if white.empty?
          box = Geometry.union_bounds(white)
          loops = white.flat_map { |face| face[:loops] }
          near = source_masks.select { |candidate| same_bounds?(box, candidate[:bounds], tolerance) }
          native_boundary = nil
          native_boundary_checked = false
          candidates = near.select do |candidate|
            unless native_boundary_checked
              native_boundary = SvgRegionBoundary.normalize(white, :native_union)
              native_boundary_checked = true
            end
            unless candidate.key?(:binding_boundary)
              candidate[:binding_boundary] = SvgRegionBoundary.normalize([candidate], :svg)
            end
            source_boundary = candidate[:binding_boundary]
            native_boundary && source_boundary &&
              same_region_boundaries?(native_boundary, source_boundary, tolerance)
          end
          copy = record.dup
          copy[:pdf_paint_order] = record[:paint_order]
          copy[:native_white_faces] = white
          copy[:bounds] = box
          copy[:svg_candidates] = candidates
          copy[:native_loop_sizes] = loops.map(&:length)
          copy[:nearby_svg_diagnostics] = near.first(3).map do |candidate|
            { :offset => candidate[:svg_document_offset], :loop_sizes => candidate[:loops].map(&:length),
              :fill_rule => candidate[:fill_rule], :normalized_loops => candidate[:binding_boundary] && candidate[:binding_boundary].length }
          end
          bound_masks << copy
        end
        # Duplicate equal-shape paints remain distinct: associate their source
        # occurrences only when both inventories have the same complete count.
        bound_masks.each do |mask|
          candidates = mask[:svg_candidates]
          matches = bound_masks.select { |other| other[:svg_candidates] == candidates }
          ordered = matches.all? { |m| Geometry.valid_order?(m[:pdf_paint_order]) }
          ordered &&= matches.map { |m| m[:pdf_paint_order] }.uniq.length == matches.length
          if !candidates.empty? && candidates.length == matches.length && ordered
            position = matches.sort_by { |m| m[:pdf_paint_order] }.index(mask)
            match = candidates.sort_by { |m| m[:paint_order] }[position]
            mask[:paint_order] = match[:paint_order]
            mask[:svg_document_offset] = match[:svg_document_offset]
            stats[:matched_masks] += 1
          else
            mask[:paint_order] = nil
            stats[:unmatched_masks] += 1
          end
        end
        ink.each do |face|
          face[:paint_order] = nil
          if face[:final_page_crop] == true
            # A verified crop is the final same-page composite, including the
            # white pixels. Its rectangle replaces that backing within its
            # own footprint regardless of individual source paint order.
            face[:paint_order] = [1, 0]
            stats[:final_page_crops] += 1
            next
          end
          indices = Array(face[:source_placement_indices])
          # Containment alone cannot establish identity: a small unrelated
          # triangle can fit inside a larger source glyph. Physical text must
          # carry its exact source indices; only verified final crops above
          # have a different, item-bound proof path.
          valid_indices = !indices.empty? && indices.all? { |index| index.is_a?(Integer) && index >= 0 }
          candidates = valid_indices ? indices.flat_map { |index| glyphs_by_index[index] || [] }.uniq : []
          candidates = candidates.select do |glyph|
            Geometry.valid_order?(glyph[:paint_order]) &&
              glyph[:fill_opacity].is_a?(Numeric) && glyph[:fill_opacity] == 1.0 &&
              face_within_glyph?(face, glyph, tolerance)
          end
          orders = candidates.map { |glyph| glyph[:paint_order] }.uniq
          if orders.length == 1
            face[:paint_order] = orders[0]
            stats[:bound_ink_faces] += 1
          else
            stats[:unbound_ink_faces] += 1
          end
        end
        bound_masks.each do |mask|
          overlapping = ink.select { |face| Geometry.boxes_overlap?(mask[:bounds], face[:bounds]) }
          next if overlapping.empty?
          if overlapping.all? { |face| face[:final_page_crop] == true }
            mask[:paint_order] = [0, 0]
            mask[:order_proof] = 'verified_same_page_final_crops'
          end
          unless Geometry.valid_order?(mask[:paint_order])
            Geometry.fail_contract('source SVG paint order is unproven for an overlapping white mask: PDF order=' +
              mask[:pdf_paint_order].inspect + ', bounds=' + mask[:bounds].inspect +
              ', source candidates=' + mask[:svg_candidates].length.to_s +
              ', native loop sizes=' + mask[:native_loop_sizes].first(12).inspect +
              ', nearby SVG=' + mask[:nearby_svg_diagnostics].inspect)
          end
          unknown = overlapping.find { |face| !Geometry.valid_order?(face[:paint_order]) }
          if unknown
            Geometry.fail_contract('source SVG glyph paint order is unproven for ' +
              unknown[:source_span_id].to_s + ', placement indices=' + unknown[:source_placement_indices].inspect)
          end
        end
        { :masks => bound_masks, :ink_faces => ink, :binding => stats }
      end

      def self.geometry_record(record)
        result = record.dup
        loops = Array(record[:loops]).map do |loop|
          loop.map do |point|
            point.respond_to?(:x) ? [point.x.to_f, point.y.to_f, point.z.to_f] :
              [point[0].to_f, point[1].to_f, point[2].to_f]
          end
        end
        result[:loops] = loops
        points = loops.flatten(1)
        result[:bounds] = [points.map { |p| p[0] }.min, points.map { |p| p[1] }.min,
                          points.map { |p| p[0] }.max, points.map { |p| p[1] }.max]
        result
      end

      def self.box_candidates(index, box)
        size = Geometry::GRID_SIZE
        result = index[:large].dup
        x0, y0, x1, y1 = box.map { |value| (value / size).floor }
        (x0..x1).each do |x|
          (y0..y1).each { |y| result.concat(index[:grid][[x, y]] || []) }
        end
        result.uniq
      end

      def self.same_bounds?(a, b, tolerance)
        a.length == 4 && b.length == 4 && a.each_with_index.all? do |v, index|
          (v - b[index]).abs <= tolerance
        end
      end

      def self.same_loops?(native, source, tolerance)
        return false unless native.length == source.length
        unused = source.dup
        native.each do |loop|
          candidates = unused.select do |other|
            loop_samples(loop).all? { |p| on_boundary?(p, [other], tolerance) } &&
              loop_samples(other).all? { |p| on_boundary?(p, [loop], tolerance) }
          end
          return false unless candidates.length == 1
          unused.delete_at(unused.index(candidates[0]))
        end
        unused.empty?
      end

      # Normalization cancels only proven internal seams. Compare every full
      # remaining edge, in both directions, while retaining outer/hole signs
      # and component count. Cairo tolerance binds identities only; neither
      # source nor native geometry is moved or reconstructed here.
      def self.same_region_boundaries?(native, source, tolerance)
        return false unless native.length == source.length && !native.empty?
        unused = source.dup
        native.each do |loop|
          candidates = unused.select do |other|
            area = signed_loop_area(loop)
            other_area = signed_loop_area(other)
            area * other_area > 0.0 &&
              loop_edges(loop).all? { |a,b| boundary_segment_covered?(a,b,other,tolerance) } &&
              loop_edges(other).all? { |a,b| boundary_segment_covered?(a,b,loop,tolerance) }
          end
          return false unless candidates.length == 1
          unused.delete_at(unused.index(candidates[0]))
        end
        unused.empty?
      end

      def self.signed_loop_area(loop)
        origin = loop.first
        return 0.0 unless origin
        loop_edges(loop).inject(0.0) do |area,pair|
          a,b = pair
          area + (a[0]-origin[0])*(b[1]-origin[1]) - (b[0]-origin[0])*(a[1]-origin[1])
        end * 0.5
      end

      def self.loop_edges(loop)
        points = loop.dup
        points.pop if points.length > 1 && points[-1] == points[0]
        return [] if points.length < 3
        points.each_with_index.map { |point,index| [point,points[(index+1)%points.length]] }
      end

      def self.boundary_segment_covered?(a, b, boundary, tolerance)
        dx, dy = b[0]-a[0], b[1]-a[1]
        length = Math.sqrt(dx*dx+dy*dy)
        return false unless length > 0.0
        ux, uy = dx/length, dy/length
        intervals = []
        loop_edges(boundary).each do |c,d|
          next unless (d[0]-c[0])*ux+(d[1]-c[1])*uy > 0.0
          c_along = (c[0]-a[0])*ux+(c[1]-a[1])*uy
          d_along = (d[0]-a[0])*ux+(d[1]-a[1])*uy
          c_normal = (c[0]-a[0])*uy-(c[1]-a[1])*ux
          d_normal = (d[0]-a[0])*uy-(d[1]-a[1])*ux
          # A rounded/clipped corner may have a short edge near the endpoint
          # of a longer opposing edge. Its other endpoint can be outside this
          # strip; retain the exact endpoint-disk coverage before requiring
          # both endpoints for the directed segment's interior coverage.
          c_slack = c_normal.abs <= tolerance ? Math.sqrt([tolerance*tolerance-c_normal*c_normal,0.0].max) : nil
          d_slack = d_normal.abs <= tolerance ? Math.sqrt([tolerance*tolerance-d_normal*d_normal,0.0].max) : nil
          intervals << [c_along-c_slack,c_along+c_slack] if c_slack
          intervals << [d_along-d_slack,d_along+d_slack] if d_slack
          next unless c_slack && d_slack
          intervals << [c_along-c_slack,d_along+d_slack]
        end
        covered = 0.0
        intervals.sort_by { |interval| interval[0] }.each do |low,high|
          next if high < covered
          return false if low > covered
          covered = high if high > covered
          return true if covered >= length
        end
        false
      end

      def self.loop_samples(loop)
        result = []
        previous = loop[-1]
        loop.each do |point|
          result << point
          result << [(previous[0] + point[0]) * 0.5, (previous[1] + point[1]) * 0.5, 0.0]
          previous = point
        end
        result
      end

      def self.face_within_glyph?(face, glyph, tolerance)
        fill_rule = (glyph[:fill_rule] || :nonzero).to_s
        return false unless ['nonzero', 'evenodd'].include?(fill_rule)
        a, b = face[:bounds], glyph[:bounds]
        return false unless a[0] >= b[0] - tolerance && a[1] >= b[1] - tolerance &&
                            a[2] <= b[2] + tolerance && a[3] <= b[3] + tolerance
        face[:loops].all? do |loop|
          loop_samples(loop).all? do |point|
            winding = winding_number(point, glyph[:loops])
            inside = fill_rule == 'evenodd' ? winding.abs.odd? : winding != 0
            on_boundary?(point, glyph[:loops], tolerance) ||
              inside
          end
        end
      end

      def self.on_boundary?(point, loops, tolerance)
        squared = tolerance * tolerance
        loops.any? do |loop|
          previous = loop[-1]
          found = loop.any? do |current|
            dx, dy = current[0] - previous[0], current[1] - previous[1]
            length2 = dx * dx + dy * dy
            t = length2 > 0.0 ? ((point[0] - previous[0]) * dx + (point[1] - previous[1]) * dy) / length2 : 0.0
            t = [[t, 0.0].max, 1.0].min
            distance2 = (point[0] - previous[0] - t * dx) ** 2 +
                        (point[1] - previous[1] - t * dy) ** 2
            previous = current
            distance2 <= squared
          end
          found
        end
      end

      def self.winding_number(point, loops)
        winding = 0
        loops.each do |loop|
          previous = loop[-1]
          loop.each do |current|
            side = (current[0] - previous[0]) * (point[1] - previous[1]) -
                   (point[0] - previous[0]) * (current[1] - previous[1])
            if previous[1] <= point[1] && current[1] > point[1] && side > 0.0
              winding += 1
            elsif previous[1] > point[1] && current[1] <= point[1] && side < 0.0
              winding -= 1
            end
            previous = current
          end
        end
        winding
      end
    end
  end
end
