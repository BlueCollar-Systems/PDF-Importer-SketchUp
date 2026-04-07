# bc_pdf_vector_importer/generic_recognizer.rb
# Domain-neutral geometry recognition.
# Detects: closed boundaries, circles, repeated patterns,
# dimension associations, annotation leaders, tables, title block.
#
# This runs for ALL PDFs regardless of domain.
# Generic document analysis.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module GenericRecognizer

      GenericResults = Struct.new(
        :circles,           # Array of { center:, radius:, prim_id:, confidence: }
        :closed_boundaries, # Array of { prim_id:, area:, bbox:, edge_count: }
        :repeated_patterns, # Array of { prim_ids:, count:, bbox_template: }
        :tables,            # Array of { bbox:, cell_count: }
        :title_block_bbox,  # [x0,y0,x1,y1] or nil
        :dimension_assocs,  # Array of { text_id:, nearest_prim_id:, value: }
        :page_profile       # PageProfile from DocumentProfiler
      )

      # ---------------------------------------------------------------
      # Run generic recognition on a PageData.
      # Returns GenericResults.
      # ---------------------------------------------------------------
      def self.analyze(page_data, config = nil)
        config ||= RecognitionConfig.default
        prims = page_data.primitives
        texts = page_data.text_items

        # Classify text and primitives generically
        GenericClassifier.classify_text(page_data)
        GenericClassifier.classify_primitives(page_data)

        # Profile the document
        profile = DocumentProfiler.profile(page_data)

        # Detect circles (any closed loop that fits a circle well)
        circles = detect_circles(prims, config)

        # Detect significant closed boundaries
        boundaries = detect_boundaries(prims, config)

        # Detect repeated geometry patterns
        patterns = detect_repeated_patterns(prims)

        # Detect tables
        tables = GenericClassifier.detect_tables(page_data)

        # Detect title block
        tb_bbox = GenericClassifier.detect_title_block(page_data)

        # Associate dimension text with nearest geometry
        dim_assocs = associate_dimensions(texts, prims, config)

        GenericResults.new(
          circles,
          boundaries,
          patterns,
          tables,
          tb_bbox,
          dim_assocs,
          profile
        )
      end

      private

      # ---------------------------------------------------------------
      # Detect all circles in the geometry
      # ---------------------------------------------------------------
      def self.detect_circles(prims, config)
        circles = []
        prims.each do |p|
          next unless p.type == :closed_loop && p.closed
          next unless p.points && p.points.length >= 6

          fit = nil
          begin
            fit = ArcFitter.circle_fit(p.points)
          rescue StandardError => e
            Logger.warn("GenericRecognizer", "circle_fit failed: #{e.message}")
          end
          next unless fit
          cx, cy, r, rms = fit
          next if rms > config.circle_fit_tol
          next if r * 2 < 0.05  # skip micro circles

          circles << {
            center: [cx, cy],
            radius: r,
            diameter: r * 2,
            prim_id: p.id,
            rms: rms,
            confidence: rms < config.circle_fit_tol * 0.5 ? 0.95 : 0.80
          }
        end
        circles
      end

      # ---------------------------------------------------------------
      # Detect significant closed boundaries (potential outlines)
      # ---------------------------------------------------------------
      def self.detect_boundaries(prims, config)
        boundaries = []
        prims.each do |p|
          next unless p.type == :closed_loop && p.closed
          next unless p.area && p.area >= config.closed_loop_min_area

          boundaries << {
            prim_id: p.id,
            area: p.area,
            bbox: p.bbox,
            edge_count: p.points ? p.points.length : 0,
            is_rectangular: rectangular?(p)
          }
        end

        # Sort by area descending
        boundaries.sort_by! { |b| -b[:area] }
        boundaries
      end

      # ---------------------------------------------------------------
      # Detect repeated geometry patterns (same shape, different location)
      # ---------------------------------------------------------------
      def self.detect_repeated_patterns(prims)
        # Group closed loops by approximate area + point count
        groups = {}
        prims.each do |p|
          next unless p.type == :closed_loop && p.area && p.area > 0.01
          key = "#{(p.area * 100).round}_#{(p.points || []).length}"
          groups[key] ||= []
          groups[key] << p
        end

        patterns = []
        groups.each do |_, group|
          next if group.length < 3  # need at least 3 to be a "pattern"

          patterns << {
            prim_ids: group.map(&:id),
            count: group.length,
            representative_area: group.first.area,
            representative_point_count: (group.first.points || []).length
          }
        end

        patterns.sort_by! { |p| -p[:count] }
        patterns
      end

      # ---------------------------------------------------------------
      # Associate dimension-like text with nearest geometry
      # ---------------------------------------------------------------
      def self.associate_dimensions(texts, prims, config)
        assocs = []

        dim_texts = texts.select { |t| t.classifications.include?(:dimension_like) }
        dim_texts.each do |txt|
          # Parse the dimension value
          parsed = DimensionParser.parse(txt.text)
          next unless parsed.value && parsed.confidence > 0.3

          # Find nearest primitive
          nearest = nil
          nearest_dist = config.dimension_assoc_radius

          prims.each do |p|
            next unless p.bbox
            # Distance from text insertion to primitive bbox center
            pcx = (p.bbox[0] + p.bbox[2]) / 2.0
            pcy = (p.bbox[1] + p.bbox[3]) / 2.0
            d = Math.sqrt((txt.insertion[0] - pcx)**2 + (txt.insertion[1] - pcy)**2)
            if d < nearest_dist
              nearest = p
              nearest_dist = d
            end
          end

          assocs << {
            text_id: txt.id,
            text: txt.text,
            parsed_value: parsed.value,
            parsed_kind: parsed.kind,
            parsed_units: parsed.units,
            nearest_prim_id: nearest ? nearest.id : nil,
            distance: nearest_dist
          }
        end

        assocs
      end

      def self.rectangular?(prim)
        pts = prim.points
        return false unless pts && (pts.length == 4 || pts.length == 5)
        # Normalize to 4 unique corners (5th point may duplicate first for closure)
        corners = pts.length == 5 ? pts[0..3] : pts
        # Check that all 4 interior angles are approximately 90°
        (0...4).each do |i|
          p0 = corners[(i - 1) % 4]
          p1 = corners[i]
          p2 = corners[(i + 1) % 4]
          v1 = [p0[0] - p1[0], p0[1] - p1[1]]
          v2 = [p2[0] - p1[0], p2[1] - p1[1]]
          len1 = Math.sqrt(v1[0]**2 + v1[1]**2)
          len2 = Math.sqrt(v2[0]**2 + v2[1]**2)
          return false if len1 < 1e-9 || len2 < 1e-9
          dot = v1[0] * v2[0] + v1[1] * v2[1]
          cos_angle = dot / (len1 * len2)
          # cos(90°) = 0; allow ~5° tolerance → |cos| < 0.087
          return false if cos_angle.abs > 0.087
        end
        true
      end

    end
  end
end
