# Editable original annotation capsules. Construction uses a scaled local frame
# so source micro-centerlines survive SketchUp's minimum edge tolerance.
require 'json'
require_relative 'annotation_composite_provider'
require_relative 'page_transform'
require_relative 'item_raster_display'

module BlueCollarSystems
  module PDFVectorImporter
    module AnnotationMicrostrokeGeometry
      CONSTRUCTION_SCALE = 1024.0
      ARC_SEGMENTS = 48
      DICTIONARY = 'BC_PDF_Importer'.freeze

      def self.plan(record, context)
        unless record[:original_geometry_verified] == true && record[:full_capsule_clip_verified] == true &&
               AnnotationCompositeProvider.eligible_microline?(record)
          fail_contract('native capsule lacks eligible original annotation geometry')
        end
        factor = SourceRoundAnnotationInk.number(context.fetch(:scale)) / 72.0
        raise SourceRoundAnnotationInk::Unproven, 'annotation model scale is not positive' unless factor > 0
        y_offset = SourceRoundAnnotationInk.number(context.fetch(:page_y_offset))
        a,b = [:start_pdf,:end_pdf].map do |key|
          xy = PageTransform.transform_point(record[key][0],record[key][1],context.fetch(:media_box),context.fetch(:page_rotation))
          [xy[0]*factor,xy[1]*factor+y_offset,0.0]
        end
        dx,dy = b[0]-a[0],b[1]-a[1]
        length = Math.sqrt(dx*dx+dy*dy)
        radius = SourceRoundAnnotationInk.number(record[:radius_pdf])*factor
        fail_contract('native capsule source size is not positive') unless length > 0 && radius > 0
        ux,uy = dx/length,dy/length
        size = CONSTRUCTION_SCALE
        local_length,local_radius = length*size,radius*size
        if local_length < 0.01 || local_radius < 0.01
          raise SourceRoundAnnotationInk::Unproven, 'source microline is below the bounded scale-safe construction size'
        end
        { :source=>record, :world_start=>a, :world_end=>b,
          :source_radius_inches=>radius, :source_length_inches=>length,
          :source_analytic_area_inches2=>2.0*radius*length+Math::PI*radius*radius,
          :construction_scale=>size, :local_length=>local_length, :local_radius=>local_radius,
          :arc_segments_per_semicircle=>ARC_SEGMENTS,
          :expected_local_face_area=>2.0*local_radius*local_length +
            ARC_SEGMENTS*local_radius*local_radius*Math.sin(Math::PI/ARC_SEGMENTS),
          :transform=>[ux/size,uy/size,0.0,0.0,-uy/size,ux/size,0.0,0.0,
            0.0,0.0,1.0/size,0.0,a[0],a[1],0.0,1.0] }
      end

      def self.point(values); Geom::Point3d.new(*values); end
      def self.vector(values); Geom::Vector3d.new(*values); end

      def self.close?(actual,expected,tolerance = 1.0e-8)
        a,b = Float(actual),Float(expected)
        a.finite? && b.finite? && (a-b).abs <= tolerance*[1.0,b.abs].max
      rescue ArgumentError,TypeError
        false
      end

      def self.same_point?(actual,expected)
        values = actual.respond_to?(:to_a) ? actual.to_a : Array(actual)
        values.length == 3 && values.zip(expected).all? { |a,b| close?(a,b) }
      end

      def self.same_segment?(edge, a, b)
        return false unless edge && edge.valid?
        (same_point?(edge.start.position,a) && same_point?(edge.end.position,b)) ||
          (same_point?(edge.start.position,b) && same_point?(edge.end.position,a))
      end

      def self.verify_arc!(edges, center, radius, side)
        fail_contract('native annotation semicircle was not created') unless edges.is_a?(Array) && edges.length == ARC_SEGMENTS && edges.all? { |edge| edge && edge.valid? }
        curve = edges.first.curve
        unless curve && curve.respond_to?(:radius) && edges.all? { |edge| edge.curve == curve } &&
               close?(curve.radius,radius) && same_point?(curve.center,center) &&
               same_point?(curve.normal,[0,0,1]) && close?((curve.end_angle-curve.start_angle).abs,Math::PI)
          fail_contract('native annotation arc lost original center/radius/sweep')
        end
        vertices = edges.flat_map { |edge| [edge.start.position,edge.end.position] }
        unless vertices.all? do |vertex|
          p = vertex.to_a
          close?(p[2],0.0) && close?(Math.sqrt((p[0]-center[0])**2+(p[1]-center[1])**2),radius) &&
            (side == :right ? p[0] >= center[0]-1.0e-8 : p[0] <= center[0]+1.0e-8)
        end
          fail_contract('native annotation semicircle turns inward or changes radius')
        end
        curve
      end

      def self.assign_layer!(entity,layer)
        entity.layer = layer
        fail_contract('native annotation layer setter was ignored') unless entity.layer == layer
      end

      def self.new_material(model,rgb)
        color = rgb.map { |n| (SourceRoundAnnotationInk.number(n)*255).round }
        fail_contract('native annotation RGB is invalid') unless color.length == 3 && color.all? { |n| n >= 0 && n <= 255 }
        base = 'PDF_OriginalAnnotation_' + color.join('_')
        name,index = base,0
        while model.materials[name]
          index += 1
          name = base + '_' + index.to_s
        end
        material = model.materials.add(name)
        material.color = Sketchup::Color.new(*color)
        actual = material.color
        unless [actual.red,actual.green,actual.blue] == color && material.alpha.to_f == 1.0 && material.texture.nil?
          fail_contract('native annotation material is not opaque original RGB')
        end
        material
      end

      def self.build!(owner,record,context)
        specification = plan(record,context)
        group = owner.add_group
        fail_contract('native annotation capsule group is unavailable') unless group && group.valid?
        layer = context.fetch(:layer)
        assign_layer!(group,layer)
        group.hidden = false
        group.material = nil
        fail_contract('native annotation group is hidden or tinted') unless !group.hidden? && group.material.nil?
        group.name = 'Original annotation ' + record[:annotation_ref].to_s
        group.set_attribute(DICTIONARY,'original_annotation_capsule',true)
        group.set_attribute(DICTIONARY,'original_annotation_source',JSON.generate(record))
        group.transformation = Geom::Transformation.new(specification[:transform])
        actual_matrix = ItemRasterDisplay.matrix!(group.transformation.to_a)
        unless actual_matrix.length == 16 && actual_matrix.zip(specification[:transform]).all? { |a,b| close?(a,b,1.0e-12) }
          fail_contract('native annotation placement setter was ignored')
        end
        boundary, centerline = group.entities.add_group, group.entities.add_group
        [boundary,centerline].each { |child| assign_layer!(child,layer) }
        boundary.name = 'Round stroke footprint'
        boundary.set_attribute(DICTIONARY,'original_annotation_boundary',true)
        centerline.name = 'Original editable centerline'
        centerline.set_attribute(DICTIONARY,'original_annotation_centerline',true)
        length,radius = specification.values_at(:local_length,:local_radius)
        lower = boundary.entities.add_line(point([0,-radius,0]),point([length,-radius,0]))
        right = boundary.entities.add_arc(point([length,0,0]),vector([0,-1,0]),vector([0,0,1]),radius,0.0,Math::PI,ARC_SEGMENTS)
        upper = boundary.entities.add_line(point([length,radius,0]),point([0,radius,0]))
        left = boundary.entities.add_arc(point([0,0,0]),vector([0,1,0]),vector([0,0,1]),radius,0.0,Math::PI,ARC_SEGMENTS)
        verify_arc!(right,[length,0,0],radius,:right)
        verify_arc!(left,[0,0,0],radius,:left)
        unless lower && upper && lower.valid? && upper.valid?
          fail_contract('native annotation side edges were dropped')
        end
        edges = [lower] + right + [upper] + left
        face = boundary.entities.add_face(edges)
        unless face && face.valid? && face.loops.length == 1 && face.edges.length == edges.length &&
               close?(face.area,specification[:expected_local_face_area])
          fail_contract('native annotation face lost capsule topology or polygon area')
        end
        material = new_material(context.fetch(:model),record[:stroke_rgb])
        face.material = material
        face.back_material = material
        unless face.material == material && face.back_material == material
          fail_contract('native annotation face material setter was ignored')
        end
        edges.each do |edge|
          assign_layer!(edge,layer)
          edge.hidden = true
          fail_contract('native annotation boundary edge remained visible') unless edge.hidden?
        end
        assign_layer!(face,layer)
        line = centerline.entities.add_line(point([0,0,0]),point([length,0,0]))
        unless same_segment?(line,[0,0,0],[length,0,0])
          fail_contract('native original annotation centerline was not retained')
        end
        assign_layer!(line,layer)
        # The source paint is the capsule, not an extra visible centerline.
        line.hidden = true
        fail_contract('native source centerline remained visible') unless line.hidden?
        group.set_attribute(DICTIONARY,'original_annotation_geometry_plan',JSON.generate(specification))
        verify_snapshot!(snapshot(group),specification)
        { :entity=>group, :boundary=>boundary, :centerline=>centerline,
          :source=>record, :geometry_plan=>specification,
          :native_face_polygon_area_inches2=>face.area/(CONSTRUCTION_SCALE**2),
          :native_curve_type=>'ArcCurve', :native_face_is_segmented=>true }
      rescue StandardError
        group.erase! if group && group.valid?
        raise
      end

      def self.material_snapshot(material)
        return nil unless material
        color = material.color
        { :rgb=>[color.red,color.green,color.blue], :alpha=>material.alpha.to_f,
          :textured=>!material.texture.nil? }
      end

      def self.entity_id(entity)
        RepresentationFidelity.stable_entity_id(entity)
      end

      def self.entity_state(entity)
        { :entity_id=>entity_id(entity), :typename=>entity.typename.to_s,
          :valid=>entity.valid?, :hidden=>entity.hidden?, :layer=>entity.layer.name.to_s,
          :material=>material_snapshot(entity.material) }
      end

      # Read the native curve metadata and every endpoint; the importer-written
      # JSON is deliberately not used as physical geometry evidence.
      def self.snapshot(group)
        result = entity_state(group).merge(:transformation=>group.transformation.to_a)
        result[:children] = group.entities.to_a.map do |child|
          state = entity_state(child)
          next state unless child.typename.to_s == 'Group'
          state[:transformation] = child.transformation.to_a
          state[:boundary] = child.get_attribute(DICTIONARY,'original_annotation_boundary',false) == true
          state[:centerline] = child.get_attribute(DICTIONARY,'original_annotation_centerline',false) == true
          curves = {}
          state[:entities] = child.entities.to_a.map do |entity|
            item = entity_state(entity)
            if entity.typename.to_s == 'Edge'
              item[:points] = [entity.start.position.to_a,entity.end.position.to_a]
              curve = entity.curve
              if curve
                key = curve.object_id
                unless curves.key?(key)
                  fail_contract('annotation boundary curve is not an ArcCurve') unless curve.respond_to?(:radius) && curve.respond_to?(:center)
                  curves[key] = { :index=>curves.length, :center=>curve.center.to_a,
                    :radius=>curve.radius.to_f, :normal=>curve.normal.to_a,
                    :start_angle=>curve.start_angle.to_f, :end_angle=>curve.end_angle.to_f }
                end
                item[:arc_index] = curves[key][:index]
              end
            elsif entity.typename.to_s == 'Face'
              item[:area] = entity.area.to_f
              item[:loops] = entity.loops.map { |loop| loop.vertices.map { |vertex| vertex.position.to_a } }
              item[:back_material] = material_snapshot(entity.back_material)
            end
            item
          end
          state[:arcs] = curves.values.sort_by { |curve| curve[:index] }
          state
        end
        result
      end

      def self.symbols(value)
        case value
        when Hash
          value.each_with_object({}) { |(key,item),result| result[key.to_sym] = symbols(item) }
        when Array
          value.map { |item| symbols(item) }
        else
          value
        end
      end

      def self.verify_snapshot!(raw,expected,expected_hidden = false)
        actual = symbols(raw)
        expected = symbols(expected)
        matrix = ItemRasterDisplay.matrix!(actual[:transformation])
        unless [true,false].include?(expected_hidden) &&
               actual[:typename] == 'Group' && actual[:valid] == true && actual[:hidden] == expected_hidden &&
               actual[:material].nil? && matrix.zip(expected[:transform]).all? { |a,b| close?(a,b,1.0e-12) }
          fail_contract('original annotation group placement/style changed')
        end
        children = actual[:children]
        unless children.is_a?(Array) && children.length == 2 && children.all? do |child|
          child[:typename] == 'Group' && child[:valid] == true && child[:hidden] == false && child[:material].nil? &&
            child[:layer] == actual[:layer] && ItemRasterDisplay.matrix!(child[:transformation]) == ItemRasterDisplay::IDENTITY
        end
          fail_contract('original annotation child ownership/style changed')
        end
        boundaries = children.select { |child| child[:boundary] == true && child[:centerline] == false }
        lines = children.select { |child| child[:centerline] == true && child[:boundary] == false }
        fail_contract('original annotation roles are ambiguous') unless boundaries.length == 1 && lines.length == 1
        boundary,line = boundaries.first,lines.first
        length,radius = expected.values_at(:local_length,:local_radius)
        edge = Array(line[:entities])
        unless edge.length == 1 && edge.first[:typename] == 'Edge' && edge.first[:valid] == true &&
               edge.first[:hidden] == true && edge.first[:arc_index].nil? &&
               edge.first[:layer] == actual[:layer] &&
               same_points_unordered?(edge.first[:points],[[0,0,0],[length,0,0]])
          fail_contract('original annotation centerline changed')
        end
        entities = Array(boundary[:entities])
        edges,faces = entities.partition { |item| item[:typename] == 'Edge' }
        unless edges.length == 2+2*ARC_SEGMENTS && faces.length == 1 && faces.first[:typename] == 'Face' &&
               entities.all? { |item| item[:valid] == true && item[:layer] == actual[:layer] } &&
               edges.all? { |item| item[:hidden] == true }
          fail_contract('original annotation native topology changed')
        end
        straight = edges.select { |item| item[:arc_index].nil? }
        sides = [[[0,-radius,0],[length,-radius,0]],[[0,radius,0],[length,radius,0]]]
        unless straight.length == 2 && sides.all? { |points| straight.count { |item| same_points_unordered?(item[:points],points) } == 1 }
          fail_contract('original annotation straight sides changed')
        end
        arcs = Array(boundary[:arcs])
        fail_contract('original annotation lost its two analytic semicircles') unless arcs.length == 2
        [[length,0,0],[0,0,0]].each_with_index do |center,index|
          matches = arcs.select { |curve| same_point?(curve[:center],center) }
          fail_contract('original annotation arc center changed') unless matches.length == 1
          curve = matches.first
          arc_edges = edges.select { |item| item[:arc_index] == curve[:index] }
          points = arc_edges.flat_map { |item| Array(item[:points]) }
          unless close?(curve[:radius],radius) && same_point?(curve[:normal],[0,0,1]) &&
                 close?((curve[:end_angle]-curve[:start_angle]).abs,Math::PI) && arc_edges.length == ARC_SEGMENTS &&
                 points.all? do |p|
                   p.is_a?(Array) && p.length == 3 && close?(p[2],0) &&
                     close?(Math.sqrt((p[0]-center[0])**2+(p[1]-center[1])**2),radius) &&
                     (index == 0 ? p[0] >= center[0]-1.0e-8 : p[0] <= center[0]+1.0e-8)
                 end
            fail_contract('original annotation semicircle radius/side/sweep changed')
          end
          samples = (0..ARC_SEGMENTS).map do |sample|
            angle = Math::PI*sample/ARC_SEGMENTS
            [center[0]+(index == 0 ? 1.0 : -1.0)*radius*Math.sin(angle),
              (index == 0 ? -1.0 : 1.0)*radius*Math.cos(angle),0.0]
          end
          unless samples.each_cons(2).all? do |a,b|
            arc_edges.count { |item| same_points_unordered?(item[:points],[a,b]) } == 1
          end
            fail_contract('original annotation arc connectivity or subdivision changed')
          end
        end
        face = faces.first
        rgb = expected[:source][:stroke_rgb].map { |n| (n*255).round }
        desired = { :rgb=>rgb, :alpha=>1.0, :textured=>false }
        unless face[:hidden] == false && face[:material] == desired && face[:back_material] == desired &&
               close?(face[:area],expected[:expected_local_face_area]) && face[:loops].is_a?(Array) && face[:loops].length == 1 &&
               same_points_unordered?(face[:loops].first,edges.flat_map { |item| item[:points] }.uniq)
          fail_contract('original annotation face area/boundary/fill changed')
        end
        loop_points = face[:loops].first
        unless loop_points.each_with_index.all? do |point,index|
          pair = [point,loop_points[(index+1)%loop_points.length]]
          edges.count { |item| same_points_unordered?(item[:points],pair) } == 1
        end
          fail_contract('original annotation face loop connectivity changed')
        end
        true
      end

      def self.same_points_unordered?(actual,expected)
        actual.is_a?(Array) && actual.length == expected.length &&
          expected.all? { |point| actual.count { |value| same_point?(value,point) } == 1 }
      end

      def self.fail_contract(message)
        raise RepresentationFidelity::ContractError,message
      end
    end
  end
end
