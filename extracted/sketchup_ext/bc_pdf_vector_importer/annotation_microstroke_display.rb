# Original annotation geometry plus a separately certified display-only crop.
require_relative 'annotation_microstroke_geometry'
require_relative 'embedded_image_placement'

module BlueCollarSystems
  module PDFVectorImporter
    module AnnotationMicrostrokeDisplay
      DICTIONARY = 'BC_PDF_Importer'.freeze
      SCHEMA = 'bcs.original_annotation_native/1'.freeze
      POLICY = 'original_annotation_rgb_crop_no_source_glyph_ink/1'.freeze
      DISPLAY_GAP = 0.01

      def self.fail_contract(message)
        raise RepresentationFidelity::ContractError, 'original annotation: ' + message
      end

      def self.symbols(value)
        AnnotationMicrostrokeGeometry.symbols(value)
      end

      def self.crop_placement(record,context,depth)
        source,crop = record.values_at(:source,:crop)
        expected = AnnotationCompositeSource.crop_plan(source,context.fetch(:media_box),context.fetch(:page_rotation))
        fail_contract('display crop differs from original pixel lattice') unless crop == expected
        x0,y0,x1,y1 = crop.fetch(:source_box_pdf)
        placement = EmbeddedImagePlacement.affine([[x0,y0],[x1,y0],[x1,y1],[x0,y1]],
          context.fetch(:media_box),context.fetch(:scale),context.fetch(:page_y_offset),context.fetch(:page_rotation))
        placement[:matrix][14] = depth
        placement[:corners].each { |point| point[2] = depth }
        placement
      end

      def self.source_binding!(source,context)
        unless source[:source_pdf_sha256] == context[:source_pdf_sha256] && source[:page_number] == context[:page] &&
               source[:original_geometry_verified] == true && source[:full_capsule_clip_verified] == true &&
               /\A[0-9a-f]{64}\z/ =~ context[:source_pdf_sha256].to_s
          fail_contract('native delivery has an unbound original annotation')
        end
      end

      def self.apply!(page_group,provider,stats,context)
        records = provider.geometry_records
        return nil if records.empty?
        # All prior native page representations remain untouched. Original
        # annotations paint after page contents; the glyph absence proof and
        # disjoint other-annotation check are required for each display crop.
        highest = highest_other_z(page_group.entities)
        depth = highest + DISPLAY_GAP
        proof = context.reject { |key,_| [:model,:layer].include?(key) }.merge(
          :schema=>SCHEMA, :policy=>POLICY,
          :page_group_id=>RepresentationFidelity.stable_entity_id(page_group),
          :highest_prior_native_z=>highest, :display_gap_inches=>DISPLAY_GAP,
          :display_z=>depth, :placements=>[])
        records.each do |record|
          source_binding!(record,context)
          built = AnnotationMicrostrokeGeometry.build!(page_group.entities,record,context)
          group = built.fetch(:entity)
          row = { :source=>record, :geometry_plan=>built[:geometry_plan],
            :capsule_entity_id=>RepresentationFidelity.stable_entity_id(group),
            :native_geometry=>AnnotationMicrostrokeGeometry.snapshot(group),
            :native_face_is_segmented=>true, :arc_segments_per_semicircle=>AnnotationMicrostrokeGeometry::ARC_SEGMENTS,
            :source_analytic_area_inches2=>built[:geometry_plan][:source_analytic_area_inches2],
            :native_face_polygon_area_inches2=>built[:native_face_polygon_area_inches2] }
          matching = provider.composite_records.select { |item| item[:source][:annotation_ref] == record[:annotation_ref] }
          fail_contract('duplicate original annotation display crop') if matching.length > 1
          unless matching.empty?
            composite = matching.first
            fail_contract('display crop source record changed') unless composite[:source] == record
            validate_composite_proof!(composite,context)
            placement = crop_placement(composite,context,depth)
            image = page_group.entities.add_image(composite[:png_path],Geom::Point3d.new(0,0,0),1.0,1.0)
            fail_contract('original annotation Image creation failed') unless image && image.valid? && image.typename.to_s == 'Image'
            AnnotationMicrostrokeGeometry.assign_layer!(image,context.fetch(:layer))
            image.hidden = false
            fail_contract('original annotation Image remains hidden') if image.hidden?
            image.set_attribute(DICTIONARY,'annotation_composite_image',true)
            image.set_attribute(DICTIONARY,'annotation_source_pdf_sha256',context[:source_pdf_sha256])
            image.set_attribute(DICTIONARY,'annotation_ref',record[:annotation_ref])
            image.set_attribute(DICTIONARY,'annotation_page_number',context[:page])
            transform = Geom::Transformation.new(placement[:matrix])
            expected_matrix = transform * image.transformation
            image.transform!(transform)
            unless EmbeddedImagePlacement.same_matrix?(image.transformation.to_a,expected_matrix.to_a)
              fail_contract('original annotation Image transform setter was ignored')
            end
            actual = ItemRasterDisplay.image_corners(image.transformation.to_a,ItemRasterDisplay::IDENTITY,image.width.to_f,image.height.to_f)
            ItemRasterDisplay.close_points!(actual,placement[:corners],'original annotation Image corners')
            row[:display] = composite.reject { |key,_| [:png_path].include?(key) }.merge(
              :image_entity_id=>RepresentationFidelity.stable_entity_id(image),
              :image_matrix=>image.transformation.to_a, :expected_corners=>placement[:corners])
          end
          proof[:placements] << row
        end
        stats[:original_annotation_placements] ||= []
        stats[:original_annotation_placements] << proof
        proof
      end

      def self.highest_other_z(entities)
        entities.to_a.map do |entity|
          next unless entity.valid?
          next if entity.get_attribute(DICTIONARY,'original_annotation_capsule',false) == true ||
            entity.get_attribute(DICTIONARY,'annotation_composite_image',false) == true
          bounds = entity.bounds
          bounds.max.z.to_f if bounds && !bounds.empty?
        end.compact.push(0.0).max
      end

      def self.validate_composite_proof!(composite,context)
        source_binding!(composite[:source],context)
        pixels,background = composite.values_at(:pixels,:background_proof)
        unless pixels.is_a?(Hash) && pixels[:transparent_pixel_present] == false && pixels[:visible_pixel_present] == true &&
               pixels[:pixel_width] == composite[:crop][:pixel_width] && pixels[:pixel_height] == composite[:crop][:pixel_height] &&
               /\A[0-9a-f]{64}\z/ =~ pixels[:visual_pixel_sha256].to_s &&
               /\A[0-9a-f]{64}\z/ =~ pixels[:content_sha256].to_s &&
               background.is_a?(Hash) && background[:source_pdf_sha256] == context[:source_pdf_sha256] &&
               background[:page_number] == context[:page] && background[:original_byte_prefix_unchanged] == true &&
               background[:overridden_key] == '/Annots' && background[:other_annotations_disjoint].is_a?(Array) &&
               background[:all_crop_glyph_bounds_disjoint] == true && background[:clip_mask_visibility_narrowing_ignored] == true &&
               background[:flattened_image_bounds_disjoint] == true &&
               background[:font_scope].is_a?(Hash) && background[:font_scope][:type3_and_pattern_programs_absent] == true &&
               background[:font_scope][:text_clipping_modes_absent] == true &&
               background[:font_scope][:text_stroke_modes_absent] == true &&
               background[:possible_glyph_count].is_a?(Integer) && background[:possible_glyph_count] >= 0 &&
               background[:source_crop_boxes_svg].is_a?(Array) &&
               background[:crop_count] == background[:source_crop_boxes_svg].length &&
               background[:source_crop_boxes_svg].include?(composite[:crop][:source_box_svg]) &&
               /\A[0-9a-f]{64}\z/ =~ background[:svg_sha256].to_s
          fail_contract('original annotation display pixels/source absence proof is missing')
        end
        crop_placement(composite,context,0.0)
        true
      end

      def self.walk(rows,parent = nil,&block)
        Array(rows).each do |row|
          yield row,parent
          walk(row[:children],row,&block)
        end
      end

      def self.row_id(row)
        persistent = row[:persistent_id]
        return 'persistent_id:' + persistent.to_s if persistent.is_a?(Integer) && persistent > 0
        'entity_id:' + row[:entity_id].to_s
      end

      def self.visible!(row,label)
        style = row[:style_evidence]
        unless row[:valid] == true && row[:deleted] == false && style.is_a?(Hash) &&
               style[:entity_visible] == true && style[:layer_visible] == true
          fail_contract(label + ' is not live and visible')
        end
      end

      def self.verify_manifest!(stats,manifest)
        stats,manifest = symbols(stats),symbols(manifest)
        rows,parents = {},{}
        walk(manifest) do |row,parent|
          id = row_id(row)
          fail_contract('duplicate host entity identity') if rows.key?(id)
          rows[id],parents[id] = row,parent
        end
        actual_capsules = rows.select { |_id,row| row[:original_annotation_capsule] == true }.keys.sort
        actual_images = rows.select { |_id,row| row[:annotation_composite_image] == true }.keys.sort
        expected_capsules,expected_images = [],[]
        Array(stats[:original_annotation_placements]).each do |proof|
          unless proof[:schema] == SCHEMA && proof[:policy] == POLICY && proof[:display_gap_inches] == DISPLAY_GAP &&
                 AnnotationMicrostrokeGeometry.close?(proof[:display_z],proof[:highest_prior_native_z]+DISPLAY_GAP,1.0e-12)
            fail_contract('display policy or depth changed')
          end
          page = rows[proof[:page_group_id]]
          fail_contract('owning annotation page is missing') unless page
          visible!(page,'annotation page')
          unless AnnotationMicrostrokeGeometry.close?(page[:annotation_highest_other_z],proof[:highest_prior_native_z],1.0e-12)
            fail_contract('annotation display depth is not bound to actual prior native content')
          end
          ItemRasterDisplay.close_points!([ItemRasterDisplay.transform([0,0,0],page[:transformation] || ItemRasterDisplay::IDENTITY)],[[0,0,0]],'annotation page origin')
          fail_contract('annotation page transform changed') unless ItemRasterDisplay.matrix!(page[:transformation] || ItemRasterDisplay::IDENTITY) == ItemRasterDisplay::IDENTITY
          Array(proof[:placements]).each do |placement|
            source = placement[:source]
            source_binding!(source,proof)
            expected = AnnotationMicrostrokeGeometry.plan(source,proof)
            fail_contract('stored source geometry plan changed') unless placement[:geometry_plan] == expected
            capsule_id = placement[:capsule_entity_id]
            capsule = rows[capsule_id]
            unless capsule && capsule[:original_annotation_capsule] == true && parents[capsule_id].equal?(page)
              fail_contract('original annotation capsule ownership changed')
            end
            visible!(capsule,'annotation capsule')
            AnnotationMicrostrokeGeometry.verify_snapshot!(capsule[:annotation_native_geometry],expected)
            saved = placement[:native_geometry]
            if native_ids(capsule[:annotation_native_geometry]) != native_ids(saved)
              fail_contract('original annotation native entities were replaced')
            end
            expected_capsules << capsule_id
            display = placement[:display]
            next unless display
            validate_composite_proof!(display,proof)
            image_id = display[:image_entity_id]
            image = rows[image_id]
            unless image && image[:annotation_composite_image] == true && image[:typename] == 'Image' && parents[image_id].equal?(page)
              fail_contract('original annotation Image ownership changed')
            end
            visible!(image,'annotation Image')
            binding = image[:annotation_source_binding]
            unless binding == { :source_pdf_sha256=>proof[:source_pdf_sha256],:page=>proof[:page],:annotation_ref=>source[:annotation_ref] }
              fail_contract('original annotation Image source identity changed')
            end
            content = image[:content_evidence]
            pixels = display[:pixels]
            unless content && content[:host_texture_export_verified] == true &&
                   content[:host_texture_export_byte_size].is_a?(Integer) && content[:host_texture_export_byte_size] > 0 &&
                   content[:host_visual_pixel_sha256] == pixels[:visual_pixel_sha256] &&
                   content[:host_pixel_width] == pixels[:pixel_width] && content[:host_pixel_height] == pixels[:pixel_height]
              fail_contract('saved annotation Image pixels were not physically verified')
            end
            unless EmbeddedImagePlacement.same_matrix?(image[:transformation],display[:image_matrix])
              fail_contract('saved annotation Image matrix changed')
            end
            expected_corners = crop_placement(display,proof,proof[:display_z])[:corners]
            actual_corners = ItemRasterDisplay.image_corners(image[:transformation],ItemRasterDisplay::IDENTITY,content[:display_width],content[:display_height])
            ItemRasterDisplay.close_points!(actual_corners,expected_corners,'saved original annotation Image')
            expected_images << image_id
          end
        end
        unless expected_capsules.sort == actual_capsules && expected_images.sort == actual_images &&
               expected_capsules.uniq.length == expected_capsules.length && expected_images.uniq.length == expected_images.length
          fail_contract('original annotation delivery inventory differs from live host')
        end
        reports = Array(stats[:original_annotation_ink])
        unless reports.inject(0) { |sum,report| sum+report[:eligible_geometry_count].to_i } == expected_capsules.length &&
               reports.inject(0) { |sum,report| sum+report[:composite_count].to_i } == expected_images.length
          fail_contract('source annotation inventory or composite count changed')
        end
        true
      end

      def self.native_ids(snapshot)
        row = symbols(snapshot)
        ([row[:entity_id]] + Array(row[:children]).flat_map do |child|
          [child[:entity_id]] + Array(child[:entities]).map { |entity| entity[:entity_id] }
        end).sort
      end
    end
  end
end
