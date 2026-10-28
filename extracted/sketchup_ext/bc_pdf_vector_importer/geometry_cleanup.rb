# bc_pdf_vector_importer/geometry_cleanup.rb
# Post-import geometry cleanup engine for SketchUp.
# Fixes the common mess from CAD PDF imports:
#   - micro segments
#   - duplicate edges
#   - overlapping lines
#   - collinear segments that should be one edge
#   - tiny gaps preventing face creation
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.
require 'json'

module BlueCollarSystems
  module PDFVectorImporter
    module GeometryCleanup
      # Callers own the model operation and must abort on this error. A failed
      # destructive join cannot be downgraded to a warning and committed.
      class CleanupFailure < StandardError; end

      def self.source_width_owned?(group)
        return false unless group.respond_to?(:get_attribute) &&
          group.get_attribute('BC_PDF_Importer','source_width_footprint',false) == true
        begin
          style=JSON.parse(group.get_attribute('BC_PDF_Importer','source_width_style',''))
          width=style['source_width_pdf_points']
          matrix=style['source_ctm']
          rgb=style['source_rgb']
          valid=width.is_a?(Numeric) && width.to_f.finite? && width > 0 &&
            matrix.is_a?(Array) && matrix.length == 6 && matrix.all? { |v| v.is_a?(Numeric) && v.to_f.finite? } &&
            rgb.is_a?(Array) && rgb.length == 3 && rgb.all? { |v| v.is_a?(Integer) && v >= 0 && v <= 255 } &&
            [0,1,2].include?(style['source_line_cap']) && [0,1,2].include?(style['source_line_join']) &&
            style['native_curve_representation'] == 'source_sampled_polygonal_footprint'
          raise 'invalid source width/style binding' unless valid
        rescue StandardError => error
          raise CleanupFailure, 'Claimed source-width stroke ownership is incomplete: ' + error.message
        end
        true
      end

      # A selected footprint or one of its child groups reaches cleanup through
      # Entities rather than its owning Group. Follow normal definition/instance
      # ancestry without modifying any native object or image definition.
      def self.source_width_ancestor?(entities)
        return false unless entities.respond_to?(:parent)
        pending=[entities.parent]; visited={}
        until pending.empty?
          owner=pending.pop
          next if owner.nil? || visited[owner.object_id]
          visited[owner.object_id]=true
          raise CleanupFailure, 'Source-stroke cleanup ancestry budget exceeded' if visited.length > 4096
          return true if source_width_owned?(owner)
          if owner.respond_to?(:instances)
            pending.concat(owner.instances.to_a)
          elsif owner.respond_to?(:parent)
            pending << owner.parent
          end
        end
        false
      end

      # ---------------------------------------------------------------
      # Run the full cleanup pipeline on a group's entities.
      # Returns a stats hash.
      # ---------------------------------------------------------------
      def self.cleanup(entities, opts = {})
        # Resolve cleanup_level preset if provided (Phase 2)
        if opts[:cleanup_level] && defined?(ImportConfig)
          preset = ImportConfig::CLEANUP_PRESETS[opts[:cleanup_level].to_s]
          if preset
            opts = preset.merge(opts) { |_k, preset_v, user_v| user_v }
          end
        end

        merge_tol     = opts[:merge_tolerance] || 0.005   # inches
        collinear_tol = opts[:collinear_tolerance] || 0.001
        micro_len     = opts[:min_edge_length] || 0.002   # inches

        stats = { merged_verts: 0, removed_dupes: 0, removed_micro: 0,
                  joined_collinear: 0, closed_gaps: 0, preserved_source_strokes: 0 }
        pulse!
        if source_width_ancestor?(entities)
          stats[:preserved_source_strokes]=1
          return stats
        end

        # Nested color/page Groups often hold the real edges. Top-level-only
        # cleanup left them dirty so SketchUp 2017 save/reopen could heal
        # them differently and break host continuity digests.
        entities.grep(Sketchup::Group).each do |group|
          next unless group.respond_to?(:valid?) && group.valid?
          if source_width_owned?(group)
            stats[:preserved_source_strokes] += 1
            next
          end
          begin
            nested = cleanup(group.entities, opts)
            nested.each do |key, value|
              stats[key] = (stats[key] || 0) + value.to_i
            end
          rescue CleanupFailure
            raise
          rescue StandardError => e
            Logger.warn("GeometryCleanup", "nested group cleanup failed: #{e.message}")
          end
        end

        # Phase 1: Remove micro segments
        stats[:removed_micro] += remove_micro_edges(entities, micro_len)
        pulse!

        # Phase 2: Merge near-coincident vertices
        stats[:merged_verts] += merge_vertices(entities, merge_tol)
        pulse!

        # Phase 3: Remove duplicate edges (same two endpoints)
        stats[:removed_dupes] += remove_duplicate_edges(entities)
        pulse!

        # Phase 4: Join collinear segments
        stats[:joined_collinear] += join_collinear_edges(entities, collinear_tol)
        pulse!

        # Phase 5: Close tiny face gaps
        stats[:closed_gaps] += close_face_gaps(entities, merge_tol * 2)
        pulse!

        # Joining/bridging can leave redundant native edges after Phase 3.
        # SketchUp 2017 repaired shared-vertex duplicates on the first Save,
        # inserting a separate Check Validity Undo step. Remove only exact,
        # equally styled loose duplicates inside the caller's import operation.
        stats[:removed_dupes] += remove_exact_duplicate_loose_edges(entities)

        stats
      end

      # Keeps SketchUp's window answering Windows during a long cleanup.
      def self.pulse!
        ImportRunControl.heartbeat!(:cleanup) if defined?(ImportRunControl)
      end

      # ---------------------------------------------------------------
      # Phase 1: Remove edges shorter than threshold
      # ---------------------------------------------------------------
      def self.remove_micro_edges(entities, min_length)
        count = 0
        edges = entities.grep(Sketchup::Edge)
        edges.each do |edge|
          begin
            if edge.valid? && edge.length < min_length
              # Don't remove edges that are part of a face
              if edge.faces.empty?
                edge.erase!
                count += 1
              end
            end
          rescue StandardError => e
            Logger.warn("GeometryCleanup", "remove_short_edges failed: #{e.message}")
          end
        end
        count
      end

      # ---------------------------------------------------------------
      # Phase 2: Merge vertices that are within tolerance
      # Uses spatial hashing for performance on large models.
      # ---------------------------------------------------------------
      def self.merge_vertices(entities, tolerance)
        count = 0
        edges = entities.grep(Sketchup::Edge).select(&:valid?)
        return 0 if edges.empty?

        # Build spatial hash of vertex positions
        cell_size = tolerance * 2
        vertex_map = {}  # { grid_key => [vertex, ...] }

        all_verts = []
        edges.each do |e|
          all_verts << e.start if e.valid?
          all_verts << e.end if e.valid?
        end
        all_verts.uniq!

        all_verts.each do |v|
          key = grid_key(v.position, cell_size)
          vertex_map[key] ||= []
          vertex_map[key] << v
        end

        # Find merge candidates
        merge_pairs = []  # [[victim_vertex, target_point], ...]
        processed = {}

        vertex_map.each do |key, verts|
          next if verts.length < 2

          # Check all pairs in this cell
          (0...verts.length).each do |i|
            ((i + 1)...verts.length).each do |j|
              next unless verts[i].valid? && verts[j].valid?
              next if processed[verts[i].object_id] || processed[verts[j].object_id]

              dist = verts[i].position.distance(verts[j].position)
              if dist < tolerance && dist > 0
                # Move verts[j] to verts[i]'s position
                merge_pairs << [verts[j], verts[i].position]
                processed[verts[j].object_id] = true
              end
            end
          end
        end

        # Apply merges by moving vertices
        merge_pairs.each do |victim, target_pos|
          begin
            if victim.valid?
              # Find all edges connected to this vertex and adjust
              victim.edges.each do |edge|
                next unless edge.valid?
                if edge.start == victim || edge.end == victim
                  # Move whichever end matches the victim vertex
                  other_vert = (edge.start == victim) ? edge.end : edge.start
                  if other_vert.position.distance(target_pos) > 0.0001
                    begin
                      entities.transform_entities(
                        Geom::Transformation.new(target_pos - victim.position),
                        victim
                      )
                    rescue StandardError => e
                      Logger.warn("GeometryCleanup", "transform_entities failed: #{e.message}")
                    end
                  end
                end
              end
              count += 1
            end
          rescue StandardError => e
            Logger.warn("GeometryCleanup", "merge_vertices failed: #{e.message}")
          end
        end

        count
      end

      # ---------------------------------------------------------------
      # Phase 3: Remove duplicate edges (same endpoints, different objects)
      # ---------------------------------------------------------------
      def self.remove_duplicate_edges(entities)
        count = 0
        edges = entities.grep(Sketchup::Edge).select(&:valid?)

        # Hash edges by sorted endpoint coordinates (rounded).
        #
        # The snapshot above goes stale as we erase: erasing one edge can also
        # delete others (SketchUp removes geometry that the erase orphans), so a
        # later element of `edges` may already be gone by the time we reach it.
        # Dereferencing it then raises TypeError: reference to deleted Edge,
        # which — unlike every other phase in this file — used to escape
        # uncaught and abort the whole page import via the pipeline's re-raise.
        # Re-check validity each iteration and contain per-edge failures.
        edge_hash = {}
        edges.each do |edge|
          begin
            next unless edge.valid?

            p1 = edge.start.position
            p2 = edge.end.position
            key = edge_key(p1, p2)

            kept = edge_hash[key]
            if kept && kept.valid?
              # Duplicate found — keep the first, remove this one
              if edge.faces.empty?
                edge.erase!
                count += 1
              end
            else
              # No survivor for this key yet (or the previous keeper was itself
              # erased as a side effect), so this edge becomes the keeper.
              edge_hash[key] = edge
            end
          rescue StandardError => e
            Logger.warn("GeometryCleanup", "remove_duplicate_edges failed: #{e.message}")
          end
        end

        count
      end

      def self.exact_loose_edge_signature(edge)
        return nil unless edge.valid? && edge.faces.empty?
        style = joinable_edge_style(edge)
        return nil unless style
        endpoints = [edge.start, edge.end].map do |vertex|
          return nil unless vertex.respond_to?(:entityID)
          identity = vertex.entityID
          return nil unless identity.is_a?(Integer) && identity > 0
          position = vertex.position
          coordinates = [position.x.to_f, position.y.to_f, position.z.to_f]
          return nil unless coordinates.all? { |value| value.finite? }
          [identity, coordinates]
        end.sort_by { |endpoint| endpoint[0] }
        return nil if endpoints[0][0] == endpoints[1][0]
        [endpoints, style]
      end

      # Unlike the earlier rounded cleanup, this final sweep must preserve
      # distinct coincident vertices, nearby strokes, faces, curves, attributes
      # and every style property. A matching source segment must survive erase.
      #
      # Erasing the duplicate can make SketchUp heal: a vertex left with only
      # the kept edge and one other edge is merged away, leaving one longer
      # edge, whenever it lies within SketchUp's 0.001 in tolerance of the
      # segment between their far ends, at any angle. Measured in SketchUp
      # 2017 on a handrail sheet (2026-10-23): 3 of 7 erasures merged the
      # kept edge into its same-style neighbour, so the kept object was gone
      # although its segment was still drawn. Requiring that exact object
      # stopped the page. The rule is now checked on the strokes themselves:
      # every edge around the duplicate must still be drawn, in its own style,
      # and nothing may be drawn beyond them. A heal that would join different
      # styles or owned edges, or that would bend a line which is not exactly
      # straight (a short segment of a flattened curve), is never started;
      # both copies are kept instead.
      #
      # A heal can also make a new exact duplicate: an edge that grows onto
      # two vertices another same-style edge already joins. Survivors are
      # filed under the vertices they had when first seen, so the grown edge
      # was never compared again and the pair stayed for Save to repair.
      # After every accepted erase the live edges around it are checked again
      # at once, under their current vertices. A native erase or heal never
      # adds edges, so erasures cannot outnumber the edges swept. If they
      # ever do, re-checks stop and the sweep only finishes the edges it
      # listed at the start, so it always ends.
      def self.remove_exact_duplicate_loose_edges(entities)
        return 0 if source_width_ancestor?(entities)
        count = 0
        survivors = {}
        pending = entities.grep(Sketchup::Edge)
        swept = pending.length
        until pending.empty?
          edge = pending.shift
          signature = exact_loose_edge_signature(edge)
          next unless signature
          endpoints, style = signature
          bucket = (survivors[endpoints] ||= [])
          kept = bucket.find do |candidate|
            !heal_same?(candidate, edge) && exact_loose_edge_signature(candidate) == signature
          end
          unless kept
            bucket << edge unless bucket.any? { |candidate| heal_same?(candidate, edge) }
            next
          end

          neighbourhood = duplicate_erase_neighbourhood(kept, edge, style)
          next unless neighbourhood
          edge.erase!
          around = edge.valid? ? nil : heal_ring_edges(neighbourhood[:ring], nil)
          unless around && duplicate_erase_preserved?(neighbourhood, around)
            raise CleanupFailure, 'exact duplicate cleanup did not preserve its native source edge'
          end
          count += 1
          pending.unshift(*around) if count <= swept
        end
        count
      rescue CleanupFailure
        raise
      rescue StandardError => error
        # An erase may already have changed native topology. The caller must
        # roll back its operation rather than commit an uncertain cleanup.
        raise CleanupFailure, "exact duplicate cleanup failed (#{error.class}): #{error.message}"
      end

      # Inches. A hundred times finer than SketchUp's own 0.001 in tolerance.
      HEAL_POINT_TOLERANCE = 1.0e-5
      # Inches. SketchUp 2017 (17.2.2555) merged the two edges left at a
      # vertex whenever the vertex lay within about 0.001 in of the segment
      # between their far ends, whatever the angle: on made-up edges 0.005 to
      # 100 in long it healed at 0.000999 in from that segment and never at
      # 0.0015 in or more (2026-10-23). Twice its tolerance leaves a margin.
      # Farther than this no heal is expected.
      HEAL_POSSIBLE_DISTANCE = 2.0e-3
      # Sine of the angle between two edges at a vertex at or below which they
      # are one straight line: a merged edge then stays within the point
      # tolerance for 1,000 in. Any other heal bends or moves ink, so the
      # duplicate stays.
      HEAL_STRAIGHT_SINE = 1.0e-9

      # Records every edge within two vertices of the kept edge (the duplicate
      # excluded) before the erase, or returns nil when the erase must not
      # happen: a vertex that would be left with the kept edge and one other
      # edge may be healed when it lies within HEAL_POSSIBLE_DISTANCE of the
      # segment between their far ends, and that is only allowed when the
      # other edge is loose, unowned, exactly straight-on and styled exactly
      # the same.
      def self.duplicate_erase_neighbourhood(kept, duplicate, style)
        vertices = [kept.start, kept.end]
        return nil unless vertices.all? { |vertex| vertex.respond_to?(:edges) }
        vertices.each do |vertex|
          others = vertex.edges.select do |other|
            other.valid? && !heal_same?(other, kept) && !heal_same?(other, duplicate)
          end
          next unless others.length == 1
          other = others.first
          relation = native_heal_relation(kept, other, vertex)
          next if relation == :none
          return nil unless relation == :joins && other.faces.empty? &&
                            joinable_edge_style(other) == style
        end
        ring = []
        vertices.each do |vertex|
          vertex.edges.each do |other|
            next if !other.valid? || heal_same?(other, duplicate)
            [other.start, other.end].each do |point|
              ring << point unless ring.any? { |seen| heal_same?(seen, point) }
            end
          end
        end
        { :ring => ring,
          :records => heal_ring_edges(ring, duplicate).map { |other| heal_record(other) } }
      end

      # Called only after the duplicate is gone, so no deleted entity is read.
      # +around+ is heal_ring_edges(neighbourhood[:ring], nil) read after it.
      def self.duplicate_erase_preserved?(neighbourhood, around)
        before = neighbourhood[:records]
        after = around.map { |other| heal_record(other) }
        kept_drawn = before.all? { |old| heal_record_drawn?(old, after) }
        nothing_added = after.all? { |now| heal_record_drawn?(now, before) }
        kept_drawn && nothing_added
      end

      # Either the same edge with the same ends and style, or a loose stroke
      # covered end to end by edges of exactly its style in +records+. Faced,
      # attributed and curve edges (style nil) must be unchanged.
      def self.heal_record_drawn?(record, records)
        same = records.find { |other| heal_same?(other[:edge], record[:edge]) }
        return true if same && same[:style] == record[:style] &&
                       ([same[:from], same[:to]] == [record[:from], record[:to]] ||
                        [same[:to], same[:from]] == [record[:from], record[:to]])
        return false if record[:style].nil?
        heal_covered?(record, records.select { |other| other[:style] == record[:style] })
      end

      # Identity of two native entities. A deleted one is only ever equal to
      # its own reference and is never asked anything else.
      def self.heal_same?(first, second)
        return true if first.equal?(second)
        return false if first.nil? || second.nil?
        first.valid? && second.valid? && first == second
      end

      # What a native erase may do at +vertex+ once only +kept+ and +other+
      # are left there: :none (the vertex is too far from the segment between
      # their far ends for SketchUp to merge them), :joins (the two run
      # exactly straight on from each other, so a merge moves no ink) or
      # :uncertain (a merge is possible and would bend or move the line).
      # SketchUp decides by that distance, not by the angle, so a short
      # segment turning a few hundredths of a radian is merged too. An other
      # edge lying along the kept one from the same vertex is as far from
      # that segment as the shorter of the two is long, so it is :none.
      def self.native_heal_relation(kept, other, vertex)
        origin = heal_xyz(vertex)
        far_kept = heal_same?(kept.start, vertex) ? kept.end : kept.start
        far_other = heal_same?(other.start, vertex) ? other.end : other.start
        # Another edge between the same two vertices (a copy in another
        # style) is no end-to-end junction; a native heal cannot join them.
        return :none if heal_same?(far_other, far_kept)
        kept_end = heal_xyz(far_kept)
        other_end = heal_xyz(far_other)
        a = heal_sub(kept_end, origin)
        b = heal_sub(other_end, origin)
        lengths = Math.sqrt(heal_dot(a, a)) * Math.sqrt(heal_dot(b, b))
        return :uncertain unless lengths > 0.0 && lengths.finite?
        gap = heal_segment_distance(origin, kept_end, other_end)
        return :uncertain unless gap.finite?
        return :none if gap > HEAL_POSSIBLE_DISTANCE
        sine = heal_cross_length(a, b) / lengths
        return :joins if sine <= HEAL_STRAIGHT_SINE && heal_dot(a, b) < 0.0
        :uncertain
      end

      # Distance from +point+ to the segment from +first+ to +last+.
      def self.heal_segment_distance(point, first, last)
        axis = heal_sub(last, first)
        length_squared = heal_dot(axis, axis)
        offset = heal_sub(point, first)
        along = length_squared > 0.0 ? heal_dot(offset, axis) / length_squared : 0.0
        along = 0.0 unless along > 0.0
        along = 1.0 if along > 1.0
        nearest = [first[0] + axis[0] * along, first[1] + axis[1] * along,
                   first[2] + axis[2] * along]
        apart = heal_sub(point, nearest)
        Math.sqrt(heal_dot(apart, apart))
      end

      def self.heal_ring_edges(ring, excluded)
        found = []
        ring.each do |vertex|
          next unless vertex.valid?
          vertex.edges.each do |other|
            next if !other.valid? || heal_same?(other, excluded)
            found << other unless found.any? { |seen| heal_same?(seen, other) }
          end
        end
        found
      end

      def self.heal_record(edge)
        style = edge.faces.empty? ? joinable_edge_style(edge) : nil
        { :edge => edge, :from => heal_xyz(edge.start), :to => heal_xyz(edge.end),
          :style => style }
      end

      # True when the union of the candidate strokes lying on the target's
      # line covers the target from end to end.
      def self.heal_covered?(target, candidates)
        origin = target[:from]
        axis = heal_sub(target[:to], origin)
        length_squared = heal_dot(axis, axis)
        return false unless length_squared > 0.0 && length_squared.finite?
        spans = []
        candidates.each do |candidate|
          start = candidate[:from]
          direction = heal_sub(candidate[:to], start)
          size = Math.sqrt(heal_dot(direction, direction))
          next unless size > 0.0
          on_line = [target[:from], target[:to]].all? do |point|
            heal_cross_length(direction, heal_sub(point, start)) / size <= HEAL_POINT_TOLERANCE
          end
          next unless on_line
          ends = [candidate[:from], candidate[:to]].map do |point|
            heal_dot(heal_sub(point, origin), axis) / length_squared
          end
          spans << ends.sort
        end
        slack = HEAL_POINT_TOLERANCE / Math.sqrt(length_squared)
        reach = 0.0
        spans.sort_by { |span| span[0] }.each do |low, high|
          break if low > reach + slack
          reach = high if high > reach
        end
        reach >= 1.0 - slack
      end

      def self.heal_xyz(vertex)
        point = vertex.position
        [point.x.to_f, point.y.to_f, point.z.to_f]
      end

      def self.heal_sub(a, b)
        [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
      end

      def self.heal_dot(a, b)
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
      end

      def self.heal_cross_length(a, b)
        x = a[1] * b[2] - a[2] * b[1]
        y = a[2] * b[0] - a[0] * b[2]
        z = a[0] * b[1] - a[1] * b[0]
        Math.sqrt(x * x + y * y + z * z)
      end

      # ---------------------------------------------------------------
      # Phase 4: Join collinear edges that share a vertex
      # Only replace a true between-endpoints junction. Two collinear edges
      # can instead overlap on the same side of their shared vertex; joining
      # their other endpoints would erase part of the source stroke union.
      # ---------------------------------------------------------------
      def self.join_collinear_edges(entities, tolerance)
        count = 0
        changed = true

        while changed
          changed = false
          edges = entities.grep(Sketchup::Edge).select(&:valid?)

          # Build vertex → edges map
          vert_edges = {}
          edges.each do |e|
            [e.start, e.end].each do |v|
              vert_edges[v.object_id] ||= []
              vert_edges[v.object_id] << e
            end
          end

          # Look for vertices with exactly 2 edges that are collinear
          vert_edges.each do |vid, vedges|
            next unless vedges.length == 2
            next unless vedges.all?(&:valid?)

            e1, e2 = vedges
            # Both must be simple edges (no faces)
            next unless e1.faces.empty? && e2.faces.empty?
            style = joinable_edge_style(e1)
            next unless style && style == joinable_edge_style(e2)

            # Check collinearity
            v1 = e1.line[1]  # direction vector
            v2 = e2.line[1]

            # Vectors should be parallel (cross product ≈ 0)
            cross = v1.cross(v2)
            if cross.length < tolerance
              # They're collinear — find the two outer endpoints
              shared_vert = nil
              [e1.start, e1.end].each do |v|
                if v == e2.start || v == e2.end
                  shared_vert = v
                  break
                end
              end
              next unless shared_vert

              # Get the two endpoints that aren't shared
              outer1 = (e1.start == shared_vert) ? e1.end.position : e1.start.position
              outer2 = (e2.start == shared_vert) ? e2.end.position : e2.start.position

              # Directions must point away from the shared vertex on opposite
              # rays. Parallel line vectors alone cannot distinguish a junction
              # from a nested overlap, and edge start/end order is arbitrary.
              ray1 = outer1 - shared_vert.position
              ray2 = outer2 - shared_vert.position
              next unless ray1.dot(ray2) < 0.0
              next if outer1.distance(outer2) < 0.001

              # Remove old edges and create new one
              begin
                e1.erase!
                e2.erase!
                new_edge = entities.add_line(outer1, outer2)
                unless new_edge && new_edge.respond_to?(:valid?) && new_edge.valid?
                  raise CleanupFailure, 'native host did not create the joined source edge'
                end
                style.each do |property, value|
                  new_edge.public_send("#{property}=", value)
                end
                unless joinable_edge_style(new_edge) == style
                  raise CleanupFailure, 'native joined edge did not retain the source style'
                end
                count += 1
                changed = true
              rescue StandardError => e
                raise CleanupFailure,
                  "collinear source-edge cleanup failed (#{e.class}): #{e.message}"
              end
            end
          end
        end

        count
      end

      # Cleanup must not collapse source ownership, native curves, or distinct
      # edge appearance. Attributed edges stay intact because a new single edge
      # cannot honestly inherit two independent source/extension identities.
      def self.joinable_edge_style(edge)
        if edge.respond_to?(:attribute_dictionaries)
          dictionaries = edge.attribute_dictionaries
          return nil if dictionaries && !dictionaries.to_a.empty?
        end
        return nil if edge.respond_to?(:curve) && edge.curve
        style = {}
        { :layer => :layer, :material => :material, :hidden => :hidden?,
          :soft => :soft?, :smooth => :smooth?,
          :casts_shadows => :casts_shadows? }.each do |property, reader|
          next unless edge.respond_to?(reader)
          return nil unless edge.respond_to?("#{property}=")
          style[property] = edge.public_send(reader)
        end
        style
      end

      # ---------------------------------------------------------------
      # Phase 5: Close tiny gaps to enable face creation
      # Finds open endpoints near other endpoints and bridges them.
      # ---------------------------------------------------------------
      def self.close_face_gaps(entities, max_gap)
        count = 0
        edges = entities.grep(Sketchup::Edge).select(&:valid?)

        # Find "open" vertices (connected to only one edge)
        open_verts = []
        vert_count = {}
        edges.each do |e|
          [e.start, e.end].each do |v|
            vert_count[v.object_id] ||= 0
            vert_count[v.object_id] += 1
          end
        end

        edges.each do |e|
          [e.start, e.end].each do |v|
            if vert_count[v.object_id] == 1
              open_verts << v
            end
          end
        end

        return 0 if open_verts.length < 2

        # Spatial hash (same grid as merge_vertices). Pairing rule stays the
        # prior first later-index match within max_gap — only the candidate
        # search is narrowed from all-pairs to neighbor cells.
        cell_size = max_gap * 2
        vertex_map = {}
        open_verts.each_with_index do |v, index|
          next unless v.valid?
          key = grid_key(v.position, cell_size)
          vertex_map[key] ||= []
          vertex_map[key] << [index, v]
        end

        used = {}
        open_verts.each_with_index do |v1, i|
          next if used[v1.object_id]
          next unless v1.valid?

          p1 = v1.position
          gx = (p1.x / cell_size).floor
          gy = (p1.y / cell_size).floor
          gz = (p1.z / cell_size).floor
          best_index = nil
          best_v2 = nil

          (-1..1).each do |dx|
            (-1..1).each do |dy|
              (-1..1).each do |dz|
                neighbors = vertex_map["#{gx + dx}_#{gy + dy}_#{gz + dz}"]
                next unless neighbors
                neighbors.each do |j, v2|
                  next if j <= i
                  next if used[v2.object_id]
                  next unless v2.valid?
                  dist = p1.distance(v2.position)
                  next unless dist > 0 && dist < max_gap
                  if best_index.nil? || j < best_index
                    best_index = j
                    best_v2 = v2
                  end
                end
              end
            end
          end

          next unless best_v2
          begin
            edge = entities.add_line(p1, best_v2.position)
            if edge
              count += 1
              used[v1.object_id] = true
              used[best_v2.object_id] = true
            end
          rescue StandardError => e
            Logger.warn("GeometryCleanup", "close_face_gaps failed: #{e.message}")
          end
        end

        count
      end

      private

      def self.grid_key(point, cell_size)
        gx = (point.x / cell_size).floor
        gy = (point.y / cell_size).floor
        gz = (point.z / cell_size).floor
        "#{gx}_#{gy}_#{gz}"
      end

      def self.edge_key(p1, p2, precision = 4)
        # Sort the two points so the key is the same regardless of direction
        coords1 = [p1.x.round(precision), p1.y.round(precision), p1.z.round(precision)]
        coords2 = [p2.x.round(precision), p2.y.round(precision), p2.z.round(precision)]
        sorted = [coords1, coords2].sort
        "#{sorted[0].join(',')}_#{sorted[1].join(',')}"
      end

    end
  end
end
