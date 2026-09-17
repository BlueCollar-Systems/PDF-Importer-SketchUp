# Proven final PDF rectangle annotations, kept as native vector geometry.
# This changes only decorative display depth; source XY and text stay intact.
require File.join(File.dirname(__FILE__), 'planar_white_knockout')

module BlueCollarSystems
  module PDFVectorImporter
    module LatePdfOverlays
      DISPLAY_GAP = 0.001 # inches in the caller's page/model coordinate context
      DICTIONARY = 'BC_PDF_Importer'.freeze

      def self.valid_order?(order)
        PlanarWhiteKnockout.valid_order?(order)
      end

      # All source text operands, not merged text-span minima, must be supplied.
      # Extra orders can include image paints. Unknown source order fails closed.
      def self.eligible_records(paths, text_orders, extra_paint_orders = [])
        paths = Array(paths)
        orders = Array(text_orders) + Array(extra_paint_orders)
        return [] unless orders.all? { |order| valid_order?(order) }
        return [] unless paths.all? { |path| valid_order?(path.source_paint_order) }
        candidates = []
        paths.each_with_index do |path, index|
          record = rectangle_record(path, index)
          record ? candidates << record : orders << path.source_paint_order
        end
        barrier = orders.max
        candidates.select do |record|
          !barrier || (record[:paint_order] <=> barrier) == 1
        end.sort_by { |record| record[:paint_order] }
      end

      def self.number?(value)
        value.is_a?(Numeric) && value.to_f.finite?
      end

      def self.color?(value)
        value.is_a?(Array) && value.length == 3 &&
          value.all? { |component| number?(component) && component >= 0 && component <= 1 }
      end

      def self.uniform_ctm_scale(ctm)
        return nil unless ctm.is_a?(Array) && ctm.length == 6 && ctm.all? { |v| number?(v) }
        a, b, c, d = ctm.first(4).map(&:to_f)
        first, second, dot = a * a + b * b, c * c + d * d, a * c + b * d
        return nil unless first > 0 && second > 0
        tolerance = [first, second].max * 1.0e-10
        return nil unless (first - second).abs <= tolerance && dot.abs <= tolerance
        Math.sqrt(first)
      end

      def self.rectangle_bounds(path)
        subpaths = Array(path.subpaths)
        return nil unless subpaths.length == 1 && subpaths[0].closed == true
        segments = Array(subpaths[0].segments)
        return nil unless segments.length == 5 && segments[0].type == :move &&
                          segments.drop(1).all? { |segment| segment.type == :line }
        lines = segments.drop(1).map(&:points)
        return nil unless lines.all? do |line|
          line.length == 2 && line.all? do |point|
            point.length == 2 && point.all? { |value| number?(value) }
          end
        end
        return nil unless segments[0].points == [lines[0][0]]
        return nil unless lines.each_with_index.all? { |line, i| line[1] == lines[(i + 1) % 4][0] }
        corners = lines.map(&:first)
        return nil unless corners.uniq.length == 4
        return nil unless lines.all? { |line| (line[0][0] == line[1][0]) != (line[0][1] == line[1][1]) }
        xs, ys = corners.map(&:first), corners.map(&:last)
        box = [xs.min, ys.min, xs.max, ys.max]
        return nil unless corners.all? { |p| [box[0], box[2]].include?(p[0]) && [box[1], box[3]].include?(p[1]) }
        box
      end

      def self.rectangle_record(path, index = nil)
        return nil unless path.fill && path.stroke && path.source_clip_clear == true &&
                          path.source_stroke_style_proven == true
        alpha = path.source_fill_opacity
        return nil unless number?(alpha) && alpha > 0 && alpha < 1 && path.source_stroke_opacity == 1.0
        return nil unless path.line_join == 0 && number?(path.source_miter_limit) &&
                          path.source_miter_limit >= Math.sqrt(2.0)
        dash = path.dash_pattern
        return nil unless dash.nil? || (dash.is_a?(Array) && dash.length == 2 && dash[0] == [])
        return nil unless color?(path.fill_color) && color?(path.stroke_color)
        scale = uniform_ctm_scale(path.ctm)
        return nil unless scale && number?(path.line_width) && path.line_width > 0
        box = rectangle_bounds(path)
        return nil unless box && valid_order?(path.source_paint_order)
        width = path.line_width * scale
        return nil unless width < [box[2] - box[0], box[3] - box[1]].min
        { :path => path, :path_index => index, :bounds => box,
          :paint_order => path.source_paint_order.dup, :stroke_width => width,
          :fill_rgb => path.fill_color.dup, :stroke_rgb => path.stroke_color.dup,
          :fill_opacity => alpha, :stroke_opacity => 1.0 }
      end

      # The opaque centered stroke covers the underlying translucent fill.
      # Partition the visible paint into an inner fill plus four disjoint miter
      # bands, avoiding coplanar double paint or a host line-width approximation.
      def self.paint_polygons(record)
        x0, y0, x1, y1 = record[:bounds]
        half = record[:stroke_width] * 0.5
        inner = [[x0 + half, y0 + half], [x1 - half, y0 + half],
                 [x1 - half, y1 - half], [x0 + half, y1 - half]]
        outer = [[x0 - half, y0 - half], [x1 + half, y0 - half],
                 [x1 + half, y1 + half], [x0 - half, y1 + half]]
        result = [{ :points => inner, :rgb => record[:fill_rgb], :opacity => record[:fill_opacity] }]
        4.times do |index|
          following = (index + 1) % 4
          result << { :points => [outer[index], outer[following], inner[following], inner[index]],
                      :rgb => record[:stroke_rgb], :opacity => 1.0 }
        end
        result
      end

      def self.material_for(materials, rgb, alpha)
        name = 'PDF final overlay ' + (rgb + [alpha]).map { |v| format('%.8g', v) }.join(',')
        material = materials[name] || materials.add(name)
        material.color = rgb.map { |v| (v * 255.0).round }
        material.alpha = alpha
        material
      end

      def self.map_point(mapper, point)
        mapped = mapper.call(point[0], point[1])
        values = mapped.respond_to?(:x) ? [mapped.x.to_f, mapped.y.to_f, mapped.z.to_f] : Array(mapped)
        values << 0.0 if values.length == 2
        unless values.length == 3 && values.all? { |v| number?(v) } && values[2].abs <= 1.0e-7
          fail_contract('late overlay mapper did not produce a finite page-plane point')
        end
        values.map(&:to_f)
      end

      # Caller supplies its complete PDF->page XY mapper and actual highest text
      # Z in the same coordinate context. It must abort the enclosing import if
      # this method raises; no text geometry or claim certificates are changed.
      def self.build!(entities, records, opts)
        mapper, materials = opts.fetch(:point_mapper), opts.fetch(:materials)
        top = opts.fetch(:highest_text_z)
        fail_contract('late overlay text-top depth is unknown') unless number?(top)
        crops = Array(opts[:final_page_crops]).select do |crop|
          crop[:final_page_crop] == true && opts[:page_number].is_a?(Integer) &&
            crop[:raster_page_number] == opts[:page_number] &&
            opts[:source_pdf_sha256].is_a?(String) &&
            crop[:source_pdf_sha256] == opts[:source_pdf_sha256]
        end
        Array(records).each_with_index.map do |record, index|
          group = entities.add_group
          group.name = 'PDF final vector annotation' if group.respond_to?(:name=)
          begin
            polygons = paint_polygons(record).map do |paint|
              paint.merge(:points => paint[:points].map { |point| map_point(mapper, point) })
            end
            points = polygons.flat_map { |paint| paint[:points] }
            origin = [points.map { |p| p[0] }.min, points.map { |p| p[1] }.min, 0.0]
            surface = group.entities.add_group
            surface.transformation = Geom::Transformation.translation(Geom::Point3d.new(*origin)) *
                                     Geom::Transformation.scaling(1.0 / PlanarWhiteKnockout::CONSTRUCTION_SCALE)
            paint_groups = polygons.map do |paint|
              # Adjacent fill/stroke polygons have different alpha. Keep their
              # native topology isolated while subtracting final-page crops;
              # rediscovering coplanar faces across all five paints can create
              # an overlapping combined face in the legacy host.
              paint_group = surface.entities.add_group
              face = paint_group.entities.add_face(paint[:points].map do |point|
                PlanarWhiteKnockout.construction_point(point, origin)
              end)
              fail_contract('native final overlay face construction failed') unless face && face.valid?
              material = material_for(materials, paint[:rgb], paint[:opacity])
              face.material = face.back_material = material
              face.reverse! if face.normal.z < 0
              paint_group.entities.to_a.each do |entity|
                next unless entity.valid?
                entity.hidden = true if entity.typename.to_s == 'Edge'
              end
              paint_group
            end
            identity = Geom::Transformation.new
            faces = PlanarWhiteKnockout.snapshots(group, identity, false)
            expected = polygons.inject(0.0) { |sum, paint| sum + PlanarWhiteKnockout.loop_area(paint[:points]) }
            actual = PlanarWhiteKnockout.source_area(faces)
            unless (actual - expected).abs <= [expected.abs * 1.0e-7, 1.0e-10].max
              fail_contract('native final overlay changed source paint area')
            end
            removed = paint_groups.inject(0.0) do |sum, paint_group|
              paint_faces = PlanarWhiteKnockout.snapshots(paint_group, surface.transformation, false)
              box = PlanarWhiteKnockout.union_bounds(paint_faces)
              intersections = crops.select { |crop| PlanarWhiteKnockout.boxes_overlap?(box, crop[:bounds]) }
              cropped = intersections.empty? ? 0.0 : PlanarWhiteKnockout.compose_group!(
                paint_group, surface.transformation, paint_faces, intersections)
              paint_group.erase! if paint_group.entities.to_a.empty?
              sum + cropped
            end
            # Fully cropped source paints must not leave containers that the
            # host silently removes after the page certificate is recorded.
            surface.erase! if surface.entities.to_a.empty?
            depth = [top.to_f, 0.0].max + DISPLAY_GAP * (index + 1)
            if group.entities.to_a.empty?
              group.erase!
              next record.merge(:group => nil, :display_depth => depth, :cropped_area => removed)
            end
            group.transformation = Geom::Transformation.translation(Geom::Point3d.new(0, 0, depth))
            { 'late_pdf_overlay' => true, 'source_paint_order' => record[:paint_order],
              'source_fill_opacity' => record[:fill_opacity], 'source_stroke_opacity' => 1.0,
              'source_stroke_width_pdf' => record[:stroke_width], 'display_depth_inches' => depth,
              'source_path_index' => record[:path_index] }.each do |key, value|
              group.set_attribute(DICTIONARY, key, value) unless value.nil?
            end
            record.merge(:group => group, :display_depth => depth, :cropped_area => removed)
          rescue StandardError
            group.erase! if group && group.valid?
            raise
          end
        end
      end

      def self.fail_contract(message)
        raise RepresentationFidelity::ContractError, message
      end
    end
  end
end
