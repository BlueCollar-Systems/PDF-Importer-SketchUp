# bc_pdf_vector_importer/representation_fidelity.rb
# Shared fail-closed evidence and cleanup helpers for requested import modes.

require 'digest'
require 'json'

module BlueCollarSystems
  module PDFVectorImporter
    module RepresentationFidelity
      class ContractError < StandardError; end

      SOURCE_ID = /\Atext_span:([1-9]\d*):(0|[1-9]\d*)\z/.freeze
      ENTITY_ID = /\A(?:persistent_id|entity_id):[1-9]\d*\z/.freeze
      IMPORTER_ID = 'sketchup_pdf_vector_importer'.freeze
      SOURCE_EXPECTED_SCHEMA = 'bcs.source_expected/1.0'.freeze
      FLAT_TEXT_CAPABILITY_SCHEMA =
        'bcs.sketchup_flat_text_capability/1.0'.freeze
      FLAT_TEXT_HOST_API_FACT =
        'Sketchup::Entities#add_text exposes Sketchup::Text annotations/labels; ' \
        'no distinct flat editable model Text constructor is exposed'.freeze
      MODES = [:text, :labels, :text3d, :glyphs, :geometry, :raster].freeze
      LADDERS = {
        # Closest structural representation first; the final rung is always a
        # verified real raster. FallbackController is the only authority that
        # may advance this finite ladder, and it accepts only affirmative,
        # item-specific impossibility evidence with verified owned cleanup.
        text:     [:text, :labels, :text3d, :glyphs, :geometry, :raster],
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
          if from_mode == :text
            RepresentationFidelity.validate_flat_editable_text_transition!(
              proof, @requested_mode, @source_span_id, binding
            )
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
        when 'text', 'flat_text', 'editable_text' then :text
        when 'labels', 'label', 'add_text' then :labels
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

      # Some extractors expose bbox as four separate accessors; others expose a
      # single Array method returning [x0, y0, x1, y1]. Accept either form so a
      # missing bbox_x0 accessor does not block downstream placement proofs.
      def bbox_values_from_item(item)
        return nil unless item
        names = [:bbox_x0, :bbox_y0, :bbox_x1, :bbox_y1]
        if names.all? { |name| item.respond_to?(name) }
          return names.map { |name| item.send(name) }
        end
        if item.respond_to?(:bbox)
          bbox = item.bbox
          return bbox if bbox.is_a?(Array) && bbox.length == 4
        end
        nil
      rescue StandardError
        nil
      end

      def strict_source_bbox_pdf(item)
        values = bbox_values_from_item(item)
        unless values
          raise ContractError, 'source text bbox is unavailable'
        end
        values = values.map do |raw|
          raise ContractError, 'source text bbox is incomplete' if raw.nil?
          value = Float(raw)
          raise ContractError, 'source text bbox is non-finite' unless value.finite?
          canonical_number(value)
        end
        values
      rescue ContractError
        raise
      rescue StandardError => e
        raise ContractError, "source text bbox is unreadable: #{e.message}"
      end

      def sketchup_instance_method_names(constant_name)
        unless defined?(Sketchup) && Sketchup.const_defined?(constant_name)
          raise ContractError,
                "SketchUp #{constant_name} API class is unavailable"
        end
        klass = Sketchup.const_get(constant_name)
        names = klass.instance_methods.map { |name| name.to_s }.uniq.sort
        raise ContractError,
              "SketchUp #{constant_name} API inventory is empty" if names.empty?
        names
      rescue ContractError
        raise
      rescue StandardError => e
        raise ContractError,
              "SketchUp #{constant_name} API inventory failed: #{e.message}"
      end

      # SketchUp has an annotation entity named Sketchup::Text, created by
      # Entities#add_text.  It is the Labels representation: its vector is the
      # leader, not a model-space glyph rotation.  This observation-only probe
      # never creates an entity.  It proves, for one exact source item, that
      # the distinct flat editable Text representation is absent before the
      # controller may advance to Labels.
      def flat_editable_text_impossibility_proof(item)
        source_id = source_span_id(item)
        binding = proof_binding(source_id)
        source_text = item.respond_to?(:text) ? item.text.to_s : ''
        raise ContractError, 'source text content is unavailable' if source_text.empty?
        bbox = strict_source_bbox_pdf(item)
        entities_methods = sketchup_instance_method_names(:Entities)
        text_methods = sketchup_instance_method_names(:Text)
        add_text_observed = entities_methods.include?('add_text')
        annotation_methods = ['text', 'point', 'vector']
        annotation_observed = annotation_methods.all? do |name|
          text_methods.include?(name)
        end
        distinct_candidates = entities_methods.select do |name|
          name =~ /\Aadd_(?:flat|model|editable).*text\z/ ||
            name =~ /\Aadd_text_(?:flat|model|editable)\z/
        end
        unless add_text_observed && annotation_observed &&
               distinct_candidates.empty?
          raise ContractError,
                'SketchUp flat Text capability cannot be affirmatively classified'
        end
        host_version = if defined?(Sketchup) && Sketchup.respond_to?(:version)
                         Sketchup.version.to_s
                       else
                         ''
                       end
        host_major = host_version.split('.').first.to_i
        raise ContractError, 'SketchUp host version is unavailable' unless host_major > 0
        observed_entities_text_methods = entities_methods.select do |name|
          name.include?('text')
        end
        observed_text_annotation_methods = text_methods.select do |name|
          ['text', 'text=', 'point', 'point=', 'vector', 'vector=',
           'display_leader', 'display_leader=', 'display_leader?'].include?(name)
        end
        evidence = {
          :schema => FLAT_TEXT_CAPABILITY_SCHEMA,
          :source_span_id => source_id,
          :importer_id => binding[:importer_id],
          :page_number => binding[:page_number],
          :requested_mode => :text,
          :source_text_sha256 => Digest::SHA256.hexdigest(source_text),
          :source_bbox_pdf => bbox,
          :host_product => 'SketchUp',
          :host_version => host_version,
          :host_major_version => host_major,
          :entities_add_text_observed => true,
          :sketchup_text_class_observed => true,
          :sketchup_text_annotation_api_observed => true,
          :observed_entities_text_methods => observed_entities_text_methods,
          :observed_sketchup_text_annotation_methods =>
            observed_text_annotation_methods,
          :distinct_flat_text_constructor_observed => false,
          :native_flat_editable_text_available => false,
          :capability_observation_only => true,
          :host_api_fact => FLAT_TEXT_HOST_API_FACT
        }
        evidence[:evidence_sha256] = canonical_sha256(evidence)
        {
          :source_span_id => source_id,
          :importer_id => binding[:importer_id],
          :page_number => binding[:page_number],
          :requested_mode => :text,
          :scope => :item,
          :category => :exact_representation_impossible,
          :affirmative_impossibility => true,
          :generic_failure => false,
          :from_mode => :text,
          :to_mode => :labels,
          :reason_code => :host_representation_unsupported,
          :attempted_renderer =>
            'sketchup_flat_editable_text_capability_observation',
          :created_entity_ids => [],
          :cleaned_entity_ids => [],
          :cleanup_outcome => :not_required,
          :evidence => evidence
        }
      end

      def validate_flat_editable_text_transition!(proof, requested_mode,
                                                   source_id, binding = nil)
        unless proof.is_a?(Hash) &&
               normalize_mode(contract_hash_value(proof, :requested_mode)) == :text &&
               normalize_mode(requested_mode) == :text
          raise ContractError, 'flat Text capability proof request is misbound'
        end
        expected_binding = binding || proof_binding(source_id)
        evidence = contract_hash_value(proof, :evidence)
        bbox = contract_hash_value(evidence, :source_bbox_pdf)
        unless evidence.is_a?(Hash) &&
               contract_hash_value(evidence, :schema).to_s ==
                 FLAT_TEXT_CAPABILITY_SCHEMA &&
               contract_hash_value(evidence, :source_span_id).to_s ==
                 source_id.to_s &&
               contract_hash_value(evidence, :importer_id).to_s ==
                 expected_binding[:importer_id] &&
               contract_hash_value(evidence, :page_number).to_i ==
                 expected_binding[:page_number] &&
               normalize_mode(contract_hash_value(evidence, :requested_mode)) ==
                 :text &&
               contract_hash_value(
                 evidence, :source_text_sha256
               ).to_s.downcase =~ /\A[0-9a-f]{64}\z/ &&
               bbox.is_a?(Array) && bbox.length == 4 && bbox.all? do |value|
                  value.is_a?(Numeric) && value.to_f.finite?
                end
          raise ContractError, 'flat Text capability evidence source binding is invalid'
        end
        host_version = contract_hash_value(evidence, :host_version).to_s
        host_major = contract_hash_value(evidence, :host_major_version)
        entity_methods = contract_hash_value(
          evidence, :observed_entities_text_methods
        )
        annotation_methods = contract_hash_value(
          evidence, :observed_sketchup_text_annotation_methods
        )
        unless contract_hash_value(evidence, :host_product).to_s == 'SketchUp' &&
               !host_version.strip.empty? && host_major.is_a?(Integer) &&
               host_major > 0 && host_version.split('.').first.to_i == host_major &&
               contract_hash_value(evidence, :entities_add_text_observed) == true &&
               contract_hash_value(evidence, :sketchup_text_class_observed) == true &&
               contract_hash_value(
                 evidence, :sketchup_text_annotation_api_observed
               ) == true &&
               entity_methods.is_a?(Array) && entity_methods.include?('add_text') &&
               annotation_methods.is_a?(Array) &&
               ['text', 'point', 'vector'].all? do |name|
                  annotation_methods.include?(name)
                end &&
               contract_hash_value(
                 evidence, :distinct_flat_text_constructor_observed
               ) == false &&
               contract_hash_value(
                 evidence, :native_flat_editable_text_available
               ) == false &&
               contract_hash_value(evidence, :capability_observation_only) == true &&
               contract_hash_value(evidence, :host_api_fact).to_s ==
                 FLAT_TEXT_HOST_API_FACT
          raise ContractError, 'flat Text host capability evidence is invalid'
        end
        unsigned = evidence.dup
        digest = contract_hash_value(unsigned, :evidence_sha256).to_s.downcase
        unsigned.delete(:evidence_sha256)
        unsigned.delete('evidence_sha256')
        unless digest =~ /\A[0-9a-f]{64}\z/ &&
               canonical_sha256(unsigned) == digest
          raise ContractError, 'flat Text capability evidence digest is invalid'
        end
        true
      end

      def contract_hash_value(hash, key)
        return nil unless hash.is_a?(Hash)
        symbol_present = hash.key?(key)
        string_present = hash.key?(key.to_s)
        if symbol_present && string_present &&
           canonical_json(hash[key]) != canonical_json(hash[key.to_s])
          raise ContractError, "conflicting #{key} evidence aliases"
        end
        symbol_present ? hash[key] : hash[key.to_s]
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

      # Validate an explicit ownership claim without treating every concurrent
      # addition to the collection as importer-owned. A renderer may clean up
      # only references it actually received from the host API.
      def claimed_created_entities!(before_snapshot, after_snapshot, claims)
        claimed = Array(claims).compact
        return [] if claimed.empty?
        ids = stable_ids(claimed)
        preexisting = ids.select { |identity| before_snapshot[:by_id].key?(identity) }
        missing = ids.reject { |identity| after_snapshot[:by_id].key?(identity) }
        unless preexisting.empty?
          raise ContractError,
                "ownership claim includes pre-existing entities: #{preexisting.join(', ')}"
        end
        unless missing.empty?
          raise ContractError,
                "ownership claim is absent from the host collection: #{missing.join(', ')}"
        end
        claimed
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

      # Build expected host-space bounds from source outlines and the required
      # page transform. Created host bounds must never become their own source
      # expectation, because that would allow a translated artifact to certify
      # itself.
      def transformed_extent_bounds(extent, transformation, min_z = 0.0,
                                    max_z = 0.0)
        unless extent.is_a?(Array) && extent.length >= 4
          raise ContractError, 'source outline extent is unavailable'
        end
        matrix = Array(transformation)
        unless matrix.length == 16
          raise ContractError, 'source page transformation is unavailable'
        end
        values = matrix.map { |value| canonical_number(value) }
        xs = [canonical_number(extent[0]), canonical_number(extent[2])]
        ys = [canonical_number(extent[1]), canonical_number(extent[3])]
        zs = [canonical_number(min_z), canonical_number(max_z)]
        points = []
        xs.each do |x|
          ys.each do |y|
            zs.each do |z|
              points << [
                (values[0] * x) + (values[4] * y) +
                  (values[8] * z) + values[12],
                (values[1] * x) + (values[5] * y) +
                  (values[9] * z) + values[13],
                (values[2] * x) + (values[6] * y) +
                  (values[10] * z) + values[14]
              ].map { |number| canonical_number(number) }
            end
          end
        end
        {
          :min => 3.times.map { |axis| points.map { |point| point[axis] }.min },
          :max => 3.times.map { |axis| points.map { |point| point[axis] }.max }
        }
      end

      # Evidence is deliberately derived from the physical host entities, not
      # from the report flags which describe them.  The same canonical payload
      # is captured again by the guarded host after save/reopen.
      def canonical_number(value)
        number = value.to_f
        raise ContractError, 'evidence contains a non-finite number' unless number.finite?
        rounded = (number * 1.0e9).round / 1.0e9
        rounded == -0.0 ? 0.0 : rounded
      end

      def canonical_value(value)
        case value
        when Hash
          result = {}
          value.keys.map { |key| key.to_s }.uniq.sort.each do |name|
            key = value.keys.find { |candidate| candidate.to_s == name }
            result[name] = canonical_value(value[key])
          end
          result
        when Array
          value.map { |entry| canonical_value(entry) }
        when Numeric
          canonical_number(value)
        when Symbol
          value.to_s
        when true, false, nil
          value
        else
          value.to_s
        end
      end

      def canonical_json(value)
        JSON.generate(canonical_value(value))
      end

      def canonical_sha256(value)
        Digest::SHA256.hexdigest(canonical_json(value))
      end

      def entity_type(entity)
        return entity.typename.to_s if entity.respond_to?(:typename)
        entity.class.name.to_s.split('::').last
      rescue StandardError
        ''
      end

      def entity_children(entity)
        collection = if entity.respond_to?(:entities)
                       entity.entities
                     elsif entity.respond_to?(:definition) && entity.definition &&
                           entity.definition.respond_to?(:entities)
                       entity.definition.entities
                     end
        return [] unless collection && collection.respond_to?(:to_a)
        Array(collection.to_a)
      rescue StandardError
        []
      end

      def entity_bounds_payload(entity)
        return nil unless entity.respond_to?(:bounds)
        box = entity.bounds
        return nil unless box && box.respond_to?(:min) && box.respond_to?(:max)
        low = numeric_point(box.min)
        high = numeric_point(box.max)
        return nil unless low && high
        { :min => low, :max => high }
      rescue StandardError
        nil
      end

      def entity_transformation_payload(entity)
        return nil unless entity.respond_to?(:transformation)
        transform = entity.transformation
        return nil unless transform && transform.respond_to?(:to_a)
        values = Array(transform.to_a)
        return nil if values.empty?
        values.map { |value| canonical_number(value) }
      rescue StandardError
        nil
      end

      def vertex_position(vertex)
        point = vertex.respond_to?(:position) ? vertex.position : vertex
        numeric_point(point)
      rescue StandardError
        nil
      end

      def ordered_points(values)
        points = Array(values).map { |value| vertex_position(value) }.compact
        points.map { |point| point.map { |number| canonical_number(number) } }.sort_by do |point|
          point.join(',')
        end
      end

      def edge_points(entity)
        return [] unless entity.respond_to?(:start) && entity.respond_to?(:end)
        ordered_points([entity.start, entity.end])
      rescue StandardError
        []
      end

      def face_loops(entity)
        if entity.respond_to?(:loops)
          loops = Array(entity.loops).map do |loop|
            vertices = loop.respond_to?(:vertices) ? loop.vertices : []
            ordered_points(vertices)
          end
          return loops.reject { |points| points.empty? }.sort_by do |points|
            canonical_json(points)
          end
        end
        vertices = entity.respond_to?(:vertices) ? entity.vertices : []
        points = ordered_points(vertices)
        points.empty? ? [] : [points]
      rescue StandardError
        []
      end

      def geometry_entity_payload(entity, child_payloads = nil)
        type = entity_type(entity)
        payload = {
          :type => type,
          :bounds => entity_bounds_payload(entity),
          :transformation => entity_transformation_payload(entity)
        }
        if type == 'Edge'
          payload[:endpoints] = edge_points(entity)
        elsif type == 'Face'
          payload[:loops] = face_loops(entity)
        elsif type == 'Text'
          payload[:anchor] = numeric_point(entity.point) if entity.respond_to?(:point)
          payload[:text_sha256] = Digest::SHA256.hexdigest(entity.text.to_s) if
            entity.respond_to?(:text)
        elsif type == 'Image'
          payload[:width] = canonical_number(entity.width) if entity.respond_to?(:width)
          payload[:height] = canonical_number(entity.height) if entity.respond_to?(:height)
        end
        children = if child_payloads.nil?
                     entity_children(entity).map do |child|
                       geometry_entity_payload(child)
                     end
                   else
                     Array(child_payloads)
                   end
        payload[:children] = children.sort_by { |child| canonical_json(child) }
        payload
      end

      def visible_state(entity)
        return false if entity.respond_to?(:hidden?) && entity.hidden? == true
        return false if entity.respond_to?(:visible?) && entity.visible? == false
        true
      rescue StandardError
        nil
      end

      def layer_payload(entity)
        layer = entity.respond_to?(:layer) ? entity.layer : nil
        return { :name => nil, :visible => nil } unless layer
        visible = if layer.respond_to?(:visible?)
                    layer.visible?
                  elsif layer.respond_to?(:visible)
                    layer.visible
                  end
        {
          :name => layer.respond_to?(:name) ? layer.name.to_s : layer.to_s,
          :visible => visible == true ? true : (visible == false ? false : nil)
        }
      rescue StandardError
        { :name => nil, :visible => nil }
      end

      def color_payload(color)
        return nil unless color
        values = {}
        [:red, :green, :blue, :alpha].each do |name|
          values[name] = color.send(name).to_i if color.respond_to?(name)
        end
        values.empty? ? color.to_s : values
      rescue StandardError
        nil
      end

      def material_payload(material)
        return nil unless material
        {
          :name => material.respond_to?(:name) ? material.name.to_s : material.to_s,
          :color => material.respond_to?(:color) ? color_payload(material.color) : nil,
          :alpha => material.respond_to?(:alpha) ? canonical_number(material.alpha) : nil
        }
      rescue StandardError
        nil
      end

      def style_entity_payload(entity, child_payloads = nil)
        layer = layer_payload(entity)
        payload = {
          :type => entity_type(entity),
          :entity_visible => visible_state(entity),
          :layer_name => layer[:name],
          :layer_visible => layer[:visible],
          :material => entity.respond_to?(:material) ?
            material_payload(entity.material) : nil,
          :back_material => entity.respond_to?(:back_material) ?
            material_payload(entity.back_material) : nil,
          :casts_shadows => entity.respond_to?(:casts_shadows?) ?
            entity.casts_shadows? : nil,
          :receives_shadows => entity.respond_to?(:receives_shadows?) ?
            entity.receives_shadows? : nil
        }
        children = if child_payloads.nil?
                     entity_children(entity).map do |child|
                       style_entity_payload(child)
                     end
                   else
                     Array(child_payloads)
                   end
        payload[:children] = children.sort_by { |child| canonical_json(child) }
        payload
      end

      def recursive_entity_count(entity)
        1 + entity_children(entity).inject(0) do |total, child|
          total + recursive_entity_count(child)
        end
      end

      # Capture geometry, style, and descendants in one host walk.  Callers
      # that already walked the descendants (the guarded save/reopen manifest)
      # can supply their child trees and avoid repeatedly enumerating the same
      # potentially enormous SketchUp collections.
      def physical_entity_tree(entity, child_trees = nil)
        children = if child_trees.nil?
                     entity_children(entity).map do |child|
                       physical_entity_tree(child)
                     end
                   else
                     Array(child_trees)
                   end
        geometry = geometry_entity_payload(
          entity, children.map { |child| child[:geometry_payload] }
        )
        style = style_entity_payload(
          entity, children.map { |child| child[:style_payload] }
        )
        direct_types = children.map do |child|
          child[:topology][:root_type].to_s
        end.sort
        descendant_counts = {}
        children.each do |child|
          child_topology = child[:topology]
          root_type = child_topology[:root_type].to_s
          descendant_counts[root_type] =
            descendant_counts.fetch(root_type, 0) + 1
          child_topology[:descendant_type_counts].each do |name, count|
            key = name.to_s
            descendant_counts[key] =
              descendant_counts.fetch(key, 0) + count.to_i
          end
        end
        descendant_counts = descendant_counts.keys.sort.inject({}) do |memo, key|
          memo[key] = descendant_counts[key]
          memo
        end
        live = entity.respond_to?(:valid?) && entity.valid? == true &&
          entity.respond_to?(:deleted?) && entity.deleted? == false
        {
          :geometry_payload => geometry,
          :style_payload => style,
          :physical_entity_count => 1 + children.inject(0) do |total, child|
            total + child[:physical_entity_count].to_i
          end,
          :topology => {
            :root_type => geometry[:type].to_s,
            :direct_child_types => direct_types,
            :descendant_type_counts => descendant_counts,
            :descendant_entity_count => descendant_counts.values.inject(0, :+),
            :live_entity_count => (live ? 1 : 0) + children.inject(0) do |total, child|
              total + child[:topology][:live_entity_count].to_i
            end
          }
        }
      end

      # Component definitions are immutable while one synchronous import
      # delivery is being finalized. Reuse their already-captured physical
      # child trees, while rebuilding every instance root so its own bounds,
      # transform, style, liveness, and topology remain independently hashed.
      def physical_entity_tree_with_definition_cache(entity, cache)
        definition_key = shared_component_definition_key(entity)
        children = if definition_key && cache.key?(definition_key)
                     cache[definition_key]
                   else
                     entity_children(entity).map do |child|
                       physical_entity_tree_with_definition_cache(child, cache)
                     end
                   end
        cache[definition_key] = children if definition_key &&
          !cache.key?(definition_key)
        physical_entity_tree(entity, children)
      end

      def shared_component_definition_key(entity)
        return nil if entity.respond_to?(:entities)
        return nil unless entity_type(entity) == 'ComponentInstance'
        return nil unless entity.respond_to?(:definition)
        definition = entity.definition
        return nil unless definition && definition.respond_to?(:entities)
        definition.object_id
      rescue StandardError
        nil
      end

      def physical_evidence_from_trees(trees)
        values = Array(trees).compact
        raise ContractError, 'physical evidence has no entity trees' if
          values.empty?
        geometry = values.map { |tree| tree[:geometry_payload] }
        geometry = geometry.sort_by { |entry| canonical_json(entry) }
        style = values.map { |tree| tree[:style_payload] }
        style = style.sort_by { |entry| canonical_json(entry) }
        {
          :geometry_payload => geometry,
          :style_payload => style,
          :physical_geometry_sha256 => canonical_sha256(geometry),
          :physical_style_sha256 => canonical_sha256(style),
          :physical_entity_count => values.inject(0) do |total, tree|
            total + tree[:physical_entity_count].to_i
          end
        }
      end

      def physical_evidence(entities, definition_tree_cache = nil)
        values = Array(entities).compact
        raise ContractError, 'physical evidence has no entities' if values.empty?
        cache = definition_tree_cache
        unless cache.nil? || cache.is_a?(Hash)
          raise ContractError, 'physical definition tree cache must be a Hash'
        end
        physical_evidence_from_trees(
          values.map do |entity|
            if cache
              physical_entity_tree_with_definition_cache(entity, cache)
            else
              physical_entity_tree(entity)
            end
          end
        )
      end

      def source_bbox_pdf(item)
        values = bbox_values_from_item(item)
        return nil unless values
        values.map { |raw| canonical_number(raw) }
      rescue StandardError
        nil
      end

      def source_font_descriptor(item, supplied = nil)
        return supplied unless supplied.nil? || supplied.to_s.empty?
        descriptor = {}
        [:font_name, :font_family, :font, :font_size, :font_size_pts,
         :font_flags, :bold, :italic].each do |name|
          descriptor[name] = item.send(name) if item.respond_to?(name)
        end
        descriptor
      rescue StandardError
        {}
      end

      def source_rotation_degrees(item)
        [:angle, :rotation_degrees, :rotation, :angle_degrees].each do |name|
          next unless item.respond_to?(name)
          value = item.send(name)
          return canonical_number(value) unless value.nil?
        end
        0.0
      rescue StandardError
        0.0
      end

      def source_expected_evidence(item, mode, values)
        raise ContractError, 'source evidence values must be a Hash' unless values.is_a?(Hash)
        normalized_mode = normalize_mode(mode)
        raise ContractError, 'source evidence representation is invalid' unless normalized_mode
        source_id = source_span_id(item)
        text = item.respond_to?(:text) ? item.text.to_s : values[:source_text].to_s
        physical = physical_evidence(
          values[:entities], values[:physical_definition_tree_cache]
        )
        evidence = {
          :schema => SOURCE_EXPECTED_SCHEMA,
          :source_span_id => source_id,
          :representation => normalized_mode,
          :source_text_sha256 => Digest::SHA256.hexdigest(text),
          :source_bbox_pdf => values[:source_bbox_pdf] || source_bbox_pdf(item),
          :source_anchor => values[:source_anchor],
          :source_rotation_radians => canonical_number(values[:source_rotation_radians] || 0.0),
          :source_font_sha256 => canonical_sha256(
            source_font_descriptor(item, values[:source_font_identity])
          ),
          :expected_width => canonical_number(values[:expected_width] || 0.0),
          :expected_height => canonical_number(values[:expected_height] || 0.0),
          :expected_depth => canonical_number(values[:expected_depth] || 0.0),
          :expected_bounds => values[:expected_bounds],
          :expected_transformation => values[:expected_transformation],
          :physical_geometry_sha256 => physical[:physical_geometry_sha256],
          :physical_style_sha256 => physical[:physical_style_sha256],
          :physical_entity_count => physical[:physical_entity_count]
        }
        evidence[:evidence_sha256] = canonical_sha256(evidence)
        evidence
      end

      def attach_source_evidence!(entities, evidence, renderer = nil)
        unless evidence.is_a?(Hash) &&
               evidence[:schema].to_s == SOURCE_EXPECTED_SCHEMA &&
               evidence[:evidence_sha256].to_s =~ /\A[0-9a-f]{64}\z/
          raise ContractError, 'source expected evidence is incomplete'
        end
        Array(entities).compact.each do |entity|
          if entity.respond_to?(:set_attribute)
            dictionary = 'BC_PDF_Importer'
            entity.set_attribute(dictionary, 'source_claim_root', true)
            entity.set_attribute(dictionary, 'source_span_id', evidence[:source_span_id].to_s)
            entity.set_attribute(dictionary, 'source_kind', 'text_span')
            entity.set_attribute(dictionary, 'representation', evidence[:representation].to_s)
            entity.set_attribute(dictionary, 'renderer', renderer.to_s) unless renderer.to_s.empty?
            entity.set_attribute(dictionary, 'source_evidence_sha256', evidence[:evidence_sha256])
            entity.set_attribute(dictionary, 'source_text_sha256', evidence[:source_text_sha256])
            entity.set_attribute(dictionary, 'physical_geometry_sha256',
                                 evidence[:physical_geometry_sha256])
            entity.set_attribute(dictionary, 'physical_style_sha256',
                                 evidence[:physical_style_sha256])
          end
        end
        true
      end
    end
  end
end
