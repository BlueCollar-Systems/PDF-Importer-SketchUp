# Bounded, editable source-width paint for ordinary PDF vector strokes.
# Curves use bounded width-relative source Bezier sampling. This is not a claim of
# analytic curve/pixel equality or complete PDF paint-order composition.
require 'json'
require_relative 'planar_white_knockout'

module BlueCollarSystems
  module PDFVectorImporter
    module VectorStrokeFootprint
      class Unsupported < StandardError; end
      ROUND_SEGMENTS = 48 # per semicircle, matching original annotation capsules
      MAX_POINTS = 256
      MAX_CURVE_DEPTH = 12
      DICTIONARY = 'BC_PDF_Importer'.freeze

      def self.fail_contract(message)
        raise RepresentationFidelity::ContractError, 'Source-width stroke: ' + message
      end

      def self.finite_number?(value)
        value.is_a?(Numeric) && value.to_f.finite?
      end

      def self.add(a, b); [a[0]+b[0], a[1]+b[1]]; end
      def self.sub(a, b); [a[0]-b[0], a[1]-b[1]]; end
      def self.mul(a, value); [a[0]*value, a[1]*value]; end
      def self.cross(a, b); a[0]*b[1]-a[1]*b[0]; end
      def self.area2(loop)
        loop.each_index.inject(0.to_r) { |sum,i| sum + cross(loop[i],loop[(i+1)%loop.length]) }
      end

      def self.intersection(a, direction_a, b, direction_b)
        denominator = cross(direction_a,direction_b)
        raise Unsupported, 'parallel/reversing offset join' if denominator == 0
        add(a,mul(direction_a,cross(sub(b,a),direction_b)/denominator))
      end

      def self.arc(center, start_vector, sweep)
        start = Math.atan2(start_vector[1],start_vector[0])
        radius = Math.sqrt(start_vector[0]**2+start_vector[1]**2)
        count = [(sweep.abs/Math::PI*ROUND_SEGMENTS).ceil,1].max
        (0..count).map do |index|
          angle = start+sweep*index/count
          add(center,[radius*Math.cos(angle),radius*Math.sin(angle)].map(&:to_r))
        end
      end

      # Flatten in the source stroke metric, before its CTM. A bound on both
      # control-point distances to the chord segment bounds the whole cubic
      # by convexity. Tiny/complex curves stop at a finite budget, never silently
      # accept the fixed 0.25pt centerline sampling as width fidelity.
      def self.flatten_subpath(path, subpath)
        raise Unsupported, 'source solid stroke color is unproven (Pattern or unqualified color space)' unless
          path.respond_to?(:source_stroke_solid_color_proven) && path.source_stroke_solid_color_proven == true
        matrix=path.ctm
        raise Unsupported, 'invalid source stroke CTM' unless matrix.is_a?(Array) && matrix.length == 6 && matrix.all? { |v| finite_number?(v) }
        a,b,c,d,e,f=matrix.map(&:to_r)
        determinant=a*d-b*c
        raise Unsupported, 'singular source stroke CTM' if determinant == 0
        width=path.line_width
        raise Unsupported, 'invalid or device-dependent zero-width stroke' unless finite_number?(width) && width > 0
        tolerance=[width.to_f/64.0,0.05].min
        inverse=lambda do |point|
          raise Unsupported, 'invalid source curve point' unless point.is_a?(Array) && point.length == 2 && point.all? { |v| finite_number?(v) }
          dx,dy=point[0].to_r-e,point[1].to_r-f
          [(d*dx-c*dy)/determinant,(-b*dx+a*dy)/determinant]
        end
        points=[]
        sampled=false
        subpath.segments.each do |segment|
          case segment.type
          when :move
            raise Unsupported, 'multiple moves in one source subpath' unless points.empty?
            points << inverse.call(segment.points.fetch(0))
          when :line
            p,q=segment.points.map(&inverse)
            raise Unsupported, 'disconnected source line' unless points.last == p
            points << q unless points.last == q
          when :curve
            controls=segment.points.map(&inverse)
            raise Unsupported, 'disconnected source cubic' unless controls.length == 4 && points.last == controls[0]
            append_cubic!(points,controls,tolerance,0)
            sampled=true
          else
            raise Unsupported, 'unsupported source path segment'
          end
          raise Unsupported, 'centerline point budget exceeded' if points.length > MAX_POINTS+1
        end
        mapped=points.map { |x,y| [(a*x+c*y+e).to_f,(b*x+d*y+f).to_f] }
        {:points=>mapped,:curve_sampled=>sampled,:source_curve_tolerance_pdf_points=>sampled ? tolerance : 0.0}
      end

      def self.append_cubic!(points, controls, tolerance, depth)
        p,q,r,s=controls
        direction=sub(s,p)
        squared=direction.inject(0.to_r) { |sum,v| sum+v*v }
        flat=[q,r].all? do |control|
          relative=sub(control,p)
          t=squared == 0 ? 0.to_r : relative.zip(direction).inject(0.to_r) { |sum,pair| sum+pair[0]*pair[1] }/squared
          t=[[t,0.to_r].max,1.to_r].min
          delta=sub(relative,mul(direction,t))
          delta.inject(0.to_r) { |sum,v| sum+v*v } <= tolerance.to_r**2
        end
        if flat
          points << s unless points.last == s
          raise Unsupported, 'centerline point budget exceeded' if points.length > MAX_POINTS+1
          return
        end
        raise Unsupported, 'width-relative curve subdivision budget exceeded' if depth >= MAX_CURVE_DEPTH
        pq=mul(add(p,q),Rational(1,2)); qr=mul(add(q,r),Rational(1,2)); rs=mul(add(r,s),Rational(1,2))
        left=mul(add(pq,qr),Rational(1,2)); right=mul(add(qr,rs),Rational(1,2)); middle=mul(add(left,right),Rational(1,2))
        append_cubic!(points,[p,pq,left,middle],tolerance,depth+1)
        append_cubic!(points,[middle,right,rs,s],tolerance,depth+1)
      end

      # Polygonal clipping applies to the complete stroke footprint, not just
      # its centerline, so caps painting across a rectangular clip are retained.
      def self.clip_polygon(loop, bounds)
        return [] if bounds == :empty
        result = loop
        [[0,bounds[0],1],[0,bounds[2],-1],[1,bounds[1],1],[1,bounds[3],-1]].each do |axis,value,sign|
          output=[]
          result.each_with_index do |b,index|
            a=result[index-1]
            inside_a=(a[axis]-value)*sign >= 0
            inside_b=(b[axis]-value)*sign >= 0
            if inside_a != inside_b
              t=(value.to_r-a[axis])/(b[axis]-a[axis])
              output << add(a,mul(sub(b,a),t))
            end
            output << b if inside_b
          end
          result=output
          break if result.empty?
        end
        clean=[]
        result.each { |point| clean << point unless clean.last == point }
        clean.pop if clean.length > 1 && clean.last == clean.first
        clean
      end

      def self.plan(path, points, closed, bounds)
        raise Unsupported, bounds[:unsupported] if bounds.is_a?(Hash) && bounds[:unsupported]
        raise Unsupported, 'stroke style/opacity is unproven or translucent' unless
          path.source_stroke_style_proven == true && path.source_stroke_opacity == 1.0
        raise Unsupported, 'source solid stroke color is unproven (Pattern or unqualified color space)' unless
          path.respond_to?(:source_stroke_solid_color_proven) && path.source_stroke_solid_color_proven == true
        raise Unsupported, 'path construction CTM is unproven' unless
          path.respond_to?(:source_stroke_ctm_proven) && path.source_stroke_ctm_proven == true
        raise Unsupported, 'combined fill/stroke paint is outside this bounded footprint route' if path.fill
        width=path.line_width
        raise Unsupported, 'zero-width hairline is device-dependent' if width == 0
        raise Unsupported, 'invalid source width' unless finite_number?(width) && width > 0
        rgb=path.stroke_color
        raise Unsupported, 'invalid source stroke color' unless rgb.is_a?(Array) && rgb.length >= 3 &&
          rgb.first(3).all? { |v| finite_number?(v) && v >= 0 && v <= 1 }
        dash=path.dash_pattern
        raise Unsupported, 'dashed stroke footprint is not yet represented' unless
          dash.nil? || (dash.is_a?(Array) && dash.length == 2 && dash[0] == [])
        raise Unsupported, 'invalid cap/join or miter limit' unless
          [0,1,2].include?(path.line_cap) && [0,1,2].include?(path.line_join) &&
          finite_number?(path.source_miter_limit) && path.source_miter_limit >= 1
        matrix=path.ctm
        raise Unsupported, 'invalid source stroke CTM' unless matrix.is_a?(Array) && matrix.length == 6 && matrix.all? { |v| finite_number?(v) }
        a,b,c,d=matrix.first(4).map(&:to_r)
        determinant=a*d-b*c
        raise Unsupported, 'singular source stroke CTM' if determinant == 0
        clean=[]
        points.each do |point|
          raise Unsupported, 'invalid source centerline' unless point.is_a?(Array) && point.length >= 2 && point.first(2).all? { |v| finite_number?(v) }
          p=point.first(2).map(&:to_r)
          clean << p unless clean.last == p
        end
        clean.pop if closed && clean.length > 1 && clean.first == clean.last
        raise Unsupported, 'centerline point budget exceeded' if clean.length > MAX_POINTS
        raise Unsupported, 'degenerate source centerline' if clean.length < (closed ? 3 : 2)
        raise Unsupported, 'open multisegment stroke requires general join/overlap composition' if !closed && clean.length != 2
        origin=clean.first
        # Invert deltas exactly; translation and nonuniform/reflected CTMs must
        # never be replaced by one averaged width scale.
        user=clean.map do |point|
          dx,dy=sub(point,origin)
          [(d*dx-c*dy)/determinant,(-b*dx+a*dy)/determinant]
        end
        user.reverse! if closed && area2(user) < 0
        edges=(closed ? user+[user.first] : user).each_cons(2).map do |p,q|
          direction=sub(q,p)
          length=Math.sqrt(direction[0]**2+direction[1]**2)
          raise Unsupported, 'degenerate source segment' unless length.finite? && length > 0
          normal=[-direction[1].to_f/length,direction[0].to_f/length].map(&:to_r)
          {:start=>p,:finish=>q,:direction=>direction,:normal=>normal}
        end
        half=width.to_r/2
        polygons=[]
        if closed
          raise Unsupported, 'nonconvex/reversing closed stroke needs general offset composition' unless
            edges.each_index.all? { |i| cross(edges[i-1][:direction],edges[i][:direction]) > 0 } &&
              edges.all? { |edge| user.all? { |point| cross(edge[:direction],sub(point,edge[:start])) >= 0 } }
          inner=[]; outer=[]
          user.each_with_index do |point,index|
            before,after=edges[index-1],edges[index]
            inward_before=add(point,mul(before[:normal],half))
            inward_after=add(point,mul(after[:normal],half))
            inner << intersection(inward_before,before[:direction],inward_after,after[:direction])
            first=add(point,mul(before[:normal],-half))
            last=add(point,mul(after[:normal],-half))
            miter=intersection(first,before[:direction],last,after[:direction])
            ratio=Math.sqrt(sub(miter,point).inject(0) { |sum,v| sum+v*v })/half
            corner = if path.line_join == 0 && ratio <= path.source_miter_limit
                       [miter]
                     elsif path.line_join == 1
                       sweep=Math.atan2(cross(before[:direction],after[:direction]),
                         before[:direction].zip(after[:direction]).inject(0) { |sum,pair| sum+pair[0]*pair[1] })
                       arc(point,sub(first,point),sweep).tap { |values| values[0]=first; values[-1]=last }
                     else
                       [first,last] # bevel is also the PDF miter-limit fallback
                     end
            outer << corner
          end
          # Offset collapse must not fill a genuine counter or invert strips.
          raise Unsupported, 'stroke width collapses the convex inner counter' unless
            area2(inner) > 0 && inner.each_index.all? do |i|
              cross(sub(inner[(i+1)%inner.length],inner[i]),sub(inner[(i+2)%inner.length],inner[(i+1)%inner.length])) > 0 &&
                edges.all? { |edge| cross(edge[:direction],sub(inner[i],edge[:start])) > 0 }
            end
          user.each_index do |index|
            following=(index+1)%user.length
            polygons << [outer[index].last,outer[following].first,inner[following],inner[index]]
            outer[index].each_cons(2) { |p,q| polygons << [p,q,inner[index]] }
          end
        else
          edge=edges.first
          p,q=edge.values_at(:start,:finish)
          normal=mul(edge[:normal],half)
          if path.line_cap == 2
            length=Math.sqrt(edge[:direction][0]**2+edge[:direction][1]**2)
            extension=mul(edge[:direction],(half/length).to_r)
            p=sub(p,extension); q=add(q,extension)
          end
          polygons << [sub(p,normal),sub(q,normal),add(q,normal),add(p,normal)]
          if path.line_cap == 1
            [ [edge[:start],normal], [edge[:finish],mul(normal,-1)] ].each do |point,start|
              values=arc(point,start,Math::PI)
              values[0]=add(point,start); values[-1]=sub(point,start)
              values.each_cons(2) { |v,w| polygons << [point,v,w] }
            end
          end
        end
        map=lambda { |p| [origin[0]+a*p[0]+c*p[1],origin[1]+b*p[0]+d*p[1]] }
        polygons=polygons.map do |polygon|
          clipped=clip_polygon(polygon.map(&map),bounds)
          clipped.reverse! if area2(clipped) < 0
          clipped
        end.select { |polygon| polygon.length >= 3 && area2(polygon) > 0 }
        # All construction cells must be convex. No host rediscovery, polygon
        # repair or merge tolerance is permission to change the planned boundary.
        polygons.each do |polygon|
          raise Unsupported, 'stroke footprint cell is not strictly convex' unless polygon.each_index.all? do |i|
            cross(sub(polygon[(i+1)%polygon.length],polygon[i]),sub(polygon[(i+2)%polygon.length],polygon[(i+1)%polygon.length])) > 0
          end
        end
        {:polygons=>polygons, :centerline=>clean, :closed=>closed,
          :source_width_pdf_points=>width, :source_ctm=>matrix.dup,
          :source_line_cap=>path.line_cap, :source_line_join=>path.line_join,
          :source_miter_limit=>path.source_miter_limit,
          :source_rgb=>rgb.first(3).map { |v| (v*255).round },
          :round_segments_per_semicircle=>ROUND_SEGMENTS,
          :native_curve_representation=>'source_sampled_polygonal_footprint'}
      end

      def self.build!(owner, specification, mapper, material, layer)
        cells=specification[:polygons].map do |polygon|
          {:loop=>polygon.map do |point|
            p=mapper.call(point[0].to_f,point[1].to_f)
            [p.x.to_r,p.y.to_r,0.to_r]
          end}
        end
        return {:group=>nil,:face_count=>0,:edge_count=>0,:clipped_empty=>true} if cells.empty?
        scale=1024.0
        required=PlanarWhiteKnockout.partition_construction_scale(cells)
        scale *= 2 while scale < required
        group=owner.add_group
        fail_contract('native owned group creation failed') unless group && group.valid?
        group.name='PDF source-width vector stroke'
        group.layer=layer if layer
        fail_contract('native footprint layer readback differs') if layer && group.layer != layer
        group.transformation=Geom::Transformation.scaling(1.0/scale,1.0/scale,1.0/scale)
        points=PlanarWhiteKnockout.partition_construction_points(cells,[0.0,0.0,0.0],scale)
        points.each do |expected,point|
          actual=point.transform(group.transformation)
          fail_contract('native scale changed page coordinates') unless
            [actual.x.to_f,actual.y.to_f,actual.z.to_f] == expected.map(&:to_f)
        end
        edge_count=0
        cells.each do |cell|
          container=group.entities.add_group
          container.layer=layer if layer
          fail_contract('native footprint cell layer readback differs') if layer && container.layer != layer
          face=container.entities.add_face(cell[:loop].map { |point| points.fetch(point) })
          fail_contract('native footprint face is missing') unless face
          PlanarWhiteKnockout.verify_partition_face!(face,cell[:loop].map { |point| points.fetch(point) })
          face.material=face.back_material=material
          face.layer=layer if layer
          fail_contract('native footprint color readback differs') unless face.material == material && face.back_material == material
          color=face.material.color
          fail_contract('native footprint RGB/opacity readback differs') unless
            [color.red,color.green,color.blue] == specification[:source_rgb] &&
              face.material.alpha == 1.0 && face.material.texture.nil?
          fail_contract('native footprint face layer readback differs') if layer && face.layer != layer
          face.reverse! if face.normal.z < 0
          face.edges.each do |edge|
            edge.hidden=true
            edge.layer=layer if layer
            fail_contract('native footprint contour remains visible') unless edge.hidden?
            fail_contract('native footprint contour layer readback differs') if layer && edge.layer != layer
            edge_count += 1
          end
        end
        # Retain exact editable centerlines in their own hidden container.
        centerline=group.entities.add_group
        centerline.name='Original editable stroke centerline'
        centerline.layer=layer if layer
        fail_contract('native centerline layer readback differs') if layer && centerline.layer != layer
        centerline.hidden=true
        fail_contract('native centerline container remains visible') unless centerline.hidden?
        source=specification[:centerline].map do |point|
          p=mapper.call(point[0].to_f,point[1].to_f)
          Geom::Point3d.new(p.x*scale,p.y*scale,0.0)
        end
        source << source.first if specification[:closed]
        source.each_cons(2) do |p,q|
          edge=centerline.entities.add_line(p,q)
          fail_contract('native editable source centerline is missing') unless edge && edge.valid?
          actual=[edge.start.position,edge.end.position].map { |v| [v.x.to_f,v.y.to_f,v.z.to_f] }.sort
          expected=[p,q].map { |v| [v.x.to_f,v.y.to_f,v.z.to_f] }.sort
          fail_contract('native source centerline moved') unless actual == expected
          edge.material=material
          edge.layer=layer if layer
          fail_contract('native centerline color readback differs') unless edge.material == material
          fail_contract('native centerline layer readback differs') if layer && edge.layer != layer
          edge_count += 1
        end
        group.set_attribute(DICTIONARY,'source_width_footprint',true)
        fail_contract('native footprint binding readback differs') unless group.get_attribute(DICTIONARY,'source_width_footprint',false) == true
        binding=JSON.generate(specification.reject { |key,_value| [:polygons,:centerline].include?(key) })
        group.set_attribute(DICTIONARY,'source_width_style',binding)
        fail_contract('native source style binding readback differs') unless group.get_attribute(DICTIONARY,'source_width_style',nil) == binding
        {:group=>group,:face_count=>cells.length,:edge_count=>edge_count,:construction_scale=>scale}
      rescue StandardError => primary
        cleanup_error=nil
        if group
          begin
            group.erase! if group.valid?
            raise 'owned footprint group remains valid after erase' if group.valid?
          rescue StandardError => error
            cleanup_error=error
          end
        end
        if cleanup_error
          # Keep the triggering host failure and its backtrace. The caller must
          # abort the owning import; failed local cleanup never becomes success.
          raise RepresentationFidelity::ContractError,
            "#{primary.class}: #{primary.message}; owned stroke cleanup failed (#{cleanup_error.class}: #{cleanup_error.message})",
            primary.backtrace
        end
        raise
      end
    end
  end
end
