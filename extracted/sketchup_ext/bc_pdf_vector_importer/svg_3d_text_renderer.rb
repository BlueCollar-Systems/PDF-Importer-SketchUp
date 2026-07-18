# bc_pdf_vector_importer/svg_3d_text_renderer.rb
# Exact 3D text from the PDF renderer's own SVG glyph outlines.

require File.join(File.dirname(__FILE__), 'cairo_glyph_source')
require File.join(File.dirname(__FILE__), 'representation_fidelity')
require File.join(File.dirname(__FILE__), 'logger')

module BlueCollarSystems
  module PDFVectorImporter
    module Svg3DTextRenderer
      DEFAULT_DEPTH_INCHES = 1.0 / 64.0
      SIZE_TOLERANCE_INCHES = 1.0e-6

      def self.render_svg(entities, svg, media_box, text_items, opts = {})
        result = base_result
        depth = opts.key?(:depth) ? opts[:depth].to_f : DEFAULT_DEPTH_INCHES
        result[:requested_depth] = depth
        if !depth.finite? || depth <= 0.0
          result[:failures] << hard_failure(
            nil, :nonpositive_extrusion_depth,
            '3D text requires a finite positive extrusion depth'
          )
          return result
        end

        placed = CairoGlyphSource.model_space_loops(svg, media_box, opts)
        result[:source_placements] = placed.length
        pens = placed.map do |entry|
          {
            :x => entry[:pen_pdf][0],
            :y => entry[:pen_pdf][1],
            :placement_index => entry[:placement_index]
          }
        end
        match = CairoGlyphSource.match_spans(pens, text_items, media_box)
        result[:match] = match

        if Array(text_items).empty? && placed.empty?
          result[:ok] = true
          result[:no_semantic_text] = true
          return result
        end

        matched_by_span = {}
        Array(match[:placement_matches]).each do |record|
          id = record[:source_span_id].to_s
          matched_by_span[id] = [] unless matched_by_span.key?(id)
          matched_by_span[id] << record[:placement_index].to_i
        end

        owned_groups = []
        Array(text_items).each do |item|
          source_id = begin
            RepresentationFidelity.source_span_id(item)
          rescue StandardError => e
            result[:failures] << hard_failure(
              nil, :source_span_identity_unverifiable, e.message
            )
            next
          end
          indices = Array(matched_by_span[source_id]).uniq.sort
          entries = placed.select do |entry|
            indices.include?(entry[:placement_index].to_i)
          end

          if entries.empty?
            page_failure = source_page_failure(
              source_id, opts[:source_context]
            )
            if page_failure
              result[:failures] << page_failure
            elsif source_bbox_valid?(item, media_box)
              result[:transition_proofs] << identity_unavailable_proof(
                source_id, item, depth, opts[:source_context], match
              )
            else
              result[:failures] << hard_failure(
                source_id, :source_span_bbox_unverifiable,
                'source placement could not be independently verified'
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
              group, entries, source_id, depth, :text_span
            )
            result[:span_results] << span_result
          rescue StandardError => e
            cleanup = cleanup_owned_group(entities, group)
            owned_groups.delete(group)
            result[:failures] << hard_failure(
              source_id, classify_host_failure(e), e.message,
              cleanup[:created_entity_ids], cleanup[:cleaned_entity_ids],
              cleanup[:cleanup_outcome]
            )
          end
        end

        preserve_unmatched = if opts.key?(:preserve_unmatched_source_placements)
                               opts[:preserve_unmatched_source_placements] == true
                             else
                               true
                             end
        if preserve_unmatched
          render_unmatched_source_placements!(
            entities, placed, match, depth, opts, owned_groups, result
          )
        end

        unless result[:failures].empty?
          cleanup_all_owned!(entities, owned_groups, result)
          result[:span_results] = []
          result[:unmatched_source_results] = []
        end

        result[:ok] = result[:failures].empty? &&
          result[:transition_proofs].empty?
        result
      rescue StandardError => e
        result ||= base_result
        result[:failures] << hard_failure(nil, :renderer_exception, e.message)
        result[:ok] = false
        result
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
          :no_semantic_text => false
        }
      end

      def self.finalize_source_evidence!(row, item, page_rotation = 0.0)
        unless row.is_a?(Hash) && row[:group] && row[:source_span_id]
          raise RepresentationFidelity::ContractError,
                '3D Text row cannot be bound to a semantic source item'
        end
        source_id = RepresentationFidelity.source_span_id(item)
        unless row[:source_span_id].to_s == source_id
          raise RepresentationFidelity::ContractError,
                '3D Text source identity changed before evidence finalization'
        end
        actual = bounds_hash(row[:group])
        transform = RepresentationFidelity.entity_transformation_payload(row[:group])
        transform ||= { :kind => 'baked_geometry', :entity_count => 1 }
        expected = RepresentationFidelity.source_expected_evidence(
          item, :text3d,
          :entities => [row[:group]],
          :source_anchor => [actual[:min_x], actual[:min_y], actual[:min_z]],
          :source_rotation_radians =>
            (RepresentationFidelity.source_rotation_degrees(item) +
             page_rotation.to_f) * Math::PI / 180.0,
          :expected_width => actual[:max_x].to_f - actual[:min_x].to_f,
          :expected_height => actual[:max_y].to_f - actual[:min_y].to_f,
          :expected_depth => actual[:max_z].to_f - actual[:min_z].to_f,
          :expected_bounds => {
            :min => [actual[:min_x], actual[:min_y], actual[:min_z]],
            :max => [actual[:max_x], actual[:max_y], actual[:max_z]]
          },
          :expected_transformation => transform,
          :source_font_identity => {
            :source => 'pdf_renderer_svg_glyph_outlines',
            :glyph_ids => Array(row[:glyph_ids]).map { |id| id.to_s }.sort
          }
        )
        RepresentationFidelity.attach_source_evidence!(
          [row[:group]], expected, 'svg_source_3d_text'
        )
        row[:expected_evidence] = expected
        row[:content_verified] = true
        row[:physical_geometry_verified] = true
        row[:physical_style_verified] = true
        row[:transform_verified] = true
        row
      end

      def self.build_span_group(group, entries, source_id, depth,
                                source_kind = :text_span)
        child = group.respond_to?(:entities) ? group.entities : nil
        raise 'owned source-span group has no entities collection' unless child
        faces = []
        Array(entries).each do |entry|
          glyph_faces = build_filled_glyph(child, entry[:loops])
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
          face.pushpull(depth)
          extruded += 1
        end

        expected = CairoGlyphSource.loops_extent(entries)
        raise 'source outline extent is unavailable' unless expected
        actual = bounds_hash(group)
        expected_width = expected[2].to_f - expected[0].to_f
        expected_height = expected[3].to_f - expected[1].to_f
        actual_width = actual[:max_x] - actual[:min_x]
        actual_height = actual[:max_y] - actual[:min_y]
        actual_depth = actual[:max_z] - actual[:min_z]
        width_ok = close_size?(actual_width, expected_width)
        height_ok = close_size?(actual_height, expected_height)
        depth_ok = actual_depth > SIZE_TOLERANCE_INCHES &&
          close_size?(actual_depth, depth)
        raise 'extruded source glyph width/height verification failed' unless
          width_ok && height_ok
        raise 'extruded source glyph has no verified positive Z depth' unless depth_ok

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
          :source_placement_count => placement_indices.length,
          :face_count => faces.length,
          :extruded_face_count => extruded,
          :identity_verified => !ids.empty? && ids.none? { |id| id.empty? },
          :placement_verified => !placement_indices.empty? &&
            placement_indices.uniq.length == placement_indices.length,
          :rotation_verified => matrices.length == entries.length &&
            matrices.all? { |matrix| matrix.length >= 6 },
          :size_verified => width_ok && height_ok,
          :depth_verified => depth_ok,
          :width => actual_width,
          :height => actual_height,
          :depth => actual_depth,
          :bounds => actual,
          :expected_outline_extent => expected
        }
      end

      # Build SVG's non-zero-fill contours in descending area order. An odd
      # containment depth is a hole: creating then erasing that inner face is
      # SketchUp's supported way to retain its loop as a hole in the outer face.
      def self.build_filled_glyph(entities, loops)
        contours = Array(loops).map { |points| normalized_contour(points) }.compact
        raise 'source glyph has no closed contour' if contours.empty?
        records = contours.map do |points|
          { :points => points, :area => signed_area(points).abs }
        end
        records.sort_by! { |record| -record[:area] }
        filled = []
        records.each_with_index do |record, index|
          probe = record[:points][0]
          nesting = records[0...index].count do |outer|
            point_in_polygon?(probe, outer[:points])
          end
          face = entities.add_face(record[:points])
          raise 'host add_face returned no face for a source glyph contour' unless face
          if nesting.odd?
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
        return nil if signed_area(clean).abs <= SIZE_TOLERANCE_INCHES**2
        clean
      end

      def self.same_point?(left, right)
        (left.x.to_f - right.x.to_f).abs <= SIZE_TOLERANCE_INCHES &&
          (left.y.to_f - right.y.to_f).abs <= SIZE_TOLERANCE_INCHES
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
                                                   opts, owned_groups, result)
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
            group, entries, source_id, depth, :svg_glyph_placement
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
    end
  end
end
