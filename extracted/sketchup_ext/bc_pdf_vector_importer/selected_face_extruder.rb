# Manual selection tool; not used by the PDF import pipeline.
# Ruby 2.2 / SketchUp 2017 syntax. All dimensions are physical world inches.
module BlueCollarSystems
  module PDFVectorImporter
    module SelectedFaceExtruder
      DICTIONARY = 'BC_PDF_Importer'.freeze
      NUMBER = '(?:\\d+(?:\\.\\d*)?|\\.\\d+)'.freeze
      VALUE = '(?:\\d+\\s+\\d+\\s*/\\s*\\d+|\\d+\\s*/\\s*\\d+|' + NUMBER + ')'
      UNIT_FACTORS = {
        'in' => 1.0, 'inch' => 1.0, 'inches' => 1.0, '"' => 1.0,
        'ft' => 12.0, 'foot' => 12.0, 'feet' => 12.0, "'" => 12.0,
        'mm' => 1.0/25.4, 'millimeter' => 1.0/25.4, 'millimeters' => 1.0/25.4,
        'cm' => 10.0/25.4, 'centimeter' => 10.0/25.4, 'centimeters' => 10.0/25.4,
        'm' => 1000.0/25.4, 'meter' => 1000.0/25.4, 'meters' => 1000.0/25.4,
        'yd' => 36.0, 'yard' => 36.0, 'yards' => 36.0
      }.freeze
      COORDINATE_TOLERANCE = 1.0e-7
      AXIS_TOLERANCE = 1.0e-10
      MAX_ANCESTORS = 64
      MAX_TARGETS = 256

      class Error < StandardError; end
      class InputError < Error; end
      class SelectionError < Error; end
      class TransformError < Error; end
      class ProofError < Error; end
      class TransactionError < Error; end
      class RollbackFailure < Error
        attr_reader :primary_error, :rollback_error
        def initialize(primary, rollback)
          @primary_error, @rollback_error = primary, rollback
          super("#{primary.message}\nSketchUp could not confirm rollback: #{rollback}. " \
            'Partial model changes may remain; inspect the model before continuing.')
          set_backtrace(primary.backtrace)
        end
      end

      def self.parse_depth(text)
        unless text.is_a?(String) && text.bytesize <= 128
          raise InputError, 'Enter a positive depth, such as 1/8", 10mm or 2\'. Bare numbers mean inches.'
        end
        text = text.strip.downcase
        feet = /\A(#{NUMBER})\s*(?:'|ft|foot|feet)(?:\s*[-]?\s*(#{VALUE})\s*(?:"|in|inch|inches)?)?\z/.match(text)
        if feet
          value = numeric_value(feet[1])*12.0 + (feet[2] ? numeric_value(feet[2]) : 0.0)
        else
          units = UNIT_FACTORS.keys.map { |unit| Regexp.escape(unit) }.sort_by { |unit| -unit.length }.join('|')
          match = /\A(#{VALUE})\s*(#{units})?\z/.match(text)
          raise InputError, 'Use a valid dimension with a recognized unit; bare numbers mean inches.' unless match
          value = numeric_value(match[1]) * (match[2] ? UNIT_FACTORS.fetch(match[2]) : 1.0)
        end
        require_positive_finite!(value)
      end

      def self.numeric_value(text)
        if (match = /\A(\d+)\s+(\d+)\s*\/\s*(\d+)\z/.match(text))
          denominator = match[3].to_f
          raise InputError, 'A fraction denominator must be greater than zero.' unless denominator > 0.0 && denominator.finite?
          match[1].to_f + match[2].to_f / denominator
        elsif (match = /\A(\d+)\s*\/\s*(\d+)\z/.match(text))
          denominator = match[2].to_f
          raise InputError, 'A fraction denominator must be greater than zero.' unless denominator > 0.0 && denominator.finite?
          match[1].to_f / denominator
        elsif /\A#{NUMBER}\z/.match(text)
          text.to_f
        else
          raise InputError, 'Invalid dimension.'
        end
      end

      def self.require_positive_finite!(value)
        unless value.is_a?(Numeric) && value.to_f.finite? && value.to_f > 0.0
          raise InputError, 'Extrusion depth must be finite and greater than zero.'
        end
        value.to_f
      end

      # Each target is an isolated horizontal planar face, with optional holes.
      # Positive depth means world +Z, including reversed/reflected local faces.
      def self.run(model, depth_inches)
        depth = require_positive_finite!(depth_inches)
        raise SelectionError, 'Open a SketchUp model first.' unless model
        active = model.active_entities
        selection = unique_entities(model.selection.to_a)
        raise SelectionError, 'Select closed faces or whole groups/components.' if selection.empty?
        active_ids = active.to_a.map { |entity| entity_id(entity) }
        selection.each do |entity|
          unless active_ids.include?(entity_id(entity))
            raise SelectionError, 'Selection changed or is outside the current editing context.'
          end
        end
        path = model.active_path || []
        unless path.empty?
          raise SelectionError, 'Close the open group or component, then select the whole instance. ' \
            'This tool edits only from the model context to protect other copies and keep world dimensions correct.'
        end
        root_transform = affine(Geom::Transformation.new)
        before = collect(selection, active, root_transform, depth, false, [], {})
        return result(:no_eligible_faces, depth, before) if before[:targets].empty?
        if before[:targets].length > MAX_TARGETS
          raise SelectionError, "Select at most #{MAX_TARGETS} isolated profiles at a time for this manual tool."
        end

        operation_owned = false
        begin
          unless model.start_operation('Extrude Selected Planar Faces', true) == true
            raise TransactionError, 'SketchUp did not confirm starting the extrusion operation. This tool made no geometry edits.'
          end
          operation_owned = true
          owned = collect(selection, active, root_transform, depth, true, [], {})
          unless owned[:targets].length == before[:targets].length
            raise SelectionError, 'Target faces changed while isolating selected instances.'
          end
          peers = snapshot_peers(owned[:targets])
          # Preserve a starting cap explicitly; nil is the documented native
          # return and does not itself prove the resulting geometry.
          owned[:targets].each { |target| target[:face].pushpull(target[:local_depth], true) }
          proof_cache = {}
          owned[:targets].each do |target|
            key = [target[:owner].object_id, target[:transform]]
            proof_cache[key] ||= native_polygons(target)
            verify_extrusion!(target, depth, proof_cache[key])
          end
          verify_peers!(peers)
          completed = result(:completed, depth, owned)
          unless model.commit_operation == true
            raise TransactionError, 'SketchUp did not confirm committing the extrusion operation.'
          end
          operation_owned = false
          completed
        rescue StandardError => primary
          if operation_owned
            begin
              confirmed = model.abort_operation
              raise TransactionError, 'abort_operation returned without confirming success' unless confirmed == true
            rescue StandardError => rollback
              raise RollbackFailure.new(primary, rollback.message)
            end
          end
          raise
        end
      end

      def self.result(status, depth, state)
        {:status => status, :world_depth_inches => depth,
          :faces_extruded => status == :completed ? state[:targets].length : 0,
          :skipped => state[:skipped].dup}
      end

      def self.collect(items, owner, transform, depth, isolate, definitions, seen, scope = [])
        raise SelectionError, 'Container nesting is too deep for a safe manual edit.' if definitions.length > MAX_ANCESTORS
        state = {:targets => [], :skipped => Hash.new(0)}
        unique_entities(items).each do |entity|
          reason = blocked_reason(entity)
          if reason
            state[:skipped][reason] += 1
          elsif native_face?(entity)
            # A shared definition is one target per selected instance before
            # isolation, while duplicate selection references remain one target.
            key = [scope, entity_id(entity)]
            next if seen[key]
            seen[key] = true
            target = target_for(entity, owner, transform, depth)
            if target
              state[:targets] << target
            else
              state[:skipped][:non_horizontal_face] += 1
            end
          elsif native_container?(entity)
            definition = entity.definition
            if definition.respond_to?(:live_component?) && definition.live_component?
              raise SelectionError, 'Live Components cannot be edited by this manual tool.'
            end
            if definitions.include?(definition.object_id)
              raise SelectionError, 'Recursive component definitions cannot be safely extruded.'
            end
            if isolate
              returned = entity.make_unique
              unless returned == entity && entity.valid?
                raise SelectionError, 'SketchUp did not confirm isolating a selected instance.'
              end
              assert_unique!(entity, 'Selected instance is still shared after make_unique')
            end
            child_owner = native_group?(entity) ? entity.entities : entity.definition.entities
            child = collect(child_owner.to_a, child_owner,
              compose(transform, affine(entity.transformation)), depth, isolate,
              definitions + [definition.object_id], seen, scope + [entity_id(entity)])
            state[:targets].concat(child[:targets])
            child[:skipped].each { |key, count| state[:skipped][key] += count }
          else
            state[:skipped][:unsupported_entity] += 1
          end
        end
        state
      end

      def self.blocked_reason(entity)
        raise SelectionError, 'A selected entity is no longer valid.' unless entity.valid?
        if entity.get_attribute(DICTIONARY, 'source_width_footprint', false) == true
          return :source_stroke_paint
        end
        source_kind = entity.get_attribute(DICTIONARY, 'source_kind', nil)
        representation = entity.get_attribute(DICTIONARY, 'representation', nil)
        if ['text_span','svg_glyph_placement','shared_glyph_outline'].include?(source_kind) ||
            entity.get_attribute(DICTIONARY, 'representation_container', false) == true ||
            entity.get_attribute(DICTIONARY, 'decorative_text_container', false) == true ||
            entity.get_attribute(DICTIONARY, 'decorative_text_wrapper', false) == true ||
            (['text','labels','text3d','3d_text','glyphs','geometry','raster'].include?(representation) &&
              !entity.get_attribute(DICTIONARY, 'source_span_id', '').to_s.empty?)
          return :source_text
        end
        return :hidden if entity.respond_to?(:hidden?) && entity.hidden?
        return :hidden if entity.respond_to?(:layer) && !layer_visible?(entity.layer)
        return :locked if entity.respond_to?(:locked?) && entity.locked?
        nil
      end

      def self.layer_visible?(layer)
        return true unless layer
        return false unless layer.visible? == true
        folder = layer.respond_to?(:folder) ? layer.folder : nil
        seen = {}
        while folder
          if seen[folder.object_id] || seen.length > MAX_ANCESTORS
            raise SelectionError, 'Tag folder ancestry cannot be safely resolved.'
          end
          seen[folder.object_id] = true
          return false unless folder.visible? == true
          folder = folder.folder
        end
        true
      end

      def self.assert_unique!(instance, message)
        raise SelectionError, "#{message}." unless native_container?(instance)
        instances = instance.definition.instances.to_a.select { |item| item.valid? }
        unless instances.length == 1 && same_entity?(instances.first, instance)
          raise SelectionError, "#{message}."
        end
      end

      def self.target_for(face, owner, transform, depth)
        loops = face.loops.to_a.map { |loop| loop.vertices.to_a.map { |v| point(transform, coordinates(v.position)) } }
        raise SelectionError, 'A closed face has an invalid boundary.' if loops.empty? || loops.any? { |loop| loop.length < 3 }
        z = loops.first.first[2]
        return nil unless loops.flatten(1).all? { |p| (p[2]-z).abs <= COORDINATE_TOLERANCE }
        edges = face.edges.to_a
        edge_ids = edges.map { |edge| entity_id(edge) }.sort
        connected = face.all_connected.to_a
        unless connected.select { |item| native_face?(item) }.all? { |item| same_entity?(item, face) } &&
            connected.select { |item| native_edge?(item) }.map { |edge| entity_id(edge) }.sort == edge_ids &&
            edges.all? { |edge| edge.faces.to_a.length == 1 && same_entity?(edge.faces.to_a.first, face) }
          raise SelectionError, 'Select isolated flat profiles: connected faces or attached edges require a separate edit.'
        end
        normal = coordinates(face.normal)
        length = Math.sqrt(normal.inject(0.0) { |sum, value| sum + value*value })
        raise TransformError, 'Face normal is invalid.' unless length.finite? && length > 0.0
        step = vector(transform, normal.map { |value| value/length })
        if step[2] == 0.0 || step[0].abs > step[2].abs*AXIS_TOLERANCE || step[1].abs > step[2].abs*AXIS_TOLERANCE
          raise TransformError, 'The composed transform shears the extrusion axis. Reset that transform before extruding.'
        end
        local_depth = depth / step[2]
        raise TransformError, 'The requested depth cannot be represented under this transform.' unless local_depth.finite? && local_depth != 0.0
        loops.flatten(1).each { |p| finite_coordinates!([p[0],p[1],p[2]+depth]) }
        {:face => face, :owner => owner, :transform => transform, :loops => loops,
          :local_depth => local_depth, :edges => edges}
      end

      # Measure transformed origin/bases through the host, including the
      # pre-2018 single-argument scaling matrix convention. Never use inverse.
      def self.affine(transformation)
        values = transformation.to_a
        unless values.length == 16 && values.all? { |v| v.is_a?(Numeric) && v.to_f.finite? } &&
            [3,7,11].all? { |i| values[i].to_f == 0.0 } && values[15].to_f != 0.0
          raise TransformError, 'A transform is non-finite or non-affine.'
        end
        origin = coordinates(Geom::Point3d.new(0,0,0).transform(transformation))
        basis = [[1,0,0],[0,1,0],[0,0,1]].map do |p|
          coordinates(Geom::Point3d.new(*p).transform(transformation)).each_with_index.map { |value,i| value-origin[i] }
        end
        check_affine!(basis + [origin])
      end

      def self.check_affine!(matrix)
        unless matrix.flatten.all? { |v| v.finite? }
          raise TransformError, 'The composed transform is non-finite.'
        end
        a,b,c = matrix[0,3]
        determinant = a[0]*(b[1]*c[2]-b[2]*c[1]) - b[0]*(a[1]*c[2]-a[2]*c[1]) + c[0]*(a[1]*b[2]-a[2]*b[1])
        raise TransformError, 'A singular transform cannot be safely extruded.' unless determinant.finite? && determinant != 0.0
        matrix
      end

      def self.compose(parent, child)
        check_affine!(child[0,3].map { |column| vector(parent,column) } + [point(parent,child[3])])
      end

      def self.coordinates(position)
        values = [position.x.to_f, position.y.to_f, position.z.to_f]
        raise TransformError, 'Geometry contains a non-finite coordinate.' unless values.all? { |v| v.finite? }
        values
      end

      def self.vector(matrix, values)
        finite_coordinates!(3.times.map { |row| 3.times.inject(0.0) { |sum,col| sum + matrix[col][row]*values[col] } })
      end

      def self.point(matrix, values)
        finite_coordinates!(vector(matrix,values).each_with_index.map { |value,i| value + matrix[3][i] })
      end

      def self.finite_coordinates!(values)
        raise TransformError, 'The transformed boundary or depth is non-finite.' unless values.all? { |value| value.finite? }
        values
      end

      def self.native_polygons(target)
        faces = target[:owner].to_a.select { |entity| native_face?(entity) && entity.valid? }
        faces.map do |face|
          [face, face.loops.to_a.map { |loop| loop.vertices.to_a.map { |v| point(target[:transform],coordinates(v.position)) } }]
        end
      end

      def self.verify_extrusion!(target, depth, polygons)
        tolerance = [COORDINATE_TOLERANCE, depth*1.0e-6].min
        top = target[:loops].map { |loop| loop.map { |p| [p[0],p[1],p[2]+depth] } }
        unless polygons.any? { |_face, loops| matching_loops?(loops,target[:loops],tolerance) }
          raise ProofError, 'Native push/pull did not preserve the starting boundary.'
        end
        unless polygons.any? { |_face, loops| matching_loops?(loops,top,tolerance) }
          raise ProofError, 'Native push/pull did not produce the requested top boundary and world depth.'
        end
        target[:loops].each do |loop|
          loop.each_with_index do |p,i|
            q = loop[(i+1)%loop.length]
            side = [p,q,[q[0],q[1],q[2]+depth],[p[0],p[1],p[2]+depth]]
            unless polygons.any? { |_face, loops| loops.length == 1 && matching_points?(loops.first,side,tolerance) }
              raise ProofError, 'Native push/pull did not produce a complete side boundary.'
            end
          end
        end
        true
      end

      def self.matching_loops?(actual, expected, tolerance)
        unmatched = actual.dup
        expected.length == actual.length && expected.all? do |loop|
          index = unmatched.index { |candidate| matching_points?(candidate,loop,tolerance) }
          index ? !!unmatched.delete_at(index) : false
        end
      end

      def self.matching_points?(actual, expected, tolerance)
        return false if expected.empty? || expected.length != actual.length
        actual.each_index.any? do |start|
          [1,-1].any? do |direction|
            expected.each_with_index.all? do |p,index|
              q = actual[(start+direction*index)%actual.length]
              3.times.all? { |i| (p[i]-q[i]).abs <= tolerance }
            end
          end
        end
      end

      def self.snapshot_peers(targets)
        owners = targets.map { |target| target[:owner] }.uniq
        ignored = targets.map { |target| entity_id(target[:face]) } + targets.map { |target| target[:edges].map { |edge| entity_id(edge) } }.flatten
        owners.map do |owner|
          owner.to_a.select { |entity| (native_face?(entity) || native_edge?(entity)) && !ignored.include?(entity_id(entity)) }.map do |entity|
            [entity, geometry_signature(entity)]
          end
        end.flatten(1)
      end

      def self.verify_peers!(peers)
        peers.each do |entity, expected|
          unless entity.valid? && geometry_signature(entity) == expected
            raise ProofError, 'Native extrusion changed geometry outside the selected planar islands.'
          end
        end
      end

      def self.geometry_signature(entity)
        if native_face?(entity)
          entity.loops.to_a.map { |loop| loop.vertices.to_a.map { |v| coordinates(v.position) } }
        else
          [coordinates(entity.start.position), coordinates(entity.end.position)]
        end
      end

      def self.entity_id(entity)
        id = entity.entityID
        raise SelectionError, 'Native entity identity is unavailable.' unless id.is_a?(Integer) && id > 0
        id
      end

      def self.same_entity?(first, second); entity_id(first) == entity_id(second); end
      def self.unique_entities(items); items.uniq { |entity| entity_id(entity) }; end
      def self.native_face?(entity); defined?(Sketchup::Face) && entity.is_a?(Sketchup::Face); end
      def self.native_edge?(entity); defined?(Sketchup::Edge) && entity.is_a?(Sketchup::Edge); end
      def self.native_group?(entity); defined?(Sketchup::Group) && entity.is_a?(Sketchup::Group); end
      def self.native_container?(entity)
        native_group?(entity) || (defined?(Sketchup::ComponentInstance) && entity.is_a?(Sketchup::ComponentInstance))
      end
    end
  end
end
