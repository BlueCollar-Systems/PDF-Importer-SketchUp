# bc_pdf_vector_importer/svg_item_representation_renderer.rb
# Item-scoped exact source Glyphs and flat Geometry representations.
#
# Every placement is delivered as its exact source outline EDGES plus filled
# FACES for the outer contours (counters such as O/A/B stay open), painted
# with the source ink through the same material path 3D Text uses. Edge-only
# delivery rendered every glyph hollow (white inside a 1 px outline) while the
# PDF shows filled glyphs -- a visible difference under the owner's ruling
# (visual oracle, sheet 1011, 2026-08-16). A contour the host cannot face is
# recorded in the item evidence and its edges are kept; it never raises.

require File.join(File.dirname(__FILE__), 'cairo_glyph_source')
require File.join(File.dirname(__FILE__), 'representation_fidelity')
require File.join(File.dirname(__FILE__), 'svg_3d_text_renderer')
require 'digest'

module BlueCollarSystems
  module PDFVectorImporter
    module SvgItemRepresentationRenderer
      SIZE_TOLERANCE_INCHES = 0.001
      COLLINEAR_DISTANCE_TOLERANCE_INCHES = 1.0e-9
      SUPPORTED_MODES = [:glyphs, :geometry].freeze
      PEER_OWNER_GRID_SIZE_PT = 32.0
      PEER_OWNER_MAX_CELLS_PER_BOX = 4096

      def self.render_svg(entities, svg, media_box, item, requested_mode,
                          opts = {})
        mode = RepresentationFidelity.normalize_mode(requested_mode)
        unless SUPPORTED_MODES.include?(mode)
          raise RepresentationFidelity::ContractError,
                'item vector renderer supports only Glyphs or Geometry'
        end
        source_id = RepresentationFidelity.source_span_id(item)
        verify_source_context!(source_id, opts[:source_context])
        base_x = media_box.is_a?(Array) ? media_box[0].to_f : 0.0
        base_y = media_box.is_a?(Array) ? media_box[1].to_f : 0.0
        unless CairoGlyphSource.item_bbox_media_relative(item, base_x, base_y)
          return impossible_result(
            source_id, item, mode, [], {}, opts[:source_context], {},
            :source_item_bbox_unavailable
          )
        end

        group = nil
        emit_progress_callback(
          opts[:progress_callback], 'svg_item_snapshot_started',
          "source_id=#{source_id}; mode=#{mode}"
        )
        before = RepresentationFidelity.snapshot(entities)
        emit_progress_callback(
          opts[:progress_callback], 'svg_item_snapshot_completed',
          "source_id=#{source_id}; mode=#{mode}"
        )
        placed = if opts.key?(:precomputed_placed) &&
                    opts[:precomputed_placed].is_a?(Array)
                   opts[:precomputed_placed]
                 else
                   CairoGlyphSource.model_space_loops(svg, media_box, opts)
                 end
        pens = if opts.key?(:precomputed_pens) &&
                  opts[:precomputed_pens].is_a?(Array)
                 opts[:precomputed_pens]
               else
                 Array(placed).map do |entry|
                   CairoGlyphSource.placement_pen_record(entry)
                 end
               end
        match = if opts[:precomputed_match].is_a?(Hash)
                  opts[:precomputed_match]
                else
                  CairoGlyphSource.match_spans(pens, [item], media_box)
                 end
        emit_progress_callback(
          opts[:progress_callback], 'svg_item_selection_started',
          "source_id=#{source_id}; mode=#{mode}"
        )
        selection = select_item_placements(
          source_id, mode, match, pens, media_box, opts[:peer_items],
          opts[:precomputed_peer_boxes], opts[:precomputed_peer_owners]
        )
        indices = selection[:indices]
        emit_progress_callback(
          opts[:progress_callback], 'svg_item_selection_join_started',
          "source_id=#{source_id}; placements=#{Array(indices).length}; mode=#{mode}"
        )
        index_lookup = {}
        Array(indices).each { |index| index_lookup[index.to_i] = true }
        entries = Array(placed).select do |entry|
          index_lookup[entry[:placement_index].to_i] == true
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
        emit_progress_callback(
          opts[:progress_callback], 'svg_item_validation_started',
          "source_id=#{source_id}; placements=#{entries.length}; mode=#{mode}"
        )
        validate_entries!(source_id, entries)
        emit_progress_callback(
          opts[:progress_callback], 'svg_item_selection_completed',
          "source_id=#{source_id}; placements=#{entries.length}; mode=#{mode}"
        )

        group = create_owned_group!(entities, source_id, mode, opts[:layer],
                                    indices)
        emit_progress_callback(
          opts[:progress_callback], 'svg_item_build_started',
          "source_id=#{source_id}; placements=#{entries.length}; mode=#{mode}"
        )
        build = mode == :glyphs ?
          build_glyph_groups!(
            group, entries, source_id, opts[:layer],
            opts[:model], opts[:glyph_component_cache],
            opts[:progress_callback]
          ) :
          build_flat_geometry!(group, entries, source_id, opts[:layer])
        apply_item_ink!(group, entries, build)
        emit_progress_callback(
          opts[:progress_callback], 'svg_item_build_completed',
          "source_id=#{source_id}; edges=#{build[:edge_count]}; " \
            "faces=#{build[:face_count]}; ink_applied=#{build[:ink_applied]}; " \
            "mode=#{mode}"
        )
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
        emit_progress_callback(
          opts[:progress_callback], 'svg_item_bounds_verified',
          "source_id=#{source_id}; mode=#{mode}"
        )
        verify_structure!(group, mode, entries.length, build[:edge_count],
                          source_id)
        emit_progress_callback(
          opts[:progress_callback], 'svg_item_structure_verified',
          "source_id=#{source_id}; mode=#{mode}"
        )
        verify_visible_tree!(group, source_id)
        physical = physical_entities(group, mode)
        physical_ids = RepresentationFidelity.stable_ids(physical)
        if physical_ids.empty?
          raise RepresentationFidelity::ContractError,
                "#{source_id}: item vector representation has no physical entities"
        end
        emit_progress_callback(
          opts[:progress_callback], 'svg_item_physical_verified',
          "source_id=#{source_id}; physical=#{physical_ids.length}; mode=#{mode}"
        )

        {
          :ok => true,
          :renderer => if mode == :glyphs
                         build[:glyph_component_instances].to_i > 0 ?
                           :svg_item_glyph_components :
                           :svg_item_glyph_groups
                       else
                         :svg_item_flat_geometry
                       end,
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
          :face_count => build[:face_count].to_i,
          :hole_count => build[:hole_count].to_i,
          :face_fill_failures => Array(build[:face_fill_failures]),
          :ink_applied => build[:ink_applied] == true,
          :source_ink_rgb => build[:source_ink_rgb],
          :source_ink_material_name => build[:source_ink_material_name],
          :glyph_group_count => build[:glyph_group_count],
          :glyph_component_definition_builds =>
            build[:glyph_component_definition_builds].to_i,
          :glyph_component_cache_hits =>
            build[:glyph_component_cache_hits].to_i,
          :glyph_component_instances =>
            build[:glyph_component_instances].to_i,
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
        cleanup_error = cleanup_claimed_group(entities, before, group)
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
        renderer = if result[:mode] == :glyphs
                     result[:renderer].to_s == 'svg_item_glyph_components' ?
                       'svg_item_glyph_component_renderer' :
                       'svg_item_glyph_group_renderer'
                   else
                     'svg_item_flat_geometry_renderer'
                   end
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
                                 source_context, selection = {},
                                 reason = nil)
        binding = RepresentationFidelity.proof_binding(source_id)
        to_mode = mode == :glyphs ? :geometry : :raster
        renderer = mode == :glyphs ? 'svg_item_glyph_component_renderer' :
          'svg_item_flat_geometry_renderer'
        contract = mode == :glyphs ?
          'one independently selectable owned physical glyph per exact source placement' :
          'one owned flat raw-edge set for the exact source item'
        if reason.nil?
          reason = Array(placed).empty? ? :source_vector_geometry_absent :
            :source_item_identity_unavailable
        end
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
            :source_renderer => (source_context || {})[:renderer].to_s,
            :source_placement_count => Array(placed).length,
            :matched_item_placement_count => 0,
            :bbox_geometry_candidate_count =>
              Array(selection && selection[:candidate_indices]).length,
            :peer_ambiguous_placement_indices =>
              Array(selection && selection[:ambiguous_indices]),
            :glyph_coverage_failures =>
              Array(match && match[:coverage_failures]),
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
      # the source bbox belongs unambiguously to this item. Peer overlap
      # rejects the entire candidate set instead of duplicating another text
      # artifact or silently omitting part of the source span.
      def self.build_placement_peer_owners(pens, peer_boxes)
        grid_size = PEER_OWNER_GRID_SIZE_PT
        grid = {}
        broad_boxes = []

        Array(peer_boxes).each do |peer_id, raw_box|
          box = Array(raw_box)
          next unless box.length >= 4
          x0, x1 = [box[0].to_f, box[2].to_f].minmax
          y0, y1 = [box[1].to_f, box[3].to_f].minmax
          normalized = [x0, y0, x1, y1]
          min_cell_x = (x0 / grid_size).floor
          max_cell_x = (x1 / grid_size).floor
          min_cell_y = (y0 / grid_size).floor
          max_cell_y = (y1 / grid_size).floor
          cell_count = (max_cell_x - min_cell_x + 1) *
                       (max_cell_y - min_cell_y + 1)
          record = [peer_id.to_s, normalized]
          if cell_count > PEER_OWNER_MAX_CELLS_PER_BOX
            broad_boxes << record
            next
          end
          (min_cell_x..max_cell_x).each do |cell_x|
            (min_cell_y..max_cell_y).each do |cell_y|
              key = [cell_x, cell_y]
              grid[key] ||= []
              grid[key] << record
            end
          end
        end

        owners_by_placement = {}
        Array(pens).each do |pen|
          x = pen[:x].to_f
          y = pen[:y].to_f
          key = [(x / grid_size).floor, (y / grid_size).floor]
          owners = Array(grid[key]) + broad_boxes
          matching = owners.inject([]) do |values, record|
            peer_id, box = record
            if x >= box[0] && x <= box[2] && y >= box[1] && y <= box[3]
              values << peer_id unless values.include?(peer_id)
            end
            values
          end
          next if matching.empty?
          placement_index = pen[:placement_index].to_i
          existing = Array(owners_by_placement[placement_index])
          owners_by_placement[placement_index] = (existing + matching).uniq.sort
        end
        owners_by_placement
      end

      def self.select_item_placements(source_id, mode, match, pens, media_box,
                                      peer_items,
                                      precomputed_peer_boxes = nil,
                                      precomputed_peer_owners = nil)
        exact = Array(match[:placement_matches]).select do |record|
          record[:source_span_id].to_s == source_id
        end.map { |record| record[:placement_index].to_i }.uniq.sort
        unless exact.empty?
          # Page-wide match_spans already assigns each pen to at most one
          # source span. Packed extractor bboxes still overlap, so a later
          # "pen sits in a peer bbox" check false-proved whole spans
          # impossible and dumped them to item Raster. Trust the unique
          # assignment; isolated per-item matches keep the peer-bbox gate.
          if uniquely_assigned_page_match?(match)
            return {
              :indices => exact,
              :candidate_indices => exact,
              :ambiguous_indices => [],
              :strategy => :exact_glyph_ownership
            }
          end
          ambiguous = ambiguous_peer_placements(
            exact, pens, media_box, source_id, peer_items,
            precomputed_peer_boxes, precomputed_peer_owners
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
          candidates, pens, media_box, source_id, peer_items,
          precomputed_peer_boxes, precomputed_peer_owners
        )
        {
          :indices => ambiguous.empty? ? candidates : [],
          :candidate_indices => candidates,
          :ambiguous_indices => ambiguous,
          :strategy => :bbox_raw_outline_set
        }
      end

      def self.uniquely_assigned_page_match?(match)
        return false unless match.is_a?(Hash)
        owners = {}
        Array(match[:placement_matches]).each do |record|
          next unless record.is_a?(Hash)
          source_span_id = record[:source_span_id].to_s
          next if source_span_id.empty?
          placement_index = record[:placement_index].to_i
          previous = owners[placement_index]
          return false if previous && previous != source_span_id
          owners[placement_index] = source_span_id
        end
        source_ids = {}
        owners.each_value { |source_span_id| source_ids[source_span_id] = true }
        !owners.empty? && source_ids.length > 1
      end

      def self.ambiguous_peer_placements(candidate_indices, pens, media_box,
                                         source_id, peer_items,
                                         precomputed_peer_boxes = nil,
                                         precomputed_peer_owners = nil)
        candidates = Array(candidate_indices)
        return [] if candidates.empty?
        if precomputed_peer_owners.is_a?(Hash)
          return candidates.select do |index|
            owners = precomputed_peer_owners[index.to_i] ||
              precomputed_peer_owners[index.to_s]
            Array(owners).any? do |peer_id|
              peer_id.to_s != source_id.to_s
            end
          end.map { |index| index.to_i }.uniq.sort
        end
        peer_boxes = if precomputed_peer_boxes.is_a?(Hash)
                       precomputed_peer_boxes.reject do |peer_id, _box|
                         peer_id.to_s == source_id.to_s
                       end.values
                     elsif precomputed_peer_boxes.is_a?(Array)
                       Array(precomputed_peer_boxes)
                     else
                       base_x = media_box.is_a?(Array) ? media_box[0].to_f : 0.0
                       base_y = media_box.is_a?(Array) ? media_box[1].to_f : 0.0
                       tolerance = if CairoGlyphSource.const_defined?(
                         :SPAN_MATCH_TOLERANCE_PT
                       )
                                     CairoGlyphSource::SPAN_MATCH_TOLERANCE_PT.to_f
                                   else
                                     2.0
                                   end
                       Array(peer_items).map do |peer|
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
                     end
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
        fill = new_fill_summary
        Array(entries).each do |entry|
          edges.concat(add_entry_edges!(child, entry, source_id, :geometry,
                                        layer))
          faces = add_entry_faces!(child, entry, source_id, :geometry, layer)
          merge_fill_summary!(fill, faces)
          fill[:paint_targets] << [entry, faces[:faces]]
        end
        raise RepresentationFidelity::ContractError,
              "#{source_id}: Geometry created no raw edges" if edges.empty?
        # The host may split or merge edges while it builds the glyph faces
        # (add_face on the outer loop, counters erased), so the structural
        # contract must be checked against the edges that actually exist in
        # the owned group after the build -- not the count returned by
        # add_edges before any face existed. (In-host 3.7.141 regression:
        # every Geometry import raised "not a flat raw-edge representation".)
        built_edges = entity_members(group).select do |entity|
          entity_type(entity) == 'Edge'
        end
        edge_count = built_edges.empty? ? edges.length : built_edges.length
        { :edge_count => edge_count, :glyph_group_count => 0 }.merge(fill)
      end

      def self.build_glyph_groups!(group, entries, source_id, layer,
                                   model = nil, component_cache = nil,
                                   progress_callback = nil)
        child = group.respond_to?(:entities) ? group.entities : nil
        unless child && child.respond_to?(:add_group)
          raise RepresentationFidelity::ContractError,
                'owned Glyphs group cannot create physical glyph groups'
        end
        if component_cache_available?(child, model, component_cache)
          return build_glyph_components!(
            child, entries, source_id, layer, model, component_cache,
            progress_callback
          )
        end

        edge_count = 0
        glyph_count = 0
        fill = new_fill_summary
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
          faces = add_entry_faces!(
            glyph.entities, entry, source_id, :glyphs, layer
          )
          merge_fill_summary!(fill, faces)
          fill[:paint_targets] << [entry, [glyph]]
          edge_count += edges.length
          glyph_count += 1
        end
        {
          :edge_count => edge_count,
          :glyph_group_count => glyph_count,
          :glyph_component_definition_builds => 0,
          :glyph_component_cache_hits => 0,
          :glyph_component_instances => 0
        }.merge(fill)
      end

      def self.component_cache_available?(entities, model, component_cache)
        component_cache.is_a?(Hash) &&
          model && model.respond_to?(:definitions) &&
          model.definitions.respond_to?(:add) &&
          entities.respond_to?(:add_instance) &&
          defined?(Geom::Transformation)
      rescue StandardError
        false
      end

      def self.build_glyph_components!(entities, entries, source_id, layer,
                                       model, component_cache,
                                       progress_callback = nil)
        edge_count = 0
        instance_count = 0
        definition_builds = 0
        cache_hits = 0
        fill = new_fill_summary
        Array(entries).each_with_index do |entry, entry_index|
          key = glyph_definition_cache_key(entry)
          cached = component_cache[key]
          definition = cached.is_a?(Hash) ? cached[:definition] : nil
          definition_edge_count = cached.is_a?(Hash) ?
            cached[:edge_count].to_i : 0
          definition_fill = cached.is_a?(Hash) ? cached[:fill] : nil
          emit_progress_callback(
            progress_callback, 'svg_item_component_started',
            "source_id=#{source_id}; placement=#{entry_index + 1}/" \
              "#{Array(entries).length}; glyph=#{entry[:glyph_id]}; " \
              "cache_hit=#{!definition.nil?}"
          )
          if definition
            cache_hits += 1
          else
            definition = model.definitions.add(
              "BC PDF Glyph #{entry[:glyph_id]} #{key[0, 12]}"
            )
            unless definition && definition.respond_to?(:entities)
              raise RepresentationFidelity::ContractError,
                    'Glyphs component definition was not created'
            end
            definition_edges = add_definition_edges!(
              definition.entities, entry, layer
            )
            definition_edge_count = definition_edges.length
            definition_fill = add_definition_faces!(
              definition.entities, entry, layer
            )
            component_cache[key] = {
              :definition => definition,
              :edge_count => definition_edge_count,
              :fill => definition_fill
            }
            definition_builds += 1
          end
          edge_count += definition_edge_count
          merge_fill_summary!(fill, definition_fill)

          matrix = Array(entry[:cache_instance_transformation])
          unless matrix.length == 16
            raise RepresentationFidelity::ContractError,
                  "#{source_id}: Glyphs component transform is unavailable"
          end
          instance = entities.add_instance(
            definition, Geom::Transformation.new(matrix)
          )
          unless instance
            raise RepresentationFidelity::ContractError,
                  "#{source_id}: Glyphs component instance was not created"
          end
          instance.layer = layer if layer && instance.respond_to?(:layer=)
          assign_identity!(
            instance, source_id, :glyphs, entry[:glyph_id],
            [entry[:placement_index]]
          )
          fill[:paint_targets] << [entry, [instance]]
          instance_count += 1
          emit_progress_callback(
            progress_callback, 'svg_item_component_completed',
            "source_id=#{source_id}; placement=#{entry_index + 1}/" \
              "#{Array(entries).length}; glyph=#{entry[:glyph_id]}"
          )
        end
        {
          :edge_count => edge_count,
          :glyph_group_count => instance_count,
          :glyph_component_definition_builds => definition_builds,
          :glyph_component_cache_hits => cache_hits,
          :glyph_component_instances => instance_count
        }.merge(fill)
      end

      def self.glyph_definition_cache_key(entry)
        loops = Array(entry[:cache_definition_loops])
        serialized = loops.map do |loop_points|
          normalized_points(loop_points).map do |point|
            format('%.9f,%.9f,%.9f',
                   point.x.to_f, point.y.to_f, point.z.to_f)
          end.join(';')
        end.join('|')
        unless !entry[:glyph_id].to_s.empty? && !serialized.empty?
          raise RepresentationFidelity::ContractError,
                'Glyphs canonical component geometry is unavailable'
        end
        Digest::SHA256.hexdigest(
          "#{entry[:glyph_id]}\0#{serialized}"
        )
      end

      def self.add_definition_edges!(entities, entry, layer)
        unless entities && entities.respond_to?(:add_edges)
          raise RepresentationFidelity::ContractError,
                'Glyphs component definition cannot create source edges'
        end
        created = []
        expected = 0
        Array(entry[:cache_definition_loops]).each do |loop_points|
          points = normalized_points(loop_points)
          next if points.length < 2
          expected += points.length - 1
          edges = Array(entities.add_edges(points))
          edges.each do |edge|
            edge.layer = layer if layer && edge.respond_to?(:layer=)
            assign_shared_glyph_identity!(edge, entry[:glyph_id])
          end
          created.concat(edges)
        end
        unless expected > 0 && created.length == expected
          raise RepresentationFidelity::ContractError,
                'Glyphs component definition edge count is incomplete'
        end
        created
      end

      def self.assign_shared_glyph_identity!(entity, glyph_id)
        return true unless entity.respond_to?(:set_attribute)
        dictionary = 'BC_PDF_Importer'
        entity.set_attribute(dictionary, 'source_kind', 'shared_glyph_outline')
        entity.set_attribute(dictionary, 'representation', 'glyphs')
        entity.set_attribute(
          dictionary, 'renderer', 'svg_item_glyph_component_renderer'
        )
        entity.set_attribute(dictionary, 'source_glyph_id', glyph_id.to_s)
        true
      end

      def self.emit_progress_callback(callback, phase, detail = nil)
        return false unless callback.respond_to?(:call)
        callback.call(phase.to_s, detail)
        true
      rescue StandardError
        false
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

      # ---- Filled glyph faces -------------------------------------------

      def self.new_fill_summary
        {
          :face_count => 0,
          :hole_count => 0,
          :face_fill_failures => [],
          :paint_targets => []
        }
      end

      def self.merge_fill_summary!(summary, outcome)
        return summary unless outcome.is_a?(Hash)
        summary[:face_count] += Array(outcome[:faces]).length
        summary[:hole_count] += outcome[:hole_count].to_i
        summary[:face_fill_failures].concat(Array(outcome[:failures]))
        summary
      end

      def self.add_entry_faces!(entities, entry, source_id, mode, layer)
        add_loop_faces!(entities, entry[:loops], layer) do |face|
          assign_identity!(
            face, source_id, mode, entry[:glyph_id], [entry[:placement_index]]
          )
        end
      end

      def self.add_definition_faces!(entities, entry, layer)
        add_loop_faces!(entities, entry[:cache_definition_loops], layer) do |face|
          assign_shared_glyph_identity!(face, entry[:glyph_id])
        end
      end

      # Fill one placement's outline loops with host faces after its edges
      # exist. Contours follow the SVG non-zero rule the 3D Text renderer uses
      # (Svg3DTextRenderer.build_filled_glyph): a contour is a boundary only
      # when crossing it toggles the cumulative winding between zero and
      # nonzero. Boundaries whose inside winding is nonzero become filled
      # faces; boundaries whose inside winding is zero (counters) are faced
      # then erased so the enclosing face keeps a hole -- SketchUp reuses the
      # existing counter edges either way. Any contour the host cannot face is
      # recorded and skipped; the edges are already there and never removed.
      # Returns { :faces, :hole_count, :failures } and never raises.
      def self.add_loop_faces!(entities, loops, layer)
        outcome = { :faces => [], :hole_count => 0, :failures => [] }
        unless entities && entities.respond_to?(:add_face)
          outcome[:failures] << 'host entities cannot create glyph faces'
          return outcome
        end
        contours = []
        Array(loops).each_with_index do |loop_points, loop_index|
          points = face_contour_points(loop_points)
          next unless points
          area = Svg3DTextRenderer.signed_area(points)
          next unless area.finite? && area != 0.0
          contours << {
            :points => points,
            :area => area.abs,
            :winding => area > 0.0 ? 1 : -1,
            :index => loop_index
          }
        end
        contours.sort_by! { |contour| -contour[:area] }
        contours.each_with_index do |contour, index|
          probe = contour[:points][0]
          containing = contours[0...index].select do |outer|
            Svg3DTextRenderer.point_in_polygon?(probe, outer[:points])
          end
          outside_winding = containing.inject(0) do |total, outer|
            total + outer[:winding]
          end
          inside_winding = outside_winding + contour[:winding]
          next if outside_winding.zero? == inside_winding.zero?
          face = nil
          failure = nil
          begin
            face = entities.add_face(contour[:points])
          rescue StandardError => e
            failure = "loop #{contour[:index]}: add_face failed: #{e.message}"
          end
          if face.nil? && inside_winding.zero?
            # The host may already have split the enclosing face along these
            # counter edges and decline to "add" the face again; the counter
            # face then already exists and must still be erased for the hole.
            face = find_face_bounded_by(entities, contour[:points])
          end
          unless face
            outcome[:failures] << (
              failure || "loop #{contour[:index]}: host returned no face"
            )
            next
          end
          if inside_winding.zero?
            begin
              Svg3DTextRenderer.erase_face!(entities, face)
              outcome[:hole_count] += 1
            rescue StandardError => e
              outcome[:failures] <<
                "loop #{contour[:index]}: hole face erase failed: #{e.message}"
            end
          else
            orient_face_up!(face)
            face.layer = layer if layer && face.respond_to?(:layer=)
            yield face if block_given?
            outcome[:faces] << face
          end
        end
        outcome
      rescue StandardError => e
        outcome[:failures] << "glyph face fill failed: #{e.message}"
        outcome
      end

      # The existing host face whose vertex set equals +points+ (within the
      # host merge tolerance), or nil.
      def self.find_face_bounded_by(entities, points)
        return nil unless entities.respond_to?(:to_a)
        wanted = Array(points)
        entities.to_a.each do |entity|
          next unless entity_type(entity) == 'Face'
          vertices = if entity.respond_to?(:vertices)
                       Array(entity.vertices).map do |vertex|
                         vertex.respond_to?(:position) ? vertex.position : vertex
                       end
                     elsif entity.respond_to?(:points)
                       Array(entity.points)
                     else
                       []
                     end
          next unless vertices.length == wanted.length
          matched = wanted.all? do |point|
            vertices.any? do |vertex|
              vertex.respond_to?(:distance) &&
                vertex.distance(point).to_f <= SIZE_TOLERANCE_INCHES
            end
          end
          return entity if matched
        end
        nil
      rescue StandardError
        nil
      end

      # Distinct contour vertices without the closing point, or nil when the
      # loop is degenerate (fewer than three distinct points / zero area).
      def self.face_contour_points(loop_points)
        Svg3DTextRenderer.normalized_contour(normalized_points(loop_points))
      rescue StandardError
        nil
      end

      # SketchUp creates every face on the ground plane facing down regardless
      # of vertex order; flip it so the painted front faces the page viewer.
      def self.orient_face_up!(face)
        return false unless face.respond_to?(:normal) &&
                            face.respond_to?(:reverse!)
        normal = face.normal
        return false unless normal.respond_to?(:z) && normal.z.to_f < 0.0
        face.reverse!
        true
      rescue StandardError
        false
      end

      # Paint the delivered faces with the source ink through the 3D Text
      # material path (Svg3DTextRenderer.apply_source_text_ink!). A span with
      # one fill style paints the owned group once (nil-material faces, glyph
      # groups, component instances and shared definitions all inherit it); a
      # span mixing fill styles paints each physical unit with its own entry
      # style. The outcome is recorded on the build summary -- a headless host
      # without materials reports ink_applied false, never a silent claim.
      def self.apply_item_ink!(group, entries, build)
        build[:ink_applied] = false
        build[:source_ink_rgb] = nil
        build[:source_ink_material_name] = nil
        style = homogeneous_ink_style(entries)
        if style
          build[:source_ink_rgb] = style[:rgb]
          build[:source_ink_material_name] =
            Svg3DTextRenderer.material_name_for_rgb(style[:rgb], style[:opacity])
          build[:ink_applied] = Svg3DTextRenderer.apply_source_text_ink!(
            group, style[:rgb], style[:opacity]
          ) == true
          return build
        end
        targets = Array(build[:paint_targets])
        return build if targets.empty?
        applied = targets.all? do |entry, units|
          unit_style = homogeneous_ink_style([entry])
          next false unless unit_style
          Array(units).all? do |unit|
            painted = Svg3DTextRenderer.apply_source_text_ink!(
              unit, unit_style[:rgb], unit_style[:opacity]
            ) == true
            if painted && unit.respond_to?(:back_material=) &&
               unit.respond_to?(:material)
              unit.back_material = unit.material
            end
            painted
          end
        end
        build[:ink_applied] = applied == true
        build
      rescue StandardError => e
        Logger.warn(
          'SvgItemRepresentationRenderer',
          "item vector ink paint failed: #{e.message}"
        ) if defined?(Logger) && Logger.respond_to?(:warn)
        build[:ink_applied] = false
        build
      end

      def self.homogeneous_ink_style(entries)
        Svg3DTextRenderer.homogeneous_source_ink_style(entries)
      rescue StandardError
        nil
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
        simplify_collinear_points(points)
      rescue StandardError
        []
      end

      # SketchUp 2017 merges exact collinear edge pairs during its first save.
      # Remove only mathematically redundant intermediate vertices up front so
      # source evidence describes the same visually exact geometry that persists
      # after save/reopen. Near-collinear curve samples remain untouched.
      def self.simplify_collinear_points(points)
        values = Array(points).dup
        return values if values.length < 3
        closed = values.length > 3 &&
          values[0].distance(values[-1]).to_f <= SIZE_TOLERANCE_INCHES
        values = values[0...-1] if closed
        minimum = closed ? 3 : 2
        loop do
          break if values.length <= minimum
          removable = nil
          candidates = closed ? (0...values.length) : (1...(values.length - 1))
          candidates.each do |index|
            previous = values[(index - 1) % values.length]
            current = values[index]
            following = values[(index + 1) % values.length]
            if collinear_intermediate_point?(previous, current, following)
              removable = index
              break
            end
          end
          break unless removable
          values.delete_at(removable)
        end
        values << values[0] if closed && !values.empty?
        values
      end

      def self.collinear_intermediate_point?(first, middle, last)
        ac = [
          last.x.to_f - first.x.to_f,
          last.y.to_f - first.y.to_f,
          last.respond_to?(:z) ? last.z.to_f - first.z.to_f : 0.0
        ]
        ab = [
          middle.x.to_f - first.x.to_f,
          middle.y.to_f - first.y.to_f,
          middle.respond_to?(:z) ? middle.z.to_f - first.z.to_f : 0.0
        ]
        ac_squared = ac.inject(0.0) { |sum, value| sum + (value * value) }
        return false unless ac_squared > 0.0
        cross = [
          (ab[1] * ac[2]) - (ab[2] * ac[1]),
          (ab[2] * ac[0]) - (ab[0] * ac[2]),
          (ab[0] * ac[1]) - (ab[1] * ac[0])
        ]
        cross_squared = cross.inject(0.0) do |sum, value|
          sum + (value * value)
        end
        distance = Math.sqrt(cross_squared / ac_squared)
        return false if distance > COLLINEAR_DISTANCE_TOLERANCE_INCHES
        projection = ab.each_with_index.inject(0.0) do |sum, (value, index)|
          sum + (value * ac[index])
        end
        projection > 0.0 && projection < ac_squared
      rescue StandardError
        false
      end

      def self.assign_identity!(entity, source_id, mode, glyph_id, indices)
        return true unless entity.respond_to?(:set_attribute)
        dictionary = 'BC_PDF_Importer'
        entity.set_attribute(dictionary, 'source_span_id', source_id)
        entity.set_attribute(dictionary, 'source_kind', 'text_span')
        entity.set_attribute(dictionary, 'representation', mode.to_s)
        entity.set_attribute(
          dictionary, 'renderer',
          if mode == :glyphs
            entity_type(entity) == 'ComponentInstance' ?
              'svg_item_glyph_component_renderer' :
              'svg_item_glyph_group_renderer'
          else
            'svg_item_flat_geometry_renderer'
          end
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
        # Flat representations are the exact source outline EDGES (counted
        # against the build) plus the filled glyph FACES they bound; nothing
        # else may live inside an owned item group.
        if mode == :geometry
          edges = members.select { |entity| entity_type(entity) == 'Edge' }
          valid = edges.length == expected_edges.to_i && members.all? do |entity|
            flat_representation_member?(entity)
          end
          unless valid
            raise RepresentationFidelity::ContractError,
                  "#{source_id}: Geometry is not a flat raw-edge representation"
          end
        elsif mode == :glyphs
          valid = members.length == expected_glyphs.to_i && members.all? do |glyph|
            ['Group', 'ComponentInstance'].include?(entity_type(glyph)) &&
              !entity_members(glyph).empty? &&
              entity_members(glyph).any? do |entity|
                entity_type(entity) == 'Edge'
              end &&
              entity_members(glyph).all? do |entity|
                flat_representation_member?(entity)
              end
          end
          unless valid
            raise RepresentationFidelity::ContractError,
                  "#{source_id}: Glyphs are not distinct physical glyph units"
          end
        else
          raise RepresentationFidelity::ContractError,
                "#{source_id}: item vector mode is invalid"
        end
        true
      end

      def self.flat_representation_member?(entity)
        ['Edge', 'Face'].include?(entity_type(entity))
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
          glyphs.inject([]) do |all, glyph|
            if entity_type(glyph) == 'ComponentInstance'
              all + [glyph]
            else
              all + [glyph] + entity_members(glyph)
            end
          end
        end
      end

      def self.entity_members(entity)
        collection = entity.respond_to?(:entities) ? entity.entities : nil
        if !collection && entity.respond_to?(:definition)
          definition = entity.definition
          collection = definition.entities if
            definition && definition.respond_to?(:entities)
        end
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

      def self.cleanup_claimed_group(entities, before, group)
        return nil unless entities && before && group
        current = RepresentationFidelity.snapshot(entities)
        owned = RepresentationFidelity.claimed_created_entities!(
          before, current, [group]
        )
        RepresentationFidelity.erase_owned!(entities, owned) unless owned.empty?
        nil
      rescue StandardError => cleanup_error
        cleanup_error
      end
    end
  end
end
