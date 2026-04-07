# bc_pdf_vector_importer/import_config.rb
# Versioned import configuration object.
# Centralizes all import settings with named presets and backward-compatible
# conversion to the opts hash consumed by the rest of the pipeline.
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

      # --- Import presets (mirror ImportDialog::PRESETS) -------------------
      PRESETS = {
        'Fast' => {
          scale: '1.0', bezier_segments: '8', import_as: 'Edges Only',
          import_fills: 'No', group_by_color: 'No', detect_arcs: 'No',
          map_dashes: 'No', text_mode: 'No text', hatch_mode: 'Skip',
          strict_text_fidelity: 'No',
          cleanup_geometry: 'No', recognition_mode: 'None',
          merge_tolerance: '0.005', units: 'Inches',
          force_raster: 'No', raster_dpi: '300',
          arc_mode: 'Auto', cleanup_level: 'Balanced',
          lineweight_mode: 'Ignore', grouping_mode: 'Group per page'
        },
        'Full' => {
          scale: '1.0', bezier_segments: '24', import_as: 'Edges and Faces',
          import_fills: 'Yes', group_by_color: 'Yes', detect_arcs: 'Yes',
          map_dashes: 'Yes', text_mode: 'Geometry', hatch_mode: 'Group',
          strict_text_fidelity: 'No',
          cleanup_geometry: 'Yes', recognition_mode: 'None',
          merge_tolerance: '0.001', units: 'Inches',
          force_raster: 'No', raster_dpi: '300',
          arc_mode: 'Auto', cleanup_level: 'Balanced',
          lineweight_mode: 'Ignore', grouping_mode: 'Group per page'
        },
        'Raster Image' => {
          scale: '1.0', bezier_segments: '8', import_as: 'Edges Only',
          import_fills: 'No', group_by_color: 'No', detect_arcs: 'No',
          map_dashes: 'No', text_mode: 'No text', hatch_mode: 'Skip',
          strict_text_fidelity: 'No',
          cleanup_geometry: 'No', recognition_mode: 'None',
          merge_tolerance: '0.005', units: 'Inches',
          force_raster: 'Yes', raster_dpi: '300',
          arc_mode: 'Auto', cleanup_level: 'Balanced',
          lineweight_mode: 'Ignore', grouping_mode: 'Single group'
        },
        'Custom...' => nil
      }.freeze

      # --- Instance attributes --------------------------------------------
      attr_accessor :scale, :pages, :bezier_segments, :import_as,
                    :layer_name, :group_per_page, :flatten_to_2d,
                    :merge_tolerance, :import_fills, :group_by_color,
                    :detect_arcs, :map_dashes, :import_text, :use_3d_text,
                    :hatch_mode, :raster_fallback, :force_raster,
                    :raster_dpi, :cleanup_geometry, :recognition_mode,
                    :text_mode, :strict_text_fidelity, :units,
                    # Phase 2 additions
                    :arc_mode, :cleanup_level, :lineweight_mode, :grouping_mode

      def initialize(attrs = {})
        # Existing defaults
        @scale            = attrs[:scale]            || '1.0'
        @pages            = attrs[:pages]            || 'All'
        @bezier_segments  = attrs[:bezier_segments]  || '24'
        @import_as        = attrs[:import_as]        || 'Edges and Faces'
        @layer_name       = attrs[:layer_name]       || 'PDF Import'
        @group_per_page   = attrs[:group_per_page]   || 'Yes'
        @flatten_to_2d    = true
        @merge_tolerance  = attrs[:merge_tolerance]  || '0.001'
        @import_fills     = attrs[:import_fills]     || 'Yes'
        @group_by_color   = attrs[:group_by_color]   || 'Yes'
        @detect_arcs      = attrs[:detect_arcs]      || 'Yes'
        @map_dashes       = attrs[:map_dashes]       || 'Yes'
        @text_mode        = attrs[:text_mode]        || 'Geometry'
        @strict_text_fidelity = attrs[:strict_text_fidelity] || 'No'
        @hatch_mode       = attrs[:hatch_mode]       || 'Group'
        @raster_fallback  = attrs[:raster_fallback]  || 'Yes'
        @force_raster     = attrs[:force_raster]     || 'No'
        @raster_dpi       = attrs[:raster_dpi]       || '300'
        @cleanup_geometry = attrs[:cleanup_geometry]  || 'Yes'
        @recognition_mode = attrs[:recognition_mode] || 'None'
        @units            = attrs[:units]            || 'Inches'

        # Phase 2 defaults
        @arc_mode         = attrs[:arc_mode]         || 'Auto'
        @cleanup_level    = attrs[:cleanup_level]    || 'Balanced'
        @lineweight_mode  = attrs[:lineweight_mode]  || 'Ignore'
        @grouping_mode    = attrs[:grouping_mode]    || 'Group per page'
      end

      # Build from a named preset
      def self.from_preset(name)
        preset = PRESETS[name]
        return new unless preset
        new(preset)
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
          text_mode: @text_mode, strict_text_fidelity: @strict_text_fidelity,
          hatch_mode: @hatch_mode,
          raster_fallback: @raster_fallback, force_raster: @force_raster,
          raster_dpi: @raster_dpi, cleanup_geometry: @cleanup_geometry,
          recognition_mode: @recognition_mode, units: @units,
          arc_mode: @arc_mode, cleanup_level: @cleanup_level,
          lineweight_mode: @lineweight_mode, grouping_mode: @grouping_mode
        }
      end

    end
  end
end
