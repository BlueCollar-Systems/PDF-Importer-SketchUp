# bc_pdf_vector_importer/import_run_control.rb
# Deterministic workload, progress, and cancellation control.
# Ruby 2.2 compatible.

require 'digest'
require 'json'

module BlueCollarSystems
  module PDFVectorImporter
    module ImportRunControl
      JOURNAL_SCHEMA = 'bcs.sketchup_import_resume/1.0'.freeze
      JOURNAL_DICTIONARY = 'BC_PDF_Importer_Resume'.freeze
      JOURNAL_KEY = 'journal_json'.freeze
      IDENTITY_KEYS = %w[
        pdf_sha256 options_sha256 importer_sha256 package_sha256
        source_tree_sha256
      ].freeze
      TRANSIENT_OPTION_KEYS = [
        :progress_callback, :run_controller, :cancel_probe, :status_sink,
        :page_certifier, :resumable_page_call, :initial_y_offset,
        :defer_final_diagnostics, :complexity_confirm, :prepared_parser,
        :prepared_pdf_path, :preserve_prepared_parser, :preserve_logger
      ].freeze
      # Per-span evidence trees are restored from the live page groups on resume.
      # Cloning them into the model attribute dictionary is a multi-second JSON
      # walk on 1011 3D Text (791 expected_evidence payloads) and does not
      # change physical geometry/style SHA.
      JOURNAL_STATS_OMIT = %w[
        text_renderers
        text_attempts
        source_provenance_objects
      ].freeze

      def self.identity_for(pdf_path, options, source_root)
        opts = options.is_a?(Hash) ? options : {}
        source_sha = tree_sha256(source_root)
        package_sha = opts[:package_sha256].to_s.downcase
        if package_sha !~ /\A[0-9a-f]{64}\z/
          package_path = opts[:package_path].to_s
          package_sha = if !package_path.empty? && File.file?(package_path)
                          Digest::SHA256.file(package_path).hexdigest
                        else
                          source_sha
                        end
        end
        behavior = {}
        opts.each do |key, value|
          next if TRANSIENT_OPTION_KEYS.include?(key.to_sym)
          next if [:package_sha256, :package_path, :source_tree_sha256].include?(key.to_sym)
          behavior[key.to_s] = value
        end
        {
          :pdf_sha256 => Digest::SHA256.file(pdf_path.to_s).hexdigest,
          :options_sha256 => Digest::SHA256.hexdigest(
            module_canonical_json(behavior)
          ),
          :importer_sha256 => source_sha,
          :package_sha256 => package_sha,
          :source_tree_sha256 => source_sha
        }
      end

      def self.tree_sha256(source_root)
        root = File.expand_path(source_root.to_s)
        files = Dir.glob(File.join(root, '**', '*.rb')).select do |path|
          File.file?(path)
        end.sort
        raise ArgumentError, "no Ruby importer files under #{root}" if files.empty?
        digest = Digest::SHA256.new
        files.each do |path|
          relative = path[root.length..-1].to_s.gsub('\\', '/').sub(%r{\A/+}, '')
          digest.update(relative)
          digest.update("\0")
          digest.update(Digest::SHA256.file(path).hexdigest)
          digest.update("\n")
        end
        digest.hexdigest
      end

      def self.module_canonical_json(value)
        JSON.generate(module_canonical_value(value))
      end

      def self.module_canonical_value(value)
        if value.is_a?(Hash)
          ordered = {}
          value.keys.map { |key| key.to_s }.sort.each do |key|
            source_key = value.key?(key) ? key :
              value.keys.find { |item| item.to_s == key }
            ordered[key] = module_canonical_value(value[source_key])
          end
          ordered
        elsif value.is_a?(Array)
          value.map { |item| module_canonical_value(item) }
        elsif value.is_a?(Symbol)
          value.to_s
        elsif value.nil? || value == true || value == false ||
              value.is_a?(String) || value.is_a?(Numeric)
          value
        else
          value.to_s
        end
      end
      LARGE_WORK_UNITS = 2_000
      VERY_LARGE_WORK_UNITS = 8_000

      COUNT_WEIGHTS = {
        :paths => 1,
        :text_items => :mode,
        :glyph_placements => 1,
        :estimated_edges => 1
      }.freeze

      MODE_WEIGHTS = {
        :none => 1,
        :raster => 1,
        :text => 2,
        :labels => 2,
        :geometry => 3,
        :glyphs => 3,
        :text3d => 4,
        :'3d_text' => 4
      }.freeze

      class ImportCancelled < StandardError
        attr_reader :retained_pages, :next_page, :snapshot

        def initialize(retained_pages, next_page, snapshot)
          @retained_pages = Array(retained_pages).map { |page| page.to_i }.sort
          @next_page = next_page.nil? ? nil : next_page.to_i
          @snapshot = snapshot
          super('PDF import cancelled at a safe checkpoint')
        end

        def cancelled?
          true
        end
      end

      class ResumeMismatch < StandardError; end

      class EscapeCancelProbe
        ESCAPE_VIRTUAL_KEY = 0x1B

        def initialize(adapter = nil)
          @adapter = adapter || windows_key_adapter
        end

        def call
          value = @adapter.call(ESCAPE_VIRTUAL_KEY).to_i
          (value & 0x8000) != 0
        rescue StandardError
          false
        end

        private

        def windows_key_adapter
          require 'Win32API'
          api = Win32API.new('user32', 'GetAsyncKeyState', ['I'], 'I')
          lambda { |key| api.call(key) }
        rescue LoadError, StandardError
          lambda { |_key| 0 }
        end
      end

      class Controller
        attr_reader :pages, :requested_mode, :retained_pages

        def initialize(options = {})
          @pages = Array(options[:pages]).map { |page| page.to_i }
          @requested_mode = normalize_mode(options[:requested_mode])
          @cancel_probe = options[:cancel_probe]
          @status_sink = options[:status_sink]
          @clock = options[:clock] || lambda { Time.now.to_f }
          @started_at = finite_number(@clock.call, 'clock')
          @stage_started_at = {}
          @stage_percentages = {}
          @retained_pages = []
          @model = options[:model]
          @identity = stringify_hash(options[:identity] || {})
          @entity_signature_proc = options[:entity_signature]
        end

        def assess(counts = {})
          normalized = {}
          counts.each do |key, value|
            unless COUNT_WEIGHTS.key?(key)
              raise ArgumentError, "unknown workload count: #{key}"
            end
            unless value.is_a?(Integer) && value >= 0
              raise ArgumentError, "#{key} must be a non-negative Integer"
            end
            normalized[key] = value
          end

          mode_weight = MODE_WEIGHTS[@requested_mode] || 1
          work_units = COUNT_WEIGHTS.inject(0) do |sum, pair|
            key = pair[0]
            weight = pair[1] == :mode ? mode_weight : pair[1]
            sum + (normalized[key] || 0) * weight
          end
          work_class = if work_units >= VERY_LARGE_WORK_UNITS
                         :very_large
                       elsif work_units >= LARGE_WORK_UNITS
                         :large
                       else
                         :normal
                       end

          {
            :class => work_class,
            :work_units => work_units,
            :mode_weight => mode_weight,
            :counts => normalized
          }
        end

        def progress(stage, detail = {})
          now = finite_number(@clock.call, 'clock')
          stage_key = [stage.to_sym, detail[:page]]
          @stage_started_at[stage_key] = now unless @stage_started_at.key?(stage_key)

          completed = non_negative_integer(detail[:completed] || 0, 'completed')
          total = non_negative_integer(detail[:total] || 0, 'total')
          completed = total if total > 0 && completed > total
          raw_percentage = total > 0 ? (completed.to_f * 100.0 / total.to_f) : 0.0
          previous = @stage_percentages[stage_key] || 0.0
          percentage = raw_percentage < previous ? previous : raw_percentage
          @stage_percentages[stage_key] = percentage

          stage_elapsed = now - @stage_started_at[stage_key]
          stage_elapsed = 0.0 if stage_elapsed < 0.0
          eta = nil
          if completed > 0 && total > 0 && stage_elapsed > 0.0
            remaining = total - completed
            eta = stage_elapsed * remaining.to_f / completed.to_f
          elsif completed >= total && total > 0
            eta = 0.0
          end

          snapshot = {
            :stage => stage.to_sym,
            :completed => completed,
            :total => total,
            :percentage => percentage,
            :elapsed_seconds => [now - @started_at, 0.0].max,
            :eta_seconds => eta,
            :page => detail[:page],
            :page_index => detail[:page_index],
            :page_total => detail[:page_total]
          }
          publish(snapshot)
          snapshot
        end

        def checkpoint!(stage, detail = {})
          snapshot = progress(stage, detail)
          if cancellation_requested?(snapshot)
            next_page = detail[:page]
            raise ImportCancelled.new(@retained_pages, next_page, snapshot)
          end
          snapshot
        end

        def retain_page!(page)
          page_number = non_negative_integer(page, 'page')
          @retained_pages << page_number unless @retained_pages.include?(page_number)
          @retained_pages.sort!
          page_number
        end

        def cancelled_result(error)
          kept = error.retained_pages
          kept_text = if kept.empty?
                        'No completed pages were kept.'
                      elsif kept.length == 1
                        "Page #{kept.first} was kept."
                      else
                        "Pages #{kept.join(', ')} were kept."
                      end
          resume_text = error.next_page ? " Resume starts at page #{error.next_page}." : ''
          {
            :cancelled => true,
            :retained_pages => kept.dup,
            :next_page => error.next_page,
            :snapshot => error.snapshot,
            :message => kept_text + resume_text
          }
        end

        def certify_page!(group, page, options = {})
          ensure_journal_ready!
          page_number = non_negative_integer(page, 'page')
          unless @pages.include?(page_number)
            raise ResumeMismatch, "page #{page_number} is outside this import run"
          end
          unless live_entity?(group)
            raise ResumeMismatch, "page #{page_number} group is not live"
          end
          group_id = persistent_id_for(group)
          raise ResumeMismatch, 'retained page group has no persistent ID' unless group_id

          data = load_or_initialize_journal
          validate_journal_identity!(data)
          existing = Array(data['pages']).find do |row|
            row['page_number'].to_i == page_number
          end
          if existing
            validate_page_entry!(existing)
            unless existing['group_persistent_id'].to_i == group_id
              raise ResumeMismatch, "page #{page_number} already has another certified group"
            end
            retain_page!(page_number)
            return existing
          end

          journal_id = data['journal_id']
          set_entity_attribute(group, 'journal_id', journal_id)
          set_entity_attribute(group, 'page_number', page_number)
          set_entity_attribute(group, 'identity_sha256', identity_digest)
          set_entity_attribute(group, 'certified', true)
          signature = entity_signature(group)
          entry = {
            'page_number' => page_number,
            'group_persistent_id' => group_id,
            'entity_signature_sha256' => signature,
            'next_y_offset' => finite_number(options[:next_y_offset] || 0.0,
                                              'next_y_offset'),
            'stats' => journal_stats_payload(options[:stats])
          }
          data['pages'] << entry
          data['pages'].sort_by! { |row| row['page_number'].to_i }
          write_journal(data)
          retain_page!(page_number)
          entry
        end

        def resumable_pages
          ensure_journal_ready!
          data = read_journal
          return [] unless data
          validate_journal_identity!(data)
          pages = Array(data['pages']).map do |entry|
            validate_page_entry!(entry)
            entry['page_number'].to_i
          end.sort
          pages.each { |page| retain_page!(page) }
          pages
        end

        def resume_y_offset
          pages = resumable_pages
          return 0.0 if pages.empty?
          entries = Array(journal['pages']).select do |entry|
            pages.include?(entry['page_number'].to_i)
          end
          entries.map { |entry| entry['next_y_offset'].to_f }.max || 0.0
        end

        def page_stats(page)
          data = read_journal
          return {} unless data
          validate_journal_identity!(data)
          entry = Array(data['pages']).find do |row|
            row['page_number'].to_i == page.to_i
          end
          entry && entry['stats'].is_a?(Hash) ? symbolize_hash(entry['stats']) : {}
        end

        def journal
          read_journal
        end

        private

        def ensure_journal_ready!
          raise ResumeMismatch, 'resume journal requires a model' unless @model
          missing = IDENTITY_KEYS.reject do |key|
            @identity[key].to_s =~ /\A[0-9a-f]{64}\z/i
          end
          unless missing.empty?
            raise ResumeMismatch,
                  "resume identity is incomplete: #{missing.join(', ')}"
          end
        end

        def identity_digest
          Digest::SHA256.hexdigest(canonical_json(@identity))
        end

        def load_or_initialize_journal
          data = read_journal
          return data if data
          {
            'schema' => JOURNAL_SCHEMA,
            'journal_id' => "bcs-resume-#{identity_digest[0, 24]}",
            'identity' => @identity.dup,
            'pages' => []
          }
        end

        def read_journal
          raw = if @model.respond_to?(:get_attribute)
                  @model.get_attribute(
                    JOURNAL_DICTIONARY, journal_storage_key, nil
                  )
                end
          return nil if raw.nil? || raw.to_s.empty?
          data = JSON.parse(raw.to_s)
          unless data.is_a?(Hash) && data['schema'] == JOURNAL_SCHEMA &&
                 data['pages'].is_a?(Array)
            raise ResumeMismatch, 'resume journal schema is invalid'
          end
          data
        rescue JSON::ParserError => e
          raise ResumeMismatch, "resume journal is invalid JSON: #{e.message}"
        end

        def write_journal(data)
          unless @model.respond_to?(:set_attribute)
            raise ResumeMismatch, 'model cannot persist the resume journal'
          end
          @model.set_attribute(
            JOURNAL_DICTIONARY, journal_storage_key, canonical_json(data)
          )
          data
        end

        def journal_storage_key
          "#{JOURNAL_KEY}_#{identity_digest}"
        end

        def validate_journal_identity!(data)
          unless data['identity'].is_a?(Hash) &&
                 canonical_json(data['identity']) == canonical_json(@identity) &&
                 data['journal_id'].to_s == "bcs-resume-#{identity_digest[0, 24]}"
            raise ResumeMismatch,
                  'resume identity differs from the certified PDF/options/importer/package'
          end
          true
        end

        def validate_page_entry!(entry)
          page = entry['page_number'].to_i
          candidates = active_entities.select do |entity|
            live_entity?(entity) &&
              entity_attribute(entity, 'journal_id').to_s ==
                journal['journal_id'].to_s &&
              entity_attribute(entity, 'page_number').to_i == page
          end
          unless candidates.length == 1
            raise ResumeMismatch,
                  "page #{page} has #{candidates.length} retained groups; expected exactly one"
          end
          group = candidates.first
          unless persistent_id_for(group).to_i ==
                 entry['group_persistent_id'].to_i
            raise ResumeMismatch, "page #{page} retained group identity changed"
          end
          unless entity_attribute(group, 'certified') == true &&
                 entity_attribute(group, 'identity_sha256').to_s == identity_digest
            raise ResumeMismatch, "page #{page} certification attributes changed"
          end
          unless entity_signature(group) == entry['entity_signature_sha256'].to_s
            raise ResumeMismatch, "page #{page} retained entity signature changed"
          end
          true
        end

        def active_entities
          entities = @model.respond_to?(:active_entities) ?
            @model.active_entities : nil
          entities && entities.respond_to?(:to_a) ? entities.to_a : []
        end

        def live_entity?(entity)
          return false unless entity
          !entity.respond_to?(:valid?) || entity.valid? == true
        rescue StandardError
          false
        end

        def persistent_id_for(entity)
          return nil unless entity.respond_to?(:persistent_id)
          value = entity.persistent_id.to_i
          value > 0 ? value : nil
        rescue StandardError
          nil
        end

        def set_entity_attribute(entity, key, value)
          unless entity.respond_to?(:set_attribute)
            raise ResumeMismatch, 'retained page group cannot store certification attributes'
          end
          entity.set_attribute(JOURNAL_DICTIONARY, key, value)
        end

        def entity_attribute(entity, key)
          return nil unless entity.respond_to?(:get_attribute)
          entity.get_attribute(JOURNAL_DICTIONARY, key, nil)
        end

        def entity_signature(entity)
          if @entity_signature_proc.respond_to?(:call)
            return @entity_signature_proc.call(entity).to_s
          end
          digest = Digest::SHA256.new
          digest.update('[')
          first = [true]
          collect_entity_signature(entity, digest, first, 0)
          digest.update(']')
          digest.hexdigest
        end

        def collect_entity_signature(entity, digest, first, depth)
          raise ResumeMismatch, 'retained entity tree is too deep' if depth > 64
          row = {
            'depth' => depth,
            'persistent_id' => persistent_id_for(entity),
            'typename' => entity.respond_to?(:typename) ? entity.typename.to_s : entity.class.name.to_s,
            'name' => entity.respond_to?(:name) ? entity.name.to_s : ''
          }
          row['transformation'] = numeric_sequence(entity.transformation.to_a) if
            entity.respond_to?(:transformation) &&
            entity.transformation.respond_to?(:to_a)
          if entity.respond_to?(:bounds)
            bounds = entity.bounds
            if bounds && bounds.respond_to?(:min) && bounds.respond_to?(:max)
              row['bounds'] = [point_signature(bounds.min), point_signature(bounds.max)]
            end
          end
          if entity.respond_to?(:start) && entity.respond_to?(:end)
            endpoints = [entity.start, entity.end].map do |vertex|
              point_signature(vertex.respond_to?(:position) ? vertex.position : vertex)
            end
            row['edge_endpoints'] = endpoints.sort
          end
          if entity.respond_to?(:vertices)
            vertices = Array(entity.vertices).map do |vertex|
              point_signature(vertex.respond_to?(:position) ? vertex.position : vertex)
            end
            row['vertices'] = vertices.sort
          end
          row['text'] = entity.text.to_s if entity.respond_to?(:text)
          row['hidden'] = entity.hidden? == true if entity.respond_to?(:hidden?)
          if entity.respond_to?(:material) && entity.material
            material = entity.material
            row['material'] = material.respond_to?(:name) ? material.name.to_s : material.to_s
          end
          if entity.respond_to?(:layer) && entity.layer
            layer = entity.layer
            row['layer'] = layer.respond_to?(:name) ? layer.name.to_s : layer.to_s
          end
          encoded = JSON.generate(canonical_value(row))
          digest.update(',') unless first[0]
          first[0] = false
          digest.update(encoded)
          children = entity.respond_to?(:entities) ? entity.entities : nil
          Array(children && children.respond_to?(:to_a) ? children.to_a : []).each do |child|
            collect_entity_signature(child, digest, first, depth + 1)
          end
          true
        end

        def point_signature(point)
          values = if point.respond_to?(:to_a)
                     point.to_a
                   elsif point.respond_to?(:x) && point.respond_to?(:y) &&
                         point.respond_to?(:z)
                     [point.x, point.y, point.z]
                   else
                     [point.to_s]
                   end
          numeric_sequence(values)
        end

        def numeric_sequence(values)
          Array(values).map do |value|
            value.respond_to?(:to_f) ? value.to_f : value.to_s
          end
        end

        def canonical_json(value)
          JSON.generate(canonical_value(value))
        end

        def canonical_value(value)
          if value.is_a?(Hash)
            ordered = {}
            value.keys.map { |key| key.to_s }.sort.each do |key|
              source_key = value.key?(key) ? key : value.keys.find { |item| item.to_s == key }
              ordered[key] = canonical_value(value[source_key])
            end
            ordered
          elsif value.is_a?(Array)
            value.map { |item| canonical_value(item) }
          elsif value.is_a?(Symbol)
            value.to_s
          elsif value.nil? || value == true || value == false ||
                value.is_a?(String) || value.is_a?(Numeric)
            value
          else
            value.to_s
          end
        end

        def json_safe(value)
          canonical_value(value)
        end

        def journal_stats_payload(stats)
          return {} unless stats.is_a?(Hash)
          payload = {}
          stats.each do |key, value|
            name = key.to_s
            next if JOURNAL_STATS_OMIT.include?(name)
            payload[name] = value
          end
          json_safe(payload)
        end

        def stringify_hash(value)
          result = {}
          value.each { |key, item| result[key.to_s] = item.to_s.downcase }
          result
        end

        def symbolize_hash(value)
          result = {}
          value.each do |key, item|
            result[key.to_sym] = item.is_a?(Hash) ? symbolize_hash(item) : item
          end
          result
        end

        def normalize_mode(value)
          value.nil? ? :none : value.to_s.downcase.gsub(/[ -]/, '_').to_sym
        end

        def non_negative_integer(value, label)
          unless value.is_a?(Integer) && value >= 0
            raise ArgumentError, "#{label} must be a non-negative Integer"
          end
          value
        end

        def finite_number(value, label)
          number = Float(value)
          if number.respond_to?(:finite?) && !number.finite?
            raise ArgumentError, "#{label} must be finite"
          end
          number
        rescue ArgumentError, TypeError
          raise ArgumentError, "#{label} must be numeric"
        end

        def cancellation_requested?(snapshot)
          return false unless @cancel_probe.respond_to?(:call)
          arity = if @cancel_probe.respond_to?(:arity)
                    @cancel_probe.arity
                  else
                    @cancel_probe.method(:call).arity
                  end
          arity == 0 ? @cancel_probe.call : @cancel_probe.call(snapshot)
        end

        def publish(snapshot)
          return unless @status_sink.respond_to?(:call)
          @status_sink.call(snapshot)
        rescue ImportCancelled
          raise
        rescue StandardError
          nil
        end
      end

      class PageOrchestrator
        def initialize(options = {})
          @model = options[:model]
          @controller = options[:controller]
          @pages = Array(options[:pages]).map { |page| page.to_i }
          @runner = options[:runner]
          @group_per_page = options.key?(:group_per_page) ?
            options[:group_per_page] == true : true
        end

        def run
          unless @group_per_page
            raise ArgumentError,
                  'Resume requires Group-per-page; this grouping remains atomic.'
          end
          raise ArgumentError, 'page runner is unavailable' unless @runner.respond_to?(:call)

          resumed = @controller.resumable_pages & @pages
          aggregate = {}
          resumed.each do |page|
            merge_stats!(aggregate, @controller.page_stats(page))
          end
          offset = @controller.resume_y_offset
          new_pages = []
          pending = @pages.reject { |page| resumed.include?(page) }

          pending.each do |page|
            certified = false
            certifier = lambda do |group, next_offset, stats = {}|
              @controller.certify_page!(
                group, page,
                :next_y_offset => next_offset,
                :stats => stats
              )
              certified = true
            end
            result = @runner.call(page, offset, certifier)
            unless certified && @controller.resumable_pages.include?(page)
              raise ResumeMismatch,
                    "page #{page} runner returned without a certified page group"
            end
            stats = result.is_a?(Hash) ? result[:stats] : nil
            merge_stats!(aggregate, stats || @controller.page_stats(page))
            offset = if result.is_a?(Hash) && result.key?(:next_y_offset)
                       result[:next_y_offset].to_f
                     else
                       @controller.resume_y_offset
                     end
            @controller.retain_page!(page)
            new_pages << page
          end

          {
            :cancelled => false,
            :retained_pages => (resumed + new_pages).sort,
            :resumed_pages => resumed.sort,
            :new_pages => new_pages,
            :next_page => nil,
            :stats => aggregate
          }
        rescue ImportCancelled => error
          result = @controller.cancelled_result(error)
          result[:retained_pages] = @controller.retained_pages.dup
          result[:resumed_pages] = resumed || []
          result[:new_pages] = new_pages || []
          result[:stats] = aggregate || {}
          result
        end

        private

        def merge_stats!(target, source)
          return target unless source.is_a?(Hash)
          source.each do |key, value|
            if value.is_a?(Numeric)
              target[key] = target[key].to_f + value
              target[key] = target[key].to_i if target[key] == target[key].to_i
            elsif value.is_a?(Array)
              target[key] = Array(target[key]) + value
            elsif value.is_a?(Hash)
              target[key] = {} unless target[key].is_a?(Hash)
              merge_stats!(target[key], value)
            elsif !target.key?(key)
              target[key] = value
            end
          end
          target
        end
      end
    end
  end
end
