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

module BlueCollarSystems
  module PDFVectorImporter
    module GeometryCleanup

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
                  joined_collinear: 0, closed_gaps: 0 }

        # Phase 1: Remove micro segments
        stats[:removed_micro] = remove_micro_edges(entities, micro_len)

        # Phase 2: Merge near-coincident vertices
        stats[:merged_verts] = merge_vertices(entities, merge_tol)

        # Phase 3: Remove duplicate edges (same two endpoints)
        stats[:removed_dupes] = remove_duplicate_edges(entities)

        # Phase 4: Join collinear segments
        stats[:joined_collinear] = join_collinear_edges(entities, collinear_tol)

        # Phase 5: Close tiny face gaps
        stats[:closed_gaps] = close_face_gaps(entities, merge_tol * 2)

        stats
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

        # Hash edges by sorted endpoint coordinates (rounded)
        edge_hash = {}
        edges.each do |edge|
          p1 = edge.start.position
          p2 = edge.end.position
          key = edge_key(p1, p2)

          if edge_hash[key]
            # Duplicate found — keep the first, remove this one
            if edge.faces.empty?
              edge.erase!
              count += 1
            end
          else
            edge_hash[key] = edge
          end
        end

        count
      end

      # ---------------------------------------------------------------
      # Phase 4: Join collinear edges that share a vertex
      # If two edges share a vertex and are collinear (same direction),
      # replace them with a single edge.
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

              next if outer1.distance(outer2) < 0.001

              # Get layer from first edge
              layer = e1.layer

              # Remove old edges and create new one
              begin
                e1.erase!
                e2.erase!
                new_edge = entities.add_line(outer1, outer2)
                new_edge.layer = layer if new_edge && layer
                count += 1
                changed = true
              rescue StandardError => e
                Logger.warn("GeometryCleanup", "merge_collinear_edges failed: #{e.message}")
              end
            end
          end
        end

        count
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

        # Try to bridge open vertices that are close
        used = {}
        open_verts.each_with_index do |v1, i|
          next if used[v1.object_id]
          next unless v1.valid?

          open_verts.each_with_index do |v2, j|
            next if j <= i
            next if used[v2.object_id]
            next unless v2.valid?

            dist = v1.position.distance(v2.position)
            if dist > 0 && dist < max_gap
              begin
                edge = entities.add_line(v1.position, v2.position)
                if edge
                  count += 1
                  used[v1.object_id] = true
                  used[v2.object_id] = true
                  break
                end
              rescue StandardError => e
                Logger.warn("GeometryCleanup", "close_face_gaps failed: #{e.message}")
              end
            end
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
