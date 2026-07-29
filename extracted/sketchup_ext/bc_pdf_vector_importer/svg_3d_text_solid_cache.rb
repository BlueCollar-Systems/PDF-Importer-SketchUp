# bc_pdf_vector_importer/svg_3d_text_solid_cache.rb
# Import-scoped reuse of exact PDF-renderer glyph solids.

require 'digest'

module BlueCollarSystems
  module PDFVectorImporter
    class Svg3DTextSolidCache
      attr_reader :depth

      def initialize(model, depth)
        @model = model
        @depth = finite_number!(depth, '3D text cache depth')
        raise '3D text cache depth must be positive' unless @depth > 0.0
        @definitions = model && model.respond_to?(:definitions) ?
          model.definitions : nil
        @records = {}
        @created_definitions = []
        @metrics = {
          :definition_builds => 0,
          :cache_hits => 0,
          :cache_misses => 0,
          :instance_placements => 0,
          :unique_cache_keys => 0,
          :transaction_abort_required => false
        }
      end

      def supported_for?(target_entities)
        @definitions && @definitions.respond_to?(:add) &&
          target_entities && target_entities.respond_to?(:add_instance) &&
          defined?(Geom::Transformation) &&
          Geom::Transformation.respond_to?(:translation)
      rescue StandardError
        false
      end

      def key_for(entry)
        prepared = prepare_entry(entry)
        key_for_prepared(prepared)
      end

      def fetch(entry)
        raise ArgumentError, 'exact solid cache requires a builder block' unless
          block_given?
        prepared = prepare_entry(entry)
        key = key_for_prepared(prepared)
        cached = @records[key]
        if cached
          @metrics[:cache_hits] += 1
          return cached.merge(:origin => prepared[:origin])
        end

        @metrics[:cache_misses] += 1
        definition = @definitions.add("BC_PDF_GLYPH_#{key[0, 24]}")
        raise 'host rejected exact glyph component definition' unless definition
        unless definition.respond_to?(:entities) && definition.entities
          remove_created_definition!(definition)
          raise 'exact glyph component definition has no entities collection'
        end
        @created_definitions << definition

        begin
          build_metrics = yield(definition.entities, prepared[:entry])
          unless build_metrics.is_a?(Hash)
            raise 'exact glyph definition builder returned no metrics'
          end
          record = {
            :key => key,
            :definition => definition,
            :build_metrics => build_metrics
          }
          @records[key] = record
          @metrics[:definition_builds] += 1
          @metrics[:unique_cache_keys] = @records.length
          record.merge(:origin => prepared[:origin])
        rescue StandardError
          @records.delete(key)
          @created_definitions.delete(definition)
          remove_created_definition!(definition)
          raise
        end
      end

      def add_instance(target_entities, record)
        unless supported_for?(target_entities)
          raise 'host cannot place an exact glyph component instance'
        end
        definition = record.is_a?(Hash) ? record[:definition] : nil
        origin = record.is_a?(Hash) ? record[:origin] : nil
        unless definition && origin.is_a?(Array) && origin.length >= 3
          raise 'exact glyph cache record is incomplete'
        end
        transform = Geom::Transformation.translation(origin)
        instance = target_entities.add_instance(definition, transform)
        raise 'host rejected exact glyph component instance' unless instance
        @metrics[:instance_placements] += 1
        instance
      end

      def metrics
        @metrics.dup
      end

      # SketchUp 2017 has no DefinitionList#remove. Production imports already
      # run inside a model operation and abort that operation on a renderer
      # failure, which is the only safe way to remove definitions without
      # purging unrelated user definitions. Test/current hosts with #remove can
      # clean immediately.
      def cleanup_all!
        if @definitions && @definitions.respond_to?(:remove)
          @created_definitions.reverse_each do |definition|
            remove_created_definition!(definition)
          end
          @created_definitions = []
          @records = {}
          @metrics[:unique_cache_keys] = 0
          return true
        end
        if @model && @model.respond_to?(:abort_operation)
          @metrics[:transaction_abort_required] = true
          return false
        end
        raise 'host cannot atomically clean exact glyph component definitions'
      end

      private

      def prepare_entry(entry)
        raise 'exact glyph cache entry is unavailable' unless entry.is_a?(Hash)
        source_loops = Array(entry[:loops])
        source_points = source_loops.flatten
        if source_points.empty? || source_points.any? do |point|
          !point || !point.respond_to?(:x) || !point.respond_to?(:y)
        end
          raise 'exact glyph cache entry has invalid source loops'
        end
        local_source = Array(entry[:cache_local_loops])
        explicit_origin = Array(entry[:cache_origin])
        if !local_source.empty? && explicit_origin.length >= 3
          localized_loops = copy_loops(local_source)
          origin = explicit_origin.first(3).each_with_index.map do |value, index|
            finite_number!(value, "glyph cache origin #{index}")
          end
          verify_exact_reconstruction!(source_loops, localized_loops, origin)
          localized = entry.dup
          localized[:loops] = localized_loops
          localized.delete(:cache_local_loops)
          localized.delete(:cache_origin)
          return { :entry => localized, :origin => origin }
        end

        min_x = source_points.map { |point| finite_number!(point.x, 'glyph X') }.min
        min_y = source_points.map { |point| finite_number!(point.y, 'glyph Y') }.min
        min_z = source_points.map do |point|
          finite_number!(
            point.respond_to?(:z) ? point.z : 0.0, 'glyph Z'
          )
        end.min
        origin = [min_x, min_y, min_z]
        localized_loops = source_loops.map do |source_loop|
          Array(source_loop).map do |point|
            Geom::Point3d.new(
              finite_number!(point.x, 'glyph X') - min_x,
              finite_number!(point.y, 'glyph Y') - min_y,
              finite_number!(
                point.respond_to?(:z) ? point.z : 0.0, 'glyph Z'
              ) - min_z
            )
          end
        end
        localized = entry.dup
        localized[:loops] = localized_loops
        { :entry => localized, :origin => origin }
      end

      def copy_loops(loops)
        Array(loops).map do |source_loop|
          Array(source_loop).map do |point|
            unless point && point.respond_to?(:x) && point.respond_to?(:y)
              raise 'exact glyph cache entry has invalid local source loops'
            end
            Geom::Point3d.new(
              finite_number!(point.x, 'local glyph X'),
              finite_number!(point.y, 'local glyph Y'),
              finite_number!(
                point.respond_to?(:z) ? point.z : 0.0, 'local glyph Z'
              )
            )
          end
        end
      end

      def verify_exact_reconstruction!(world_loops, local_loops, origin)
        unless world_loops.length == local_loops.length
          raise 'exact glyph cache local/world loop inventories differ'
        end
        world_loops.each_with_index do |world_loop, loop_index|
          local_loop = local_loops[loop_index]
          unless Array(world_loop).length == Array(local_loop).length
            raise 'exact glyph cache local/world vertex inventories differ'
          end
          Array(world_loop).each_with_index do |world_point, point_index|
            local_point = local_loop[point_index]
            expected = [
              local_point.x.to_f + origin[0],
              local_point.y.to_f + origin[1],
              (local_point.respond_to?(:z) ? local_point.z.to_f : 0.0) +
                origin[2]
            ]
            actual = [
              finite_number!(world_point.x, 'world glyph X'),
              finite_number!(world_point.y, 'world glyph Y'),
              finite_number!(
                world_point.respond_to?(:z) ? world_point.z : 0.0,
                'world glyph Z'
              )
            ]
            next if actual == expected
            raise "exact glyph cache local/world reconstruction differs at " \
              "loop #{loop_index} vertex #{point_index}"
          end
        end
        true
      end

      def key_for_prepared(prepared)
        entry = prepared[:entry]
        matrix = Array(entry[:svg_matrix])
        linear = [
          matrix.fetch(0, 1.0), matrix.fetch(1, 0.0),
          matrix.fetch(2, 0.0), matrix.fetch(3, 1.0)
        ]
        colors = Array(entry[:fill_rgb])
        opacity = entry[:fill_opacity]
        opacity = 1.0 if opacity.nil?
        parts = [
          entry[:glyph_id].to_s,
          'fill_rule=nonzero',
          "depth=#{canonical_number(@depth)}",
          "linear=#{linear.map { |value| canonical_number(value) }.join(',')}",
          "fill=#{colors.map { |value| canonical_number(value) }.join(',')}",
          "opacity=#{canonical_number(opacity)}"
        ]
        Array(entry[:loops]).each_with_index do |points, loop_index|
          coordinates = Array(points).map do |point|
            [
              canonical_number(point.x),
              canonical_number(point.y),
              canonical_number(point.respond_to?(:z) ? point.z : 0.0)
            ].join(',')
          end
          parts << "loop#{loop_index}=#{coordinates.join(';')}"
        end
        Digest::SHA256.hexdigest(parts.join('|'))
      end

      def canonical_number(value)
        format('%.17g', finite_number!(value, 'cache key number'))
      end

      def finite_number!(value, label)
        number = value.to_f
        raise "#{label} is nonfinite" unless number.finite?
        number
      end

      def remove_created_definition!(definition)
        unless @definitions && @definitions.respond_to?(:remove)
          if @model && @model.respond_to?(:abort_operation)
            @metrics[:transaction_abort_required] = true
            return false
          end
          raise 'host cannot remove a failed exact glyph component definition'
        end
        removed = @definitions.remove(definition)
        raise 'host rejected exact glyph component definition cleanup' unless removed
        true
      end
    end
  end
end
