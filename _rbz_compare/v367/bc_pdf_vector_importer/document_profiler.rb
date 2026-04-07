# bc_pdf_vector_importer/document_profiler.rb
# Auto-detects page type before recognition. Scores the page as:
# CAD drawing, architectural, fabrication, schematic, table-heavy,
# vector art, mixed, or raster-only.
#
# Part of the Core Engine — domain-neutral.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module DocumentProfiler

      PROFILES = [:cad_drawing, :architectural, :fabrication,
                  :schematic, :table_heavy, :vector_art,
                  :mixed, :raster_only, :unknown].freeze

      PageProfile = Struct.new(
        :page_number,
        :primary_type,    # Symbol from PROFILES
        :scores,          # Hash { profile => Float }
        :has_layers,      # Boolean — OCG layers present
        :has_text,        # Boolean
        :has_dimensions,  # Boolean
        :circle_count,    # Integer — circles/arcs found
        :closed_loop_count,
        :line_count,
        :text_count,
        :titleblock_likely # Boolean
      )

      # ---------------------------------------------------------------
      # Profile a PageData → PageProfile
      # ---------------------------------------------------------------
      def self.profile(page_data)
        prims = page_data.primitives
        texts = page_data.text_items

        # Count geometry types
        lines = prims.count { |p| p.type == :line }
        closed = prims.count { |p| p.type == :closed_loop }
        polylines = prims.count { |p| p.type == :polyline }
        total_geom = prims.length

        # Count text types
        dim_texts = texts.count { |t| t.classifications.include?(:dimension_like) }
        scale_texts = texts.count { |t| t.classifications.include?(:scale_like) }
        tb_texts = texts.count { |t| t.classifications.include?(:titleblock_like) }
        callout_texts = texts.count { |t| t.classifications.include?(:callout_like) }
        total_text = texts.length

        # Estimate circle count from closed loops
        circles = 0
        prims.each do |p|
          next unless p.type == :closed_loop && p.points && p.points.length >= 8
          fit = nil
          begin
            fit = ArcFitter.circle_fit(p.points)
          rescue StandardError => e
            Logger.warn("DocumentProfiler", "circle_fit failed: #{e.message}")
          end
          circles += 1 if fit && fit[3] < 0.02
        end

        # Page area and density
        page_area = page_data.width * page_data.height
        geom_density = page_area > 0 ? total_geom / page_area : 0
        text_density = page_area > 0 ? total_text / page_area : 0

        # Has layers?
        has_layers = page_data.layers && !page_data.layers.empty?

        # Score each profile type
        scores = {}

        # ── Fabrication / shop drawing ──
        s = 0.0
        s += 0.20 if circles > 3
        s += 0.15 if callout_texts > 2
        s += 0.15 if dim_texts > 5
        s += 0.10 if closed > 10
        s += 0.10 if tb_texts > 2
        s += 0.10 if scale_texts > 0
        scores[:fabrication] = [s, 1.0].min

        # ── CAD drawing (generic technical) ──
        s = 0.0
        s += 0.20 if lines > 50
        s += 0.15 if dim_texts > 3
        s += 0.15 if has_layers
        s += 0.10 if closed > 5
        s += 0.10 if scale_texts > 0
        s += 0.10 if tb_texts > 0
        scores[:cad_drawing] = [s, 1.0].min

        # ── Architectural ──
        s = 0.0
        s += 0.20 if lines > 100
        s += 0.15 if has_layers
        s += 0.15 if dim_texts > 10
        s += 0.10 if total_text > 30
        s += 0.10 if tb_texts > 3
        s -= 0.15 if circles > 10  # many circles → more likely fabrication
        scores[:architectural] = [s, 1.0].min

        # ── Vector art / illustration ──
        s = 0.0
        s += 0.30 if total_geom > 20 && dim_texts == 0
        s += 0.20 if polylines > lines
        s += 0.10 if total_text < 5
        s -= 0.20 if has_layers
        s -= 0.20 if dim_texts > 2
        scores[:vector_art] = [s, 1.0].min

        # ── Table-heavy ──
        s = 0.0
        tb_texts_count = texts.count { |t| t.classifications.include?(:table_like) }
        s += 0.30 if tb_texts_count > 10
        s += 0.20 if text_density > geom_density * 2
        s += 0.10 if closed > 20 && lines > 40
        scores[:table_heavy] = [s, 1.0].min

        # ── Raster only ──
        s = total_geom == 0 && total_text == 0 ? 0.90 : 0.0
        scores[:raster_only] = s

        # ── Schematic ──
        s = 0.0
        s += 0.20 if total_text > 20 && lines > 30
        s += 0.10 if circles > 2
        s -= 0.15 if dim_texts > 5
        scores[:schematic] = [s, 1.0].min

        # Pick the highest score
        primary = scores.max_by { |_, v| v }
        primary_type = primary ? primary[0] : :unknown

        # If scores are all low, default to generic
        if scores.values.max < 0.25
          primary_type = total_geom > 0 ? :cad_drawing : :unknown
        end

        PageProfile.new(
          page_data.page_number,
          primary_type,
          scores,
          has_layers,
          total_text > 0,
          dim_texts > 0,
          circles,
          closed,
          lines,
          total_text,
          tb_texts > 2
        )
      end

      # ---------------------------------------------------------------
      # Suggest recognition mode based on profile
      # ---------------------------------------------------------------
      def self.suggest_mode(profile)
        case profile.primary_type
        when :fabrication then :technical
        when :architectural then :architectural
        when :vector_art then :none
        when :raster_only then :none
        when :table_heavy then :none
        else :generic
        end
      end

    end
  end
end
