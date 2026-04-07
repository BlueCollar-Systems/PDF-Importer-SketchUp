# bc_pdf_vector_importer/region_segmenter.rb
# Splits an imported PDF page into logical detail regions using
# spatial clustering of geometry bounding boxes. Isolates title block,
# notes areas, and individual detail/connection zones.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module RegionSegmenter

      Region = Struct.new(
        :id,            # Integer region identifier
        :label,         # "Detail_A", "TitleBlock", "Notes", etc.
        :bbox,          # [min_x, min_y, max_x, max_y] in model space
        :entity_ids,    # Array of entity persistent IDs in this region
        :text_items,    # Array of text items within this region
        :region_type,   # :detail, :title_block, :notes, :assembly, :unknown
        :area,          # Float — bounding box area
        :edge_count,    # Number of edges in this region
        :confidence     # Float 0.0–1.0 — how sure we are of the classification
      )

      # ---------------------------------------------------------------
      # Segment a group's entities into spatial regions.
      # Returns array of Region structs.
      # ---------------------------------------------------------------
      def self.segment(group, opts = {})
        gap_threshold = opts[:gap_threshold] || 2.0   # inches — min gap between regions
        min_region_edges = opts[:min_region_edges] || 3

        entities = group.entities
        edges = entities.grep(Sketchup::Edge).select(&:valid?)
        texts = entities.grep(Sketchup::Text)

        return [] if edges.empty?

        # Build bounding boxes for each edge
        edge_boxes = edges.map do |e|
          pts = [e.start.position, e.end.position]
          x_min = pts.map(&:x).min
          y_min = pts.map(&:y).min
          x_max = pts.map(&:x).max
          y_max = pts.map(&:y).max
          { edge: e, bbox: [x_min, y_min, x_max, y_max],
            cx: (x_min + x_max) / 2.0, cy: (y_min + y_max) / 2.0 }
        end

        # Cluster edges by proximity using simple grid-based grouping
        clusters = cluster_by_proximity(edge_boxes, gap_threshold)

        # Filter out tiny clusters
        clusters = clusters.select { |c| c.length >= min_region_edges }

        # Build regions
        regions = []
        clusters.each_with_index do |cluster, idx|
          # Compute aggregate bounding box
          all_x = cluster.flat_map { |eb| [eb[:bbox][0], eb[:bbox][2]] }
          all_y = cluster.flat_map { |eb| [eb[:bbox][1], eb[:bbox][3]] }
          bbox = [all_x.min, all_y.min, all_x.max, all_y.max]
          area = (bbox[2] - bbox[0]) * (bbox[3] - bbox[1])

          # Find text items within this region's bbox
          region_texts = texts.select do |t|
            pt = t.point
            pt.x >= bbox[0] && pt.x <= bbox[2] && pt.y >= bbox[1] && pt.y <= bbox[3]
          end

          entity_ids = cluster.map { |eb| eb[:edge].entityID }

          region = Region.new(
            idx,
            "Region_#{idx}",
            bbox,
            entity_ids,
            region_texts.map { |t| t.text },
            :unknown,
            area,
            cluster.length,
            0.5
          )

          regions << region
        end

        # Classify regions
        classify_regions(regions, group)

        regions
      end

      # ---------------------------------------------------------------
      # Classify detected regions
      # ---------------------------------------------------------------
      def self.classify_regions(regions, group)
        return if regions.empty?

        # Get the full page bounding box
        page_bb = group.bounds
        page_w = page_bb.width
        page_h = page_bb.height
        page_area = page_w * page_h
        return if page_area <= 0

        regions.each do |r|
          r_w = r.bbox[2] - r.bbox[0]
          r_h = r.bbox[3] - r.bbox[1]
          r_area_ratio = r.area / page_area

          # Title block: typically bottom-right, narrow and wide or boxed
          is_bottom = r.bbox[1] < page_h * 0.15
          is_right = r.bbox[2] > page_w * 0.6
          is_narrow_band = r_h < page_h * 0.2
          has_title_text = r.text_items.any? { |t|
            t =~ /\b(DRAWN|CHECKED|DATE|SCALE|REV|SHEET|PROJECT|DWG|TITLE)\b/i
          }

          if (is_bottom && is_right && is_narrow_band) || has_title_text
            r.region_type = :title_block
            r.label = "TitleBlock"
            r.confidence = has_title_text ? 0.95 : 0.7
            next
          end

          # Notes area: lots of text, few edges relative to area
          text_density = r.text_items.length.to_f / [r.area, 0.01].max
          edge_density = r.edge_count.to_f / [r.area, 0.01].max

          if r.text_items.length > 5 && text_density > edge_density * 2
            r.region_type = :notes
            r.label = "Notes"
            r.confidence = 0.75
            next
          end

          # Assembly: largest region with many edges
          if r_area_ratio > 0.3 && r.edge_count > 50
            r.region_type = :assembly
            r.label = "Assembly"
            r.confidence = 0.65
            next
          end

          # Detail: small to medium region with dense geometry
          if r.edge_count >= 10 && r_area_ratio < 0.4
            r.region_type = :detail
            # Try to name from nearby text
            detail_label = find_detail_label(r)
            r.label = detail_label || "Detail_#{r.id}"
            r.confidence = detail_label ? 0.8 : 0.5
            next
          end

          r.region_type = :unknown
          r.confidence = 0.3
        end
      end

      private

      # ---------------------------------------------------------------
      # Grid-based proximity clustering
      # ---------------------------------------------------------------
      def self.cluster_by_proximity(edge_boxes, gap)
        return [] if edge_boxes.empty?

        # Assign each edge to a grid cell
        cell_size = gap * 3
        cells = {}

        edge_boxes.each do |eb|
          gx = (eb[:cx] / cell_size).floor
          gy = (eb[:cy] / cell_size).floor
          key = "#{gx}_#{gy}"
          cells[key] ||= []
          cells[key] << eb
        end

        # Union-find for merging adjacent cells
        parent = {}
        cells.each_key { |k| parent[k] = k }

        find = lambda { |x|
          while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
          end
          x
        }

        unite = lambda { |a, b|
          ra, rb = find.call(a), find.call(b)
          parent[ra] = rb if ra != rb
        }

        # Merge cells that are adjacent (8-connected)
        cells.each_key do |key|
          gx, gy = key.split('_').map(&:to_i)
          (-1..1).each do |dx|
            (-1..1).each do |dy|
              neighbor = "#{gx + dx}_#{gy + dy}"
              if cells[neighbor]
                unite.call(key, neighbor)
              end
            end
          end
        end

        # Collect clusters
        groups = {}
        cells.each do |key, edges|
          root = find.call(key)
          groups[root] ||= []
          groups[root].concat(edges)
        end

        groups.values
      end

      # ---------------------------------------------------------------
      # Try to find a detail label from text (e.g., "DETAIL A", "SEC B-B")
      # ---------------------------------------------------------------
      def self.find_detail_label(region)
        region.text_items.each do |text|
          if text =~ /\bDETAIL\s+([A-Z](?:\d)?)\b/i
            return "Detail_#{$1}"
          end
          if text =~ /\bSEC(?:TION)?\s+([A-Z])\s*[-–]\s*([A-Z])\b/i
            return "Section_#{$1}-#{$2}"
          end
          if text =~ /\bVIEW\s+([A-Z])\b/i
            return "View_#{$1}"
          end
        end
        nil
      end

    end
  end
end
