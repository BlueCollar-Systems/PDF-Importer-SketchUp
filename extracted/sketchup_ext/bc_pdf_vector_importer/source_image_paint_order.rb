# Source-only display-order proof. This never changes image pixels, source XY,
# glyphs, or the requested text representation. Cairo definitions are traversed
# through their actual references; XML definition order is not paint order.
require 'base64'
require 'digest'
require_relative 'safe_temp'
require_relative 'svg_paint_order'
require_relative 'png_cropper'

module BlueCollarSystems
  module PDFVectorImporter
    module SourceImagePaintOrder
      IDENTITY = SvgPaintOrder::IDENTITY
      # Existing Cairo physical source-binding grid, in PDF points. Used only
      # for identity joins; never to alter a source or native coordinate.
      SOURCE_GRID = 1.0 / 128.0
      MAX_DEPTH = 64

      class Unproven < StandardError; end

      def self.number(value)
        result = Float(value)
        raise Unproven, 'nonfinite source number' unless result.finite?
        result
      rescue TypeError, ArgumentError
        raise Unproven, 'invalid source number'
      end

      def self.box(points)
        return nil if points.empty?
        [points.map { |p| p[0] }.min, points.map { |p| p[1] }.min,
         points.map { |p| p[0] }.max, points.map { |p| p[1] }.max]
      end

      def self.overlap?(a, b)
        !a || !b || (a[0] < b[2] && a[2] > b[0] && a[1] < b[3] && a[3] > b[1])
      end

      def self.covers?(a, b)
        a && b && a[0] <= b[0] && a[1] <= b[1] && a[2] >= b[2] && a[3] >= b[3]
      end

      def self.quad_covers?(quad, bounds)
        return false unless quad.length == 4 && bounds
        targets = [[bounds[0],bounds[1]],[bounds[2],bounds[1]],[bounds[2],bounds[3]],[bounds[0],bounds[3]]]
        targets.all? do |target|
          signs = quad.each_with_index.map do |a,index|
            b = quad[(index+1)%4]
            (b[0]-a[0])*(target[1]-a[1])-(b[1]-a[1])*(target[0]-a[0])
          end
          signs.all? { |v| v >= 0 } || signs.all? { |v| v <= 0 }
        end
      end

      def self.original_quad_covers?(polygon, quad)
        return false unless polygon.is_a?(Array) && polygon.length == 4 && quad.is_a?(Array) && quad.length == 4
        points = (polygon + quad).map do |point|
          raise Unproven, 'invalid original clip point' unless point.is_a?(Array) && point.length == 2
          point.map { |v| number(v) }
        end
        polygon, quad = points.first(4), points.last(4)
        edges = polygon.each_with_index.map { |a,i| b=polygon[(i+1)%4]; [b[0]-a[0],b[1]-a[1]] }
        turns = edges.each_with_index.map { |a,i| b=edges[(i+1)%4]; a[0]*b[1]-a[1]*b[0] }
        raise Unproven, 'degenerate/nonconvex original clip' unless turns.all? { |v| v > 0 } || turns.all? { |v| v < 0 }
        scale = points.flatten.map { |v| v.abs }.max
        span = [points.map { |p| p[0] }.max-points.map { |p| p[0] }.min,
                points.map { |p| p[1] }.max-points.map { |p| p[1] }.min].max
        epsilon = 64.0 * Float::EPSILON * [scale*span,1.0].max
        quad.all? do |point|
          cross = polygon.each_with_index.map do |a,i|
            b=polygon[(i+1)%4]
            (b[0]-a[0])*(point[1]-a[1])-(b[1]-a[1])*(point[0]-a[0])
          end
          cross.all? { |v| v >= -epsilon } || cross.all? { |v| v <= epsilon }
        end
      end

      def self.original_clip_proof!(image)
        proof = image[:original_clip_proof]
        raise Unproven, 'native image extends past SVG clip without original PDF clip proof' unless proof.is_a?(Hash) &&
          proof[:schema] == 'bcs.original_image_clip/1' && proof[:status] == 'FULL_FOOTPRINT' && proof[:unproven_reasons] == []
        digest = proof[:parsed_pdf_sha256]
        raise Unproven, 'original clip proof PDF identity mismatch' unless digest.is_a?(String) && digest =~ /\A[0-9a-f]{64}\z/ && digest == image[:parsed_pdf_sha256]
        [:page_number,:image_object_number,:placement_index].each do |key|
          value = proof[key]
          raise Unproven, 'original clip occurrence identity mismatch' unless value.is_a?(Integer) && value > 0 && value == image[key]
        end
        ctm, quad = proof[:ctm], proof[:corners_pts]
        raise Unproven, 'original clip affine identity mismatch' unless ctm.is_a?(Array) && ctm.length == 6 && ctm == image[:ctm] && quad == image[:corners_pts]
        ctm = ctm.map { |v| number(v) }
        expected = [[0,0],[1,0],[1,1],[0,1]].map { |p| point(ctm,p) }
        raise Unproven, 'original clip image quad disagrees with source CTM' unless quad == expected && (ctm[0]*ctm[3]-ctm[1]*ctm[2]) != 0
        clips, streams, forms = proof.values_at(:clip_polygons_pts,:source_streams,:form_chain)
        raise Unproven, 'original clip inventories missing' unless clips.is_a?(Array) && streams.is_a?(Array) && forms.is_a?(Array)
        raise Unproven, 'original page clipping inventory missing' unless clips.first(2).map { |v| v[:kind] } == ['media_box','crop_box']
        raise Unproven, 'original Form clip inventory incomplete' unless clips.length == forms.length + 2 && forms.length <= 12 &&
          clips.drop(2).map { |v| v[:obj_num] } == forms.map { |v| v[:obj_num] }
        forms.zip(clips.drop(2)).each do |form,clip|
          bbox, local, parent, combined = form.values_at(:bbox,:matrix,:parent_ctm,:combined_ctm)
          raise Unproven, 'invalid original Form clip binding' unless clip[:kind] == 'form_bbox' && form[:obj_num].is_a?(Integer) && form[:obj_num] > 0 &&
            bbox.is_a?(Array) && bbox.length == 4 && [local,parent,combined].all? { |m| m.is_a?(Array) && m.length == 6 }
          bbox = bbox.map { |v| number(v) }
          [local,parent,combined].each { |m| m.each { |v| number(v) } }
          raise Unproven, 'invalid original Form bounds/matrix' unless bbox[2] > bbox[0] && bbox[3] > bbox[1] &&
            SvgPaintOrder.multiply(parent,local) == combined
          expected_clip = [[bbox[0],bbox[1]],[bbox[2],bbox[1]],[bbox[2],bbox[3]],[bbox[0],bbox[3]]].map { |p| point(combined,p) }
          raise Unproven, 'original Form clip polygon disagrees with BBox/CTM' unless clip[:corners_pts] == expected_clip
        end
        raise Unproven, 'original clip does not contain full native image' unless clips.all? { |clip| original_quad_covers?(clip[:corners_pts],quad) }
        pages = streams.take_while { |row| row[:kind] == 'page' }
        raise Unproven, 'original source stream provenance incomplete' unless !pages.empty? && pages.map { |row| row[:index] } == (0...pages.length).to_a &&
          streams.drop(pages.length).map { |row| [row[:kind],row[:obj_num]] } == forms.map { |row| ['form',row[:obj_num]] } &&
          streams.all? { |row| row[:sha256].is_a?(String) && row[:sha256] =~ /\A[0-9a-f]{64}\z/ }
        proof
      rescue NoMethodError, TypeError
        raise Unproven, 'malformed original clip proof'
      end

      def self.intersection(a, b)
        return b unless a
        return a unless b
        result = [[a[0], b[0]].max, [a[1], b[1]].max,
                  [a[2], b[2]].min, [a[3], b[3]].min]
        result[0] < result[2] && result[1] < result[3] ? result : []
      end

      def self.point(matrix, p)
        a,b,c,d,e,f = matrix
        [a*p[0]+c*p[1]+e, b*p[0]+d*p[1]+f]
      end

      def self.corners(attrs)
        x, y = number(attrs['x'] || 0), number(attrs['y'] || 0)
        w, h = number(attrs['width']), number(attrs['height'])
        raise Unproven, 'invalid image/rectangle dimensions' unless w > 0 && h > 0
        [[x,y], [x+w,y], [x+w,y+h], [x,y+h]]
      end

      # Convex hull of all line/Bezier control points is a conservative source
      # ink bound. Arcs and unsupported commands cannot prove disjoint paint.
      def self.path_points(data)
        tokens = data.to_s.scan(/[A-Za-z]|[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/)
        raise Unproven, 'unparsed path data' unless data.to_s.gsub(/[\s,]/, '') == tokens.join
        points, current, start, command = [], [0.0,0.0], nil, nil
        until tokens.empty?
          command = tokens.shift if tokens.first =~ /\A[A-Za-z]\z/
          raise Unproven, 'path command missing' unless command
          relative = command == command.downcase
          kind = command.upcase
          if kind == 'Z'
            current = start.dup if start
            points << current.dup
            command = nil
            next
          end
          count = { 'M'=>2, 'L'=>2, 'T'=>2, 'H'=>1, 'V'=>1, 'C'=>6, 'S'=>4, 'Q'=>4 }[kind]
          raise Unproven, 'unsupported source path command' unless count
          raise Unproven, 'truncated source path' unless tokens.length >= count
          values = tokens.shift(count).map { |v| number(v) }
          if kind == 'H' || kind == 'V'
            target = current.dup
            axis = kind == 'H' ? 0 : 1
            target[axis] = values[0] + (relative ? current[axis] : 0.0)
            points << target
          else
            targets = values.each_slice(2).map do |p|
              relative ? [p[0]+current[0], p[1]+current[1]] : p
            end
            # Reflected S/T control point depends on the preceding control;
            # reject instead of pretending its explicitly listed points bound it.
            raise Unproven, 'implicit Bezier control is unbounded' if ['S','T'].include?(kind)
            points.concat(targets)
            target = targets.last
          end
          current = target
          if kind == 'M'
            start = current.dup
            command = relative ? 'l' : 'L'
          end
        end
        points
      end

      class Inventory
        attr_reader :svg_sha256

        def initialize(svg, pixel_reader = nil)
          @source = svg.to_s
          @svg_sha256 = Digest::SHA256.hexdigest(@source)
          @pixel_reader = pixel_reader || method(:read_png)
          @ids, @pixels = {}, {}
          @root = { :name=>'root', :attrs=>{}, :children=>[], :offset=>0 }
          raise Unproven, 'active/external SVG content' if @source =~ /<!DOCTYPE|<\s*script\b|<\s*style\b|<!ENTITY|<\?xml-stylesheet/i
          stack = [@root]
          @source.scan(SvgPaintOrder::TAGS) do |tag|
            offset = Regexp.last_match.begin(0)
            next if tag.start_with?('<!--', '<![CDATA[')
            if tag =~ /\A<\s*\/\s*([A-Za-z][A-Za-z0-9:_-]*)/
              raise Unproven, 'unbalanced source SVG' unless stack.length > 1 && stack.last[:name] == Regexp.last_match(1).downcase
              stack.pop
              next
            end
            name = tag[/\A<\s*([A-Za-z][A-Za-z0-9:_-]*)/,1].to_s.downcase
            attrs = SvgTextRenderer.svg_tag_attribute_map(tag)
            node = { :name=>name, :attrs=>attrs, :children=>[], :offset=>offset }
            if attrs['id']
              raise Unproven, 'duplicate source SVG id' if @ids.key?(attrs['id'])
              @ids[attrs['id']] = node
            end
            stack.last[:children] << node
            stack << node unless tag =~ /\/\s*>\s*\z/
          end
          raise Unproven, 'unclosed source SVG' unless stack.length == 1
          @placements = {}
          SvgTextRenderer.parse_use_placements(@source).each_with_index do |record, index|
            @placements[record[:source_svg_offset]] = index
          end
        end

        def read_png(data_uri)
          match = /\Adata:image\/png;base64,([A-Za-z0-9+\/=\s]+)\z/.match(data_uri.to_s)
          raise Unproven, 'source image is not an inline PNG' unless match
          bytes = Base64.strict_decode64(match[1].gsub(/\s/, ''))
          return gray_mask_proof(bytes) if bytes.bytesize >= 33 && bytes.getbyte(25) == 0
          dir = SafeTemp.mktmpdir('bc-image-order-')
          begin
            path, raw = File.join(dir, 'image.png'), File.join(dir, 'image.rgba')
            File.open(path, 'wb') { |file| file.write(bytes) }
            proof = PngCropper.prepare_rgba!(path, raw, false)
            rgba = File.binread(raw)
            all_opaque = true
            alpha_index = 3
            while alpha_index < rgba.bytesize
              all_opaque = false unless rgba.getbyte(alpha_index) == 255
              alpha_index += 4
            end
            proof.merge(:all_white_opaque=>rgba.each_byte.all? { |byte| byte == 255 },
              :all_opaque=>all_opaque)
          ensure
            FileUtils.remove_entry(dir) if File.directory?(dir)
          end
        end

        # Cairo emits its alpha-mask sample plane as 8-bit gray PNG. This
        # source-only mask format is inspected here with complete CRC/row
        # checks (tRNS keys refused); its digest equals PngCropper's gray->RGBA.
        def gray_mask_proof(bytes)
          raise Unproven, 'invalid gray PNG signature' unless bytes[0,8] == PngCropper::SIGNATURE
          position, width, height, compressed, ended = 8, nil, nil, String.new.force_encoding(Encoding::BINARY), false
          while position < bytes.bytesize
            raise Unproven, 'truncated gray PNG chunk' unless position + 12 <= bytes.bytesize
            length = bytes[position,4].unpack('N')[0]
            kind = bytes[position+4,4]
            payload = bytes[position+8,length]
            crc = bytes[position+8+length,4]
            raise Unproven, 'invalid gray PNG chunk' unless payload && payload.bytesize == length && crc && crc.bytesize == 4 && Zlib.crc32(kind+payload) == crc.unpack('N')[0]
            position += length + 12
            case kind
            when 'IHDR'
              raise Unproven, 'duplicate gray PNG header' if width
              raise Unproven, 'invalid gray PNG header length' unless payload.bytesize == 13
              width,height,depth,color,compression,filter,interlace = payload.unpack('NNC5')
              raise Unproven, 'unsupported gray PNG' unless width > 0 && height > 0 && width*height <= 25_000_000 && [depth,color,compression,filter,interlace] == [8,0,0,0,0]
            when 'IDAT'
              raise Unproven, 'gray PNG data before header' unless width
              compressed << payload
            when 'IEND'
              ended = true
              break
            when 'tRNS'
              raise Unproven, 'gray PNG transparency key is unsupported'
            end
          end
          raise Unproven, 'incomplete gray PNG' unless ended && width && position == bytes.bytesize
          inflater, rows = Zlib::Inflate.new, String.new.force_encoding(Encoding::BINARY)
          begin
            offset = 0
            while offset < compressed.bytesize
              rows << inflater.inflate(compressed[offset,16384])
              raise Unproven, 'oversized gray PNG decoded rows' if rows.bytesize > (width+1)*height
              offset += 16384
            end
            rows << inflater.finish
          ensure
            inflater.close
          end
          raise Unproven, 'gray PNG row count mismatch' unless rows.bytesize == (width+1)*height
          previous, digest, white = nil, Digest::SHA256.new, true
          height.times do |row_index|
            start = row_index*(width+1)
            row = rows[start+1,width].dup
            PngCropper.send(:unfilter!,row,previous,rows.getbyte(start),1)
            rgba = row.bytes.map { |v| white = false unless v == 255; [v,v,v,255].pack('C4') }.join
            digest.update(rgba)
            previous = row
          end
          { :pixel_width=>width, :pixel_height=>height,
            :visual_pixel_sha256=>digest.hexdigest, :all_white_opaque=>white, :all_opaque=>true }
        rescue Zlib::Error => error
          raise Unproven, 'gray PNG decode failed: ' + error.message
        end

        def pixel_proof(node)
          href = node[:attrs]['xlink:href'] || node[:attrs]['href']
          @pixels[href] ||= @pixel_reader.call(href)
        end

        def referenced(value)
          id = value.to_s[/\A(?:url\()?\#([^\)]+)\)?\z/,1]
          raise Unproven, 'missing/external source reference' unless id && @ids[id]
          @ids[id]
        end

        def attributes(node)
          attrs = node[:attrs]
          attrs.merge(SvgTextRenderer.svg_style_property_map(attrs['style']))
        end

        def context(node, parent)
          attrs = attributes(node)
          raise Unproven, 'unsupported source visibility or CSS' if attrs['class'] || attrs['display'] || attrs['visibility'] || attrs['mix-blend-mode']
          local = SvgPaintOrder.parse_transform(attrs['transform'])
          result = parent.merge(:matrix=>SvgPaintOrder.multiply(parent[:matrix], local))
          ['fill','stroke','stroke-width','stroke-miterlimit','stroke-linejoin','fill-opacity','stroke-opacity'].each do |key|
            result[key] = attrs[key] if attrs.key?(key)
          end
          result[:alpha] *= number(attrs['opacity'] || 1.0)
          result
        end

        def shape_box(node, ctx)
          points = if node[:name] == 'rect'
                     raise Unproven, 'rounded rectangle' if node[:attrs]['rx'] || node[:attrs]['ry']
                     SourceImagePaintOrder.corners(node[:attrs])
                   else
                     SourceImagePaintOrder.path_points(node[:attrs]['d'])
                   end
          bound = SourceImagePaintOrder.box(points.map { |p| SourceImagePaintOrder.point(ctx[:matrix], p) })
          if ctx['stroke'] && ctx['stroke'] != 'none'
            width = number(ctx['stroke-width'] || 1.0)
            miter = number(ctx['stroke-miterlimit'] || 4.0)
            raise Unproven, 'invalid stroke extent' unless width >= 0 && miter >= 1
            a,b,c,d = ctx[:matrix].first(4)
            extent = width * 0.5 * Math.sqrt(a*a+b*b+c*c+d*d) * miter
            bound = [bound[0]-extent,bound[1]-extent,bound[2]+extent,bound[3]+extent] if bound
          end
          bound
        end

        def number(value); SourceImagePaintOrder.number(value); end

        def rectangle_clip(node, matrix)
          attrs = attributes(node)
          raise Unproven, 'unsupported clip units' if attrs['clippathunits'] && attrs['clippathunits'] != 'userSpaceOnUse'
          raise Unproven, 'unsupported clip attributes' unless (attrs.keys - ['id','clippathunits','transform']).empty?
          children = node[:children]
          raise Unproven, 'compound clip is not an axis rectangle' unless children.length == 1
          child = children.first
          raise Unproven, 'nested clip is unproved' if attributes(child)['clip-path']
          local = SvgPaintOrder.multiply(matrix, SvgPaintOrder.parse_transform(attrs['transform']))
          ctx = context(child, { :matrix=>local, :alpha=>1.0 })
          if child[:name] == 'rect'
            raise Unproven, 'rounded clip rectangle is unproved' if child[:attrs]['rx'] || child[:attrs]['ry']
            points = SourceImagePaintOrder.corners(child[:attrs])
          elsif child[:name] == 'path'
            data = child[:attrs]['d'].to_s
            tokens = data.scan(/[A-Za-z]|[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/)
            raise Unproven, 'unparsed clip data' unless data.gsub(/[\s,]/,'') == tokens.join
            # Cairo appends a lone moveto after its closed rectangle. It has
            # no fill area; unlike a repeated contour it cannot cancel a clip.
            if tokens.length >= 4 && tokens[-4] =~ /\A[Zz]\z/ && tokens[-3] =~ /\A[Mm]\z/
              number(tokens[-2]); number(tokens[-1])
              tokens = tokens[0...-3]
              data = tokens.join(' ')
            end
            commands = tokens.select { |token| token =~ /\A[A-Za-z]\z/ }.map { |token| token.upcase }
            raise Unproven, 'clip is not one linear contour' unless commands.count('M') == 1 && commands.first == 'M' &&
              (commands - ['M','L','H','V','Z']).empty? && commands.count('Z') <= 1 &&
              (!commands.include?('Z') || commands.last == 'Z')
            points = SourceImagePaintOrder.path_points(data)
          else
            raise Unproven, 'unsupported clip geometry'
          end
          points = points.map { |p| SourceImagePaintOrder.point(ctx[:matrix], p) }
          points.pop if points.length == 5 && points.last == points.first
          raise Unproven, 'clip is not one four-corner contour' unless points.length == 4 && points.uniq.length == 4
          bound = SourceImagePaintOrder.box(points)
          expected = [[bound[0],bound[1]], [bound[2],bound[1]], [bound[2],bound[3]], [bound[0],bound[3]]]
          unique = points.uniq
          raise Unproven, 'clip is not a proven axis rectangle' unless unique.sort == expected.sort
          (points + [points.first]).each_cons(2) { |a,b| raise Unproven, 'diagonal/canceling clip' unless a[0] == b[0] || a[1] == b[1] }
          bound
        end

        # Exact geometric bbox for the bounded mask program, including fully
        # transparent rectangles (SVG filter objectBoundingBox still uses their
        # geometry). Never substitute a conservative curve bbox for this.
        def mask_geometry_box(node, matrix, depth = 0)
          raise Unproven, 'mask geometry depth' if depth > MAX_DEPTH
          return nil if ['defs','clippath','filter','title','desc','metadata'].include?(node[:name])
          attrs = attributes(node)
          local = SvgPaintOrder.multiply(matrix,SvgPaintOrder.parse_transform(attrs['transform']))
          case node[:name]
          when 'use'
            local = SvgPaintOrder.multiply(local,[1,0,0,1,number(attrs['x'] || 0),number(attrs['y'] || 0)])
            mask_geometry_box(referenced(attrs['xlink:href'] || attrs['href']),local,depth+1)
          when 'image','rect'
            SourceImagePaintOrder.box(SourceImagePaintOrder.corners(attrs).map { |p| SourceImagePaintOrder.point(local,p) })
          when 'g','mask'
            boxes = node[:children].map { |child| mask_geometry_box(child,local,depth+1) }.compact
            SourceImagePaintOrder.box(boxes.flat_map { |b| [[b[0],b[1]],[b[2],b[3]]] })
          else
            raise Unproven, 'unproved mask filter object bounds'
          end
        end

        def filter_region(filter, node, matrix)
          attrs = attributes(filter)
          allowed = ['id','x','y','width','height','filterunits','primitiveunits','color-interpolation-filters']
          raise Unproven, 'unsupported filter attributes' unless (attrs.keys-allowed).empty?
          raise Unproven, 'unsupported filter coordinate units' unless [nil,'objectBoundingBox'].include?(attrs['filterunits']) && [nil,'userSpaceOnUse'].include?(attrs['primitiveunits'])
          transform = SvgPaintOrder.multiply(matrix,SvgPaintOrder.parse_transform(attributes(node)['transform']))
          raise Unproven, 'filtered rotated/reflected/sheared mask is unproved' unless transform[1] == 0 && transform[2] == 0 && transform[0] > 0 && transform[3] > 0
          base = mask_geometry_box(node,matrix)
          raise Unproven, 'degenerate filter object bounds' unless base && base[2] > base[0] && base[3] > base[1]
          fractions = [['x','-10%'],['y','-10%'],['width','120%'],['height','120%']].map do |key,default|
            value = attrs[key] || default
            raise Unproven, 'unsupported filter region' unless value =~ /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)%\z/
            number(value[0...-1])/100.0
          end
          x,y,w,h = fractions
          raise Unproven, 'empty filter region' unless w > 0 && h > 0
          dx,dy = base[2]-base[0],base[3]-base[1]
          [base[0]+dx*x,base[1]+dy*y,base[0]+dx*(x+w),base[1]+dy*(y+h)]
        end

        # Only Cairo's explicitly proved white alpha masks and their exact
        # inversion qualify. Unknown masks may not disappear from the proof.
        def mask_relation(node, matrix, query, depth = 0)
          raise Unproven, 'mask reference depth' if depth > MAX_DEPTH
          return :none if ['defs','clippath','filter','title','desc','metadata'].include?(node[:name])
          attrs = attributes(node)
          validate_mask_attributes!(node) if node[:name] == 'mask'
          opacity = number(attrs['opacity'] || 1)
          return :none if opacity == 0
          return :partial unless opacity == 1
          return :partial if attrs['mask'] || (attrs['stroke'] && attrs['stroke'] != 'none')
          local = SvgPaintOrder.multiply(matrix, SvgPaintOrder.parse_transform(attrs['transform']))
          filter = attrs['filter']
          if filter
            filter_node = referenced(filter)
            raise Unproven, 'unsupported mask filter program' unless filter_node[:children].length == 1 && filter_node[:children].first[:name] == 'fecolormatrix' &&
              [nil,'SourceGraphic'].include?(filter_node[:children].first[:attrs]['in']) &&
              [nil,'matrix'].include?(filter_node[:children].first[:attrs]['type'])
            raise Unproven, 'unsupported mask primitive region' unless (filter_node[:children].first[:attrs].keys - ['values','in','type','color-interpolation-filters']).empty?
            values = filter_node[:children].first && filter_node[:children].first[:attrs]['values']
            invert = values.to_s.split.map { |v| number(v) } == [0,0,0,0,1, 0,0,0,0,1, 0,0,0,0,1, 0,0,0,-1,1]
            color_remove = values.to_s.split.map { |v| number(v) } == [0,0,0,0,1, 0,0,0,0,1, 0,0,0,0,1, 0,0,0,1,0]
            color_alpha = values.to_s.split.map { |v| number(v) } == [0,0,0,0,1, 0,0,0,0,1, 0,0,0,0,1, 0.2126,0.7152,0.0722,0,0]
            raise Unproven, 'unsupported mask filter' unless invert || color_remove || color_alpha
            copy = node.merge(:attrs=>node[:attrs].reject { |k,_v| k == 'filter' })
            relation = mask_relation(copy, matrix, query, depth+1)
            result = invert ? ({ :all=>:none, :none=>:all }[relation] || :partial) : relation
            region = filter_region(filter_node,copy,matrix)
            return :none unless SourceImagePaintOrder.overlap?(region,query)
            return :partial if result == :all && !SourceImagePaintOrder.covers?(region,query)
            return result
          end
          if attrs['fill-opacity'] && number(attrs['fill-opacity']) != 1
            return :none if node[:name] == 'rect' && number(attrs['fill-opacity']) == 0
            return :partial
          end
          if attrs['clip-path']
            clip = rectangle_clip(referenced(attrs['clip-path']), local)
            return :none unless SourceImagePaintOrder.overlap?(clip, query)
            return :partial unless SourceImagePaintOrder.covers?(clip, query)
          end
          result = case node[:name]
          when 'use'
            target = referenced(attrs['xlink:href'] || attrs['href'])
            shifted = SvgPaintOrder.multiply(local, [1,0,0,1,number(attrs['x'] || 0),number(attrs['y'] || 0)])
            mask_relation(target, shifted, query, depth+1)
          when 'image'
            return :partial unless pixel_proof(node)[:all_white_opaque] == true
            quad = SourceImagePaintOrder.corners(attrs).map { |p| SourceImagePaintOrder.point(local,p) }
            bound = SourceImagePaintOrder.box(quad)
            SourceImagePaintOrder.quad_covers?(quad, query) ? :all : (SourceImagePaintOrder.overlap?(bound,query) ? :partial : :none)
          when 'rect'
            return :none if number(attrs['fill-opacity'] || 1) == 0
            return :partial unless SvgTextRenderer.parse_svg_color(attrs['fill']) == [1.0,1.0,1.0] && number(attrs['fill-opacity'] || 1) == 1
            quad = SourceImagePaintOrder.corners(attrs).map { |p| SourceImagePaintOrder.point(local,p) }
            bound = SourceImagePaintOrder.box(quad)
            SourceImagePaintOrder.quad_covers?(quad,query) ? :all : (SourceImagePaintOrder.overlap?(bound,query) ? :partial : :none)
          when 'g','mask'
            relations = node[:children].map { |child| mask_relation(child, local, query, depth+1) }
            return :all if relations.include?(:all)
            relations.all? { |r| r == :none } ? :none : :partial
          else
            :partial
          end
        end

        def validate_mask_attributes!(node)
          attrs = attributes(node)
          # Cairo's unqualified mask uses userSpaceOnUse sample coordinates
          # and the default objectBoundingBox region. An explicit alternate
          # region/coordinate system needs a separate proof, not this parser.
          allowed = ['id','maskunits','maskcontentunits','x','y','width','height']
          raise Unproven, 'unsupported mask attributes' unless (attrs.keys-allowed).empty?
          expected = { 'maskunits'=>'objectBoundingBox', 'maskcontentunits'=>'userSpaceOnUse',
            'x'=>'-10%', 'y'=>'-10%', 'width'=>'120%', 'height'=>'120%' }
          expected.each { |key,value| raise Unproven, 'unsupported mask coordinate region' if attrs.key?(key) && attrs[key] != value }
        end

        def events_for(query)
          events = []
          walk(@root, { :matrix=>IDENTITY, :alpha=>1.0, 'fill'=>'black' }, query, events, [], false)
          events.each_with_index { |event,index| event[:paint_rank] = index }
          events
        end

        def single_image(node, matrix, mask, depth = 0)
          return nil if depth > MAX_DEPTH
          attrs = attributes(node)
          validate_mask_attributes!(node) if node[:name] == 'mask'
          return nil if attrs['mask'] || attrs['clip-path'] || number(attrs['opacity'] || 1) != 1 ||
            number(attrs['fill-opacity'] || 1) != 1 || (attrs['stroke'] && attrs['stroke'] != 'none')
          local = SvgPaintOrder.multiply(matrix, SvgPaintOrder.parse_transform(attrs['transform']))
          if attrs['filter']
            return nil unless mask
            filter = referenced(attrs['filter'])
            return nil unless filter[:children].length == 1 && filter[:children].first[:name] == 'fecolormatrix'
            return nil unless [nil,'SourceGraphic'].include?(filter[:children].first[:attrs]['in']) && [nil,'matrix'].include?(filter[:children].first[:attrs]['type'])
            return nil unless (filter[:children].first[:attrs].keys - ['values','in','type','color-interpolation-filters']).empty?
            values = filter[:children].first[:attrs]['values'].to_s.split.map { |v| number(v) }
            allowed = [[0,0,0,0,1, 0,0,0,0,1, 0,0,0,0,1, 0,0,0,1,0],
                       [0,0,0,0,1, 0,0,0,0,1, 0,0,0,0,1, 0.2126,0.7152,0.0722,0,0]]
            return nil unless allowed.include?(values)
          end
          result = case node[:name]
          when 'mask','g'
            return nil unless node[:children].length == 1
            single_image(node[:children].first, local, mask, depth+1)
          when 'use'
            local = SvgPaintOrder.multiply(local,[1,0,0,1,number(attrs['x'] || 0),number(attrs['y'] || 0)])
            single_image(referenced(attrs['xlink:href'] || attrs['href']),local,mask,depth+1)
          when 'image'
            return nil if mask && pixel_proof(node)[:all_white_opaque] != true
            SourceImagePaintOrder.corners(attrs).map { |p| SourceImagePaintOrder.point(local,p) }
          end
          if result && attrs['filter']
            copy = node.merge(:attrs=>node[:attrs].reject { |key,_v| key == 'filter' })
            region = filter_region(referenced(attrs['filter']),copy,matrix)
            return nil unless SourceImagePaintOrder.covers?(region,SourceImagePaintOrder.box(result))
          end
          result
        end

        def same_opaque_image_mask?(node, ctx, mask)
          plain = node.merge(:attrs=>node[:attrs].reject { |key,_value| ['mask','transform'].include?(key) })
          actual = single_image(plain,ctx[:matrix],false)
          expected = single_image(mask,ctx[:matrix],true)
          actual && expected && actual == expected
        end

        def walk(node, parent, query, events, chain, referenced_node)
          raise Unproven, 'source reference cycle/depth' if chain.length > MAX_DEPTH || chain.include?(node.object_id)
          chain = chain + [node.object_id]
          return if ['title','desc','metadata','clippath','mask','filter'].include?(node[:name]) && !referenced_node
          return if node[:name] == 'defs' && !referenced_node
          attrs = attributes(node)
          ctx = context(node, parent)
          return if ctx[:alpha] == 0.0
          if attrs['mask']
            mask = referenced(attrs['mask'])
            relation = same_opaque_image_mask?(node,ctx,mask) ? :all : mask_relation(mask, ctx[:matrix], query)
            return if relation == :none
            raise Unproven, 'mask crosses queried image footprint: ' + attrs['mask'].to_s unless relation == :all
          end
          if attrs['clip-path']
            clip = rectangle_clip(referenced(attrs['clip-path']), ctx[:matrix])
            ctx[:clip] = SourceImagePaintOrder.intersection(ctx[:clip], clip)
            return if ctx[:clip] == []
          end
          if attrs['filter']
            filter = referenced(attrs['filter'])
            children = filter[:children]
            plain = node.merge(:attrs=>node[:attrs].reject { |key,_value| key == 'filter' })
            unless SourceImagePaintOrder.covers?(filter_region(filter,plain,parent[:matrix]),query)
              raise Unproven, 'filter output region does not cover queried image footprint'
            end
            # Cairo additive composition of two explicitly masked surfaces.
            # Both branches are still inspected; disjoint masks prune safely.
            composite = children.last
            unless children.length == 3 && children.first(2).all? { |n| n[:name] == 'feimage' } &&
                   children.first(2).map { |n| n[:attrs]['result'] } == ['source','destination'] &&
                   composite[:name] == 'fecomposite' && composite[:attrs].values_at('in','in2','operator','k1','k2','k3','k4') == ['source','destination','arithmetic','0','1','1','0']
              raise Unproven, 'overlapping/unbounded Cairo filter semantics'
            end
            branches = []
            children.first(2).reverse.each do |image|
              raise Unproven, 'nonzero filter image origin' unless number(image[:attrs]['x'] || 0) == 0 && number(image[:attrs]['y'] || 0) == 0
              raise Unproven, 'unproved filter viewport' unless number(image[:attrs]['width']) > 0 && number(image[:attrs]['height']) > 0 &&
                image[:attrs].values_at('width','height') == children.first[:attrs].values_at('width','height')
              target = referenced(image[:attrs]['xlink:href'] || image[:attrs]['href'])
              branch = []
              walk(target, ctx, query, branch, chain, true)
              branches << branch
            end
            unless branches.count { |branch| branch.any? { |paint| paint[:zero_ink] != true && SourceImagePaintOrder.overlap?(paint[:bounds],query) } } <= 1
              raise Unproven, 'additive filter branches overlap queried image'
            end
            branches.each { |branch| events.concat(branch) }
            return
          end
          case node[:name]
          when 'root','svg','g','symbol'
            node[:children].each { |child| walk(child,ctx,query,events,chain,false) }
          when 'use'
            target = referenced(attrs['xlink:href'] || attrs['href'])
            shifted = ctx.merge(:matrix=>SvgPaintOrder.multiply(ctx[:matrix], [1,0,0,1,number(attrs['x'] || 0),number(attrs['y'] || 0)]))
            if @placements.key?(node[:offset])
              bounds = glyph_bounds(target, shifted)
              events << { :kind=>:glyph, :placement_index=>@placements[node[:offset]], :bounds=>bounds,
                :zero_ink=>bounds.nil?, :svg_offset=>node[:offset] }
            else
              walk(target,shifted,query,events,chain,true)
            end
          when 'path','rect'
            return if ctx['fill'] == 'none' && (!ctx['stroke'] || ctx['stroke'] == 'none')
            return if number(ctx['fill-opacity'] || 1) == 0 && (!ctx['stroke'] || ctx['stroke'] == 'none')
            bounds = shape_box(node,ctx)
            events << { :kind=>:vector, :bounds=>bounds, :svg_offset=>node[:offset] }
          when 'image'
            quad = SourceImagePaintOrder.corners(attrs).map { |p| SourceImagePaintOrder.point(ctx[:matrix],p) }
            events << { :kind=>:image, :bounds=>SourceImagePaintOrder.box(quad), :corners=>quad,
              :clip_bounds=>ctx[:clip], :svg_image_id=>attrs['id'], :svg_offset=>node[:offset],
              :alpha=>ctx[:alpha], :pixels=>pixel_proof(node) }
          else
            raise Unproven, 'unaccounted source paint element ' + node[:name]
          end
        rescue ArgumentError => error
          raise Unproven, error.message
        end

        def glyph_bounds(node, ctx)
          bounds = []
          visit = lambda do |part, parent|
            local = context(part,parent)
            if part[:name] == 'path'
              bounds << shape_box(part,local)
            elsif ['g','symbol'].include?(part[:name])
              part[:children].each { |child| visit.call(child,local) }
            else
              raise Unproven, 'unsupported glyph definition'
            end
          end
          visit.call(node,ctx)
          points = bounds.compact.flat_map { |b| [[b[0],b[1]], [b[2],b[3]]] }
          SourceImagePaintOrder.box(points)
        end

        # Final-page crop pixels already contain the completed PDF composition.
        # This is coverage evidence, not a claim that the crop owns a Cairo use
        # or can be moved through the native glyph-wrapper path.
        def final_page_crop_for(paint, image, crops)
          raise Unproven, 'later glyph has no finite conservative ink bounds' unless paint[:bounds].is_a?(Array) && paint[:bounds].length == 4
          candidates = crops.select do |crop|
            sid, id = crop.values_at(:source_span_id, :resulting_entity_id)
            page, digest = image.values_at(:page_number, :parsed_pdf_sha256)
            unless page.is_a?(Integer) && page > 0 && digest.is_a?(String) && digest =~ /\A[0-9a-f]{64}\z/ &&
              crop[:page_number] == page && crop[:source_pdf_sha256] == digest &&
              sid.is_a?(String) && sid =~ /\Atext_span:#{page}:\d+\z/ &&
              id.is_a?(String) && id =~ /\A(?:persistent_id|entity_id):[1-9]\d*\z/
              raise Unproven, 'final-page crop source/native identity is incomplete'
            end
            source_box, bounds = crop.values_at(:source_box, :bounds_svg)
            page_box, viewbox = image.values_at(:svg_page_box, :svg_viewbox)
            unless [source_box, bounds, page_box, viewbox].all? { |b| b.is_a?(Array) && b.length == 4 && b.all? { |v| v.is_a?(Numeric) && v.to_f.finite? } } &&
              source_box[0] < source_box[2] && source_box[1] < source_box[3]
              raise Unproven, 'final-page crop source bounds are invalid'
            end
            expected = [source_box[0]-page_box[0]+viewbox[0], viewbox[3]+viewbox[1]+page_box[1]-source_box[3],
              source_box[2]-page_box[0]+viewbox[0], viewbox[3]+viewbox[1]+page_box[1]-source_box[1]]
            raise Unproven, 'final-page crop SVG bounds differ from its PDF source box' unless bounds == expected
            SourceImagePaintOrder.covers?(bounds, paint[:bounds])
          end
          return nil if candidates.empty?
          # Any fully containing final-page crop carries the same source paint.
          # Choose one stable witness; do not invent exclusive glyph ownership.
          crop = candidates.min_by { |row| b=row[:bounds_svg]; [(b[2]-b[0])*(b[3]-b[1]), row[:resulting_entity_id]] }
          crop.merge(:placement_index=>paint[:placement_index], :paint_rank=>paint[:paint_rank],
            :glyph_bounds_svg=>paint[:bounds].dup)
        end

        def qualify(image, roots, final_page_crops = [])
          query = SourceImagePaintOrder.box(image.fetch(:corners_svg))
          events = events_for(query)
          matches = events.select do |event|
            next false unless event[:kind] == :image && event[:alpha] == 1.0
            proof = event[:pixels]
            image[:pixel_width] == proof[:pixel_width] && image[:pixel_height] == proof[:pixel_height] &&
              image[:visual_pixel_sha256] == proof[:visual_pixel_sha256] &&
              image[:corners_svg].zip(event[:corners]).all? { |a,b| a.zip(b).all? { |x,y| (x-y).abs <= SOURCE_GRID } }
          end
          raise Unproven, 'image pixels/affine do not bind exactly one live source occurrence' unless matches.length == 1
          event = matches.first
          # Final-page text crops already contain this source image. Retaining
          # translucent pixels beneath them would composite those pixels twice.
          # Paint opacity alone does not prove the decoded PNG is opaque.
          raise Unproven, 'source image pixels are not proven fully opaque' unless event[:pixels][:all_opaque] == true
          clip_qualification = if event[:clip_bounds] && !SourceImagePaintOrder.covers?(event[:clip_bounds],query)
            { :policy=>'original_pdf_full_affine_clip_coverage',
              :original_clip_proof=>SourceImagePaintOrder.original_clip_proof!(image),
              :cairo_clip_bounds=>event[:clip_bounds],
              :scope=>'Cairo backend clip is narrower; original parsed PDF clips contain unchanged full image' }
          else
            { :policy=>'svg_clip_covers_full_native_affine_footprint' }
          end
          later = events.select { |paint| paint[:paint_rank] > event[:paint_rank] && paint[:zero_ink] != true && SourceImagePaintOrder.overlap?(paint[:bounds],query) }
          raise Unproven, 'later overlapping nontext paint requires unsupported display ordering' unless later.all? { |paint| paint[:kind] == :glyph }
          by_index = {}
          events.select { |paint| paint[:kind] == :glyph }.each { |paint| (by_index[paint[:placement_index]] ||= []) << paint }
          moved, covered = [], []
          later.each do |paint|
            candidates = roots.select { |root| Array(root[:placement_indices]).include?(paint[:placement_index]) }
            if candidates.empty?
              crop = final_page_crop_for(paint, image, final_page_crops)
              if crop
                covered << crop
                next
              end
            end
            raise Unproven, 'later glyph lacks one native source owner' unless candidates.length == 1
            root = candidates.first
            indices = root[:placement_indices]
            raise Unproven, 'native root source indices are incomplete' unless indices.is_a?(Array) && !indices.empty? && indices.uniq.length == indices.length
            paints = indices.map do |index|
              matches = by_index[index]
              raise Unproven, 'native root source occurrence is absent or repeated' unless matches && matches.length == 1
              matches.first
            end
            raise Unproven, 'native root straddles source image paint order' unless paints.all? { |p| p[:paint_rank] > event[:paint_rank] }
            moved << root.merge(:source_paint_ranks=>paints.map { |p| p[:paint_rank] })
          end
          { :schema=>'bcs.source_image_paint_order/1.0', :source_svg_sha256=>svg_sha256,
            :image_id=>image[:id], :image_paint_rank=>event[:paint_rank],
            :source_image_event=>event, :later_roots=>moved.uniq,
            :later_final_page_crops=>covered,
            :clip_qualification=>clip_qualification,
            :query_bounds_svg=>query, :later_overlapping_paint_count=>later.length,
            :proof_scope=>'full_native_affine_footprint; exact_source_rgba; rendered_reference_order' }
        end
      end
    end
  end
end
