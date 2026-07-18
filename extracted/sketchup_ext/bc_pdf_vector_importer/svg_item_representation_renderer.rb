# bc_pdf_vector_importer/svg_item_representation_renderer.rb
# Item-scoped exact source Glyphs and flat Geometry representations.

require File.join(File.dirname(__FILE__), 'cairo_glyph_source')
require File.join(File.dirname(__FILE__), 'representation_fidelity')

module BlueCollarSystems
  module PDFVectorImporter
    module SvgItemRepresentationRenderer
      SIZE_TOLERANCE_INCHES = 1.0e-6
      SUPPORTED_MODES = [:glyphs, :geometry].freeze

      def self.render_svg(entities, svg, media_box, item, requested_mode,
                          opts = {})
        mode = RepresentationFidelity.normalize_mode(requested_mode)
        unless SUPPORTED_MODES.include?(mode)
          raise RepresentationFidelity::ContractError,
                'item vector renderer supports only Glyphs or Geometry'
        end
        source_id = RepresentationFidelity.source_span_id(item)
        verify_source_context!(source_id, opts[:source_context])
        verify_source_bbox!(item, media_box)

        before = RepresentationFidelity.snapshot(entities)
        placed = CairoGlyphSource.model_space_loops(svg, media_box, opts)
        pens = Array(placed).map do |entry|
          {
            :x => Array(entry[:pen_pdf])[0],
            :y => Array(entry[:pen_pdf])[1],
            :placement_index => entry[:placement_index]
          }
        end
        match = CairoGlyphSource.match_spans(pens, [item], media_box)
        selection = select_item_placements(
          source_id, mode, match, pens, media_box, opts[:peer_items]
        )
        indices = selection[:indices]
        entries = Array(placed).select do |entry|
          indices.include?(entry[:placement_index].to_i)
        end

        if indices.empty?
          return impossible_result(source_id, item, mode, placed, match,
                                   opts[:source_context], selection)
        end
        unless entries.length == indices.length
          raise RepresentationFidelity::ContractError,
                "#{source_id}: item vector placement identities could not be " \
                'joined back to every exact source outline'
        end
        validate_entries!(source_id, entries)

        group = create_owned_group!(entities, source_id, mode, opts[:layer],
                                    indices)
        build = mode == :glyphs ?
          build_glyph_groups!(group, entries, source_id, opts[:layer]) :
          build_flat_geometry!(group, entries, source_id, opts[:layer])
        after = RepresentationFidelity.snapshot(entities)
        created = RepresentationFidelity.created_between(before, after)
        created_ids = RepresentationFidelity.stable_ids(created)
        group_id = RepresentationFidelity.stable_entity_id(group)
        unless created_ids == [group_id]
          raise RepresentationFidelity::ContractError,
                "#{source_id}: item vector artifacts escaped their owned group"
        end

        expected = CairoGlyphSource.loops_extent(entries)
        verify_bounds!(group, expected, source_id)
        verify_structure!(group, mode, entries.length, build[:edge_count],
                          source_id)
        verify_visible_tree!(group, source_id)
        physical = physical_entities(group, mode)
        physical_ids = RepresentationFidelity.stable_ids(physical)
        if physical_ids.empty?
          raise RepresentationFidelity::ContractError,
                "#{source_id}: item vector representation has no physical entities"
        end

        {
          :ok => true,
          :renderer => mode == :glyphs ? :svg_item_glyph_groups :
            :svg_item_flat_geometry,
          :mode => mode,
          :source_span_id => source_id,
          :source_item => item,
          :group => group,
          :group_entity_id => group_id,
          :created_entities => created,
          :created_entity_ids => created_ids,
          :physical_entity_ids => physical_ids,
          :placement_indices => indices,
          :association_strategy => selection[:strategy],
          :glyph_ids => entries.map { |entry| entry[:glyph_id].to_s },
          :source_extent => expected.map { |value| value.to_f },
          :edge_count => build[:edge_count],
          :glyph_group_count => build[:glyph_group_count],
          :identity_verified => true,
          :placement_verified => true,
          :rotation_verified => entries.all? do |entry|
            Array(entry[:svg_matrix]).length >= 6
          end,
          :size_verified => true,
          :entity_type_verified => true,
          :visibility_verified => true,
          :visual_fidelity_verified => true,
          :transition_proof => nil,
          :failures => []
        }
      rescue StandardError => error
        cleanup_error = cleanup_created_since(entities, before)
        if cleanup_error
          raise RepresentationFidelity::ContractError,
                "item #{mode || requested_mode} renderer failed: " \
                "#{error.message}; owned cleanup failed: #{cleanup_error.message}"
        end
        raise error if error.is_a?(RepresentationFidelity::ContractError)
        raise RepresentationFidelity::ContractError,
              "item #{mode || requested_mode} renderer failed: #{error.message}"
      end

      def self.verify_transformed_delivery!(result)
        unless result.is_a?(Hash) && result[:ok] == true && result[:group]
          raise RepresentationFidelity::ContractError,
                'transformed item vector delivery is missing its owned group'
        end
        group = result[:group]
        unless RepresentationFidelity.stable_entity_id(group) ==
               result[:group_entity_id].to_s
          raise RepresentationFidelity::ContractError,
                'transformed item vector group identity changed'
        end
        verify_structure!(
          group, result[:mode], result[:placement_indices].length,
          result[:edge_count], result[:source_span_id]
        )
        verify_visible_tree!(group, result[:source_span_id])
        box = bounds_hash(group)
        unless box[:width] > SIZE_TOLERANCE_INCHES ||
               box[:height] > SIZE_TOLERANCE_INCHES
          raise RepresentationFidelity::ContractError,
                'transformed item vector group has empty bounds'
        end
        true
      end

      def self.finalize_source_evidence!(result, item, page_rotation = 0.0)
        verify_transformed_delivery!(result)
        group = result[:group]
        source_id = RepresentationFidelity.source_span_id(item)
        unless result[:source_span_id].to_s == source_id
          raise RepresentationFidelity::ContractError,
                'item vector source identity changed before evidence finalization'
        end
        box = bounds_hash(group)
        transform = RepresentationFidelity.entity_transformation_payload(group)
        transform ||= { :kind => 'baked_geometry', :entity_count => 1 }
        expected_box = nil
        source_extent = result[:source_extent]
        if source_extent
          unless result[:page_transform_verified] == true &&
                 Array(result[:source_page_transformation]).length == 16
            raise RepresentationFidelity::ContractError,
                  'item vector source page transform was not independently verified'
          end
          expected_box = RepresentationFidelity.transformed_extent_bounds(
            source_extent, result[:source_page_transformation], 0.0, 0.0
          )
          expected_min = expected_box[:min]
          expected_max = expected_box[:max]
          actual_values = [
            box[:min_x], box[:min_y], box[:min_z],
            box[:max_x], box[:max_y], box[:max_z]
          ]
          expected_values = expected_min + expected_max
          tolerance = [
            SIZE_TOLERANCE_INCHES,
            (expected_max[0] - expected_min[0]).abs * 1.0e-5,
            (expected_max[1] - expected_min[1]).abs * 1.0e-5
          ].max
          unless actual_values.each_with_index.all? do |value, index|
            (value.to_f - expected_values[index].to_f).abs <= tolerance
          end
            raise RepresentationFidelity::ContractError,
                  'item vector final bounds differ from source outlines and page transform'
          end
          transform = result[:source_page_transformation]
        end
        expected_box ||= {
          :min => [box[:min_x], box[:min_y], box[:min_z]],
          :max => [box[:max_x], box[:max_y], box[:max_z]]
        }
        expected = RepresentationFidelity.source_expected_evidence(
          item, result[:mode],
          :entities => [group],
          :source_anchor => expected_box[:min],
          :source_rotation_radians =>
            (RepresentationFidelity.source_rotation_degrees(item) +
             page_rotation.to_f) * Math::PI / 180.0,
          :expected_width => expected_box[:max][0] - expected_box[:min][0],
          :expected_height => expected_box[:max][1] - expected_box[:min][1],
          :expected_depth => expected_box[:max][2] - expected_box[:min][2],
          :expected_bounds => expected_box,
          :expected_transformation => transform
        )
        renderer = result[:mode] == :glyphs ?
          'svg_item_glyph_group_renderer' :
          'svg_item_flat_geometry_renderer'
        RepresentationFidelity.attach_source_evidence!(
          [group], expected, renderer
        )
        result[:expected_evidence] = expected
        result[:content_verified] = true
        result[:physical_geometry_verified] = true
        result[:physical_style_verified] = true
        result[:transform_verified] = true
        result
      end

      def self.impossible_result(source_id, item, mode, placed, match,
                                 source_context, selection = {})
        binding = RepresentationFidelity.proof_binding(source_id)
        to_mode = mode == :glyphs ? :geometry : :raster
        renderer = mode == :glyphs ? 'svg_item_glyph_group_renderer' :
          'svg_item_flat_geometry_renderer'
        contract = mode == :glyphs ?
          'one owned physical glyph group per exact source placement' :
          'one owned flat raw-edge set for the exact source item'
        reason = Array(placed).empty? ? :source_vector_geometry_absent :
          :source_item_identity_unavailable
        proof = {
          :source_span_id => source_id,
          :importer_id => binding[:importer_id],
          :page_number => binding[:page_number],
          :scope => :item,
          :category => :exact_representation_impossible,
          :affirmative_impossibility => true,
          :generic_failure => false,
          :from_mode => mode,
          :to_mode => to_mode,
          :reason_code => reason,
          :attempted_renderer => renderer,
          :created_entity_ids => [],
          :cleaned_entity_ids => [],
          :cleanup_outcome => :not_required,
          :evidence => {
            :source_observation =>
              'complete page inventory contained no exact item-bound outline set for this representation contract',
            :source_text => CairoGlyphSource.item_text(item),
            :source_renderer => source_context[:renderer].to_s,
            :source_placement_count => Array(placed).length,
            :matched_item_placement_count => 0,
            :bbox_geometry_candidate_count =>
              Array(selection[:candidate_indices]).length,
            :peer_ambiguous_placement_indices =>
              Array(selection[:ambiguous_indices]),
            :glyph_coverage_failures => Array(match[:coverage_failures]),
            :representation_contract_checked => contract,
            :verification =>
              'source bbox, complete page inventory, placement ownership, and representation-specific physical structure were checked'
          }
        }
        {
          :ok => false,
          :renderer => renderer.to_sym,
          :mode => mode,
          :source_span_id => source_id,
          :created_entity_ids => [],
          :transition_proof => proof,
          :failures => []
        }
      end

      # Glyphs preserves one independently owned physical unit for each exact
      # source glyph, so it uses the strict one-to-one semantic association.
      # Flat Geometry has a different contract: it may preserve a ligature or
      # combined source outline as raw paths when every renderer placement in
      # the source bbox belongs unambiguously to this item. Peer overlap rejects
      # the entire candidate set instead of duplicating another text artifact.
      def self.select_item_placements(source_id, mode, match, pens, media_box,
                                      peer_items)
        exact = Array(match[:placement_matches]).select do |record|
          record[:source_span_id].to_s == source_id
        end.map { |record| record[:placement_index].to_i }.uniq.sort
        unless exact.empty?
          ambiguous = ambiguous_peer_placements(
            exact, pens, media_box, source_id, peer_items
          )
          return {
            :indices => ambiguous.empty? ? exact : [],
            :candidate_indices => exact,
            :ambiguous_indices => ambiguous,
            :strategy => :exact_glyph_ownership
          }
        end
        return {
          :indices => [], :candidate_indices => [],
          :ambiguous_indices => [], :strategy => :exact_glyph_ownership
        } unless mode == :geometry

        candidates = Array(match[:coverage_failures]).select do |failure|
          failure[:source_span_id].to_s == source_id
        end.inject([]) do |values, failure|
          values + Array(failure[:placement_indices]).map { |index| index.to_i }
        end.uniq.sort
        ambiguous = ambiguous_peer_placements(
          candidates, pens, media_box, source_id, peer_items
        )
        {
          :indices => ambiguous.empty? ? candidates : [],
          :candidate_indices => candidates,
          :ambiguous_indices => ambiguous,
          :strategy => :bbox_raw_outline_set
        }
      end

      def self.ambiguous_peer_placements(candidate_indices, pens, media_box,
                                         source_id, peer_items)
        candidates = Array(candidate_indices)
        return [] if candidates.empty?
        base_x = media_box.is_a?(Array) ? media_box[0].to_f : 0.0
        base_y = media_box.is_a?(Array) ? media_box[1].to_f : 0.0
        tolerance = if CairoGlyphSource.const_defined?(
          :SPAN_MATCH_TOLERANCE_PT
        )
                      CairoGlyphSource::SPAN_MATCH_TOLERANCE_PT.to_f
                    else
                      2.0
                    end
        peer_boxes = Array(peer_items).map do |peer|
          peer_id = RepresentationFidelity.source_span_id(peer)
          next if peer_id == source_id
          box = CairoGlyphSource.item_bbox_media_relative(peer, base_x, base_y)
          unless box
            raise RepresentationFidelity::ContractError,
                  "#{source_id}: peer source bbox is unavailable; Geometry " \
                  'ownership cannot be verified'
          end
          x0, x1 = [box[0].to_f, box[2].to_f].minmax
          y0, y1 = [box[1].to_f, box[3].to_f].minmax
          [x0 - tolerance, y0 - tolerance,
           x1 + tolerance, y1 + tolerance]
        end.compact
        Array(pens).select do |pen|
          index = pen[:placement_index].to_i
          next false unless candidates.include?(index)
          x = pen[:x].to_f
          y = pen[:y].to_f
          peer_boxes.any? do |box|
            x >= box[0] && x <= box[2] && y >= box[1] && y <= box[3]
          end
        end.map { |pen| pen[:placement_index].to_i }.uniq.sort
      end

      def self.verify_source_context!(source_id, context)
        unless context.is_a?(Hash)
          raise RepresentationFidelity::ContractError,
                "#{source_id}: item vector page inventory evidence is missing"
        end
        binding = RepresentationFidelity.proof_binding(source_id)
        importer_id = context[:importer_id].to_s.strip
        page = context[:page_number]
        unless importer_id == binding[:importer_id] &&
               page.to_s.strip =~ /\A[1-9]\d*\z/ &&
               page.to_i == binding[:page_number]
          raise RepresentationFidelity::ContractError,
                "#{source_id}: item vector page inventory is misbound"
        end
        failures = context[:page_failures]
        failures_present = if failures.is_a?(Hash)
                             failures.any? do |_key, value|
                               !value.nil? && !value.to_s.strip.empty?
                             end
                           elsif failures.is_a?(Array)
                             !failures.empty?
                           else
                             !failures.nil?
                           end
        complete = context[:render_status].to_s == 'complete' &&
          context[:font_inventory_status].to_s == 'complete' &&
          !failures_present
        unless complete
          raise RepresentationFidelity::ContractError,
                "#{source_id}: item vector page inventory is incomplete"
        end
        true
      end

      def self.verify_source_bbox!(item, media_box)
        base_x = media_box.is_a?(Array) ? media_box[0].to_f : 0.0
        base_y = media_box.is_a?(Array) ? media_box[1].to_f : 0.0
        return true if CairoGlyphSource.item_bbox_media_relative(
          item, base_x, base_y
        )
        raise RepresentationFidelity::ContractError,
              'item vector source bbox is unavailable'
      end

      def self.validate_entries!(source_id, entries)
        valid = !Array(entries).empty? && Array(entries).all? do |entry|
          !entry[:glyph_id].to_s.empty? &&
            entry[:placement_index].to_s =~ /\A\d+\z/ &&
            Array(entry[:loops]).any? do |loop_points|
              normalized_points(loop_points).length >= 2
            end
        end
        return true if valid
        raise RepresentationFidelity::ContractError,
              "#{source_id}: exact source outline inventory is malformed"
      end

      def self.create_owned_group!(entities, source_id, mode, layer, indices)
        unless entities.respond_to?(:add_group)
          raise RepresentationFidelity::ContractError,
                'parent entities cannot create an owned item vector group'
        end
        group = entities.add_group
        raise RepresentationFidelity::ContractError,
              'owned item vector group was not created' unless group
        group.name = "PDF #{mode == :glyphs ? 'Glyphs' : 'Geometry'} " \
          "#{source_id}" if group.respond_to?(:name=)
        group.layer = layer if layer && group.respond_to?(:layer=)
        assign_identity!(group, source_id, mode, nil, indices)
        group
      end

      def self.build_flat_geometry!(group, entries, source_id, layer)
        child = group.respond_to?(:entities) ? group.entities : nil
        raise RepresentationFidelity::ContractError,
              'owned Geometry group has no entities collection' unless child
        edges = []
        Array(entries).each do |entry|
          edges.concat(add_entry_edges!(child, entry, source_id, :geometry,
                                        layer))
        end
        raise RepresentationFidelity::ContractError,
              "#{source_id}: Geometry created no raw edges" if edges.empty?
        { :edge_count => edges.length, :glyph_group_count => 0 }
      end

      def self.build_glyph_groups!(group, entries, source_id, layer)
        child = group.respond_to?(:entities) ? group.entities : nil
        unless child && child.respond_to?(:add_group)
          raise RepresentationFidelity::ContractError,
                'owned Glyphs group cannot create physical glyph groups'
        end
        edge_count = 0
        glyph_count = 0
        Array(entries).each do |entry|
          glyph = child.add_group
          raise RepresentationFidelity::ContractError,
                'physical source glyph group was not created' unless glyph
          glyph.layer = layer if layer && glyph.respond_to?(:layer=)
          glyph.name = "Glyph #{entry[:glyph_id]} ##{entry[:placement_index]}" if
            glyph.respond_to?(:name=)
          assign_identity!(
            glyph, source_id, :glyphs, entry[:glyph_id],
            [entry[:placement_index]]
          )
          edges = add_entry_edges!(
            glyph.entities, entry, source_id, :glyphs, layer
          )
          raise RepresentationFidelity::ContractError,
                "#{source_id}: physical Glyph created no edges" if edges.empty?
          edge_count += edges.length
          glyph_count += 1
        end
        { :edge_count => edge_count, :glyph_group_count => glyph_count }
      end

      def self.add_entry_edges!(entities, entry, source_id, mode, layer)
        unless entities.respond_to?(:add_edges)
          raise RepresentationFidelity::ContractError,
                'item vector entities cannot create raw source edges'
        end
        created = []
        expected = 0
        Array(entry[:loops]).each do |loop_points|
          points = normalized_points(loop_points)
          next if points.length < 2
          expected += points.length - 1
          edges = Array(entities.add_edges(points))
          edges.each do |edge|
            edge.layer = layer if layer && edge.respond_to?(:layer=)
            assign_identity!(
              edge, source_id, mode, entry[:glyph_id],
              [entry[:placement_index]]
            )
          end
          created.concat(edges)
        end
        unless expected > 0 && created.length == expected
          raise RepresentationFidelity::ContractError,
                "#{source_id}: raw source edge count is incomplete " \
                "(expected #{expected}, created #{created.length})"
        end
        created
      end

      def self.normalized_points(values)
        points = []
        Array(values).each do |point|
          next unless point && point.respond_to?(:x) && point.respond_to?(:y)
          if points.empty? || points[-1].distance(point).to_f >
                              SIZE_TOLERANCE_INCHES
            points << point
          end
        end
        points
      rescue StandardError
        []
      end

      def self.assign_identity!(entity, source_id, mode, glyph_id, indices)
        return true unless entity.respond_to?(:set_attribute)
        dictionary = 'BC_PDF_Importer'
        entity.set_attribute(dictionary, 'source_span_id', source_id)
        entity.set_attribute(dictionary, 'source_kind', 'text_span')
        entity.set_attribute(dictionary, 'representation', mode.to_s)
        entity.set_attribute(
          dictionary, 'renderer',
          mode == :glyphs ? 'svg_item_glyph_group_renderer' :
            'svg_item_flat_geometry_renderer'
        )
        entity.set_attribute(dictionary, 'source_glyph_id', glyph_id.to_s) if
          glyph_id
        entity.set_attribute(
          dictionary, 'source_placement_indices',
          Array(indices).map { |index| index.to_i }.join(',')
        )
        true
      end

      def self.verify_structure!(group, mode, expected_glyphs, expected_edges,
                                 source_id)
        members = entity_members(group)
        raise RepresentationFidelity::ContractError,
              "#{source_id}: item vector group is empty" if members.empty?
        if mode == :geometry
          valid = members.length == expected_edges.to_i && members.all? do |entity|
            entity_type(entity) == 'Edge'
          end
          unless valid
            raise RepresentationFidelity::ContractError,
                  "#{source_id}: Geometry is not a flat raw-edge representation"
          end
        elsif mode == :glyphs
          valid = members.length == expected_glyphs.to_i && members.all? do |glyph|
            entity_type(glyph) == 'Group' &&
              !entity_members(glyph).empty? &&
              entity_members(glyph).all? do |entity|
                entity_type(entity) == 'Edge'
              end
          end
          unless valid
            raise RepresentationFidelity::ContractError,
                  "#{source_id}: Glyphs are not distinct physical glyph groups"
          end
        else
          raise RepresentationFidelity::ContractError,
                "#{source_id}: item vector mode is invalid"
        end
        true
      end

      def self.verify_bounds!(group, expected, source_id)
        unless expected.is_a?(Array) && expected.length >= 4
          raise RepresentationFidelity::ContractError,
                "#{source_id}: expected source outline extent is unavailable"
        end
        actual = bounds_hash(group)
        expected_width = expected[2].to_f - expected[0].to_f
        expected_height = expected[3].to_f - expected[1].to_f
        tolerance = [
          SIZE_TOLERANCE_INCHES,
          expected_width.abs * 1.0e-5,
          expected_height.abs * 1.0e-5
        ].max
        nonempty = expected_width.abs > SIZE_TOLERANCE_INCHES ||
          expected_height.abs > SIZE_TOLERANCE_INCHES
        accurate = (actual[:width] - expected_width.abs).abs <= tolerance &&
          (actual[:height] - expected_height.abs).abs <= tolerance &&
          (actual[:min_x] - expected[0].to_f).abs <= tolerance &&
          (actual[:min_y] - expected[1].to_f).abs <= tolerance &&
          (actual[:max_x] - expected[2].to_f).abs <= tolerance &&
          (actual[:max_y] - expected[3].to_f).abs <= tolerance &&
          actual[:min_z].abs <= tolerance && actual[:max_z].abs <= tolerance
        unless nonempty && accurate
          raise RepresentationFidelity::ContractError,
                "#{source_id}: item vector bounds do not match source outlines"
        end
        true
      end

      def self.bounds_hash(entity)
        box = entity.respond_to?(:bounds) ? entity.bounds : nil
        low = box && RepresentationFidelity.numeric_point(box.min)
        high = box && RepresentationFidelity.numeric_point(box.max)
        unless low && high
          raise RepresentationFidelity::ContractError,
                'item vector bounds are unavailable'
        end
        {
          :min_x => low[0], :min_y => low[1], :min_z => low[2],
          :max_x => high[0], :max_y => high[1], :max_z => high[2],
          :width => high[0] - low[0], :height => high[1] - low[1]
        }
      end

      def self.verify_visible_tree!(entity, source_id)
        unless entity_visible?(entity)
          raise RepresentationFidelity::ContractError,
                "#{source_id}: item vector artifact is hidden"
        end
        entity_members(entity).each do |child|
          verify_visible_tree!(child, source_id)
        end
        true
      end

      def self.entity_visible?(entity)
        return false if entity.respond_to?(:hidden?) && entity.hidden? == true
        return false if entity.respond_to?(:visible?) && entity.visible? == false
        layer = entity.respond_to?(:layer) ? entity.layer : nil
        if layer
          return false if layer.respond_to?(:visible?) && layer.visible? == false
          return false if layer.respond_to?(:visible) && layer.visible == false
        end
        true
      rescue StandardError
        false
      end

      def self.physical_entities(group, mode)
        if mode == :geometry
          entity_members(group)
        else
          glyphs = entity_members(group)
          glyphs + glyphs.inject([]) do |all, glyph|
            all + entity_members(glyph)
          end
        end
      end

      def self.entity_members(entity)
        collection = entity.respond_to?(:entities) ? entity.entities : nil
        return [] unless collection && collection.respond_to?(:to_a)
        Array(collection.to_a)
      rescue StandardError
        []
      end

      def self.entity_type(entity)
        return entity.typename.to_s if entity.respond_to?(:typename)
        entity.class.name.to_s.split('::').last
      rescue StandardError
        ''
      end

      def self.cleanup_created_since(entities, before)
        return nil unless entities && before
        current = RepresentationFidelity.snapshot(entities)
        owned = RepresentationFidelity.created_between(before, current)
        RepresentationFidelity.erase_owned!(entities, owned) unless owned.empty?
        nil
      rescue StandardError => cleanup_error
        cleanup_error
      end
    end
  end
end
