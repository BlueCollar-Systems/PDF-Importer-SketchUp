# bc_pdf_vector_importer/generic_classifier.rb
# Domain-neutral classification of primitives and text.
# Identifies: title blocks, tables, dimension text, leaders,
# symbol clusters, repeated forms, geometric outlines, decorative regions.
#
# Part of Core Engine — Domain-neutral.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module GenericClassifier

      # ---------------------------------------------------------------
      # Classify all text items with domain-neutral tags.
      # Adds :domain_tags to each NormalizedText (mutates in place).
      # ---------------------------------------------------------------
      def self.classify_text(page_data)
        page_data.text_items.each do |txt|
          # Classifications from primitive_extractor are already generic.
          # Here we add deeper classification based on context.
          tags = txt.classifications.dup

          t = txt.text.strip
          tu = txt.normalized

          # Pure number → likely a dimension value or table cell
          if t =~ /\A\d+(?:\.\d+)?(?:\s+\d+\/\d+)?\z/
            tags << :numeric_value
          end

          # Contains units → dimension
          if tu =~ /\b(MM|CM|IN|FT|INCH|FEET|METER)\b/
            tags << :has_units
          end

          # Revision marker: REV, R1, REV.A
          if tu =~ /\bREV[.\s]?[A-Z0-9]?\b/
            tags << :revision_like
          end

          # Section/detail reference: DETAIL A, SECTION B-B, VIEW C
          if tu =~ /\b(DETAIL|SECTION|SEC|VIEW|ELEVATION|ELEV)\s+[A-Z]/
            tags << :detail_reference
          end

          # Note indicator: NOTE, NOTES, N.T.S., SEE DWG
          if tu =~ /\b(NOTE|NOTES|N\.?T\.?S\.?|SEE\s+DWG|REFER\s+TO)\b/
            tags << :note_indicator
          end

          # Quantity: QTY, EA, EACH, PCS
          if tu =~ /\b(QTY|EA|EACH|PCS|PIECES?)\b/
            tags << :quantity_indicator
          end

          txt.classifications = tags
        end
      end

      # ---------------------------------------------------------------
      # Classify primitives with domain-neutral geometry tags.
      # ---------------------------------------------------------------
      def self.classify_primitives(page_data)
        prims = page_data.primitives

        # Identify likely border/frame (largest rectangle near page edges)
        page_area = page_data.width * page_data.height
        prims.each do |p|
          p_tags = []

          # Large closed rectangle near page size → border
          if p.type == :closed_loop && p.area && p.area > page_area * 0.7 &&
             p.points && p.points.length <= 5
            p_tags << :page_border
          end

          # Small closed rectangle → possible table cell
          if p.type == :closed_loop && p.area && p.area < 2.0 &&
             p.points && p.points.length <= 5
            p_tags << :possible_table_cell
          end

          # Dashed line → hidden/center/phantom
          if p.dash_pattern && !p.dash_pattern.empty?
            p_tags << :dashed_line
          end

          # Very thin line (construction/reference)
          if p.line_width && p.line_width < 0.3
            p_tags << :thin_line
          end

          # Store tags in the dedicated tags field
          existing = p.tags || []
          p.tags = existing + p_tags
        end
      end

      # ---------------------------------------------------------------
      # Detect title block region from page geometry/text
      # Returns bbox [min_x, min_y, max_x, max_y] or nil
      # ---------------------------------------------------------------
      def self.detect_title_block(page_data)
        w = page_data.width
        h = page_data.height

        # Title blocks are typically in the bottom-right quadrant
        # Look for concentration of titleblock_like text
        tb_texts = page_data.text_items.select { |t|
          t.classifications.include?(:titleblock_like)
        }

        return nil if tb_texts.length < 2

        # Get bounding box of titleblock text
        xs = tb_texts.map { |t| t.insertion[0] }
        ys = tb_texts.map { |t| t.insertion[1] }

        tb_bbox = [xs.min - 0.5, ys.min - 0.5, xs.max + 0.5, ys.max + 0.5]

        # Validate: should be in lower portion of page
        if tb_bbox[3] < h * 0.4  # bottom 40%
          tb_bbox
        else
          nil
        end
      end

      # ---------------------------------------------------------------
      # Detect table regions (clusters of small rectangles + text)
      # ---------------------------------------------------------------
      def self.detect_tables(page_data)
        tables = []
        # Find clusters of small closed rectangles
        cells = page_data.primitives.select { |p|
          p.type == :closed_loop && p.area && p.area < 3.0 &&
          p.points && p.points.length <= 5
        }

        return tables if cells.length < 4

        # Cluster cells by proximity
        used = Array.new(cells.length, false)
        cells.each_with_index do |cell, i|
          next if used[i]
          cluster = [cell]
          used[i] = true

          cells.each_with_index do |other, j|
            next if i == j || used[j]
            if bboxes_adjacent?(cell.bbox, other.bbox, 0.5)
              cluster << other
              used[j] = true
            end
          end

          if cluster.length >= 4
            all_x = cluster.flat_map { |c| [c.bbox[0], c.bbox[2]] }
            all_y = cluster.flat_map { |c| [c.bbox[1], c.bbox[3]] }
            tables << {
              bbox: [all_x.min, all_y.min, all_x.max, all_y.max],
              cell_count: cluster.length
            }
          end
        end

        tables
      end

      private

      def self.bboxes_adjacent?(b1, b2, threshold)
        # Check if two bboxes are within threshold of each other
        gap_x = [[b1[0] - b2[2], b2[0] - b1[2]].max, 0].max
        gap_y = [[b1[1] - b2[3], b2[1] - b1[3]].max, 0].max
        gap_x < threshold && gap_y < threshold
      end

    end
  end
end
