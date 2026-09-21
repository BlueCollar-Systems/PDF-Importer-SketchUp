# Preserve the source XY and text certificates while displaying a proved PDF
# image above earlier paint and its source-owned later text above that image.
require_relative 'item_raster_display'
require_relative 'embedded_image_placement'

module BlueCollarSystems
  module PDFVectorImporter
    module DecorativeDisplay
      module_function
      Math3 = ItemRasterDisplay
      Fidelity = RepresentationFidelity
      DICTIONARY = 'BC_PDF_Importer'.freeze
      POLICY = 'source_image_then_later_text_z_only/1.1'.freeze
      SCHEMA = 'bcs.decorative_display/1.1'.freeze
      # A .001-inch image clearance leaked covered filled text in native
      # oblique views. Separate the tested image depth guard from the smaller
      # later-text clearance; neither changes source XY or text geometry.
      IMAGE_GAP = 0.01
      GAP = 0.001

      def value(hash, key); Math3.value(hash, key); end
      def fail_contract(message)
        raise Fidelity::ContractError, "source image display: #{message}"
      end

      def digest?(digest); /\A[0-9a-f]{64}\z/ =~ digest.to_s; end

      def symbolic(object)
        return object.map { |v| symbolic(v) } if object.is_a?(Array)
        return object unless object.is_a?(Hash)
        object.each_with_object({}) { |(k,v),h| h[k.to_sym] = symbolic(v) }
      end

      def verify_original_clip!(record, context, projected)
        proof = value(record,:source_proof)
        event = value(proof,:source_image_event)
        clip = value(event,:clip_bounds)
        query = [projected.map { |p| p[0] }.min,projected.map { |p| p[1] }.min,
                 projected.map { |p| p[0] }.max,projected.map { |p| p[1] }.max]
        unless clip.nil? || (clip.is_a?(Array) && clip.length == 4 && clip.all? { |v| Math3.number?(v) } &&
          clip[2] > clip[0] && clip[3] > clip[1])
          fail_contract('source clip bounds are malformed')
        end
        narrower = clip && !(clip[0] <= query[0] && clip[1] <= query[1] && clip[2] >= query[2] && clip[3] >= query[3])
        qualification = value(proof,:clip_qualification)
        if narrower
          unless value(qualification,:policy) == 'original_pdf_full_affine_clip_coverage' &&
            value(qualification,:cairo_clip_bounds) == clip
            fail_contract('narrow renderer clip has no original PDF coverage proof')
          end
          require_relative 'source_image_paint_order'
          begin
            SourceImagePaintOrder.original_clip_proof!(
              :original_clip_proof=>symbolic(value(qualification,:original_clip_proof)),
              :parsed_pdf_sha256=>value(context,:source_pdf_sha256),
              :page_number=>value(context,:page),
              :image_object_number=>value(record,:image_object_number),
              :placement_index=>value(record,:placement_index),
              :ctm=>value(record,:ctm), :corners_pts=>value(record,:corners_pdf))
          rescue SourceImagePaintOrder::Unproven => error
            fail_contract(error.message)
          end
        elsif value(qualification,:policy) != 'svg_clip_covers_full_native_affine_footprint'
          fail_contract('source clip qualification policy missing')
        end
      end

      def indices(value)
        if value.is_a?(String) && /\A\d+(?:,\d+)*\z/ =~ value
          value = value.split(',').map { |v| v.to_i }
        end
        fail_contract('invalid source placement indices') unless value.is_a?(Array) &&
          !value.empty? && value.all? { |v| v.is_a?(Integer) && v >= 0 } && value.uniq == value
        value
      end

      def visible_neutral_style!(row, neutral)
        style = value(row,:style_evidence)
        fail_contract('display entity is hidden') unless value(style,:entity_visible) == true &&
          value(style,:layer_visible) == true
        fail_contract('display wrapper changes inherited material') if neutral &&
          (!value(style,:material).nil? || !value(style,:back_material).nil?)
      end

      def same_matrix!(actual, expected, label)
        fail_contract(label) unless EmbeddedImagePlacement.same_matrix?(actual, expected)
      end

      def translation(z)
        values = Math3::IDENTITY.dup
        values[14] = z
        values
      end

      def planar_parent!(matrix)
        matrix = Math3.matrix!(matrix)
        fail_contract('parent cannot retain a pure source Z offset') unless
          matrix.values_at(2, 6, 8, 9) == [0, 0, 0, 0] && matrix[10] > 0
        matrix
      end

      def minimum_z(bounds, parent)
        low, high = value(bounds,:min), value(bounds,:max)
        Math3.bounds_top(bounds,parent) # Validate all native numbers first.
        (0...8).map do |i|
          Math3.transform((0...3).map { |axis| (i & (1 << axis)).zero? ? low[axis] : high[axis] },parent)[2]
        end.min
      end

      def source_corners(record, context)
        EmbeddedImagePlacement.affine(value(record, :corners_pdf),
          value(context, :media_box), value(context, :scale),
          value(context, :page_y_offset), value(context, :page_rotation))[:corners]
      end

      # A final-page crop is a coverage witness, never a fabricated glyph owner.
      # Rejoin it to the certified source artifact before moving an image, and
      # to the actual saved Image (including exported pixels) during host QA.
      def verify_final_page_crops!(record, context, stats, rows = nil)
        source = value(record,:source_proof)
        crops = value(source,:later_final_page_crops)
        crops = [] if crops.nil?
        fail_contract('later final-page crop witnesses are malformed') unless crops.is_a?(Array)
        claimed = Array(value(source,:later_roots)).flat_map { |r| value(r,:placement_indices) }
        crops.each do |crop|
          index, rank = value(crop,:placement_index), value(crop,:paint_rank)
          fail_contract('later crop repeats or precedes source paint') unless
            index.is_a?(Integer) && index >= 0 && !claimed.include?(index) &&
            rank.is_a?(Integer) && rank > value(source,:image_paint_rank)
          claimed << index
          id, sid = value(crop,:resulting_entity_id), value(crop,:source_span_id)
          records = Math3.item_records(stats,value(context,:page)).select { |r| value(r,:resulting_entity_ids) == [id] }
          fail_contract('later crop lacks one certified source artifact') unless records.length == 1
          artifact, bound_sid, bound_id = Math3.validate_binding!(records.first,context)
          box = value(artifact,:source_box)
          canonical = Math3.source_corners(artifact,context)
          fail_contract('later crop source identity differs') unless sid == bound_sid && id == bound_id &&
            value(crop,:source_box) == box && value(crop,:page_number) == value(context,:page) &&
            value(crop,:source_pdf_sha256) == value(context,:source_pdf_sha256)
          page_box, view = value(context,:svg_page_box), value(context,:svg_viewbox)
          expected = [box[0]-page_box[0]+view[0],view[3]+view[1]+page_box[1]-box[3],
                      box[2]-page_box[0]+view[0],view[3]+view[1]+page_box[1]-box[1]]
          glyph = value(crop,:glyph_bounds_svg)
          fail_contract('later glyph is not fully contained in its final-page crop') unless
            value(crop,:bounds_svg) == expected && glyph.is_a?(Array) && glyph.length == 4 &&
            glyph.all? { |n| Math3.number?(n) } && glyph[2] > glyph[0] && glyph[3] > glyph[1] &&
            expected[0] <= glyph[0] && expected[1] <= glyph[1] &&
            expected[2] >= glyph[2] && expected[3] >= glyph[3]
          next unless rows
          matches = Math3.manifest_roots(rows).select { |r| Math3.row_claim?(r[:row],id) && r[:source_span_id] == sid }
          fail_contract('later crop native Image is absent or duplicated') unless matches.length == 1
          root = matches.first
          image, content = root[:row], value(root[:row],:content_evidence)
          fail_contract('later crop saved pixels/source differ') unless value(image,:typename) == 'Image' &&
            value(content,:raster_source_pdf_sha256) == value(context,:source_pdf_sha256) &&
            value(content,:raster_page_number) == value(context,:page) &&
            value(content,:host_texture_export_verified) == true &&
            value(content,:host_visual_pixel_sha256) == value(artifact,:visual_pixel_sha256) &&
            value(content,:host_pixel_width) == value(artifact,:pixel_width) &&
            value(content,:host_pixel_height) == value(artifact,:pixel_height)
          visible_neutral_style!(image,false)
          actual = Math3.image_corners(value(image,:transformation),root[:parent],
            value(content,:display_width),value(content,:display_height))
          depth = actual.first[2]
          fail_contract('later final-page crop is not above the source image') unless
            depth >= value(context,:image_display_z) + GAP - Math3::TOLERANCE
          Math3.close_points!(actual,canonical.map { |p| [p[0],p[1],depth] },'later final-page crop footprint')
        end
        true
      end

      def validate_source!(record, context)
        proof = value(record, :source_proof)
        event = value(proof, :source_image_event)
        pixels = value(event, :pixels)
        unless value(proof, :schema) == 'bcs.source_image_paint_order/1.0' &&
               digest?(value(context, :source_svg_sha256)) &&
               value(proof, :source_svg_sha256) == value(context, :source_svg_sha256) &&
               value(proof, :image_id) == value(record, :image_id) &&
               value(proof, :image_paint_rank).is_a?(Integer) &&
               value(proof, :image_paint_rank) == value(event, :paint_rank) &&
               value(event, :alpha) == 1.0 && value(event, :kind).to_s == 'image' &&
               value(pixels, :all_opaque) == true &&
               digest?(value(pixels, :visual_pixel_sha256)) &&
               [:pixel_width, :pixel_height].all? { |k| value(pixels, k).is_a?(Integer) && value(pixels, k) > 0 }
          fail_contract('image lacks a source-bound paint-order proof')
        end
        later = value(proof, :later_roots)
        fail_contract('later source owners are missing') unless later.is_a?(Array)
        ids = later.map { |r| value(r,:id) }
        fail_contract('later source owner repeats') unless ids.uniq == ids
        later.each do |root|
          indices, ranks = value(root, :placement_indices), value(root, :source_paint_ranks)
          unless indices.is_a?(Array) && !indices.empty? && indices.uniq == indices &&
                 indices.all? { |i| i.is_a?(Integer) && i >= 0 } &&
                 ranks.is_a?(Array) && ranks.length == indices.length &&
                 ranks.all? { |rank| rank.is_a?(Integer) && rank > value(proof, :image_paint_rank) }
            fail_contract('later text root straddles the source image paint order')
          end
        end
        box, view = value(context,:svg_page_box), value(context,:svg_viewbox)
        unless [box,view].all? { |b| b.is_a?(Array) && b.length == 4 && b.all? { |v| Math3.number?(v) } } &&
          box[2] > box[0] && box[3] > box[1] && view[2] > 0 && view[3] > 0
          fail_contract('source image SVG page mapping missing')
        end
        raw = value(record,:corners_pdf)
        fail_contract('source image corners missing') unless raw.is_a?(Array) && raw.length == 4 &&
          raw.all? { |p| p.is_a?(Array) && p.length == 2 && p.all? { |n| Math3.number?(n) } }
        projected = [3,2,1,0].map { |i| [raw[i][0]-box[0]+view[0],view[3]+view[1]+box[1]-raw[i][1]] }
        event_corners = value(event,:corners)
        fail_contract('source image affine differs from its actual source occurrence') unless
          event_corners.is_a?(Array) && event_corners.length == 4 &&
          projected.zip(event_corners).all? do |a,b|
            b.is_a?(Array) && b.length == 2 && a.zip(b).all? { |x,y| Math3.number?(y) && (x-y).abs <= 1.0/128.0 }
          end
        verify_original_clip!(record,context,projected)
        source_corners(record, context)
      end

      def apply!(page_group, stats, plans, context)
        return nil if plans.empty?
        fail_contract('invalid source PDF identity') unless digest?(context[:source_pdf_sha256])
        roots = Math3.live_roots(page_group.entities)
        top = roots.reject { |r| r[:entity].typename.to_s == 'Image' }.map do |root|
          Math3.bounds_top(Fidelity.entity_bounds_payload(root[:entity]), root[:parent].to_a)
        end.push(0.0).max
        proof = context.merge(:schema=>SCHEMA, :policy=>POLICY,
          :page_group_id=>Fidelity.stable_entity_id(page_group), :display_gap_inches=>GAP,
          :image_display_gap_inches=>IMAGE_GAP,
          :canonical_text_top=>top, :image_display_z=>top+IMAGE_GAP, :placements=>[])
        ledger = (stats[:decorative_display_placements] ||= [])
        fail_contract('display order already applied to page') if ledger.any? { |p| value(p,:page_group_id) == proof[:page_group_id] }
        owners = {}
        plans.each do |plan|
          image, asset, source = plan.fetch(:image_entity), plan.fetch(:asset), plan.fetch(:source_proof)
          record = { :image_id=>Fidelity.stable_entity_id(image), :corners_pdf=>asset.corners_pts,
            :image_object_number=>asset.obj_num, :placement_index=>asset.placement_index, :ctm=>asset.ctm,
            :source_proof=>source, :later_text=>[] }
          corners = validate_source!(record, proof)
          verify_final_page_crops!(record,proof,stats)
          fail_contract('image is not a direct page child') unless page_group.entities.to_a.include?(image)
          fail_contract('image is not an embedded source Image') unless image.typename.to_s == 'Image' &&
            image.get_attribute(DICTIONARY,'source_span_id','').to_s.empty?
          Math3.close_points!(Math3.image_corners(image.transformation.to_a, Math3::IDENTITY,
            image.width.to_f,image.height.to_f), corners, 'original embedded image corners')
          record[:canonical_transformation] = image.transformation.to_a
          expected_image = Geom::Transformation.new(translation(top+IMAGE_GAP)) * image.transformation
          image.transformation = expected_image
          same_matrix!(image.transformation.to_a,expected_image.to_a,'host ignored image display transformation')
          Math3.close_points!(Math3.image_corners(image.transformation.to_a,Math3::IDENTITY,
            image.width.to_f,image.height.to_f),corners.map { |p| [p[0],p[1],top+IMAGE_GAP] },'displayed embedded image corners')
          image.set_attribute(DICTIONARY, 'decorative_source_image', true)
          record[:expected_display_transformation] = image.transformation.to_a
          later = plan.fetch(:later_roots)
          fail_contract('later source root coverage differs') unless later.length == value(source,:later_roots).length
          later.each do |entry|
            root, parent = entry.fetch(:entity), entry.fetch(:parent)
            id = Fidelity.stable_entity_id(root)
            fail_contract('later source root is assigned twice') if owners[id]
            owners[id] = true
            claims = value(source,:later_roots).select { |r| value(r,:id) == id }
            fail_contract('later source claim is not bound') unless claims.length == 1
            claim = claims.first
            source_indices = indices(root.get_attribute(DICTIONARY,'source_placement_indices',nil))
            fail_contract('later native source indices differ') unless source_indices == value(claim,:placement_indices) &&
              root.get_attribute(DICTIONARY,'source_span_id','') == value(claim,:source_span_id)
            matrix = planar_parent!(parent.to_a)
            canonical = root.transformation.to_a
            bounds = Fidelity.entity_bounds_payload(root)
            before = Fidelity.physical_evidence([root])
            low = minimum_z(bounds, matrix)
            dz = top + IMAGE_GAP + GAP - low
            candidates = []
            visit = lambda do |entities|
              entities.to_a.each do |entity|
                next unless ['Group','ComponentInstance'].include?(entity.typename.to_s)
                children = entity.respond_to?(:entities) ? entity.entities : entity.definition.entities
                candidates << entity if children.to_a.include?(root)
                visit.call(children) unless entity.equal?(root)
              end
            end
            visit.call(page_group.entities)
            fail_contract('dedicated original text container missing') unless candidates.length == 1
            wrapper = candidates.first
            fail_contract('text container is shared or already transformed') unless
              wrapper.get_attribute(DICTIONARY,'decorative_text_container',false) == true &&
              wrapper.entities.to_a == [root] &&
              EmbeddedImagePlacement.same_matrix?(wrapper.transformation.to_a,Math3::IDENTITY)
            expected_wrapper = translation(dz/matrix[10])
            wrapper.transformation = Geom::Transformation.new(expected_wrapper)
            same_matrix!(wrapper.transformation.to_a,expected_wrapper,'host ignored wrapper display transformation')
            fail_contract('dedicated text container changes source visibility/material') unless
              wrapper.visible? && wrapper.layer.visible? && wrapper.material.nil?
            wrapper.set_attribute(DICTIONARY,'decorative_text_wrapper',true)
            fail_contract('display wrapper changed canonical text') unless Fidelity.physical_evidence([root]) == before &&
              wrapper.entities.to_a == [root]
            record[:later_text] << { :root_id=>id, :wrapper_id=>Fidelity.stable_entity_id(wrapper),
              :source_span_id=>value(claim,:source_span_id), :placement_indices=>source_indices,
              :canonical_parent=>matrix, :canonical_transformation=>canonical,
              :canonical_bounds=>bounds, :canonical_physical=>before,
              :expected_wrapper_transformation=>wrapper.transformation.to_a }
          end
          proof[:placements] << record
        end
        ledger << proof
        proof
      end

      def find_rows(rows, claim)
        found = []
        Math3.walk_rows(rows) { |row| found << row if Math3.row_claim?(row,claim) }
        fail_contract('native display identity is missing or repeated') unless found.length == 1
        found.first
      end

      def rows_with_parents(rows, parent = Math3::IDENTITY, result = [])
        Array(rows).each do |row|
          result << [row,parent]
          children = value(row,:children)
          if children.is_a?(Array) && !children.empty?
            rows_with_parents(children,Math3.multiply(parent,value(row,:transformation)),result)
          end
        end
        result
      end

      def verify_manifest!(stats, manifest)
        ledgers = value(stats,:decorative_display_placements)
        fail_contract('display ledger missing') unless ledgers.is_a?(Array)
        seen_images, seen_wrappers, seen_pages = [], [], []
        ledgers.each do |proof|
          unless value(proof,:schema) == SCHEMA && value(proof,:policy) == POLICY &&
                 value(proof,:display_gap_inches) == GAP &&
                 value(proof,:image_display_gap_inches) == IMAGE_GAP &&
                 value(proof,:source_pdf_sha256) == (value(stats,:normalized_input_sha256) || value(stats,:normalized_pdf_sha256))
            fail_contract('display policy/source mismatch')
          end
          page_id = value(proof,:page_group_id)
          fail_contract('duplicate display page') if seen_pages.include?(page_id)
          seen_pages << page_id
          page = find_rows(manifest,page_id)
          rows = value(page,:children)
          all_rows = rows_with_parents(rows)
          placements = value(proof,:placements)
          fail_contract('empty display ledger') unless placements.is_a?(Array) && !placements.empty?
          wrapped = placements.flat_map { |p| Array(value(p,:later_text)) }
          roots = Math3.manifest_roots(rows)
          top = roots.reject { |r| value(r[:row],:typename) == 'Image' }.map do |root|
            claim = wrapped.select { |w| Math3.row_claim?(root[:row],value(w,:root_id)) }
            fail_contract('duplicate later text root') if claim.length > 1
            parent = claim.empty? ? root[:parent] : value(claim.first,:canonical_parent)
            Math3.bounds_top(value(root[:row],:bounds),parent)
          end.push(0.0).max
          Math3.close_points!([[0,0,value(proof,:canonical_text_top)],[0,0,value(proof,:image_display_z)]],
            [[0,0,top],[0,0,top+IMAGE_GAP]],'canonical source text top')
          placements.each do |placement|
            canonical = validate_source!(placement,proof)
            verify_final_page_crops!(placement,proof,stats,rows)
            id = value(placement,:image_id)
            image = find_rows(rows,id)
            fail_contract('embedded image is not a direct marked child') unless rows.include?(image) &&
              value(image,:typename) == 'Image' && value(image,:decorative_source_image) == true
            seen_images << id
            visible_neutral_style!(image,false)
            expected = Math3.multiply(translation(top+IMAGE_GAP),value(placement,:canonical_transformation))
            same_matrix!(value(placement,:expected_display_transformation),expected,'recorded image matrix changed')
            same_matrix!(value(image,:transformation),expected,'native image matrix changed')
            content = value(image,:content_evidence)
            pixels = value(value(value(placement,:source_proof),:source_image_event),:pixels)
            unless value(content,:host_texture_export_verified) == true &&
                   value(content,:host_visual_pixel_sha256) == value(pixels,:visual_pixel_sha256) &&
                   value(content,:host_pixel_width) == value(pixels,:pixel_width) &&
                   value(content,:host_pixel_height) == value(pixels,:pixel_height)
              fail_contract('native embedded pixels differ from the source')
            end
            actual = Math3.image_corners(value(image,:transformation),Math3::IDENTITY,
              value(content,:display_width),value(content,:display_height))
            Math3.close_points!(actual,canonical.map { |p| [p[0],p[1],top+IMAGE_GAP] },'native source-image footprint')
            expected_roots = value(value(placement,:source_proof),:later_roots)
            text = value(placement,:later_text)
            fail_contract('later text coverage differs') unless text.is_a?(Array) &&
              text.map { |r| value(r,:root_id) }.sort == expected_roots.map { |r| value(r,:id) }.sort
            text.each do |item|
              wrapper_id = value(item,:wrapper_id)
              wrapper = find_rows(rows,wrapper_id)
              seen_wrappers << wrapper_id
              children = value(wrapper,:children)
              fail_contract('wrapper ownership changed') unless value(wrapper,:typename) == 'Group' &&
                value(wrapper,:decorative_text_wrapper) == true && children.is_a?(Array) && children.length == 1 &&
                value(wrapper,:native_child_count) == 1 &&
                Math3.row_claim?(children.first,value(item,:root_id))
              root = children.first
              fail_contract('wrapped canonical claim contains a second source claim') unless Array(value(root,:children)).empty?
              visible_neutral_style!(wrapper,true)
              parent = all_rows.find { |pair| pair[0].equal?(wrapper) }[1]
              same_matrix!(parent,value(item,:canonical_parent),'wrapper ancestry changed')
              planar_parent!(parent)
              same_matrix!(value(root,:transformation),value(item,:canonical_transformation),'canonical text transformation changed')
              physical = value(item,:canonical_physical)
              fail_contract('canonical text geometry/style changed') unless
                value(value(root,:geometry_evidence),:sha256) == value(physical,:physical_geometry_sha256) &&
                value(value(root,:style_evidence),:sha256) == value(physical,:physical_style_sha256)
              Math3.close_points!([value(value(root,:bounds),:min),value(value(root,:bounds),:max)],
                [value(value(item,:canonical_bounds),:min),value(value(item,:canonical_bounds),:max)],'canonical text bounds')
              low = minimum_z(value(root,:bounds),parent)
              expected_wrapper = translation((top+IMAGE_GAP+GAP-low)/parent[10])
              same_matrix!(value(wrapper,:transformation),expected_wrapper,'native wrapper is not exact source Z display offset')
              same_matrix!(value(item,:expected_wrapper_transformation),expected_wrapper,'wrapper ledger changed')
              source = expected_roots.find { |r| value(r,:id) == value(item,:root_id) }
              fail_contract('wrapped source owner changed') unless
                value(value(root,:representation_evidence),:source_span_id) == value(source,:source_span_id) &&
                value(item,:placement_indices) == value(source,:placement_indices) &&
                indices(value(value(root,:representation_evidence),:source_placement_indices)) == value(source,:placement_indices)
            end
          end
        end
        actual_images, actual_wrappers = [], []
        Math3.walk_rows(manifest) do |row|
          id = "persistent_id:#{value(row,:persistent_id)}"
          actual_images << id if value(row,:decorative_source_image) == true
          actual_wrappers << id if value(row,:decorative_text_wrapper) == true
        end
        fail_contract('display entity coverage is not exact') unless
          seen_images.uniq == seen_images && seen_wrappers.uniq == seen_wrappers &&
          actual_images.sort == seen_images.sort && actual_wrappers.sort == seen_wrappers.sort
        qualifications = value(stats,:embedded_image_paint_order)
        if qualifications
          fail_contract('source qualification ledger is invalid') unless qualifications.is_a?(Array)
          qualifications.each do |qualification|
            count = value(qualification,:qualified_count)
            page_proofs = ledgers.select { |p| value(p,:page) == value(qualification,:page) }
            fail_contract('qualified image display proof is missing') unless count.is_a?(Integer) && count >= 0 &&
              page_proofs.inject(0) { |n,p| n + value(p,:placements).length } == count
          end
        end
        true
      end
    end
  end
end
