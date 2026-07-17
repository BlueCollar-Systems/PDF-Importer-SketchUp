# bc_pdf_vector_importer/representation_fidelity.rb
# Shared fail-closed evidence and cleanup helpers for requested import modes.

module BlueCollarSystems
  module PDFVectorImporter
    module RepresentationFidelity
      class ContractError < StandardError; end

      SOURCE_ID = /\Atext_span:([1-9]\d*):(0|[1-9]\d*)\z/.freeze
      ENTITY_ID = /\A(?:persistent_id|entity_id):[1-9]\d*\z/.freeze
      IMPORTER_ID = 'sketchup_pdf_vector_importer'.freeze
      MODES = [:labels, :text3d, :glyphs, :geometry, :raster].freeze
      LADDERS = {
        # Closest structural representation first; the final rung is always a
        # verified real raster. FallbackController is the only authority that
        # may advance this finite ladder, and it accepts only affirmative,
        # item-specific impossibility evidence with verified owned cleanup.
        labels:   [:labels, :text3d, :glyphs, :geometry, :raster],
        text3d:   [:text3d, :glyphs, :geometry, :raster],
        glyphs:   [:glyphs, :geometry, :raster],
        geometry: [:geometry, :raster],
        raster:   [:raster]
      }.freeze

      AFFIRMATIVE_REASON_CODES = [
        :verified_source_representation_impossible,
        :source_item_identity_unavailable,
        :source_vector_geometry_absent,
        :host_representation_unsupported
      ].freeze

      STOP_REASON_CODES = [
        :exception,
        :empty_artifact,
        :renderer_missing,
        :renderer_failed,
        :helper_failed,
        :timeout,
        :placement_verification_failed,
        :visual_verification_failed,
        :cleanup_failed,
        :cleanup_unverified
      ].freeze

      # Owns one source item's finite representation ladder. A renderer may
      # report a failure, but only this controller can decide whether that
      # failure is affirmative proof of impossibility or a hard stop.
      class FallbackController
        attr_reader :requested_mode, :source_span_id, :current_mode,
                    :transitions

        def initialize(requested_mode, source_span_id)
          @requested_mode = RepresentationFidelity.normalize_mode(requested_mode)
          raise ContractError, 'requested representation mode is invalid' unless @requested_mode
          @source_span_id = RepresentationFidelity.source_span_id(source_span_id)
          @ladder = RepresentationFidelity.ladder_for(@requested_mode)
          raise ContractError, 'requested representation ladder is unavailable' if @ladder.empty?
          @current_mode = @ladder.first
          @transitions = []
        end

        def terminal?
          @current_mode == @ladder.last
        end

        def next_mode
          index = @ladder.index(@current_mode)
          return nil unless index
          @ladder[index + 1]
        end

        def advance!(proof)
          raise ContractError, 'representation ladder is already terminal' if terminal?
          normalized = validate_transition_proof!(proof)
          @transitions << normalized
          @current_mode = normalized[:to_mode]
        end

        private

        def validate_transition_proof!(proof)
          raise ContractError, 'transition proof must be a Hash' unless proof.is_a?(Hash)
          source_id = RepresentationFidelity.source_span_id(proof[:source_span_id])
          unless source_id == @source_span_id
            raise ContractError, 'transition proof belongs to a different source span'
          end
          binding = RepresentationFidelity.proof_binding(source_id)
          importer_id = proof[:importer_id].to_s.strip
          unless importer_id == binding[:importer_id]
            raise ContractError, 'transition proof belongs to a different importer'
          end
          raw_page = proof[:page_number]
          unless raw_page.to_s.strip =~ /\A[1-9]\d*\z/ &&
                 raw_page.to_i == binding[:page_number]
            raise ContractError, 'transition proof belongs to a different page'
          end
          unless proof[:scope] == :item
            raise ContractError, 'transition proof must be item-scoped'
          end
          unless proof[:category] == :exact_representation_impossible
            raise ContractError, 'transition proof is not an exact-representation impossibility'
          end
          unless proof[:affirmative_impossibility] == true
            raise ContractError, 'transition proof is not affirmative'
          end
          unless proof[:generic_failure] == false
            raise ContractError, 'generic failure cannot authorize a representation transition'
          end

          reason = normalize_reason(proof[:reason_code])
          if STOP_REASON_CODES.include?(reason)
            raise ContractError,
              "#{reason} cannot authorize a representation transition"
          end
          unless AFFIRMATIVE_REASON_CODES.include?(reason)
            raise ContractError, 'transition proof reason is not an approved impossibility fact'
          end

          from_mode = RepresentationFidelity.normalize_mode(proof[:from_mode])
          to_mode = RepresentationFidelity.normalize_mode(proof[:to_mode])
          unless from_mode == @current_mode
            raise ContractError, 'transition proof does not begin at the current rung'
          end
          unless to_mode == next_mode
            raise ContractError, 'transition proof must advance exactly one adjacent rung'
          end

          renderer = proof[:attempted_renderer].to_s.strip
          raise ContractError, 'transition proof is missing the attempted renderer' if renderer.empty?
          evidence = proof[:evidence]
          unless evidence.is_a?(Hash) && !evidence.empty? &&
                 evidence.values.any? { |value| !value.to_s.strip.empty? }
            raise ContractError, 'transition proof has no affirmative evidence'
          end

          created = validated_entity_ids(proof[:created_entity_ids], 'created')
          cleaned = validated_entity_ids(proof[:cleaned_entity_ids], 'cleaned')
          cleanup = proof[:cleanup_outcome]
          if created.empty?
            unless cleaned.empty? && [:not_required, :verified].include?(cleanup)
              raise ContractError, 'transition cleanup proof is inconsistent'
            end
          else
            unless cleanup == :verified && created.sort == cleaned.sort
              raise ContractError, 'every owned artifact must be verifiably cleaned before transition'
            end
          end

          normalized = proof.dup
          normalized[:source_span_id] = source_id
          normalized[:importer_id] = importer_id
          normalized[:page_number] = raw_page.to_i
          normalized[:from_mode] = from_mode
          normalized[:to_mode] = to_mode
          normalized[:reason_code] = reason
          normalized[:created_entity_ids] = created
          normalized[:cleaned_entity_ids] = cleaned
          normalized
        end

        def normalize_reason(value)
          value.to_s.strip.downcase.to_sym
        rescue StandardError
          nil
        end

        def validated_entity_ids(value, label)
          unless value.is_a?(Array)
            raise ContractError, "#{label} entity identities must be an Array"
          end
          return [] if value.empty?
          ids = RepresentationFidelity.positive_entity_ids(value)
          raise ContractError, "#{label} entity identities are malformed" unless ids
          ids
        end
      end

      module_function

      def normalize_mode(value)
        case value.to_s.strip.downcase
        when 'labels', 'label', 'text', 'add_text' then :labels
        when 'text3d', '3d_text', '3d text', 'add_3d_text' then :text3d
        when 'glyphs', 'glyph', 'glyph_outline' then :glyphs
        when 'geometry', 'outlines', 'outline', 'page_path_geometry' then :geometry
        when 'raster', 'image' then :raster
        else nil
        end
      end

      def ladder_for(value)
        LADDERS[normalize_mode(value)] || []
      end

      def proof_binding(value)
        identity = source_span_id(value)
        match = SOURCE_ID.match(identity)
        raise ContractError, 'source span page binding is unavailable' unless match
        {
          :importer_id => IMPORTER_ID,
          :page_number => match[1].to_i
        }
      end

      # Exact SVG representations need a single owned page container. It is
      # the unit used for post-transform verification and, if every
      # item-specific ladder reaches raster, atomic cleanup. A display/grouping
      # preference may not silently disable the requested representation.
      def owned_page_group_policy(requested_group_per_page, renderer)
        renderer_name = renderer.to_s.strip
        requires_owner = ['svg_text', 'svg_3d_text'].include?(renderer_name)
        forced = requires_owner && requested_group_per_page == false
        {
          :effective_group_per_page => requires_owner ? true :
            requested_group_per_page != false,
          :forced => forced,
          :reason_code => forced ?
            :representation_entity_ownership_required : nil
        }
      end

      def source_span_id(value)
        text = if value.respond_to?(:source_span_id)
                 value.source_span_id.to_s.strip
               else
                 value.to_s.strip
               end
        raise ContractError, 'source span identity is missing or malformed' unless text =~ SOURCE_ID
        text
      rescue ContractError
        raise
      rescue StandardError => e
        raise ContractError, "source span identity is unreadable: #{e.message}"
      end

      def stable_entity_id(entity)
        raise ContractError, 'entity is nil' if entity.nil?
        candidates = [[:persistent_id, 'persistent_id'], [:entityID, 'entity_id']]
        candidates.each do |method_name, prefix|
          next unless entity.respond_to?(method_name)
          raw = entity.send(method_name)
          next if raw == true || raw == false || raw.nil?
          number = raw.to_i
          next unless number > 0 && raw.to_s.strip =~ /\A\d+\z/
          return "#{prefix}:#{number}"
        end
        raise ContractError, 'entity has no positive numeric stable host identity'
      rescue ContractError
        raise
      rescue StandardError => e
        raise ContractError, "entity stable identity is unreadable: #{e.message}"
      end

      def stable_entity_map(values)
        raise ContractError, 'entity collection is not an Array' unless values.is_a?(Array)
        map = {}
        values.each do |entity|
          identity = stable_entity_id(entity)
          raise ContractError, "duplicate stable entity identity #{identity}" if map.key?(identity)
          map[identity] = entity
        end
        map
      end

      def snapshot(collection)
        raise ContractError, 'entity collection cannot be enumerated' unless collection.respond_to?(:to_a)
        values = Array(collection.to_a)
        { entities: values, by_id: stable_entity_map(values) }
      rescue ContractError
        raise
      rescue StandardError => e
        raise ContractError, "entity snapshot failed: #{e.message}"
      end

      def created_between(before_snapshot, after_snapshot)
        before_ids = before_snapshot[:by_id].keys
        ids = after_snapshot[:by_id].keys.reject { |identity| before_ids.include?(identity) }
        ids.map { |identity| after_snapshot[:by_id][identity] }
      end

      def stable_ids(values)
        stable_entity_map(Array(values))
        Array(values).map { |entity| stable_entity_id(entity) }
      end

      def erase_owned!(collection, entities)
        doomed = Array(entities).compact
        return [] if doomed.empty?
        ids = stable_ids(doomed)
        raise ContractError, 'entity collection cannot erase owned artifacts' unless collection.respond_to?(:erase_entities)
        collection.erase_entities(*doomed)
        remaining = snapshot(collection)[:by_id]
        live = ids.select { |identity| remaining.key?(identity) }
        raise ContractError, "owned artifact cleanup is unverifiable: #{live.join(', ')}" unless live.empty?
        ids
      rescue ContractError
        raise
      rescue StandardError => e
        raise ContractError, "owned artifact cleanup failed: #{e.message}"
      end

      def positive_entity_ids(value)
        return nil unless value.is_a?(Array) && !value.empty?
        ids = value.map { |identity| identity.to_s.strip }
        return nil unless ids.uniq.length == ids.length
        return nil unless ids.all? { |identity| identity =~ ENTITY_ID }
        ids
      rescue StandardError
        nil
      end

      def numeric_point(point)
        return nil unless point && point.respond_to?(:x) && point.respond_to?(:y)
        x = point.x.to_f
        y = point.y.to_f
        z = point.respond_to?(:z) ? point.z.to_f : 0.0
        return nil unless x.finite? && y.finite? && z.finite?
        [x, y, z]
      rescue StandardError
        nil
      end

      def bounds(values)
        mins = [nil, nil, nil]
        maxs = [nil, nil, nil]
        Array(values).each do |entity|
          next unless entity.respond_to?(:bounds)
          box = entity.bounds
          low = numeric_point(box.min)
          high = numeric_point(box.max)
          next unless low && high
          3.times do |axis|
            mins[axis] = low[axis] if mins[axis].nil? || low[axis] < mins[axis]
            maxs[axis] = high[axis] if maxs[axis].nil? || high[axis] > maxs[axis]
          end
        end
        raise ContractError, 'created entity bounds are unavailable' if mins.any? { |v| v.nil? }
        {
          min_x: mins[0], min_y: mins[1], min_z: mins[2],
          max_x: maxs[0], max_y: maxs[1], max_z: maxs[2],
          width: maxs[0] - mins[0], height: maxs[1] - mins[1]
        }
      rescue ContractError
        raise
      rescue StandardError => e
        raise ContractError, "created entity bounds are unreadable: #{e.message}"
      end

      def close?(actual, expected, tolerance)
        (actual.to_f - expected.to_f).abs <= tolerance.to_f
      end

      def expected_rotated_bounds(anchor, width, height, angle_degrees)
        point = numeric_point(anchor)
        raise ContractError, 'target anchor is unreadable' unless point
        radians = angle_degrees.to_f * Math::PI / 180.0
        c = Math.cos(radians)
        s = Math.sin(radians)
        corners = [[0.0, 0.0], [width, 0.0], [width, height], [0.0, height]]
        xs = []
        ys = []
        corners.each do |x, y|
          xs << point[0] + (x * c) - (y * s)
          ys << point[1] + (x * s) + (y * c)
        end
        { min_x: xs.min, max_x: xs.max, min_y: ys.min, max_y: ys.max,
          width: xs.max - xs.min, height: ys.max - ys.min }
      end
    end
  end
end
