# bc_pdf_vector_importer/svg_3d_text_renderer.rb
# Exact 3D text from the PDF renderer's own SVG glyph outlines.

require File.join(File.dirname(__FILE__), 'cairo_glyph_source')
require File.join(File.dirname(__FILE__), 'representation_fidelity')
require File.join(File.dirname(__FILE__), 'logger')
require File.join(File.dirname(__FILE__), 'svg_3d_text_solid_cache')
require File.join(File.dirname(__FILE__), 'import_run_control')

module BlueCollarSystems
  module PDFVectorImporter
    module Svg3DTextRenderer
      DEFAULT_DEPTH_INCHES = 1.0 / 64.0
      SIZE_TOLERANCE_INCHES = 1.0e-6
      HOST_POINT_TOLERANCE_INCHES = 0.001
      MAX_CONSTRUCTION_SCALE = 1_000_000.0
      # Default SVG fill is black. Source SVG colors replace this fallback when
      # pdftocairo/mutool supplies inherited or per-use fill evidence.
      TEXT_INK_MATERIAL_NAME = 'PDF_0_0_0'.freeze
      TEXT_INK_RGB = [0, 0, 0].freeze

      def self.render_svg(entities, svg, media_box, text_items, opts = {})
        render_started = monotonic_ms
        result = base_result
        solid_cache = nil
        owned_groups = []
        render_items = Array(text_items)
        match_items = if opts.key?(:match_text_items)
                        Array(opts[:match_text_items])
                      else
                        render_items
                      end
        result[:authoritative_match_span_count] = match_items.length
        result[:render_target_span_count] = render_items.length
        depth = opts.key?(:depth) ? opts[:depth].to_f : DEFAULT_DEPTH_INCHES
        result[:requested_depth] = depth
        if !depth.finite? || depth <= 0.0
          result[:failures] << hard_failure(
            nil, :nonpositive_extrusion_depth,
            '3D text requires a finite positive extrusion depth'
          )
          return result
        end
        run_checkpoint!(opts, :renderer_stage, 0, 5)
        model = opts[:model] || model_for_entities(entities)
        candidate_cache = Svg3DTextSolidCache.new(
          model, depth,
          :run_controller => opts[:run_controller],
          :page_number => opts[:page_number]
        )
        if candidate_cache.supported_for?(entities)
          solid_cache = candidate_cache
          result[:solid_cache] = solid_cache.metrics.merge(:enabled => true)
        end

        parse_started = monotonic_ms
        loop_opts = opts.merge(:cache_model_space_loops => false)
        placed = CairoGlyphSource.model_space_loops(svg, media_box, loop_opts)
        solid_cache.configure_progress!(placed.length) if solid_cache
        run_checkpoint!(opts, :renderer_stage, 1, 5)
        record_phase_ms!(result, :parse_ms, parse_started)
        result[:source_placements] = placed.length
        verification_started = monotonic_ms
        loop_binding = CairoGlyphSource.verify_model_loop_bindings(
          svg, media_box, placed, opts
        )
        record_phase_ms!(result, :verification_ms, verification_started)
        result[:source_loop_binding] = loop_binding
        run_checkpoint!(opts, :renderer_stage, 2, 5)
        unless loop_binding[:ok] == true
          detail = Array(loop_binding[:failures]).first
          detail = detail ? detail.inspect : 'independent SVG loop binding failed'
          result[:failures] << hard_failure(
            nil, :source_loop_binding_mismatch, detail
          )
          publish_performance!(result, solid_cache, render_started)
          return result
        end
        inventory_started = monotonic_ms
        pens = placed.map do |entry|
          {
            :x => entry[:pen_pdf][0],
            :y => entry[:pen_pdf][1],
            :placement_index => entry[:placement_index],
            :glyph_id => entry[:glyph_id],
            :ink_bbox_pdf => entry[:ink_bbox_pdf],
            :ink_points_pdf => entry[:ink_points_pdf],
            :source_primary_axis => entry[:source_primary_axis]
          }
        end
        render_ids = render_items.map do |item|
          RepresentationFidelity.source_span_id(item)
        end
        match_ids = match_items.map do |item|
          RepresentationFidelity.source_span_id(item)
        end
        if render_ids.uniq.length != render_ids.length ||
           match_ids.uniq.length != match_ids.length
          result[:failures] << hard_failure(
            nil, :duplicate_semantic_source_identity,
            '3D text render and match inventories require unique source-span IDs'
          )
          return result
        end
        missing_ids = render_ids.reject { |source_id| match_ids.include?(source_id) }
        unless missing_ids.empty?
          result[:failures] << hard_failure(
            nil, :render_target_absent_from_match_inventory,
            "3D text render target is absent from authoritative match inventory: " \
            "#{missing_ids.join(', ')}"
          )
          return result
        end

        record_phase_ms!(result, :verification_ms, inventory_started)
        match_started = monotonic_ms
        match = CairoGlyphSource.match_spans(pens, match_items, media_box)
        record_phase_ms!(result, :match_ms, match_started)
        result[:match] = match

        if render_items.empty? && placed.empty?
          result[:match_scope_verified] = true
          result[:ok] = true
          result[:no_semantic_text] = true
          publish_performance!(result, solid_cache, render_started)
          return result
        end

        assignment_started = monotonic_ms
        matched_by_span = {}
        assigned_placements = {}
        Array(match[:placement_matches]).each do |record|
          id = record[:source_span_id].to_s
          placement_index = record[:placement_index].to_i
          if assigned_placements.key?(placement_index)
            result[:failures] << hard_failure(
              id, :duplicate_source_placement_assignment,
              "SVG placement #{placement_index} is assigned to more than one " \
              'semantic source span'
            )
            return result
          end
          assigned_placements[placement_index] = id
          matched_by_span[id] = [] unless matched_by_span.key?(id)
          matched_by_span[id] << placement_index
        end
        result[:match_scope_verified] = true
        source_ink_by_span = {}
        Array(match[:source_ink_matches]).each do |evidence|
          next unless evidence.is_a?(Hash)
          source_ink_by_span[evidence[:source_span_id].to_s] = evidence
        end
        record_phase_ms!(result, :verification_ms, assignment_started)

        entries_by_span = {}
        placed.each do |entry|
          assigned_source_id =
            assigned_placements[entry[:placement_index].to_i]
          next unless assigned_source_id
          entries_by_span[assigned_source_id] = [] unless
            entries_by_span.key?(assigned_source_id)
          entries_by_span[assigned_source_id] << entry
        end

        span_build_started = monotonic_ms
        render_items.each_with_index do |item, render_index|
          run_checkpoint!(
            opts, :text_item, render_index, render_items.length
          )
          source_id = begin
            RepresentationFidelity.source_span_id(item)
          rescue StandardError => e
            result[:failures] << hard_failure(
              nil, :source_span_identity_unverifiable, e.message
            )
            next
          end
          indices = Array(matched_by_span[source_id]).uniq.sort
          entries = Array(entries_by_span[source_id])

          ink_evidence = source_ink_by_span[source_id]
          if ink_evidence &&
             ink_evidence[:character_count_parity] == false
            page_failure = source_page_failure(
              source_id, opts[:source_context]
            )
            if page_failure
              page_failure[:detail] =
                'shaped source-glyph coverage requires a complete page ' \
                'renderer/font inventory: ' + page_failure[:detail].to_s
              result[:failures] << page_failure
              next
            end
          end

          if entries.empty?
            page_failure = source_page_failure(
              source_id, opts[:source_context]
            )
            if page_failure
              result[:failures] << page_failure
            else
              # Even if the source bbox is degenerate or missing, the page
              # renderer/font inventory completed. Record an affirmative
              # impossibility transition so the fallback ladder can continue
              # rather than halting the whole import for one unverifiable span.
              result[:transition_proofs] << identity_unavailable_proof(
                source_id, item, depth, opts[:source_context], match
              )
            end
            next
          end

          group = nil
          begin
            raise 'parent entities cannot create an owned group' unless
              entities.respond_to?(:add_group)
            group = entities.add_group
            raise 'owned source-span group was not created' unless group
            owned_groups << group
            assign_group_identity(
              group, source_id, :text_span, opts[:layer], indices
            )
            span_result = build_span_group(
              group, entries, source_id, depth, :text_span, solid_cache
            )
            span_result[:source_ink_coverage] = ink_evidence if ink_evidence
            result[:span_results] << span_result
          rescue ImportRunControl::ImportCancelled
            cleanup_owned_group(entities, group)
            owned_groups.delete(group)
            raise
          rescue StandardError => e
            Logger.warn(
              'Svg3DTextRenderer',
              "#{source_id}: #{e.class}: #{e.message}"
            )
            cleanup = cleanup_owned_group(entities, group)
            owned_groups.delete(group)
            result[:failures] << hard_failure(
              source_id, classify_host_failure(e), e.message,
              cleanup[:created_entity_ids], cleanup[:cleaned_entity_ids],
              cleanup[:cleanup_outcome]
            )
          end
        end
        run_checkpoint!(opts, :text_item, render_items.length, render_items.length)
        record_phase_ms!(result, :span_build_ms, span_build_started)

        preserve_unmatched = if opts.key?(:preserve_unmatched_source_placements)
                               opts[:preserve_unmatched_source_placements] == true
                             else
                               true
                             end
        if preserve_unmatched
          render_unmatched_source_placements!(
            entities, placed, match, depth, opts, owned_groups, result,
            solid_cache
          )
        end

        unless result[:failures].empty?
          cleanup_all_owned!(entities, owned_groups, result)
          cleanup_solid_cache!(solid_cache, result)
          result[:span_results] = []
          result[:unmatched_source_results] = []
        end
        if solid_cache
          result[:solid_cache] = result[:solid_cache].merge(
            solid_cache.metrics.merge(:enabled => true)
          )
        end
        publish_performance!(result, solid_cache, render_started)

        run_checkpoint!(opts, :renderer_stage, 5, 5)
        result[:ok] = result[:failures].empty? &&
          result[:transition_proofs].empty?
        result
      rescue ImportRunControl::ImportCancelled
        result ||= base_result
        cleanup_all_owned!(entities, owned_groups || [], result)
        cleanup_solid_cache!(solid_cache, result)
        raise
      rescue StandardError => e
        result ||= base_result
        begin
          cleanup_all_owned!(entities, owned_groups || [], result)
          cleanup_solid_cache!(solid_cache, result)
        rescue StandardError => cleanup_error
          result[:failures] << hard_failure(
            nil, :renderer_cleanup_exception, cleanup_error.message
          )
        end
        result[:failures] << hard_failure(nil, :renderer_exception, e.message)
        publish_performance!(result, solid_cache, render_started)
        result[:ok] = false
        result
      end

      def self.run_checkpoint!(opts, stage, completed, total)
        controller = opts.is_a?(Hash) ? opts[:run_controller] : nil
        return false unless controller && controller.respond_to?(:checkpoint!)
        controller.checkpoint!(
          stage,
          :completed => completed.to_i,
          :total => total.to_i,
          :page => opts[:page_number]
        )
        true
      end

      def self.base_result
        {
          :ok => false,
          :renderer => :svg_source_3d_text,
          :span_results => [],
          :unmatched_source_results => [],
          :transition_proofs => [],
          :failures => [],
          :source_placements => 0,
          :no_semantic_text => false,
          :authoritative_match_span_count => 0,
          :render_target_span_count => 0,
          :match_scope_verified => false,
          :solid_cache => {
            :enabled => false,
            :definition_builds => 0,
            :cache_hits => 0,
            :cache_misses => 0,
            :instance_placements => 0,
            :unique_cache_keys => 0,
            :transaction_abort_required => false
          },
          :performance => {
            :definition_build_ms => 0.0,
            :instance_placement_ms => 0.0,
            :match_ms => 0.0,
            :parse_ms => 0.0,
            :span_build_ms => 0.0,
            :total_ms => 0.0,
            :verification_ms => 0.0
          }
        }
      end

      def self.finalize_source_evidence!(row, item, page_rotation = 0.0,
                                         physical_definition_tree_cache = nil,
                                         physical_canonical_json_cache = nil)
        unless row.is_a?(Hash) && row[:group] && row[:source_span_id]
          raise RepresentationFidelity::ContractError,
                '3D Text row cannot be bound to a semantic source item'
        end
        source_id = RepresentationFidelity.source_span_id(item)
        unless row[:source_span_id].to_s == source_id
          raise RepresentationFidelity::ContractError,
                '3D Text source identity changed before evidence finalization'
        end
        bounds_started = monotonic_ms
        actual = bounds_hash(row[:group])
        transform = RepresentationFidelity.entity_transformation_payload(row[:group])
        transform ||= { :kind => 'baked_geometry', :entity_count => 1 }
        expected_box = nil
        source_extent = row[:source_extent]
        if source_extent
          unless row[:page_transform_verified] == true &&
                 Array(row[:source_page_transformation]).length == 16
            raise RepresentationFidelity::ContractError,
                  '3D Text source page transform was not independently verified'
          end
          expected_box = RepresentationFidelity.transformed_extent_bounds(
            source_extent, row[:source_page_transformation], 0.0, row[:depth]
          )
          expected_values = expected_box[:min] + expected_box[:max]
          actual_values = [
            actual[:min_x], actual[:min_y], actual[:min_z],
            actual[:max_x], actual[:max_y], actual[:max_z]
          ]
          unless actual_values.each_with_index.all? do |value, index|
            close_size?(value, expected_values[index])
          end
            raise RepresentationFidelity::ContractError,
                  "3D Text final bounds differ from source outlines and page transform " \
                  "(span=#{row[:source_span_id]}, " \
                  "expected=#{expected_values.inspect}, " \
                  "actual=#{actual_values.inspect})"
          end
          transform = row[:source_page_transformation]
        end
        expected_box ||= {
          :min => [actual[:min_x], actual[:min_y], actual[:min_z]],
          :max => [actual[:max_x], actual[:max_y], actual[:max_z]]
        }
        bounds_elapsed = monotonic_ms - bounds_started
        physical_started = monotonic_ms
        physical_root_style_cache_keys =
          row.delete(:component_definition_style_cache_keys)
        expected = RepresentationFidelity.source_expected_evidence(
          item, :text3d,
          :entities => [row[:group]],
          :source_anchor => expected_box[:min],
          :source_rotation_radians =>
            (RepresentationFidelity.source_rotation_degrees(item) +
             page_rotation.to_f) * Math::PI / 180.0,
          :expected_width => expected_box[:max][0] - expected_box[:min][0],
          :expected_height => expected_box[:max][1] - expected_box[:min][1],
          :expected_depth => expected_box[:max][2] - expected_box[:min][2],
          :expected_bounds => expected_box,
          :expected_transformation => transform,
          :physical_definition_tree_cache =>
            physical_definition_tree_cache,
          :physical_canonical_json_cache =>
            physical_canonical_json_cache,
          :physical_root_style_cache_keys =>
            physical_root_style_cache_keys,
          :source_font_identity => {
            :source => 'pdf_renderer_svg_glyph_outlines',
            :glyph_ids => Array(row[:glyph_ids]).map { |id| id.to_s }.sort
          }
        )
        physical_elapsed = monotonic_ms - physical_started
        attach_started = monotonic_ms
        RepresentationFidelity.attach_source_evidence!(
          [row[:group]], expected, 'svg_source_3d_text'
        )
        attach_elapsed = monotonic_ms - attach_started
        row[:evidence_performance] = {
          :bounds_ms => bounds_elapsed.round(3),
          :physical_ms => physical_elapsed.round(3),
          :attach_ms => attach_elapsed.round(3)
        }
        row[:expected_evidence] = expected
        row[:content_verified] = true
        row[:physical_geometry_verified] = true
        row[:physical_style_verified] = row[:ink_applied] == true
        row[:transform_verified] = true
        row
      end

      def self.build_span_group(group, entries, source_id, depth,
                                source_kind = :text_span, solid_cache = nil)
        child = group.respond_to?(:entities) ? group.entities : nil
        raise 'owned source-span group has no entities collection' unless child
        if solid_cache && solid_cache.supported_for?(child)
          return build_cached_span_group(
            group, entries, source_id, depth, source_kind, solid_cache
          )
        end
        faces = []
        construction_origin = construction_origin_for(entries)
        construction_scale = safe_construction_scale(entries, construction_origin)
        construction_group = nil
        geometry_entities = child
        if construction_scale > 1.0
          raise 'host cannot create a tolerance-safe nested group' unless
            child.respond_to?(:add_group)
          construction_group = child.add_group
          geometry_entities = construction_group.respond_to?(:entities) ?
            construction_group.entities : nil
          raise 'tolerance-safe nested group has no entities collection' unless
            geometry_entities
        end
        source_vertex_count = Array(entries).inject(0) do |entry_total, entry|
          entry_total + Array(entry[:loops]).inject(0) do |loop_total, points|
            contour = normalized_contour(points)
            loop_total + (contour ? contour.length : 0)
          end
        end
        Array(entries).each do |entry|
          glyph_faces = build_filled_glyph(
            geometry_entities, entry[:loops], entry, construction_scale,
            construction_origin
          )
          raise 'source glyph produced no filled face' if glyph_faces.empty?
          faces.concat(glyph_faces)
        end
        raise 'source span produced no filled face' if faces.empty?

        extruded = 0
        faces.each do |face|
          raise 'source glyph face cannot be extruded' unless face.respond_to?(:pushpull)
          begin
            if face.respond_to?(:normal) && face.normal &&
               face.normal.respond_to?(:z) && face.normal.z.to_f < 0.0 &&
               face.respond_to?(:reverse!)
              face.reverse!
            end
          rescue StandardError
            # pushpull and the final positive-Z bounds check remain authoritative.
          end
          face.pushpull(depth * construction_scale)
          extruded += 1
        end

        if construction_scale > 1.0
          unless construction_group.respond_to?(:transform!) &&
                 defined?(Geom::Transformation) &&
                 Geom::Transformation.respond_to?(:scaling)
            raise 'host cannot retain exact inverse construction scale'
          end
          inverse = Geom::Transformation.scaling(
            construction_origin, 1.0 / construction_scale
          )
          transformed = construction_group.transform!(inverse)
          raise 'host rejected inverse construction scale' unless transformed
        end

        expected = CairoGlyphSource.loops_extent(entries)
        raise 'source outline extent is unavailable' unless expected
        actual = bounds_hash(group)
        expected_width = expected[2].to_f - expected[0].to_f
        expected_height = expected[3].to_f - expected[1].to_f
        actual_width = actual[:max_x] - actual[:min_x]
        actual_height = actual[:max_y] - actual[:min_y]
        actual_depth = actual[:max_z] - actual[:min_z]
        position_ok = close_size?(actual[:min_x], expected[0]) &&
          close_size?(actual[:min_y], expected[1]) &&
          close_size?(actual[:max_x], expected[2]) &&
          close_size?(actual[:max_y], expected[3]) &&
          close_size?(actual[:min_z], 0.0) &&
          close_size?(actual[:max_z], depth)
        width_ok = close_size?(actual_width, expected_width)
        height_ok = close_size?(actual_height, expected_height)
        depth_ok = actual_depth > SIZE_TOLERANCE_INCHES &&
          close_size?(actual_depth, depth)
        raise 'extruded source glyph width/height verification failed' unless
          width_ok && height_ok && position_ok
        raise 'extruded source glyph has no verified positive Z depth' unless depth_ok

        source_ink_rgb = source_text_ink_rgb(entries)
        ink_applied = apply_source_text_ink!(group, source_ink_rgb)

        matrices = entries.map { |entry| Array(entry[:svg_matrix]).map { |v| v.to_f } }
        ids = entries.map { |entry| entry[:glyph_id].to_s }
        placement_indices = entries.map { |entry| entry[:placement_index].to_i }
        {
          :source_span_id => source_kind == :text_span ? source_id : nil,
          :source_unit_id => source_id,
          :source_kind => source_kind,
          :group => group,
          :group_entity_id => RepresentationFidelity.stable_entity_id(group),
          :renderer => :svg_source_3d_text,
          :glyph_ids => ids,
          :placement_indices => placement_indices,
          :source_matrices => matrices.uniq,
          :source_extent => expected.map { |value| value.to_f },
          :source_placement_count => placement_indices.length,
          :face_count => faces.length,
          :extruded_face_count => extruded,
          :ink_applied => ink_applied,
          :source_ink_rgb => source_ink_rgb,
          :source_ink_material_name => material_name_for_rgb(source_ink_rgb),
          :identity_verified => !ids.empty? && ids.none? { |id| id.empty? },
          :placement_verified => !placement_indices.empty? &&
            placement_indices.uniq.length == placement_indices.length,
          :rotation_verified => matrices.length == entries.length &&
            matrices.all? { |matrix| matrix.length >= 6 },
          :size_verified => width_ok && height_ok,
          :depth_verified => depth_ok,
          :host_tolerance_adapted => construction_scale > 1.0,
          :construction_scale => construction_scale,
          :construction_origin => [
            construction_origin.x.to_f,
            construction_origin.y.to_f,
            construction_origin.z.to_f
          ],
          :construction_group_entity_id => construction_group &&
            RepresentationFidelity.stable_entity_id(construction_group),
          :collapsed_host_equal_vertices => 0,
          :source_outline_vertex_count => source_vertex_count,
          :width => actual_width,
          :height => actual_height,
          :depth => actual_depth,
          :bounds => actual,
          :expected_outline_extent => expected
        }
      end

      def self.build_cached_span_group(group, entries, source_id, depth,
                                       source_kind, solid_cache)
        child = group.respond_to?(:entities) ? group.entities : nil
        raise 'owned cached source-span group has no entities collection' unless child
        instances = []
        definition_records = []
        Array(entries).each do |entry|
          record = solid_cache.fetch(entry) do |definition_entities, local_entry|
            unless definition_entities.respond_to?(:add_group)
              raise 'exact glyph definition cannot create an owned geometry group'
            end
            definition_group = definition_entities.add_group
            raise 'exact glyph definition group was not created' unless
              definition_group
            row = build_span_group(
              definition_group, [local_entry],
              "definition:#{entry[:glyph_id]}", depth,
              :svg_glyph_definition, nil
            )
            {
              :face_count => row[:face_count],
              :extruded_face_count => row[:extruded_face_count],
              :source_outline_vertex_count => row[:source_outline_vertex_count],
              :construction_scale => row[:construction_scale],
              :host_tolerance_adapted => row[:host_tolerance_adapted],
              :definition_group_entity_id => row[:group_entity_id]
            }
          end
          instance = solid_cache.add_instance(child, record)
          instances << instance
          definition_records << record
        end
        raise 'source span produced no exact glyph component instance' if
          instances.empty?

        expected = CairoGlyphSource.loops_extent(entries)
        raise 'source outline extent is unavailable' unless expected
        actual = bounds_hash(group)
        expected_width = expected[2].to_f - expected[0].to_f
        expected_height = expected[3].to_f - expected[1].to_f
        actual_width = actual[:max_x] - actual[:min_x]
        actual_height = actual[:max_y] - actual[:min_y]
        actual_depth = actual[:max_z] - actual[:min_z]
        position_ok = close_size?(actual[:min_x], expected[0]) &&
          close_size?(actual[:min_y], expected[1]) &&
          close_size?(actual[:max_x], expected[2]) &&
          close_size?(actual[:max_y], expected[3]) &&
          close_size?(actual[:min_z], 0.0) &&
          close_size?(actual[:max_z], depth)
        width_ok = close_size?(actual_width, expected_width)
        height_ok = close_size?(actual_height, expected_height)
        depth_ok = actual_depth > SIZE_TOLERANCE_INCHES &&
          close_size?(actual_depth, depth)
        unless width_ok && height_ok && position_ok
          raise 'cached source glyph width/height verification failed'
        end
        unless depth_ok
          raise 'cached source glyph has no verified positive Z depth'
        end

        source_ink_rgb = source_text_ink_rgb(entries)
        ink_applied = apply_source_text_ink!(group, source_ink_rgb)
        matrices = entries.map do |entry|
          Array(entry[:svg_matrix]).map { |value| value.to_f }
        end
        ids = entries.map { |entry| entry[:glyph_id].to_s }
        placement_indices = entries.map do |entry|
          entry[:placement_index].to_i
        end
        build_metrics = definition_records.map { |record| record[:build_metrics] }
        face_count = build_metrics.inject(0) do |sum, metrics|
          sum + metrics[:face_count].to_i
        end
        extruded_count = build_metrics.inject(0) do |sum, metrics|
          sum + metrics[:extruded_face_count].to_i
        end
        source_vertex_count = build_metrics.inject(0) do |sum, metrics|
          sum + metrics[:source_outline_vertex_count].to_i
        end
        construction_scale = build_metrics.map do |metrics|
          metrics[:construction_scale].to_f
        end.max || 1.0
        instance_ids = instances.map do |instance|
          RepresentationFidelity.stable_entity_id(instance)
        end
        {
          :source_span_id => source_kind == :text_span ? source_id : nil,
          :source_unit_id => source_id,
          :source_kind => source_kind,
          :group => group,
          :group_entity_id => RepresentationFidelity.stable_entity_id(group),
          :renderer => :svg_source_3d_text,
          :glyph_ids => ids,
          :placement_indices => placement_indices,
          :source_matrices => matrices.uniq,
          :source_extent => expected.map { |value| value.to_f },
          :source_placement_count => placement_indices.length,
          :face_count => face_count,
          :extruded_face_count => extruded_count,
          :ink_applied => ink_applied,
          :source_ink_rgb => source_ink_rgb,
          :source_ink_material_name => material_name_for_rgb(source_ink_rgb),
          :identity_verified => !ids.empty? && ids.none? { |id| id.empty? },
          :placement_verified => !placement_indices.empty? &&
            placement_indices.uniq.length == placement_indices.length,
          :rotation_verified => matrices.length == entries.length &&
            matrices.all? { |matrix| matrix.length >= 6 },
          :size_verified => width_ok && height_ok,
          :depth_verified => depth_ok,
          :host_tolerance_adapted => build_metrics.any? do |metrics|
            metrics[:host_tolerance_adapted] == true
          end,
          :construction_scale => construction_scale,
          :construction_origin => [
            (expected[0].to_f + expected[2].to_f) * 0.5,
            (expected[1].to_f + expected[3].to_f) * 0.5,
            0.0
          ],
          :construction_group_entity_id => nil,
          :collapsed_host_equal_vertices => 0,
          :source_outline_vertex_count => source_vertex_count,
          :width => actual_width,
          :height => actual_height,
          :depth => actual_depth,
          :bounds => actual,
          :expected_outline_extent => expected,
          :component_instance_entity_ids => instance_ids,
          :component_definition_keys => definition_records.map do |record|
            record[:key]
          end.uniq.sort,
          :component_definition_style_cache_keys =>
            definition_records.inject({}) do |memo, record|
              definition = record[:definition]
              memo[definition.object_id] = true if definition
              memo
            end,
          :definition_reuse_verified => true
        }
      end

      # Render-weight contract (R-D ghosting): extruded source glyphs whose
      # faces keep nil materials render as white-filled outlines — only their
      # edges draw, so text ghosts at any size. Painting the owned span group
      # lets every nil-material glyph face (caps and extrusion walls, nested
      # construction group included) inherit the renderer's source fill color.
      # SVG's default black is used only when no explicit fill is present.
      # Returns true only
      # when the host accepted the paint; callers record the outcome (R20-2 —
      # a headless host without materials reports ink_applied false, never a
      # silent claim).
      def self.apply_source_text_ink!(group, rgb = TEXT_INK_RGB)
        return false unless group.respond_to?(:material=) &&
                            group.respond_to?(:model)
        model = group.model
        materials = model && model.respond_to?(:materials) ? model.materials : nil
        return false unless materials
        channels = normalize_source_ink_rgb(rgb) || TEXT_INK_RGB
        material_name = material_name_for_rgb(channels)
        mat = materials[material_name]
        unless mat
          mat = materials.add(material_name)
          if mat && mat.respond_to?(:color=) &&
             defined?(Sketchup) && Sketchup.const_defined?(:Color)
            mat.color = Sketchup::Color.new(
              channels[0], channels[1], channels[2]
            )
          end
        end
        return false unless mat
        group.material = mat
        true
      rescue StandardError => e
        Logger.warn(
          'Svg3DTextRenderer',
          "source text ink paint failed: #{e.message}"
        )
        false
      end

      def self.source_text_ink_rgb(entries)
        unsupported_opacity = Array(entries).any? do |entry|
          next false unless entry.is_a?(Hash) && entry.key?(:fill_opacity)
          opacity = entry[:fill_opacity]
          !opacity.is_a?(Numeric) || !opacity.to_f.finite? ||
            (opacity.to_f - 1.0).abs > 1.0e-12
        end
        if unsupported_opacity
          raise 'source text span has unsupported non-opaque fill opacity'
        end
        unsupported = Array(entries).any? do |entry|
          entry.is_a?(Hash) && entry.key?(:fill_rgb) && entry[:fill_rgb].nil?
        end
        if unsupported
          raise 'source text span has a non-solid or unsupported fill color'
        end
        colors = Array(entries).map do |entry|
          next nil unless entry.is_a?(Hash)
          normalize_source_ink_rgb(entry[:fill_rgb])
        end.compact.uniq
        return TEXT_INK_RGB.dup if colors.empty?
        if colors.length > 1
          raise 'source text span contains multiple fill colors'
        end
        colors.first
      end

      def self.normalize_source_ink_rgb(rgb)
        return nil unless rgb.is_a?(Array) && rgb.length >= 3
        raw_channels = rgb.first(3)
        values = raw_channels.map do |channel|
          value = channel.to_f
          return nil unless value.finite?
          value
        end
        byte_domain = raw_channels.all? { |channel| channel.is_a?(Integer) } ||
          values.any? { |value| value > 1.0 }
        values.map do |value|
          if byte_domain
            [[value, 0.0].max, 255.0].min.round
          else
            value = [[value, 0.0].max, 1.0].min
            (value * 255.0).round
          end
        end
      rescue StandardError
        nil
      end

      def self.material_name_for_rgb(rgb)
        channels = normalize_source_ink_rgb(rgb)
        channels ||= Array(rgb).first(3).map { |channel| channel.to_i }
        channels = TEXT_INK_RGB unless channels.length >= 3
        "PDF_#{channels[0]}_#{channels[1]}_#{channels[2]}"
      rescue StandardError
        TEXT_INK_MATERIAL_NAME
      end

      # Build SVG non-zero-fill contours in descending area order. A contour is
      # a boundary only when crossing it changes cumulative winding between
      # zero (unfilled) and nonzero (filled). Creating then erasing a boundary
      # whose inside winding is zero retains SketchUp's supported hole loop.
      def self.build_filled_glyph(entities, loops, source = {}, scale = 1.0,
                                  origin = nil)
        contours = Array(loops).map do |points|
          normalized = normalized_contour(points)
          normalized && scaled_contour(normalized, scale, origin)
        end.compact
        raise 'source glyph has no closed contour' if contours.empty?
        records = contours.map do |points|
          area = signed_area(points)
          {
            :points => points, :area => area.abs,
            :winding => area > 0.0 ? 1 : -1
          }
        end
        records.sort_by! { |record| -record[:area] }
        filled = []
        records.each_with_index do |record, index|
          probe = record[:points][0]
          containing = records[0...index].select do |outer|
            point_in_polygon?(probe, outer[:points])
          end
          outside_winding = containing.inject(0) do |total, outer|
            total + outer[:winding]
          end
          inside_winding = outside_winding + record[:winding]
          next if outside_winding.zero? == inside_winding.zero?
          begin
            face = entities.add_face(record[:points])
          rescue StandardError => e
            glyph_id = source[:glyph_id].to_s
            placement = source[:placement_index]
            detail = "add_face failed for glyph #{glyph_id} placement " \
              "#{placement} contour #{index}: #{e.message}; " \
              "host_equal_pairs=#{host_equal_pair_summary(record[:points])}"
            raise e.class, detail, e.backtrace
          end
          raise 'host add_face returned no face for a source glyph contour' unless face
          if inside_winding.zero?
            erase_face!(entities, face)
          else
            filled << face
          end
        end
        filled
      end

      def self.normalized_contour(points)
        clean = []
        Array(points).each do |point|
          next unless point && point.respond_to?(:x) && point.respond_to?(:y)
          clean << point if clean.empty? || !same_point?(clean[-1], point)
        end
        clean.pop if clean.length > 1 && same_point?(clean[0], clean[-1])
        return nil if clean.length < 3
        area = signed_area(clean)
        raise 'source contour area is nonfinite' unless area.finite?
        return nil if area == 0.0
        clean
      end

      def self.construction_origin_for(entries)
        extent = CairoGlyphSource.loops_extent(entries)
        raise 'source outline extent is unavailable for safe construction' unless extent
        Geom::Point3d.new(
          (extent[0].to_f + extent[2].to_f) * 0.5,
          (extent[1].to_f + extent[3].to_f) * 0.5,
          0.0
        )
      end

      def self.safe_construction_scale(entries, origin = nil)
        origin ||= construction_origin_for(entries)
        contours = Array(entries).flat_map do |entry|
          Array(entry[:loops]).map { |points| normalized_contour(points) }.compact
        end
        return 1.0 unless contours.any? { |points| host_duplicate_points?(points) }

        scale = 10.0
        while scale <= MAX_CONSTRUCTION_SCALE
          safe = contours.all? do |points|
            !host_duplicate_points?(scaled_contour(points, scale, origin))
          end
          return [scale * 10.0, MAX_CONSTRUCTION_SCALE].min if safe
          scale *= 10.0
        end
        raise 'source contour has coincident vertices that scaling cannot separate'
      end

      # O(N log N) duplicate check: bucket points on quantized grid cells and
      # compare only same-cell and adjacent-cell neighbours. This replaces the
      # previous O(N²) all-pairs scan which made construction-scale detection
      # agonizingly slow on glyph-dense pages on older hardware.
      def self.host_duplicate_points?(points)
        list = Array(points)
        return false if list.length < 2
        tol = HOST_POINT_TOLERANCE_INCHES
        # Quantize into grid cells whose side is tol. Two points closer than
        # tol must share a cell or be in immediately adjacent cells.
        bucket = {}
        list.each do |pt|
          px = pt.x.to_f
          py = pt.y.to_f
          pz = pt.respond_to?(:z) ? pt.z.to_f : 0.0
          gx = (px / tol).floor
          gy = (py / tol).floor
          gz = (pz / tol).floor
          (-1..1).each do |ix|
            (-1..1).each do |iy|
              (-1..1).each do |iz|
                key = [(gx + ix), (gy + iy), (gz + iz)]
                neighbours = bucket[key]
                if neighbours
                  neighbours.each do |nx, ny, nz|
                    dx = px - nx
                    dy = py - ny
                    dz = pz - nz
                    return true if (dx * dx) + (dy * dy) + (dz * dz) < tol * tol
                  end
                end
              end
            end
          end
          cell = [gx, gy, gz]
          bucket[cell] ||= []
          bucket[cell] << [px, py, pz]
        end
        false
      end

      def self.scaled_contour(points, scale, origin = nil)
        factor = scale.to_f
        return Array(points) if factor == 1.0
        ox = origin ? origin.x.to_f : 0.0
        oy = origin ? origin.y.to_f : 0.0
        oz = origin && origin.respond_to?(:z) ? origin.z.to_f : 0.0
        Array(points).map do |point|
          Geom::Point3d.new(
            ox + ((point.x.to_f - ox) * factor),
            oy + ((point.y.to_f - oy) * factor),
            oz + (((point.respond_to?(:z) ? point.z.to_f : 0.0) - oz) * factor)
          )
        end
      end

      def self.same_point?(left, right)
        left_x = left.x.to_f
        left_y = left.y.to_f
        right_x = right.x.to_f
        right_y = right.y.to_f
        left_z = left.respond_to?(:z) ? left.z.to_f : 0.0
        right_z = right.respond_to?(:z) ? right.z.to_f : 0.0
        left_x == right_x && left_y == right_y && left_z == right_z
      end

      def self.host_equal_pair_summary(points)
        matches = []
        list = Array(points)
        list.each_with_index do |left, left_index|
          ((left_index + 1)...list.length).each do |right_index|
            right = list[right_index]
            next unless left == right
            distance = if left.respond_to?(:distance)
                         left.distance(right).to_f
                       else
                         dx = left.x.to_f - right.x.to_f
                         dy = left.y.to_f - right.y.to_f
                         Math.sqrt((dx * dx) + (dy * dy))
                       end
            matches << "#{left_index},#{right_index}@#{format('%.12g', distance)}"
            return matches.join('|') if matches.length >= 8
          end
        end
        matches.empty? ? 'none' : matches.join('|')
      rescue StandardError => e
        "unavailable(#{e.class})"
      end

      def self.signed_area(points)
        area = 0.0
        Array(points).each_with_index do |point, index|
          following = points[(index + 1) % points.length]
          area += (point.x.to_f * following.y.to_f) -
            (following.x.to_f * point.y.to_f)
        end
        area * 0.5
      end

      def self.point_in_polygon?(point, polygon)
        inside = false
        j = polygon.length - 1
        polygon.each_with_index do |pi, i|
          pj = polygon[j]
          crosses = ((pi.y.to_f > point.y.to_f) !=
                     (pj.y.to_f > point.y.to_f))
          if crosses
            denominator = pj.y.to_f - pi.y.to_f
            denominator = 1.0e-20 if denominator.abs < 1.0e-20
            boundary_x = ((pj.x.to_f - pi.x.to_f) *
              (point.y.to_f - pi.y.to_f) / denominator) + pi.x.to_f
            inside = !inside if point.x.to_f < boundary_x
          end
          j = i
        end
        inside
      end

      def self.erase_face!(entities, face)
        if face.respond_to?(:erase!)
          face.erase!
        elsif entities.respond_to?(:erase_entities)
          entities.erase_entities(face)
        else
          raise 'host cannot erase a source glyph hole face'
        end
      end

      def self.assign_group_identity(group, source_id, source_kind, layer,
                                     placement_indices = [])
        group.name = "PDF 3D Text #{source_id}" if group.respond_to?(:name=)
        group.layer = layer if layer && group.respond_to?(:layer=)
        return unless group.respond_to?(:set_attribute)
        if source_kind == :text_span
          group.set_attribute('BC_PDF_Importer', 'source_span_id', source_id)
        end
        group.set_attribute('BC_PDF_Importer', 'source_unit_id', source_id)
        group.set_attribute('BC_PDF_Importer', 'source_kind', source_kind.to_s)
        group.set_attribute(
          'BC_PDF_Importer', 'source_placement_indices',
          Array(placement_indices).map { |index| index.to_i }.join(',')
        )
        group.set_attribute('BC_PDF_Importer', 'representation', 'text3d')
        group.set_attribute('BC_PDF_Importer', 'renderer', 'svg_source_3d_text')
      end

      # A renderer SVG can contain physical source glyphs that a semantic text
      # extractor does not expose as a span (for example drawing symbols or
      # damaged ToUnicode data). They are still exact source outlines. Preserve
      # them as verified positive-depth 3D source glyphs with a page-scoped
      # physical identity; never omit them and never invent a semantic span ID.
      def self.render_unmatched_source_placements!(entities, placed, match, depth,
                                                   opts, owned_groups, result,
                                                   solid_cache = nil)
        # Coverage-mismatch entries are nested evidence for placements already
        # assigned to a semantic bbox; rendering those anonymously would leave
        # partial duplicate ink beside the item fallback. Preserve only truly
        # unassigned physical placements, which retain a direct placement ID.
        unmatched = Array(match[:unmatched_placements]).select do |record|
          record.is_a?(Hash) && record.key?(:placement_index)
        end
        return if unmatched.empty?

        indices = unmatched.map do |record|
          record.is_a?(Hash) && record.key?(:placement_index) ?
            record[:placement_index].to_i : nil
        end.compact.uniq.sort
        entries = Array(placed).select do |entry|
          indices.include?(entry[:placement_index].to_i)
        end
        if indices.empty? || entries.length != indices.length
          result[:failures] << hard_failure(
            nil, :unmatched_svg_placement_identity_unverifiable,
            'unmatched source glyph placement indices could not be joined back to SVG outlines'
          )
          return
        end

        page_number = opts.key?(:page_number) ? opts[:page_number].to_i : 0
        source_id = "svg_glyph_placements:page:#{page_number}"
        group = nil
        begin
          raise 'parent entities cannot create an owned group' unless
            entities.respond_to?(:add_group)
          group = entities.add_group
          raise 'owned source-glyph group was not created' unless group
          owned_groups << group
          assign_group_identity(
            group, source_id, :svg_glyph_placement, opts[:layer], indices
          )
          row = build_span_group(
            group, entries, source_id, depth, :svg_glyph_placement, solid_cache
          )
          row[:semantic_identity_available] = false
          row[:physical_source_identity_verified] = true
          result[:unmatched_source_results] << row
        rescue StandardError => e
          cleanup = cleanup_owned_group(entities, group)
          owned_groups.delete(group)
          result[:failures] << hard_failure(
            nil, classify_host_failure(e), e.message,
            cleanup[:created_entity_ids], cleanup[:cleaned_entity_ids],
            cleanup[:cleanup_outcome]
          )
        end
      end

      def self.bounds_hash(entity)
        box = entity.bounds
        low = RepresentationFidelity.numeric_point(box.min)
        high = RepresentationFidelity.numeric_point(box.max)
        raise 'created 3D text bounds are unavailable' unless low && high
        {
          :min_x => low[0], :min_y => low[1], :min_z => low[2],
          :max_x => high[0], :max_y => high[1], :max_z => high[2]
        }
      end

      def self.close_size?(actual, expected)
        tolerance = [SIZE_TOLERANCE_INCHES, expected.to_f.abs * 1.0e-5].max
        (actual.to_f - expected.to_f).abs <= tolerance
      end

      def self.source_bbox_valid?(item, media_box)
        base_x = media_box.is_a?(Array) ? media_box[0].to_f : 0.0
        base_y = media_box.is_a?(Array) ? media_box[1].to_f : 0.0
        !CairoGlyphSource.item_bbox_media_relative(item, base_x, base_y).nil?
      rescue StandardError
        false
      end

      def self.identity_unavailable_proof(source_id, item, depth,
                                          source_context, match)
        binding = RepresentationFidelity.proof_binding(source_id)
        {
          :source_span_id => source_id,
          :importer_id => binding[:importer_id],
          :page_number => binding[:page_number],
          :scope => :item,
          :category => :exact_representation_impossible,
          :affirmative_impossibility => true,
          :generic_failure => false,
          :from_mode => :text3d,
          :to_mode => :glyphs,
          :reason_code => :source_item_identity_unavailable,
          :attempted_renderer => 'svg_source_3d_text',
          :created_entity_ids => [],
          :cleaned_entity_ids => [],
          :cleanup_outcome => :not_required,
          :evidence => {
            :source_observation => 'renderer and extractor inventories completed but no exact one-to-one source-item association was established',
            :source_text => CairoGlyphSource.item_text(item),
            :requested_depth => depth,
            :verification => 'source bbox, page source inventory, placement ownership, and exact glyph coverage were checked',
            :source_renderer => source_context[:renderer].to_s,
            :font_inventory_status => source_context[:font_inventory_status],
            :unmatched_renderer_placement_count =>
              Array(match[:unmatched_placements]).length,
            :glyph_coverage_failures => Array(match[:coverage_failures]).select do |failure|
              failure.is_a?(Hash) &&
                failure[:source_span_id].to_s == source_id
            end
          }
        }
      end

      # An empty per-span match is affirmative absence only after the entire
      # renderer page inventory completed without a page-scoped/runtime error.
      # Otherwise a page failure could be mistaken for an item-specific fact.
      def self.source_page_failure(source_id, source_context)
        unless source_context.is_a?(Hash)
          return hard_failure(
            source_id, :source_page_evidence_missing,
            'page source inventory evidence is missing'
          )
        end

        binding = RepresentationFidelity.proof_binding(source_id)
        importer_id = source_context[:importer_id].to_s.strip
        raw_page = source_context[:page_number]
        unless importer_id == binding[:importer_id] &&
               raw_page.to_s.strip =~ /\A[1-9]\d*\z/ &&
               raw_page.to_i == binding[:page_number]
          return hard_failure(
            source_id, :source_page_evidence_mismatch,
            'page source inventory evidence belongs to a different importer or page'
          )
        end

        page_failures = source_context[:page_failures]
        failures_present = if page_failures.is_a?(Hash)
                             page_failures.any? do |_key, value|
                               !value.nil? && !value.to_s.strip.empty?
                             end
                           elsif page_failures.is_a?(Array)
                             !page_failures.empty?
                           else
                             !page_failures.nil?
                           end
        inventory_complete =
          source_context[:font_inventory_status].to_s == 'complete'
        render_complete = source_context[:render_status].to_s == 'complete'
        return nil if render_complete && inventory_complete && !failures_present

        hard_failure(
          source_id, :source_page_inventory_failed,
          'page renderer/font inventory failed; exact source absence is unproven'
        )
      rescue StandardError => e
        hard_failure(
          source_id, :source_page_inventory_failed,
          "page source inventory evidence is unreadable: #{e.message}"
        )
      end

      def self.hard_failure(source_id, reason, detail, created = [], cleaned = [],
                            cleanup = :not_required)
        {
          :source_span_id => source_id,
          :reason_code => reason,
          :detail => detail.to_s,
          :generic_failure => true,
          :affirmative_impossibility => false,
          :created_entity_ids => Array(created),
          :cleaned_entity_ids => Array(cleaned),
          :cleanup_outcome => cleanup
        }
      end

      def self.classify_host_failure(error)
        message = error.message.to_s
        return :host_face_creation_exception if message =~ /add_face|face creation/i
        return :host_extrusion_exception if message =~ /pushpull|extrud/i
        return :depth_verification_failed if message =~ /positive Z depth/i
        return :size_verification_failed if message =~ /width\/height/i
        :host_3d_text_exception
      end

      def self.cleanup_owned_group(entities, group)
        return {
          :created_entity_ids => [], :cleaned_entity_ids => [],
          :cleanup_outcome => :not_required
        } unless group
        created = [RepresentationFidelity.stable_entity_id(group)]
        cleaned = RepresentationFidelity.erase_owned!(entities, [group])
        {
          :created_entity_ids => created,
          :cleaned_entity_ids => cleaned,
          :cleanup_outcome => :verified
        }
      rescue StandardError => e
        {
          :created_entity_ids => created || [],
          :cleaned_entity_ids => [],
          :cleanup_outcome => :failed,
          :cleanup_error => e.message.to_s
        }
      end

      def self.cleanup_all_owned!(entities, groups, result)
        Array(groups).each do |group|
          cleanup = cleanup_owned_group(entities, group)
          result[:cleanup_records] = [] unless result[:cleanup_records].is_a?(Array)
          result[:cleanup_records] << cleanup
          if cleanup[:cleanup_outcome] != :verified
            result[:failures] << hard_failure(
              nil, :cleanup_failed, cleanup[:cleanup_error],
              cleanup[:created_entity_ids], cleanup[:cleaned_entity_ids],
              cleanup[:cleanup_outcome]
            )
          end
        end
      end

      def self.model_for_entities(entities)
        if entities && entities.respond_to?(:model)
          model = entities.model
          return model if model
        end
        parent = if entities && entities.respond_to?(:parent)
                   entities.parent
                 end
        return parent if parent && parent.respond_to?(:definitions)
        if parent && parent.respond_to?(:model)
          model = parent.model
          return model if model
        end
        nil
      rescue StandardError
        nil
      end

      def self.cleanup_solid_cache!(solid_cache, result)
        return true unless solid_cache
        cleaned = solid_cache.cleanup_all!
        metrics = solid_cache.metrics.merge(:enabled => true)
        metrics[:cleanup_outcome] = cleaned ?
          :verified : :transaction_abort_required
        result[:solid_cache] = metrics
        cleaned
      end

      def self.monotonic_ms
        if Process.respond_to?(:clock_gettime) &&
           defined?(Process::CLOCK_MONOTONIC)
          Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
        else
          Time.now.to_f * 1000.0
        end
      end

      def self.record_phase_ms!(result, key, started_ms)
        result[:performance] ||= {}
        result[:performance][key] =
          result[:performance].fetch(key, 0.0).to_f +
          (monotonic_ms - started_ms.to_f)
      end

      def self.publish_performance!(result, solid_cache, render_started = nil)
        result[:performance] ||= {}
        if render_started
          result[:performance][:total_ms] =
            monotonic_ms - render_started.to_f
        end
        metrics = solid_cache ? solid_cache.metrics : {}
        result[:performance][:definition_build_ms] =
          metrics.fetch(:definition_build_ms, 0.0).to_f
        result[:performance][:instance_placement_ms] =
          metrics.fetch(:instance_placement_ms, 0.0).to_f
        [
          :definition_build_ms, :instance_placement_ms, :match_ms,
          :parse_ms, :span_build_ms, :total_ms, :verification_ms
        ].each do |key|
          result[:performance][key] =
            result[:performance].fetch(key, 0.0).to_f.round(3)
        end
        result[:performance]
      end
    end
  end
end
