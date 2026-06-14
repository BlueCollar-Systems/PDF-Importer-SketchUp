# bc_pdf_vector_importer/import_config.rb
# Versioned import configuration object.
# Centralizes all import settings with the 4-mode system (BCS-ARCH-001) and
# backward-compatible conversion to the opts hash consumed by the rest of
# the pipeline.
#
# BCS-ARCH-001 Rule 5 sweep: quality-tier dials (arc_mode, cleanup_level,
# lineweight_mode, hatch_mode, bezier_segments, merge_tolerance, raster_dpi,
# detect_arcs, map_dashes, force_raster, raster_fallback) are no longer
# UI-adjustable. The MODES table below holds only the per-mode strategy
# choices; quality parameters are baked into the consolidated defaults
# applied uniformly in initialize().
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    class ImportConfig

      VERSION = '2.0'.freeze

      # --- Cleanup presets ------------------------------------------------
      # Conservative = tightest tolerances (preserves detail, cleans least)
      # Aggressive   = loosest tolerances  (cleans most, merges more aggressively)
      CLEANUP_PRESETS = {
        'Conservative' => {
          merge_tolerance:    0.001,
          collinear_tolerance: 0.0005,
          min_edge_length:    0.001
        },
        'Balanced' => {
          merge_tolerance:    0.005,
          collinear_tolerance: 0.001,
          min_edge_length:    0.002
        },
        'Aggressive' => {
          merge_tolerance:    0.01,
          collinear_tolerance: 0.005,
          min_edge_length:    0.005
        }
      }.freeze

      # --- Arc reconstruction modes ---------------------------------------
      ARC_MODES = [
        'Auto',
        'Preserve curves',
        'Rebuild arcs',
        'Polyline only'
      ].freeze

      # --- Lineweight handling modes --------------------------------------
      LINEWEIGHT_MODES = [
        'Ignore',
        'Preserve visually',
        'Group by lineweight',
        'Map to tags'
      ].freeze

      # --- Grouping modes -------------------------------------------------
      GROUPING_MODES = [
        'Single group',
        'Group per page',
        'Group per layer',
        'Group per color',
        'Nested: page > layer',
        'Nested: page > lineweight'
      ].freeze

      # --- Import modes (BCS-ARCH-001 4-mode system) -----------------------
      # Auto   = decide per-page (vector | raster | hybrid)
      # Vector = force vector extraction; raster fallback OFF
      # Raster = force raster rendering; skip vectors/text/fills/arcs
      # Hybrid = vector + embedded raster images (raster fallback ON)
      #
      # Per-mode strategy choices only — quality parameters
      # (bezier_segments=32, merge_tolerance=0.0005, raster_dpi=300, etc.)
      # are consolidated into initialize() defaults because every mode
      # targets identical "indistinguishable from source" quality.
      MODES = {
        'Auto' => {
          'import_mode'        => 'auto',
          'text_mode'          => 'Geometry',
          'import_text'        => 'Yes',
          'grouping_mode'      => 'Group per page',
          'page_arrangement'   => 'Spread (20% gap)',
        }.freeze,
        'Vector' => {
          'import_mode'        => 'vector',
          'text_mode'          => 'Geometry',
          'import_text'        => 'Yes',
          'grouping_mode'      => 'Group per page',
          'page_arrangement'   => 'Spread (20% gap)',
        }.freeze,
        'Raster' => {
          'import_mode'        => 'raster',
          'text_mode'          => 'No text',
          'import_text'        => 'No',
          'grouping_mode'      => 'Single group',
          'page_arrangement'   => 'Spread (20% gap)',
        }.freeze,
        'Hybrid' => {
          'import_mode'        => 'hybrid',
          'text_mode'          => 'Geometry',
          'import_text'        => 'Yes',
          'grouping_mode'      => 'Group per page',
          'page_arrangement'   => 'Spread (20% gap)',
        }.freeze,
      }.freeze

      # --- Instance attributes --------------------------------------------
      # ImportConfig fields persist for internal use even though most
      # quality dials are no longer user-adjustable per BCS-ARCH-001 Rule 5.
      attr_accessor :scale, :pages, :bezier_segments, :import_as,
                    :layer_name, :group_per_page, :flatten_to_2d,
                    :merge_tolerance, :import_fills, :group_by_color,
                    :detect_arcs, :map_dashes, :import_text, :use_3d_text,
                    :hatch_mode, :raster_fallback, :force_raster,
                    :raster_dpi, :cleanup_geometry, :recognition_mode,
                    :text_mode, :units,
                    # Phase 2 additions
                    :arc_mode, :cleanup_level, :lineweight_mode, :grouping_mode,
                    :page_arrangement, :page_gap_ratio,
                    # BCS-ARCH-001 additions
                    :import_mode, :match_pdf_layers

      def initialize(attrs = {})
        # User-facing fields (settable from dialog/UI)
        @scale            = attrs[:scale]            || '1.0'
        @pages            = attrs[:pages]            || 'All'
        @import_text      = attrs[:import_text]      || 'Yes'
        @text_mode        = attrs[:text_mode]        || 'Geometry'
        @import_mode      = attrs[:import_mode]      || 'auto'
        @grouping_mode    = attrs[:grouping_mode]    || 'Group per page'
        @page_arrangement = attrs[:page_arrangement] || 'Spread (20% gap)'
        @layer_name       = attrs[:layer_name]       || 'PDF Import'
        @match_pdf_layers = attrs[:match_pdf_layers] || 'Yes'
        @group_per_page   = attrs[:group_per_page]   || 'Yes'
        @group_by_color   = attrs[:group_by_color]   || 'Yes'

        # Consolidated quality-tier defaults (BCS-ARCH-001 Rule 5).
        # These are NOT user-adjustable from any UI/CLI; values come from
        # the parameter table in BCS-ARCH-001 — "tightest correct value"
        # because every mode targets indistinguishable-from-source fidelity.
        @bezier_segments  = attrs[:bezier_segments]  || '32'
        @merge_tolerance  = attrs[:merge_tolerance]  || '0.0005'
        @raster_dpi       = attrs[:raster_dpi]       || '300'
        @arc_mode         = attrs[:arc_mode]         || 'Auto'
        @cleanup_level    = attrs[:cleanup_level]    || 'Balanced'
        @cleanup_geometry = attrs[:cleanup_geometry] || 'Yes'
        @recognition_mode = attrs[:recognition_mode] || 'None'
        @units            = attrs[:units]            || 'Inches'
        @page_gap_ratio   = attrs[:page_gap_ratio]   || '0.20'
        @flatten_to_2d    = true

        # Mode-driven defaults (set conditionally by from_mode for raster).
        is_raster = (@import_mode.to_s == 'raster')
        @import_as        = attrs[:import_as]        || (is_raster ? 'Edges Only' : 'Edges and Faces')
        @import_fills     = attrs[:import_fills]     || (is_raster ? 'No' : 'Yes')
        @detect_arcs      = attrs[:detect_arcs]      || (is_raster ? 'No' : 'Yes')
        @map_dashes       = attrs[:map_dashes]       || (is_raster ? 'No' : 'Yes')
        @hatch_mode       = attrs[:hatch_mode]       || (is_raster ? 'Skip' : 'Group')
        @raster_fallback  = attrs[:raster_fallback]  || (@import_mode == 'auto' || @import_mode == 'hybrid' || is_raster ? 'Yes' : 'No')
        @force_raster     = attrs[:force_raster]     || (is_raster ? 'Yes' : 'No')
        @lineweight_mode  = attrs[:lineweight_mode]  || (is_raster ? 'Ignore' : 'Preserve visually')
      end

      # Build from a named mode (BCS-ARCH-001: Auto|Vector|Raster|Hybrid)
      def self.from_mode(name)
        mode = MODES[name]
        return new unless mode
        # MODES hash uses string keys; convert to symbol keys for initialize
        sym_attrs = {}
        mode.each { |k, v| sym_attrs[k.to_sym] = v }
        new(sym_attrs)
      end

      # Convert to the opts hash that the existing pipeline expects.
      # This keeps full backward compatibility — all keys the old
      # build_opts produced are present, plus the new Phase 2 keys.
      def to_opts
        ImportDialog.send(:build_opts, to_raw)
      end

      # Return the raw string-keyed hash (same shape ImportDialog expects)
      def to_raw
        {
          scale: @scale, pages: @pages, bezier_segments: @bezier_segments,
          import_as: @import_as, layer_name: @layer_name,
          group_per_page: @group_per_page, merge_tolerance: @merge_tolerance,
          import_fills: @import_fills, group_by_color: @group_by_color,
          detect_arcs: @detect_arcs, map_dashes: @map_dashes,
          import_text: @import_text,
          text_mode: @text_mode, hatch_mode: @hatch_mode,
          raster_fallback: @raster_fallback, force_raster: @force_raster,
          raster_dpi: @raster_dpi, cleanup_geometry: @cleanup_geometry,
          recognition_mode: @recognition_mode, units: @units,
          arc_mode: @arc_mode, cleanup_level: @cleanup_level,
          lineweight_mode: @lineweight_mode, grouping_mode: @grouping_mode,
          page_arrangement: @page_arrangement, page_gap_ratio: @page_gap_ratio,
          import_mode: @import_mode, match_pdf_layers: @match_pdf_layers
        }
      end

    end
  end
end
