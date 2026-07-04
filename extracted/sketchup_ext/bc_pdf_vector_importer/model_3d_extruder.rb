# bc_pdf_vector_importer/model_3d_extruder.rb
# Optional post-import extrusion of closed PDF fill faces (BCS-ARCH-001 additive).
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module Model3DExtruder
      DEFAULT_DEPTH_MM = 3.175 # 1/8" steel plate
      MM_TO_INCH = 1.0 / 25.4
      MIN_FACE_AREA_SQ_IN = 1.0e-8

      module_function

      def resolve_depth_inches(opts)
        depth_mm = opts[:extrude_depth_mm]
        if depth_mm && depth_mm.to_f > 0.0
          return depth_mm.to_f * MM_TO_INCH
        end
        scale = (opts[:scale] || 1.0).to_f
        scale = 1.0 if scale <= 0.0
        DEFAULT_DEPTH_MM * MM_TO_INCH * scale
      end

      def build_report_payload(enabled, depth_mm, faces_extruded, skipped_reason)
        payload = {
          enabled: !!enabled,
          supported: true,
          depth_mm: depth_mm.round(4),
          faces_extruded: faces_extruded.to_i
        }
        payload[:skipped_reason] = skipped_reason.to_s unless skipped_reason.to_s.empty?
        payload
      end

      def disabled_payload(reason)
        build_report_payload(false, 0.0, 0, reason)
      end

      def extrude_imported(model, pre_import_entities, opts)
        unless opts[:extrude_to_3d]
          return disabled_payload('option_off')
        end
        unless model && model.respond_to?(:active_entities)
          return disabled_payload('no_model')
        end

        depth_in = resolve_depth_inches(opts)
        depth_mm = depth_in / MM_TO_INCH
        imported = begin
          model.active_entities.to_a - Array(pre_import_entities)
        rescue StandardError
          []
        end
        if imported.empty?
          return build_report_payload(true, depth_mm, 0, 'no_imported_geometry')
        end

        faces = []
        imported.each { |root| collect_faces(root, faces) }
        if faces.empty?
          return build_report_payload(true, depth_mm, 0, 'no_closed_fill_faces')
        end

        extruded = 0
        skipped = 0
        faces.each do |face|
          next unless face_valid_for_extrusion?(face)
          if pushpull_face(face, depth_in)
            extruded += 1
          else
            skipped += 1
          end
        end

        reason = nil
        if extruded == 0
          reason = skipped > 0 ? 'faces_failed_pushpull' : 'no_extrudable_faces'
        end
        build_report_payload(true, depth_mm, extruded, reason)
      rescue StandardError => e
        Logger.warn('Model3DExtruder', "extrude_imported failed: #{e.message}") if defined?(Logger)
        build_report_payload(true, 0.0, 0, 'extrusion_error')
      end

      def collect_faces(entity, bucket)
        return unless entity
        if defined?(Sketchup::Face) && entity.is_a?(Sketchup::Face)
          bucket << entity
          return
        end
        child_entities = nil
        if defined?(Sketchup::Group) && entity.is_a?(Sketchup::Group)
          child_entities = entity.entities
        elsif defined?(Sketchup::ComponentInstance) && entity.is_a?(Sketchup::ComponentInstance)
          child_entities = entity.definition.entities if entity.definition
        end
        return unless child_entities
        child_entities.each { |child| collect_faces(child, bucket) }
      rescue StandardError
        nil
      end

      def face_valid_for_extrusion?(face)
        return false unless face && face.valid?
        area = face.area.to_f
        area >= MIN_FACE_AREA_SQ_IN
      rescue StandardError
        false
      end

      def pushpull_face(face, depth_in)
        return false unless face && face.valid? && depth_in.to_f.abs > 0.0
        result = face.pushpull(depth_in.to_f, true)
        !!result
      rescue StandardError => e
        Logger.warn('Model3DExtruder', "pushpull failed: #{e.message}") if defined?(Logger)
        false
      end
    end
  end
end
