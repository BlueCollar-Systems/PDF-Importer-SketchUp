# bc_pdf_vector_importer/extrude_3d.rb
#
# Optional 3D extrude post-processor for the SketchUp PDF importer.
#
# After the standard flat (Z=0) geometry has been built and cleaned up,
# Extrude3D.apply walks every face in the imported entities and calls
# SketchUp's native pushpull() to lift each face by a user-specified depth.
#
# This turns a flat floor-plan, cross-section, or site-plan import into a
# rough 3D massing model with a single extra option.  The feature is:
#   - Opt-in only (extrude_depth = 0.0 by default → no change to pipeline).
#   - SketchUp-only (native pushpull API; not added to FreeCAD/Blender/LibreCAD).
#   - Non-destructive to the 2D geometry — pushpull creates the extrusion
#     volume but keeps the original face boundary edges intact.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module Extrude3D

      # Minimum face area (square inches) below which we skip push/pull.
      # This filters hairline artefacts that technically closed but enclose
      # no meaningful area (~8 mm²).
      DEFAULT_MIN_AREA_SQIN = 0.01

      # Normal Z-component threshold: we only extrude faces that are
      # essentially horizontal (flat, Z-normal).  Angled or vertical faces
      # are skipped — they are either already 3D or artefacts.
      HORIZONTAL_NORMAL_THRESHOLD = 0.99

      module_function

      # Apply push/pull extrusion to all eligible faces inside +entities+.
      #
      # Parameters:
      #   entities      — Sketchup::Entities (or any object responding to
      #                   #each / #grep(Sketchup::Face) for testability).
      #   depth_inches  — Extrusion depth in inches (positive = Z-up).
      #   opts          — Hash of optional overrides:
      #     :min_area_sqin   (Float) — skip faces smaller than this (default 0.01)
      #     :recursive       (Bool)  — descend into groups/components (default true)
      #
      # Returns a stats hash:
      #   { faces_found: N, faces_extruded: N, faces_skipped: N }
      def apply(entities, depth_inches, opts = {})
        depth = depth_inches.to_f
        return { faces_found: 0, faces_extruded: 0, faces_skipped: 0 } if depth <= 0.0

        min_area = opts.fetch(:min_area_sqin, DEFAULT_MIN_AREA_SQIN).to_f
        recursive = opts.fetch(:recursive, true)

        found     = 0
        extruded  = 0
        skipped   = 0

        collect_faces(entities, recursive).each do |face|
          found += 1
          unless eligible?(face, min_area)
            skipped += 1
            next
          end
          begin
            face.pushpull(depth)
            extruded += 1
          rescue StandardError => e
            Logger.warn('Extrude3D', "pushpull failed: #{e.message}")
            skipped += 1
          end
        end

        Logger.info('Extrude3D',
          "Extrude complete: depth=#{depth.round(4)}in, " \
          "found=#{found}, extruded=#{extruded}, skipped=#{skipped}")

        { faces_found: found, faces_extruded: extruded, faces_skipped: skipped }
      end

      # Collect every Sketchup::Face from entities, optionally recursing
      # into Group and ComponentInstance children.  Written to accept any
      # Enumerable for unit-test injection without the SketchUp runtime.
      def collect_faces(entities, recursive = true)
        faces = []
        return faces unless entities.respond_to?(:each)
        entities.each do |ent|
          if face_instance?(ent)
            faces << ent
          elsif recursive && group_or_component?(ent)
            child = child_entities(ent)
            faces.concat(collect_faces(child, true)) if child
          end
        end
        faces
      end

      # Returns true if the face should be extruded:
      #   1. Responds to pushpull (SketchUp::Face duck-type).
      #   2. Normal is essentially vertical (Z-axis) → face is horizontal/flat.
      #   3. Area is above the minimum threshold.
      def eligible?(face, min_area = DEFAULT_MIN_AREA_SQIN)
        return false unless face.respond_to?(:pushpull)
        return false unless face.respond_to?(:normal) && face.respond_to?(:area)
        normal = face.normal
        return false unless normal.respond_to?(:z)
        return false if normal.z.to_f.abs < HORIZONTAL_NORMAL_THRESHOLD
        return false if face.area.to_f < min_area.to_f
        true
      rescue StandardError
        false
      end

      # Duck-type helpers — separated so tests can override them cleanly.

      def face_instance?(ent)
        defined?(Sketchup::Face) ? ent.is_a?(Sketchup::Face) :
          ent.class.name.end_with?('Face') || (ent.respond_to?(:pushpull) && ent.respond_to?(:normal))
      end

      def group_or_component?(ent)
        return true if defined?(Sketchup::Group) && ent.is_a?(Sketchup::Group)
        return true if defined?(Sketchup::ComponentInstance) && ent.is_a?(Sketchup::ComponentInstance)
        ent.class.name.end_with?('Group') || ent.class.name.end_with?('ComponentInstance')
      end

      def child_entities(ent)
        return ent.entities if ent.respond_to?(:entities)
        return ent.definition.entities if ent.respond_to?(:definition) &&
                                          ent.definition.respond_to?(:entities)
        nil
      end

    end
  end
end
