# Exact planar composition for earlier, opaque white PDF masks and flat text.
# The caller owns the import operation and must abort it if this module raises.
# No text geometry, representation, identity, or depth is changed here.
require File.join(File.dirname(__FILE__), 'representation_fidelity')
require File.join(File.dirname(__FILE__), 'svg_region_boundary')

module BlueCollarSystems
  module PDFVectorImporter
    module PlanarWhiteKnockout
      CONSTRUCTION_SCALE = 1000.0
      PLANE_TOLERANCE = 1.0e-7
      DICTIONARY = 'BC_PDF_Importer'.freeze
      GRID_SIZE = 0.25
      MAX_INDEX_CELLS = 4096

      # All transformations map to the same page coordinate system. A record's
      # :transformation is the complete transform of its group, not its parent.
      # :before_text must come from source paint order, never build order.
      # Text roots can instead be bare groups directly inside the page context.
      def self.compose!(fill_only_groups, text_roots, opts = {})
        ink = opts.key?(:ink_faces) ? opts[:ink_faces] : collect_text_faces(text_roots)
        fail_contract('prebound physical ink faces must be an array') unless ink.is_a?(Array)
        result = { :white_groups => 0, :composed_groups => 0,
                   :ink_faces => ink.length, :removed_area => 0.0,
                   :skipped_unproven_order => 0, :skipped_nonwhite => 0 }
        Array(fill_only_groups).each do |record|
          unless opaque_white?(record)
            result[:skipped_nonwhite] += 1
            next
          end
          result[:white_groups] += 1
          group = record[:group]
          transform = record[:transformation] || group.transformation
          white = snapshots(group, transform, false)
          next if white.empty?
          unless white.all? { |face| opaque_material?(face[:material]) }
            result[:skipped_nonwhite] += 1
            next
          end
          unless white.all? { |face| planar?(face) }
            fail_contract('white mask is not on the page plane')
          end
          box = union_bounds(white)
          overlaps = ink.select { |face| boxes_overlap?(box, face[:bounds]) }
          candidates = overlaps.select { |face| earlier_mask?(record, face, opts) }
          result[:skipped_unproven_order] += overlaps.length - candidates.length
          next if candidates.empty?
          result[:removed_area] += compose_group!(group, transform, white, candidates)
          result[:composed_groups] += 1
        end
        result
      rescue RepresentationFidelity::ContractError
        raise
      rescue StandardError => error
        # Generic host failure is never affirmative evidence for a text fallback.
        fail_contract("native white-mask composition failed (#{error.class}): " +
                      safe_error_detail(error.message))
      end

      def self.safe_error_detail(message)
        message.to_s.gsub(%r{https?://\S+}, '[url]').
          gsub(/[A-Za-z]:[\\\/][^\r\n]*/, '[path]').
          gsub(%r{(?:/[\w. -]+){2,}}, '[path]').
          gsub(/[\x00-\x1f\x7f]/, ' ')[0, 180]
      end

      def self.earlier_mask?(mask, ink, opts = {})
        return true if mask[:before_text] == true || opts[:white_precedes_text] == true
        earlier = mask[:paint_order]
        later = ink[:paint_order]
        return false unless valid_order?(earlier) && valid_order?(later)
        (earlier <=> later) == -1
      end

      def self.valid_order?(order)
        order.is_a?(Array) && order.length == 2 &&
          order.all? { |value| value.is_a?(Integer) && value >= 0 }
      end

      def self.opaque_white?(record)
        return false unless record.is_a?(Hash) && record[:group]
        rgb = Array(record[:fill_rgb])
        return false unless rgb.length >= 3
        return false unless rgb.first(3).all? { |value| (value.to_f - 1.0).abs < 1.0e-9 }
        alpha = record.key?(:opacity) ? record[:opacity].to_f : 1.0
        (alpha - 1.0).abs < 1.0e-9
      end

      def self.collect_text_faces(roots)
        result = []
        Array(roots).each do |root|
          record = root.is_a?(Hash) ? root : { :group => root }
          group = record[:group]
          next unless group
          transform = record[:transformation] || group.transformation
          faces = if group.typename.to_s == 'Image'
                    image = image_snapshot(group, transform)
                    image ? [image] : []
                  else
                    snapshots(group, transform, true)
                  end
          # A positive-depth text item is already physically in front. Do not
          # punch white masks using its coplanar bottom faces alone.
          next unless faces.all? { |face| planar?(face) }
          faces = faces.select { |face| opaque_material?(face[:material]) }
          faces.each do |face|
            face[:paint_order] = record[:paint_order]
            face[:source_span_id] = source_id_for(group) if face[:source_span_id].to_s.empty?
            face[:source_placements] = record[:source_placements] if record[:source_placements].is_a?(Array)
          end
          result.concat(faces)
        end
        result.uniq { |face| [face[:entity_id], face[:loops]] }
      end

      def self.snapshots(group, transform, require_owner, inherited_owner = false,
                         inherited_material = nil, inherited_indices = [],
                         inherited_source_id = nil)
        owner = inherited_owner || source_owner?(group)
        material = (group.material if group.respond_to?(:material)) || inherited_material
        indices = source_indices_for(group, inherited_indices)
        source_id = source_id_for(group, inherited_source_id)
        result = []
        child_entities(group).to_a.each do |entity|
          next if entity.respond_to?(:valid?) && !entity.valid?
          kind = entity.typename.to_s
          if kind == 'Face'
            next if require_owner && !owner
            loops = [entity.outer_loop] + entity.loops.to_a.reject do |loop|
              loop == entity.outer_loop
            end
            points = loops.map do |loop|
              loop.vertices.map do |vertex|
                point = vertex.position.transform(transform)
                [point.x.to_f, point.y.to_f, point.z.to_f]
              end
            end
            record = face_record(points, entity)
            record[:material] ||= material
            record[:back_material] ||= material
            record[:source_placement_indices] = source_indices_for(entity, indices)
            record[:source_span_id] = source_id_for(entity, source_id)
            result << record
          elsif kind == 'Group' || kind == 'ComponentInstance'
            result.concat(snapshots(entity, transform * entity.transformation,
                                    require_owner, owner, material, indices, source_id))
          elsif kind != 'Edge' && !require_owner
            fail_contract('white fill-only group contains unrelated entities')
          end
        end
        result
      end

      def self.source_id_for(entity, inherited = nil)
        return inherited unless entity.respond_to?(:get_attribute)
        value = entity.get_attribute(DICTIONARY, 'source_span_id', '').to_s
        value.empty? ? inherited : value
      end

      def self.source_indices_for(entity, inherited = [])
        return inherited unless entity.respond_to?(:get_attribute)
        value = entity.get_attribute(DICTIONARY, 'source_placement_indices', nil)
        return inherited if value.nil?
        if value.is_a?(Array)
          return [] unless value.all? { |index| index.is_a?(Integer) && index >= 0 }
          return value.dup
        end
        return [] unless value.is_a?(String) && /\A\d+(?:,\d+)*\z/ =~ value
        value.split(',').map { |index| index.to_i }
      end

      def self.opaque_material?(material)
        return true unless material && material.respond_to?(:alpha)
        (material.alpha.to_f - 1.0).abs < 1.0e-9
      end

      # A verified crop of the transparent *whole source page* repaints the
      # opaque white pixels wherever its rectangle overlaps an earlier mask.
      # Generic transparent images do not have that property and are excluded.
      def self.image_snapshot(image, transform)
        return nil unless source_owner?(image)
        return nil unless image.get_attribute(DICTIONARY, 'renderer', '') ==
                          'pdftocairo_transparent_page_crop'
        proof_keys = ['raster_alpha_verified', 'raster_transparent_background_verified',
                      'raster_page_render_once_verified', 'raster_visible_pixel_verified']
        return nil unless proof_keys.all? { |key| image.get_attribute(DICTIONARY, key, false) == true }
        digest = image.get_attribute(DICTIONARY, 'raster_source_pdf_sha256', '').to_s
        return nil unless /\A[0-9a-f]{64}\z/i =~ digest
        matrix = image.transformation.to_a
        x_length = Math.sqrt(matrix.values_at(0, 1, 2).inject(0.0) { |sum, v| sum + v.to_f * v.to_f })
        y_length = Math.sqrt(matrix.values_at(4, 5, 6).inject(0.0) { |sum, v| sum + v.to_f * v.to_f })
        width, height = image.width.to_f, image.height.to_f
        unless [x_length, y_length, width, height].all? { |v| v.finite? && v > 0.0 }
          fail_contract('physical item raster has an invalid planar size')
        end
        w, h = width / x_length, height / y_length
        local = [[0.0, 0.0, 0.0], [w, 0.0, 0.0], [w, h, 0.0], [0.0, h, 0.0]]
        physical = local.map { |p| Geom::Point3d.new(*p).transform(image.transformation) }
        [0, 1, 2].each do |axis|
          values = physical.map { |p| [p.x, p.y, p.z][axis] }
          minimum = [image.bounds.min.x, image.bounds.min.y, image.bounds.min.z][axis]
          maximum = [image.bounds.max.x, image.bounds.max.y, image.bounds.max.z][axis]
          tolerance = [width, height, 1.0].max * 1.0e-7
          unless (values.min - minimum).abs <= tolerance && (values.max - maximum).abs <= tolerance
            fail_contract('physical item raster corners disagree with host image bounds')
          end
        end
        points = local.map do |p|
          point = Geom::Point3d.new(*p).transform(transform)
          [point.x.to_f, point.y.to_f, point.z.to_f]
        end
        record = face_record([points])
        record[:entity_id] = image.object_id
        record[:source_span_id] = source_id_for(image)
        record[:source_placement_indices] = source_indices_for(image)
        page = image.get_attribute(DICTIONARY, 'raster_page_number', nil)
        source_page = /\Atext_span:(\d+):\d+\z/.match(record[:source_span_id].to_s)
        # This flag is evidence for the caller's source-order binder, not a
        # blanket order override here. A final page crop can repaint its own
        # earlier page masks only when its source page identity also matches.
        if page.is_a?(Integer) && page > 0 && source_page && source_page[1].to_i == page
          record[:final_page_crop] = true
          record[:raster_page_number] = page
          record[:source_pdf_sha256] = digest
        end
        record
      end

      def self.child_entities(entity)
        entity.respond_to?(:entities) ? entity.entities : entity.definition.entities
      end

      def self.source_owner?(entity)
        return false unless entity.respond_to?(:get_attribute)
        !entity.get_attribute(DICTIONARY, 'source_span_id', '').to_s.empty?
      end

      def self.face_record(loops, entity = nil)
        unless loops.length > 0 && loops.all? do |loop|
          loop.length >= 3 && loop.all? { |point| point.length == 3 && point.all? { |v| v.to_f.finite? } }
        end
          fail_contract('invalid physical face contour in planar composition')
        end
        points = loops.flatten(1)
        { :loops => loops,
          :bounds => [points.map { |p| p[0] }.min, points.map { |p| p[1] }.min,
                      points.map { |p| p[0] }.max, points.map { |p| p[1] }.max],
          :entity_id => entity ? entity.object_id : nil,
          :material => entity && entity.material,
          :back_material => entity && entity.back_material,
          :layer => entity && entity.layer }
      end

      def self.planar?(face)
        face[:loops].all? { |loop| loop.all? { |point| point[2].abs <= PLANE_TOLERANCE } }
      end

      def self.union_bounds(faces)
        boxes = faces.map { |face| face[:bounds] }
        [boxes.map { |b| b[0] }.min, boxes.map { |b| b[1] }.min,
         boxes.map { |b| b[2] }.max, boxes.map { |b| b[3] }.max]
      end

      def self.boxes_overlap?(a, b)
        a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]
      end

      def self.contains?(face, point)
        box = face[:bounds]
        return false if point[0] < box[0] || point[0] > box[2] ||
                        point[1] < box[1] || point[1] > box[3]
        point_in_loop?(point, face[:loops][0]) &&
          !face[:loops].drop(1).any? { |loop| point_in_loop?(point, loop) }
      end

      def self.point_in_loop?(point, loop)
        inside = false
        previous = loop[-1]
        loop.each do |current|
          if (current[1] > point[1]) != (previous[1] > point[1])
            x = current[0] + (point[1] - current[1]) *
                (previous[0] - current[0]) / (previous[1] - current[1])
            inside = !inside if point[0] < x
          end
          previous = current
        end
        inside
      end

      def self.region_at(point, white, ink)
        return :outside unless point_candidates(white, point).any? { |face| contains?(face, point) }
        point_candidates(ink, point).any? { |face| contains?(face, point) } ? :ink : :white
      end

      def self.spatial_index(records)
        grid = {}
        large = []
        records.each do |record|
          box = record[:bounds]
          x0, y0, x1, y1 = box.map { |value| (value / GRID_SIZE).floor }
          if (x1 - x0 + 1) * (y1 - y0 + 1) > MAX_INDEX_CELLS
            large << record
            next
          end
          (x0..x1).each do |x|
            (y0..y1).each { |y| (grid[[x, y]] ||= []) << record }
          end
        end
        { :grid => grid, :large => large }
      end

      def self.point_candidates(records, point)
        return records unless records.is_a?(Hash)
        key = [(point[0] / GRID_SIZE).floor, (point[1] / GRID_SIZE).floor]
        Array(records[:grid][key]) + records[:large]
      end

      def self.loop_area(loop)
        area = 0.0
        previous = loop[-1]
        loop.each do |point|
          area += previous[0] * point[1] - point[0] * previous[1]
          previous = point
        end
        area.abs * 0.5
      end

      def self.source_area(faces)
        faces.inject(0.0) do |sum, face|
          sum + loop_area(face[:loops][0]) -
            face[:loops].drop(1).inject(0.0) { |holes, loop| holes + loop_area(loop) }
        end
      end

      def self.compose_group!(group, transform, white, ink)
        # The geometric operation preserves original face materials/alpha.
        # compose! supplies the default opaque-white eligibility policy; callers
        # proving another exact source-composite relationship may use this
        # operation directly for colored or translucent source fill groups.
        entities = child_entities(group)
        originals = entities.to_a
        stage = nil
        begin
          box = union_bounds(white)
          origin = [(box[0] + box[2]) * 0.5, (box[1] + box[3]) * 0.5, 0.0]
          stage = entities.add_group
          stage.name = 'PDF planar white composition' if stage.respond_to?(:name=)
          page_transform = Geom::Transformation.translation(Geom::Point3d.new(*origin)) *
                           Geom::Transformation.scaling(1.0 / CONSTRUCTION_SCALE)
          stage.transformation = transform.inverse * page_transform
          (white + ink).each do |record|
            record[:loops].each do |loop|
              points = loop.map { |point| construction_point(point, origin) }
              # A previously inserted coincident boundary may return nil. The
              # physical partition/coverage checks below decide success.
              stage.entities.add_face(points)
            end
          end
          subdivide_native_boundaries!(stage.entities)
          repair_native_hole_topology!(stage.entities)
          cells = partition_faces(stage.entities)
          fail_contract('native white-mask subdivision produced no faces') if cells.empty?
          white_index = spatial_index(white)
          ink_index = spatial_index(ink)
          plan = classify_cells(cells, origin, white_index, ink_index)
          expected = source_area(white)
          partition_area = plan.inject(0.0) do |sum, cell|
            cell[:region] == :outside ? sum : sum + cell[:area]
          end
          tolerance = [expected.abs * 1.0e-7, 1.0e-10].max
          if (partition_area - expected).abs > tolerance
            fail_contract('native white-mask partition changed source white area')
          end
          kept = plan.select { |cell| cell[:region] == :white }
          removed = plan.select { |cell| cell[:region] == :ink }
          verify_ink_samples!(ink, white_index, spatial_index(kept), origin, ink_index)
          plan.each do |cell|
            face = cell[:face]
            if cell[:region] == :white
              style = white.find { |record| contains?(record, cell[:sample]) }
              face.material = style[:material]
              face.back_material = style[:back_material]
              face.layer = style[:layer] if style[:layer]
              face.reverse! if face.normal.z < 0
            else
              face.erase!
            end
          end
          clean_partition_edges!(stage.entities)
          entities.erase_entities(originals)
          stage.set_attribute(DICTIONARY, 'planar_white_knockout', true)
          removed.inject(0.0) { |sum, cell| sum + cell[:area] }
        rescue StandardError => error
          stage.erase! if stage && stage.valid?
          if error.is_a?(RepresentationFidelity::ContractError)
            bounds = union_bounds(white).map { |value| format('%.8g', value) }.join(',')
            owners = ink.map { |face| face[:source_span_id] }.compact.uniq.first(6).join(',')
            fail_contract("#{error.message}; white_bbox=[#{bounds}]; " \
                          "ink_faces=#{ink.length}; spans=#{owners}")
          end
          raise
        end
      end

      def self.partition_faces(entities)
        entities.to_a.inject([]) do |faces, entity|
          next faces unless entity.valid?
          if entity.typename.to_s == 'Face'
            faces << entity
          elsif entity.typename.to_s == 'Group'
            # Only the identity-transform groups created by topology repair are
            # present inside this private construction stage.
            faces.concat(partition_faces(entity.entities))
          end
          faces
        end
      end

      def self.clean_partition_edges!(entities)
        entities.to_a.each do |entity|
          # An earlier edge erase can invalidate a later cached edge.
          next unless entity.valid?
          if entity.typename.to_s == 'Group'
            clean_partition_edges!(entity.entities)
          elsif entity.typename.to_s == 'Edge'
            entity.faces.empty? ? entity.erase! : (entity.hidden = true)
          end
        end
      end

      def self.loop_bounds2(loop)
        [loop.map { |p| p[0] }.min, loop.map { |p| p[1] }.min,
         loop.map { |p| p[0] }.max, loop.map { |p| p[1] }.max]
      end

      def self.point_in_closed_bounds?(point, box)
        point[0] >= box[0] && point[0] <= box[2] &&
          point[1] >= box[1] && point[1] <= box[3]
      end

      def self.strict_loop_inside?(point, loop, box = nil)
        return false if box && !point_in_closed_bounds?(point, box)
        return false if loop.each_index.any? do |i|
          SvgRegionBoundary.on_segment?(point, loop[i], loop[(i + 1) % loop.length])
        end
        SvgRegionBoundary.winding(point, loop) != 0
      end

      def self.invalid_native_holes?(loops)
        return false if loops.length < 2
        rational = loops.map { |loop| loop.map { |p| [p[0].to_r, p[1].to_r] } }
        outer, holes = rational.first, rational.drop(1)
        outer_bounds = loop_bounds2(outer)
        hole_bounds = holes.map { |hole| loop_bounds2(hole) }
        # Legacy find_faces can attach a hole outside its outer shell, or attach
        # a counter again inside an existing hole. Both produce invalid native
        # faces (even negative Face#area), although their edge coordinates remain.
        holes.each do |hole|
          return true if hole.any? do |p|
            !point_in_closed_bounds?(p, outer_bounds) ||
              (SvgRegionBoundary.winding(p, outer) == 0 &&
              !outer.each_index.any? { |i| SvgRegionBoundary.on_segment?(p, outer[i], outer[(i + 1) % outer.length]) }
              )
          end
        end
        holes.each_with_index do |hole, index|
          holes.each_with_index do |other, other_index|
            next if index == other_index
            return true if hole.any? { |p| strict_loop_inside?(p, other, hole_bounds[other_index]) }
          end
        end
        false
      end

      def self.repair_native_hole_topology!(entities)
        partition_faces(entities).each do |face|
          ordered = [face.outer_loop] + face.loops.to_a.reject { |loop| loop == face.outer_loop }
          raw = ordered.map do |loop|
            loop.vertices.map { |v| [v.position.x.to_f, v.position.y.to_f, v.position.z.to_f] }
          end
          next unless invalid_native_holes?(raw)
          normalized = SvgRegionBoundary.normalize([{ :loops => raw }], :native_union)
          fail_contract('native white-mask hole topology could not be reconstructed') unless normalized
          outers, holes = normalized.partition { |loop| SvgRegionBoundary.signed_area2(loop) > 0 }
          # Keep each connected region isolated: putting it back into the same
          # legacy edge graph can recreate the malformed nested/outside holes.
          groups = outers.map do |outer|
            group = entities.add_group
            created = group.entities.add_face(outer.map { |p| Geom::Point3d.new(*p) })
            fail_contract('native white-mask outer reconstruction failed') unless created
            [outer, group]
          end
          holes.each do |hole|
            point = hole.first.first(2).map(&:to_r)
            owners = groups.select do |pair|
              strict_loop_inside?(point, pair[0].map { |p| p.first(2).map(&:to_r) })
            end
            fail_contract('native white-mask counter has no unique reconstructed shell') unless owners.length == 1
            cut = owners[0][1].entities.add_face(hole.map { |p| Geom::Point3d.new(*p) })
            fail_contract('native white-mask counter reconstruction failed') unless cut
            cut.erase!
          end
          face.erase!
        end
      end

      def self.subdivide_native_boundaries!(entities)
        unless entities.respond_to?(:intersect_with)
          fail_contract('native white-mask boundary intersection API unavailable')
        end
        identity = Geom::Transformation.new
        # add_face alone can leave overlapping coplanar faces unsplit in the
        # legacy host. Explicitly intersect all boundaries in this construction
        # context before classifying cells. The permanent 1/1000 group transform
        # is deliberately absent here, preserving safe construction tolerance.
        entities.intersect_with(false, identity, entities, identity, true, entities.to_a)
        # The legacy host needs face discovery after intersection for crossing
        # boundaries. It may also create exactly coincident duplicate faces.
        # Remove only those exact loop duplicates, not overlapping polygons or
        # approximate neighbors. All boundary/area/coverage checks remain active.
        entities.to_a.each do |entity|
          next unless entity.valid?
          entity.find_faces if entity.typename.to_s == 'Edge'
        end
        remove_duplicate_faces!(entities)
      end

      def self.canonical_loop(points)
        minimum = points.min
        candidates = []
        [points, points.reverse].each do |direction|
          direction.each_index do |index|
            next unless direction[index] == minimum
            candidates << direction.rotate(index)
          end
        end
        candidates.min
      end

      def self.face_loop_signature(face)
        loops = [face.outer_loop] + face.loops.to_a.reject { |loop| loop == face.outer_loop }
        keys = loops.map do |loop|
          canonical_loop(loop.vertices.map do |vertex|
            point = vertex.position
            [point.x.to_f, point.y.to_f, point.z.to_f]
          end)
        end
        [keys.first, keys.drop(1).sort]
      end

      def self.remove_duplicate_faces!(entities)
        seen = {}
        entities.to_a.each do |entity|
          next unless entity.valid?
          next unless entity.typename.to_s == 'Face'
          key = face_loop_signature(entity)
          if seen.key?(key)
            entity.erase!
          else
            seen[key] = true
          end
        end
      end

      def self.construction_point(point, origin)
        Geom::Point3d.new((point[0] - origin[0]) * CONSTRUCTION_SCALE,
                         (point[1] - origin[1]) * CONSTRUCTION_SCALE, 0.0)
      end

      def self.page_point(point, origin)
        [point.x.to_f / CONSTRUCTION_SCALE + origin[0],
         point.y.to_f / CONSTRUCTION_SCALE + origin[1], 0.0]
      end

      # Several interior barycentric probes per native triangle prevent an
      # unsplit face that crosses a mask/glyph boundary being erased wholesale.
      def self.face_samples(face, origin)
        mesh = face.mesh(0)
        mesh.polygons.inject([]) do |samples, polygon|
          native = polygon.map { |index| mesh.point_at(index.abs) }
          fail_contract('native face mesh is not triangulated') unless native.length == 3
          next samples if degenerate_mesh_triangle?(native)
          points = native.map { |point| page_point(point, origin) }
          [[1.0 / 3, 1.0 / 3, 1.0 / 3], [0.8, 0.1, 0.1],
           [0.1, 0.8, 0.1], [0.1, 0.1, 0.8]].each do |weights|
            samples << [0, 1, 2].map do |axis|
              points.each_with_index.inject(0.0) { |sum, (p, i)| sum + p[axis] * weights[i] }
            end
          end
          samples
        end
      end

      def self.degenerate_mesh_triangle?(points)
        x0, y0 = points[0].x.to_f, points[0].y.to_f
        term1 = (points[1].x.to_f - x0) * (points[2].y.to_f - y0)
        term2 = (points[1].y.to_f - y0) * (points[2].x.to_f - x0)
        # Face#mesh can return zero-area triangles along an existing straight
        # glyph edge. Such triangles have no interior; world-space rounding
        # can otherwise put their barycentric probes on either side of ink.
        # This is an arithmetic cancellation bound, not a small-area cutoff:
        # genuinely thin triangles with a nonzero determinant are retained.
        (term1 - term2).abs <= 8.0 * Float::EPSILON * (term1.abs + term2.abs)
      end

      def self.classify_cells(cells, origin, white, ink)
        cells.map do |face|
          samples = face_samples(face, origin)
          regions = samples.map { |point| region_at(point, white, ink) }.uniq
          unless regions.length == 1
            probes = regions.first(3).map do |region|
              point = samples.find { |sample| region_at(sample, white, ink) == region }
              "#{region}@#{point.first(2).map { |value| format('%.8g', value) }.join(',')}"
            end
            fail_contract('native white-mask face still crosses a source paint boundary: ' +
                          probes.join(' / '))
          end
          loops = [face.outer_loop] + face.loops.to_a.reject { |loop| loop == face.outer_loop }
          { :face => face, :region => regions[0], :sample => samples[0],
            :area => face.area.to_f / (CONSTRUCTION_SCALE * CONSTRUCTION_SCALE),
            :loops => loops.map { |loop| loop.vertices.map { |v| page_point(v.position, origin) } },
            :bounds => page_point(face.bounds.min, origin).first(2) +
                       page_point(face.bounds.max, origin).first(2) }
        end
      end

      def self.verify_ink_samples!(ink, white, kept, origin, ink_index = ink)
        # Check every source contour edge on both sides in addition to native
        # tessellation. This catches a small uncut glyph inside a large white
        # triangle whose ordinary centroid probes all fall outside the glyph.
        ink.each do |record|
          record[:loops].each do |loop|
            previous = loop[-1]
            loop.each do |point|
              dx = point[0] - previous[0]
              dy = point[1] - previous[1]
              length = Math.sqrt(dx * dx + dy * dy)
              if length > 1.0e-12
                distance = [length * 0.001, 1.0e-6].min
                [-1.0, 1.0].each do |side|
                  probe = [(previous[0] + point[0]) * 0.5 - side * dy / length * distance,
                           (previous[1] + point[1]) * 0.5 + side * dx / length * distance, 0.0]
                  expected = region_at(probe, white, ink_index)
                  next if expected == :outside
                  covered = point_candidates(kept, probe).any? { |cell| contains?(cell, probe) }
                  if expected == :ink && covered
                    fail_contract('white face still covers physical glyph ink')
                  elsif expected == :white && !covered
                    fail_contract('native composition removed a white counter or surrounding mask')
                  end
                end
              end
              previous = point
            end
          end
        end
      end

      def self.fail_contract(message)
        raise RepresentationFidelity::ContractError, message
      end
    end
  end
end
