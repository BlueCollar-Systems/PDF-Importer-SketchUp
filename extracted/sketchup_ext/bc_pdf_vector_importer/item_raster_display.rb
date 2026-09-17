require_relative 'page_transform'
require_relative 'representation_fidelity'

module BlueCollarSystems
  module PDFVectorImporter
    # A final-page crop already contains the final PDF paint at its XY footprint.
    # Keep its source plane/certificate intact, but display the Image just above
    # native text after the planar composition has consumed the original plane.
    module ItemRasterDisplay
      DICTIONARY = 'BC_PDF_Importer'.freeze
      POLICY = 'final_page_crop_above_native_text/1.0'.freeze
      GAP = 0.001
      TOLERANCE = 1.0e-7
      IDENTITY = [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0].freeze

      def self.fail_contract(message)
        raise RepresentationFidelity::ContractError, "item Raster display: #{message}"
      end

      def self.value(hash, key)
        return nil unless hash.is_a?(Hash)
        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

      def self.number?(number)
        number.is_a?(Numeric) && number.to_f.finite?
      end

      def self.matrix!(matrix)
        unless matrix.is_a?(Array) && matrix.length == 16 && matrix.all? { |v| number?(v) } &&
               matrix.values_at(3, 7, 11) == [0, 0, 0] && matrix[15] != 0
          fail_contract('invalid physical affine transformation')
        end
        # Legacy SketchUp uniform scaling may retain a homogeneous divisor in
        # element 15. Normalize the equivalent affine matrix, never the points.
        normalized = matrix.map { |v| v.to_f / matrix[15].to_f }
        fail_contract('non-finite normalized physical transformation') unless normalized.all? { |v| number?(v) }
        normalized
      end

      def self.multiply(left, right)
        left, right = matrix!(left), matrix!(right)
        Array.new(16) do |index|
          row, column = index % 4, index / 4
          (0...4).inject(0.0) { |sum, k| sum + left[k * 4 + row] * right[column * 4 + k] }
        end
      end

      def self.transform(point, matrix)
        matrix = matrix!(matrix)
        (0...3).map do |axis|
          matrix[12 + axis] + (0...3).inject(0.0) { |sum, k| sum + point[k] * matrix[k * 4 + axis] }
        end
      end

      def self.close_points!(actual, expected, label)
        unless actual.is_a?(Array) && expected.is_a?(Array) && actual.length == expected.length &&
               actual.each_with_index.all? do |point, index|
                 point.is_a?(Array) && point.length == 3 && expected[index].is_a?(Array) &&
                   expected[index].length == 3 && point.each_with_index.all? do |v, axis|
                     number?(v) && number?(expected[index][axis]) &&
                       (v - expected[index][axis]).abs <= TOLERANCE
                   end
               end
          fail_contract("#{label} differs from the source-derived placement")
        end
        true
      end

      def self.source_corners(artifact, context)
        box = value(artifact, :source_box)
        media = value(context, :media_box)
        scale = value(context, :scale)
        offset = value(context, :page_y_offset)
        rotation = value(context, :page_rotation)
        unless [box, media].all? { |b| b.is_a?(Array) && b.length == 4 && b.all? { |v| number?(v) } && b[2] > b[0] && b[3] > b[1] } &&
               number?(scale) && scale > 0 && number?(offset) && [0, 90, 180, 270].include?(rotation) &&
               value(artifact, :page_rotation) == rotation
          fail_contract('source page placement metadata is invalid')
        end
        unless box[0] >= media[0] && box[1] >= media[1] && box[2] <= media[2] && box[3] <= media[3]
          fail_contract('source crop lies outside its MediaBox')
        end
        displayed = PageTransform.transform_bbox(*box, media, rotation)
        x0, y0, x1, y1 = displayed.map { |v| v * scale / 72.0 }
        [[x0, y0 + offset, 0.0], [x1, y0 + offset, 0.0],
         [x1, y1 + offset, 0.0], [x0, y1 + offset, 0.0]]
      end

      def self.image_corners(matrix, parent, width, height)
        matrix, parent = matrix!(matrix), matrix!(parent)
        lengths = [0, 4].map { |offset| Math.sqrt(matrix[offset, 3].inject(0.0) { |sum, v| sum + v * v }) }
        unless [width, height, *lengths].all? { |v| number?(v) && v > 0 }
          fail_contract('invalid physical Image dimensions')
        end
        w, h = width / lengths[0], height / lengths[1]
        total = multiply(parent, matrix)
        [[0, 0, 0], [w, 0, 0], [w, h, 0], [0, h, 0]].map { |point| transform(point, total) }
      end

      def self.bounds_top(bounds, parent)
        low, high = value(bounds, :min), value(bounds, :max)
        unless [low, high].all? { |p| p.is_a?(Array) && p.length == 3 && p.all? { |v| number?(v) } }
          fail_contract('native text physical bounds are missing')
        end
        (0...8).map do |i|
          point = (0...3).map { |axis| (i & (1 << axis)).zero? ? low[axis] : high[axis] }
          transform(point, parent)[2]
        end.max
      end

      def self.item_records(stats, page = nil)
        Array(value(stats, :raster_delivery_records)).select do |record|
          value(record, :delivery_scope).to_s == 'item_raster' &&
            (page.nil? || value(record, :page) == page)
        end
      end

      def self.validate_binding!(record, context)
        artifact = value(record, :artifact_evidence)
        page, digest = value(context, :page), value(context, :source_pdf_sha256)
        spans = value(record, :source_span_ids)
        sid = value(artifact, :source_span_id)
        unless page.is_a?(Integer) && page > 0 && digest.is_a?(String) && /\A[0-9a-f]{64}\z/ =~ digest &&
               spans == [sid] && /\Atext_span:#{page}:\d+\z/ =~ sid.to_s &&
               value(record, :page) == page && value(artifact, :page_number) == page &&
               value(artifact, :source_pdf_sha256) == digest &&
               [:source_crop_binding_verified, :source_pdf_binding_verified, :page_binding_verified,
                :alpha_channel_verified, :transparent_background_verified, :visible_pixel_verified,
                :page_render_once_verified, :visual_pixel_binding_verified].all? { |key| value(artifact, key) == true } &&
               [:visual_pixel_sha256, :page_render_content_sha256].all? { |key| /\A[0-9a-f]{64}\z/ =~ value(artifact, key).to_s }
          fail_contract('unproved or mismatched final-page crop')
        end
        ids = value(record, :resulting_entity_ids)
        fail_contract('ambiguous Image identity') unless ids.is_a?(Array) && ids.length == 1
        [artifact, sid, ids.first]
      end

      def self.live_roots(entities, parent = Geom::Transformation.new, result = [])
        entities.to_a.each do |entity|
          next unless entity.valid?
          kind = entity.typename.to_s
          next unless ['Group', 'ComponentInstance', 'Image'].include?(kind)
          sid = entity.get_attribute(DICTIONARY, 'source_span_id', '').to_s
          if !sid.empty?
            result << { :entity => entity, :parent => parent, :source_span_id => sid }
          elsif kind != 'Image'
            children = entity.respond_to?(:entities) ? entity.entities : entity.definition.entities
            live_roots(children, parent * entity.transformation, result)
          end
        end
        result
      end

      def self.apply!(page_group, stats, opts)
        records = item_records(stats, opts[:page])
        return nil if records.empty?
        roots = live_roots(page_group.entities)
        top = roots.reject { |root| root[:entity].typename.to_s == 'Image' }.map do |root|
          bounds = root[:entity].bounds
          bounds_top({ :min => [bounds.min.x.to_f, bounds.min.y.to_f, bounds.min.z.to_f],
                       :max => [bounds.max.x.to_f, bounds.max.y.to_f, bounds.max.z.to_f] }, root[:parent].to_a)
        end.push(0.0).max
        depth = top + GAP
        proof = opts.reject { |key, _value| key == :final_page_crops }.merge(
          :schema => 'bcs.item_raster_display/1.0', :policy => POLICY,
          :page_group_id => RepresentationFidelity.stable_entity_id(page_group),
          :highest_nonimage_text_z => top, :display_gap_inches => GAP,
          :expected_display_z => depth, :placements => [])
        if Array(value(stats, :item_raster_display_placements)).any? { |p| value(p, :page_group_id) == proof[:page_group_id] }
          fail_contract('display placement has already been applied to this page')
        end
        records.each do |record|
          artifact, sid, claim = validate_binding!(record, proof)
          matches = roots.select { |root| root[:source_span_id] == sid && RepresentationFidelity.stable_entity_id(root[:entity]) == claim }
          fail_contract('source Image is absent or duplicated') unless matches.length == 1
          root, canonical = matches.first, source_corners(artifact, proof)
          image, parent = root[:entity], root[:parent]
          unless image.typename.to_s == 'Image' &&
                 ['ghostscript_transparent_page_crop', 'pdftocairo_transparent_page_crop'].include?(image.get_attribute(DICTIONARY, 'renderer', '')) &&
                 image.get_attribute(DICTIONARY, 'raster_source_pdf_sha256', '') == proof[:source_pdf_sha256] &&
                 image.get_attribute(DICTIONARY, 'raster_page_number', nil) == proof[:page]
            fail_contract('generic or misbound Image cannot receive final-page display placement')
          end
          bound = Array(opts[:final_page_crops]).select { |crop| crop[:source_span_id] == sid && crop[:final_page_crop] == true && crop[:source_pdf_sha256] == proof[:source_pdf_sha256] && crop[:raster_page_number] == proof[:page] }
          fail_contract('final-page composition proof is missing') unless bound.length == 1
          close_points!(bound.first[:loops].first, canonical, 'canonical compositor footprint')
          close_points!(image_corners(image.transformation.to_a, parent.to_a, image.width.to_f, image.height.to_f), canonical, 'original Image plane')
          expected = canonical.map { |p| [p[0], p[1], depth] }
          translation = Geom::Transformation.translation(Geom::Point3d.new(0.0, 0.0, depth))
          image.transformation = parent.inverse * translation * parent * image.transformation
          close_points!(image_corners(image.transformation.to_a, parent.to_a, image.width.to_f, image.height.to_f), expected, 'final Image plane')
          proof[:placements] << { :source_span_id => sid, :resulting_entity_id => claim,
            :canonical_corners => canonical, :expected_display_corners => expected }
        end
        stats[:item_raster_display_placements] ||= []
        stats[:item_raster_display_placements] << proof
        proof
      end

      def self.walk_rows(rows, &block)
        Array(rows).each do |row|
          yield row
          walk_rows(value(row, :children), &block)
        end
      end

      def self.row_claim?(row, claim)
        claim == "persistent_id:#{value(row, :persistent_id)}" || claim == "entity_id:#{value(row, :entity_id)}"
      end

      def self.manifest_roots(rows, parent = IDENTITY, result = [])
        Array(rows).each do |row|
          kind = value(row, :typename).to_s
          next unless ['Group', 'ComponentInstance', 'Image'].include?(kind)
          sid = value(value(row, :representation_evidence), :source_span_id).to_s
          if !sid.empty?
            result << { :row => row, :parent => parent, :source_span_id => sid }
          elsif kind != 'Image'
            manifest_roots(value(row, :children), multiply(parent, value(row, :transformation)), result)
          end
        end
        result
      end

      # Called for each actual host snapshot (including saved/reopened). Derive
      # the policy from physical peer bounds and source crop coordinates, not
      # from attributes that merely repeat the importer's claimed final depth.
      def self.verify_manifest!(stats, manifest)
        proofs = value(stats, :item_raster_display_placements)
        fail_contract('display-placement ledger is missing') unless proofs.is_a?(Array)
        required = item_records(stats).map { |r| value(r, :resulting_entity_ids).first }.sort
        observed = []
        groups = {}
        proofs.each do |proof|
          unless value(proof, :schema) == 'bcs.item_raster_display/1.0' && value(proof, :policy) == POLICY && value(proof, :display_gap_inches) == GAP
            fail_contract('display policy is missing or unsupported')
          end
          digest = value(stats, :normalized_input_sha256) || value(stats, :normalized_pdf_sha256)
          fail_contract('display source PDF does not match the import') unless value(proof, :source_pdf_sha256) == digest
          claim = value(proof, :page_group_id)
          fail_contract('duplicate display page group') if groups[claim]
          groups[claim] = true
          pages = []
          walk_rows(manifest) { |row| pages << row if row_claim?(row, claim) }
          fail_contract('physical page group is absent or duplicated') unless pages.length == 1
          roots = manifest_roots(value(pages.first, :children))
          top = roots.reject { |root| value(root[:row], :typename) == 'Image' }.map { |root| bounds_top(value(root[:row], :bounds), root[:parent]) }.push(0.0).max
          depth = top + GAP
          close_points!([[0, 0, value(proof, :highest_nonimage_text_z)], [0, 0, value(proof, :expected_display_z)]], [[0, 0, top], [0, 0, depth]], 'physical text-top policy')
          placements = value(proof, :placements)
          fail_contract('display placements are missing') unless placements.is_a?(Array) && !placements.empty?
          placements.each do |placement|
            id = value(placement, :resulting_entity_id)
            records = item_records(stats, value(proof, :page)).select { |r| value(r, :resulting_entity_ids) == [id] }
            fail_contract('display Image lacks a unique item artifact') unless records.length == 1
            artifact, sid, _claim = validate_binding!(records.first, proof)
            fail_contract('display span identity mismatch') unless value(placement, :source_span_id) == sid
            matches = roots.select { |root| root[:source_span_id] == sid && row_claim?(root[:row], id) && value(root[:row], :typename) == 'Image' }
            fail_contract('physical display Image is missing') unless matches.length == 1
            root = matches.first
            canonical = source_corners(artifact, proof)
            expected = canonical.map { |p| [p[0], p[1], depth] }
            close_points!(value(placement, :canonical_corners), canonical, 'recorded canonical corners')
            close_points!(value(placement, :expected_display_corners), expected, 'recorded display corners')
            content = value(root[:row], :content_evidence)
            actual = image_corners(value(root[:row], :transformation), root[:parent], value(content, :display_width), value(content, :display_height))
            close_points!(actual, expected, 'physical saved Image corners')
            observed << id
          end
        end
        fail_contract('display ledger does not cover every item Image exactly once') unless observed.sort == required && observed.uniq.length == observed.length
        true
      end
    end
  end
end
