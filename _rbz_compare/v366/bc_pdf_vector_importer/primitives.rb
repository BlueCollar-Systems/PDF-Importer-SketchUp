# bc_pdf_vector_importer/primitives.rb
# Host-neutral intermediate data model.
# PDF parser outputs these. Cleanup operates on these.
# Recognizers read these. Host builders consume results.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter

    # ── Configuration ───────────────────────────────────────────────
    RecognitionConfig = Struct.new(
      :vertex_merge_tol,       # inches — snap endpoints
      :min_segment_len,        # inches — discard micro edges
      :loop_close_tol,         # inches — close tiny gaps
      :region_padding,         # inches — expand region bbox
      :text_assoc_radius,      # inches — text↔geometry link distance
      :dimension_assoc_radius, # inches — dimension↔geometry link
      :circle_min_diameter,    # inches — smallest circle to detect
      :circle_max_diameter,    # inches — largest circle to detect
      :circle_fit_tol,         # inches — max RMS for circle fit
      :closed_loop_min_aspect, # length/width minimum for elongated loops
      :closed_loop_min_area,   # sq inches — ignore tiny closed loops
      :confidence_threshold    # minimum confidence to report
    ) do
      def self.default
        new(
          0.010,   # vertex_merge_tol
          0.002,   # min_segment_len
          0.020,   # loop_close_tol
          1.0,     # region_padding
          2.0,     # text_assoc_radius
          3.0,     # dimension_assoc_radius
          0.25,    # circle_min_diameter
          4.0,     # circle_max_diameter
          0.010,   # circle_fit_tol
          1.5,     # closed_loop_min_aspect
          1.0,     # closed_loop_min_area (sq in)
          0.60     # confidence_threshold
        )
      end
    end

    # ── Primitive (single geometric element) ────────────────────────
    Primitive = Struct.new(
      :id,              # Integer — unique ID
      :type,            # :line, :arc, :circle, :polyline, :closed_loop, :rect
      :points,          # Array of [x, y] — vertices in model inches
      :center,          # [x, y] or nil — for arcs/circles
      :radius,          # Float or nil
      :start_angle,     # Float or nil (radians)
      :end_angle,       # Float or nil (radians)
      :bbox,            # [min_x, min_y, max_x, max_y]
      :stroke_color,    # [r, g, b] 0.0–1.0
      :fill_color,      # [r, g, b] or nil
      :dash_pattern,    # Array or nil
      :line_width,      # Float or nil (points)
      :layer_name,      # String or nil — OCG layer
      :closed,          # Boolean
      :area,            # Float or nil — enclosed area for closed loops
      :page_number,     # Integer
      :tags             # Array of Symbols or nil — classification tags
    )

    # ── TextItem (normalized) ───────────────────────────────────────
    NormalizedText = Struct.new(
      :id,              # Integer
      :text,            # String — raw content
      :normalized,      # String — uppercased, cleaned
      :insertion,       # [x, y] in model inches
      :bbox,            # [min_x, min_y, max_x, max_y]
      :font_size,       # Float — in model inches
      :rotation,        # Float — degrees
      :font_name,       # String
      :page_number,     # Integer
      :classifications  # Array of hashes — generic text classifications
    )

    # ── PageData (everything from one PDF page) ─────────────────────
    PageData = Struct.new(
      :page_number,
      :width,           # Float — page width in model inches
      :height,          # Float — page height in model inches
      :primitives,      # Array of Primitive
      :text_items,      # Array of NormalizedText
      :layers,          # Array of String — OCG layer names
      :xobject_names    # Array of String — Form XObject names found
    )

    # ── ParsedDimension ─────────────────────────────────────────────
    ParsedDimension = Struct.new(
      :raw_text,        # String — original
      :kind,            # :linear, :diameter, :radius, :angle, :scale, :unknown
      :value,           # Float or Hash
      :units,           # :in, :ft, :mm, :cm, :mixed_imperial
      :quantity,        # Integer or nil
      :normalized_text, # String
      :confidence,      # Float 0.0–1.0
      :warnings         # Array of String
    )

    # ── Region ──────────────────────────────────────────────────────
    Region = Struct.new(
      :id,
      :page_number,
      :bbox,            # [min_x, min_y, max_x, max_y]
      :primitive_ids,   # Array of Integer
      :text_ids,        # Array of Integer
      :region_type,     # :detail, :title_block, :notes, :assembly, :unknown
      :label,           # String — "Detail_A", "TitleBlock", etc.
      :is_titleblock,   # Boolean
      :confidence       # Float
    )

    # ── ID generator ────────────────────────────────────────────────
    module IDGen
      @next_id = 0
      def self.next
        @next_id += 1
        @next_id
      end
      def self.reset
        @next_id = 0
      end
    end

  end
end
