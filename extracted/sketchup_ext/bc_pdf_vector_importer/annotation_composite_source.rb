# Source-only authority for small original-PDF annotation display crops.
# No text representation is replaced. Ruby 2.2 compatible.
require 'digest'
require_relative 'source_round_annotation_ink'
require_relative 'source_image_paint_order'
require_relative 'svg_text_renderer'
require_relative 'text_parser'

module BlueCollarSystems
  module PDFVectorImporter
    module AnnotationCompositeSource
      Unproven = SourceRoundAnnotationInk::Unproven
      DPI = 600
      MAX_PATCH_PIXELS = 4_000_000
      MAX_PAGE_PIXELS = 32_000_000

      def self.assert_original!(parser, source_sha256)
        data = parser.instance_variable_get(:@data)
        unless data.is_a?(String) && Digest::SHA256.hexdigest(data) == source_sha256
          raise Unproven, 'annotation source bytes changed'
        end
        path = parser.instance_variable_get(:@filepath)
        unless path.is_a?(String) && File.file?(path) && Digest::SHA256.file(path).hexdigest == source_sha256
          raise Unproven, 'original annotation source file changed or is unavailable'
        end
        data
      end

      # A proof-only incremental copy. Original byte prefix, page content,
      # resources and every Form/font remain unchanged. No product extraction
      # or final crop ever uses this copy: it only exposes base-page glyph ink.
      def self.write_background_copy!(parser, source_sha256, page_number, destination)
        data = assert_original!(parser, source_sha256)
        unless page_number.is_a?(Integer) && page_number > 0 && page_number <= parser.pages.length
          raise Unproven, 'original background page number is invalid'
        end
        trailer = parser.instance_variable_get(:@trailer)
        offsets = parser.instance_variable_get(:@xref_offsets)
        unless trailer.is_a?(Hash) && !trailer.key?('/Encrypt') && offsets.is_a?(Array) &&
               offsets.first.is_a?(Integer) && offsets.first > 0
          raise Unproven, 'original background copy requires an unencrypted original xref'
        end
        ref = parser.pages.fetch(page_number - 1)
        match = /\A(\d+)\s+(\d+)\s+R\z/.match(ref.to_s)
        raise Unproven, 'original background page reference is invalid' unless match && match[2].to_i < 65535
        dict = SourceRoundAnnotationInk.dictionary(parser, ref).dup
        dict['/Annots'] = []
        root = trailer['/Root']
        size = trailer['/Size'].to_i
        unless root.is_a?(String) && root =~ /\A\d+\s+\d+\s+R\z/ && size > match[1].to_i
          raise Unproven, 'original background trailer identity is invalid'
        end
        tail = { '/Root'=>root, '/Size'=>size.to_s, '/Prev'=>offsets.first.to_s }
        ['/Info','/ID'].each { |key| tail[key] = trailer[key] if trailer.key?(key) }
        created, completed = false, false
        begin
          File.open(destination, File::WRONLY | File::CREAT | File::EXCL) do |file|
            created = true
            file.binmode
            file.write(data)
            file.write("\n")
            object_offset = file.pos
            file.write(match[1] + ' ' + match[2] + " obj\n")
            file.write(parser.annotation_pdf_value(dict) + "\nendobj\n")
            xref = file.pos
            file.write("xref\n" + match[1] + " 1\n")
            file.write(format('%010d %05d n ', object_offset, match[2].to_i) + "\n")
            file.write("trailer\n" + parser.annotation_pdf_value(tail) + "\nstartxref\n" + xref.to_s + "\n%%EOF\n")
          end
          unless File.binread(destination, data.bytesize) == data
            raise Unproven, 'original background copy changed its source byte prefix'
          end
          assert_original!(parser, source_sha256)
          completed = true
          { :schema=>'bcs.annotation_background_copy/1', :source_pdf_sha256=>source_sha256,
            :page_number=>page_number, :page_ref=>ref, :overridden_key=>'/Annots',
            :original_byte_count=>data.bytesize, :original_byte_prefix_unchanged=>true,
            :copy_sha256=>Digest::SHA256.file(destination).hexdigest }
        ensure
          File.delete(destination) if created && !completed && File.file?(destination)
        end
      end

      def self.crop_plan(record, media_box, rotation = 0)
        box = Array(media_box).map { |n| SourceRoundAnnotationInk.number(n) }
        unless box.length == 4 && box[0] == 0 && box[1] == 0 && box[2] > 0 && box[3] > 0 && rotation == 0
          raise Unproven, 'annotation composite currently requires an unrotated zero-origin page'
        end
        unless record[:original_geometry_verified] == true && record[:full_capsule_clip_verified] == true
          raise Unproven, 'annotation crop lacks original capsule geometry proof'
        end
        a, b = [:start_pdf, :end_pdf].map do |key|
          value = record[key]
          raise Unproven, 'annotation endpoint is invalid' unless value.is_a?(Array) && value.length == 2
          value.map { |n| SourceRoundAnnotationInk.number(n) }
        end
        radius = SourceRoundAnnotationInk.number(record[:radius_pdf])
        raise Unproven, 'annotation radius is not positive' unless radius > 0
        zoom = DPI / 72.0
        left = (([a[0],b[0]].min-radius)*zoom).floor - 1
        top = ((box[3]-[a[1],b[1]].max-radius)*zoom).floor - 1
        right = (([a[0],b[0]].max+radius)*zoom).ceil + 1
        bottom = ((box[3]-[a[1],b[1]].min+radius)*zoom).ceil + 1
        width, height = right-left, bottom-top
        unless left >= 0 && top >= 0 && right <= box[2]*zoom && bottom <= box[3]*zoom &&
               width > 0 && height > 0 && width*height <= MAX_PATCH_PIXELS
          raise Unproven, 'annotation crop exceeds original page or finite pixel budget'
        end
        source_box = [left/zoom,box[3]-bottom/zoom,right/zoom,box[3]-top/zoom]
        page_clips = record[:page_clip_polygons_pdf]
        unless page_clips.is_a?(Array) && !page_clips.empty? &&
               page_clips.all? { |clip| clip.is_a?(Array) && clip.length == 4 && SourceImagePaintOrder.quad_covers?(clip,source_box) }
          raise Unproven, 'annotation pixel lattice extends beyond original effective page clip'
        end
        { :schema=>'bcs.original_annotation_crop/1', :dpi=>DPI,
          :pixel_box=>[left,top,right,bottom], :pixel_width=>width, :pixel_height=>height,
          :source_box_svg=>[left/zoom,top/zoom,right/zoom,bottom/zoom],
          :source_box_pdf=>source_box,
          :page_box=>box, :page_rotation=>0 }
      end

      def self.crop_arguments(executable, source, page_number, plan, output_prefix)
        pixel = plan.fetch(:pixel_box)
        unless page_number.is_a?(Integer) && page_number > 0 && plan[:dpi] == DPI &&
               pixel.is_a?(Array) && pixel.length == 4 && pixel.all? { |n| n.is_a?(Integer) } &&
               pixel[0] >= 0 && pixel[1] >= 0 && pixel[2] > pixel[0] && pixel[3] > pixel[1] &&
               plan[:pixel_width] == pixel[2]-pixel[0] && plan[:pixel_height] == pixel[3]-pixel[1] &&
               plan[:pixel_width]*plan[:pixel_height] <= MAX_PATCH_PIXELS
          raise Unproven, 'annotation raster crop arguments are not source-bound'
        end
        [executable.to_s, '-png', '-singlefile', '-f', page_number.to_s, '-l', page_number.to_s,
          '-r', DPI.to_s, '-x', pixel[0].to_s, '-y', pixel[1].to_s,
          '-W', plan[:pixel_width].to_s, '-H', plan[:pixel_height].to_s,
          source.to_s, output_prefix.to_s]
      end

      def self.plan_page(records, media_box, rotation = 0)
        plans = records.map { |record| crop_plan(record,media_box,rotation) }
        pixels = plans.inject(0) { |sum,plan| sum + plan[:pixel_width]*plan[:pixel_height] }
        raise Unproven, 'annotation crops exceed the finite page pixel budget' if pixels > MAX_PAGE_PIXELS
        plans
      end

      def self.other_annotations_disjoint!(parser, page_number, records, plans)
        proved = records.map { |record| record.fetch(:annotation_ref) }
        checked = []
        parser.page_annotation_entries(page_number).each do |ref|
          next if proved.include?(ref)
          dict = SourceRoundAnnotationInk.dictionary(parser,ref)
          flags = SourceRoundAnnotationInk.number(dict.fetch('/F','0'))
          raise Unproven, 'other source annotation flags are invalid' unless flags >= 0 && flags == flags.to_i
          next unless (flags.to_i & 35) == 0
          raise Unproven, 'other source annotation has view-dependent extent' unless (flags.to_i & 24) == 0
          rect = SourceRoundAnnotationInk.rectangle(parser,dict['/Rect'])
          if plans.any? { |plan| SourceImagePaintOrder.overlap?(rect,plan.fetch(:source_box_pdf)) }
            raise Unproven, 'annotation crop intersects another unclassified original annotation'
          end
          checked << { :annotation_ref=>ref, :rect_pdf=>rect }
        end
        checked
      end

      # Type 3 glyphs and tiling-pattern programs can become unlabelled vector
      # paths in Cairo. They cannot support a glyph-ID absence proof. Inspect
      # every reachable resource dictionary, conservatively including unused
      # resources; ordinary page geometry remains unchanged when this refuses.
      def self.font_scope!(parser,page_number)
        page = SourceRoundAnnotationInk.dictionary(parser,parser.pages.fetch(page_number-1))
        root = parser.send(:find_inherited,page,'/Resources')
        seen,fonts,streams,forms = {},[],[],{}
        check_stream = lambda do |body|
          raise Unproven, 'background original content stream is unavailable or excessive' unless body.is_a?(String) && body.bytesize <= 64_000_000
          operands = []
          TextParser.new([]).send(:tokenize,body).each do |token|
            if token[:type] == :operator
              if token[:value] == 'Tr'
                unless operands.length == 1 && operands[0][:type] == :number && [0,3].include?(operands[0][:value])
                  raise Unproven, 'background stroked/clipped text can become unlabelled geometry'
                end
              end
              operands.clear
            else
              operands << token
            end
          end
          streams << Digest::SHA256.hexdigest(body)
        end
        original_streams = parser.page_data(page_number)[:source_content_streams]
        raise Unproven, 'original background stream inventory is unavailable' unless original_streams.is_a?(Array)
        original_streams.each { |body| check_stream.call(body) }
        visit = nil
        visit = lambda do |resource,depth|
          raise Unproven, 'background font resource graph exceeds bounded depth' if depth > 16 || seen.length > 2048
          key = resource.is_a?(String) ? resource : resource.object_id
          return if seen[key]
          seen[key] = true
          next if resource.nil? || resource == 'null'
          dict = SourceRoundAnnotationInk.dictionary(parser,resource)
          if dict['/Pattern']
            patterns = SourceRoundAnnotationInk.dictionary(parser,dict['/Pattern'])
            raise Unproven, 'background pattern text provenance is unproven' unless patterns.empty?
          end
          if dict['/Font']
            SourceRoundAnnotationInk.dictionary(parser,dict['/Font']).each do |name,ref|
              font = SourceRoundAnnotationInk.dictionary(parser,ref)
              type = font['/Subtype']
              unless ['/Type1','/MMType1','/TrueType','/Type0'].include?(type)
                raise Unproven, 'background font can contain unlabelled source glyph paint: ' + type.to_s
              end
              if type == '/Type0'
                descendants = parser.resolve_object(font['/DescendantFonts'])
                descendants = parser.send(:parse_array_string,descendants) if descendants.is_a?(String) && descendants.strip.start_with?('[')
                unless descendants.is_a?(Array) && descendants.length == 1 &&
                       ['/CIDFontType0','/CIDFontType2'].include?(SourceRoundAnnotationInk.dictionary(parser,descendants.first)['/Subtype'])
                  raise Unproven, 'background composite font descendant is unresolved'
                end
              end
              fonts << { :name=>name,:reference=>ref,:subtype=>type }
            end
          end
          if dict['/XObject']
            SourceRoundAnnotationInk.dictionary(parser,dict['/XObject']).each do |_name,ref|
              object = SourceRoundAnnotationInk.dictionary(parser,ref)
              if object['/Subtype'] == '/Form'
                unless forms[ref]
                  raise Unproven, 'background Form stream reference is unbound' unless /\A(\d+)\s+\d+\s+R\z/ =~ ref.to_s
                  forms[ref] = true
                  check_stream.call(parser.get_stream_data(Regexp.last_match(1).to_i))
                end
                visit.call(object['/Resources'] || resource,depth+1)
              end
            end
          end
        end
        visit.call(root,0)
        { :schema=>'bcs.annotation_background_font_scope/1', :type3_and_pattern_programs_absent=>true,
          :text_clipping_modes_absent=>true, :text_stroke_modes_absent=>true, :source_stream_sha256=>streams,
          :resource_dictionary_count=>seen.length,:font_resources=>fonts }
      end

      # Clip/mask/opacity can only reduce the possible original glyph ink.
      # Ignore that narrowing for an absence proof. Filters can enlarge/replicate
      # paint and therefore remain unsupported. Live references, not definition
      # ordering, supply every possible glyph occurrence.
      class BackgroundGlyphInventory < SourceImagePaintOrder::Inventory
        def verify_page_space!(media_box)
          svg = @root[:children].select { |node| node[:name] == 'svg' }
          raise Unproven, 'background SVG has no unique page viewport' unless svg.length == 1
          attrs = svg.first[:attrs]
          viewbox = attrs['viewbox'].to_s.split(/[\s,]+/).map { |n| number(n) }
          width = attrs['width'].to_s[/\A([0-9.+-]+)pt\z/,1]
          height = attrs['height'].to_s[/\A([0-9.+-]+)pt\z/,1]
          unless media_box[0] == 0 && media_box[1] == 0 &&
                 viewbox == media_box && width && height &&
                 number(width) == media_box[2] && number(height) == media_box[3]
            raise Unproven, 'background SVG is not in original unrotated page coordinates'
          end
          true
        end
        def glyph_events
          result = []
          visit_glyphs(@root, { :matrix=>SourceImagePaintOrder::IDENTITY, :alpha=>1.0,
            'fill'=>'black' }, result, [], false)
          result
        end

        def conservative_context(node, parent)
          attrs = attributes(node)
          permitted = %w[id transform fill stroke stroke-width stroke-miterlimit stroke-linejoin stroke-linecap
            fill-opacity stroke-opacity fill-rule clip-rule opacity display visibility mask clip-path filter
            x y width height viewbox version xmlns xmlns:xlink xlink:href href d preserveaspectratio overflow]
          unknown = attrs.keys - permitted - ['style']
          raise Unproven, 'unaccounted background SVG attributes: ' + unknown.join(',') unless unknown.empty?
          if node[:name] == 'svg' && !@root[:children].include?(node)
            raise Unproven, 'nested background SVG viewport is unproven'
          end
          if ['use','symbol'].include?(node[:name]) && ['viewbox','width','height'].any? { |key| attrs.key?(key) }
            raise Unproven, 'background symbol viewport scaling is unproven'
          end
          if attrs['filter'] && attrs['filter'] != 'none'
            raise Unproven, 'background glyph filter extent is unproven'
          end
          if attrs['class']
            raise Unproven, 'background glyph CSS extent is unproven'
          end
          local = SvgPaintOrder.parse_transform(attrs['transform'])
          ctx = parent.merge(:matrix=>SvgPaintOrder.multiply(parent[:matrix],local))
          ['fill','stroke','stroke-width','stroke-miterlimit','stroke-linejoin','fill-opacity','stroke-opacity'].each do |key|
            ctx[key] = attrs[key] if attrs.key?(key)
          end
          ctx
        end

        def effect_contains_glyph?(node, chain = [])
          raise Unproven, 'background effect reference cycle/depth' if chain.length > SourceImagePaintOrder::MAX_DEPTH || chain.include?(node.object_id)
          return true if node[:attrs]['id'].to_s =~ /\A(?:glyph[-_]|font[-_])/
          chain = chain + [node.object_id]
          attrs = attributes(node)
          references = ['mask','clip-path'].map { |key| attrs[key] }.compact.reject { |value| value == 'none' }
          references << (attrs['xlink:href'] || attrs['href']) if node[:name] == 'use'
          references.any? { |value| effect_contains_glyph?(referenced(value),chain) } ||
            node[:children].any? { |child| effect_contains_glyph?(child,chain) }
        end

        def visit_glyphs(node, parent, result, chain, referenced_node)
          raise Unproven, 'background source reference cycle/depth' if chain.length > SourceImagePaintOrder::MAX_DEPTH || chain.include?(node.object_id)
          chain = chain + [node.object_id]
          return if ['title','desc','metadata','clippath','mask','filter'].include?(node[:name]) && !referenced_node
          return if node[:name] == 'defs' && !referenced_node
          ctx = conservative_context(node,parent)
          attrs = attributes(node)
          ['mask','clip-path'].each do |key|
            if attrs[key] && attrs[key] != 'none' && effect_contains_glyph?(referenced(attrs[key]))
              raise Unproven, 'source glyphs used as an effect require separate ink proof'
            end
          end
          case node[:name]
          when 'root','svg','g','symbol'
            node[:children].each { |child| visit_glyphs(child,ctx,result,chain,false) }
          when 'use'
            target = referenced(attrs['xlink:href'] || attrs['href'])
            shifted = ctx.merge(:matrix=>SvgPaintOrder.multiply(ctx[:matrix],
              [1,0,0,1,number(attrs['x'] || 0),number(attrs['y'] || 0)]))
            if target[:attrs]['id'].to_s =~ /\A(?:glyph[-_]|font[-_])/
              bounds = conservative_glyph_bounds(target, shifted)
              result << { :glyph_id=>target[:attrs]['id'], :svg_offset=>node[:offset],
                :bounds=>bounds, :zero_ink=>bounds.nil? }
            else
              visit_glyphs(target,shifted,result,chain,true)
            end
          when 'image'
            # A renderer may flatten source text inside an image. Its full
            # affine footprint is possible text ink until independently proven.
            unless [nil,'none','xMidYMid meet'].include?(attrs['preserveaspectratio']) && [nil,'hidden'].include?(attrs['overflow'])
              raise Unproven, 'background image slice/overflow extent is unproven'
            end
            quad = SourceImagePaintOrder.corners(attrs).map { |point| SourceImagePaintOrder.point(ctx[:matrix],point) }
            result << { :possible_flattened_text_image=>true,
              :bounds=>SourceImagePaintOrder.box(quad), :zero_ink=>false }
          when 'path','rect'
            # Non-text source pixels are retained by the final-original crop.
          else
            raise Unproven, 'unaccounted background source element ' + node[:name]
          end
        end

        def conservative_glyph_bounds(node, parent)
          ctx = conservative_context(node,parent)
          bounds = if node[:name] == 'path'
                     [shape_box(node,ctx)]
                   elsif ['g','symbol'].include?(node[:name])
                     node[:children].map { |child| conservative_glyph_bounds(child,ctx) }
                   else
                     raise Unproven, 'unaccounted background glyph definition'
                   end
          SourceImagePaintOrder.box(bounds.compact.flat_map { |b| [[b[0],b[1]],[b[2],b[3]]] })
        end

        def prove_absence!(plans)
          glyphs = glyph_events
          plans.each do |plan|
            query = plan.fetch(:source_box_svg)
            overlap = glyphs.select { |g| !g[:zero_ink] && SourceImagePaintOrder.overlap?(g[:bounds],query) }
            raise Unproven, 'annotation composite overlaps original source glyph ink bounds' unless overlap.empty?
          end
          { :schema=>'bcs.original_annotation_background_text/1', :svg_sha256=>@svg_sha256,
            :possible_glyph_count=>glyphs.count { |item| !item[:possible_flattened_text_image] },
            :possible_flattened_text_image_count=>glyphs.count { |item| item[:possible_flattened_text_image] },
            :flattened_image_bounds_disjoint=>true, :crop_count=>plans.length,
            :source_crop_boxes_svg=>plans.map { |plan| plan.fetch(:source_box_svg) },
            :all_crop_glyph_bounds_disjoint=>true, :clip_mask_visibility_narrowing_ignored=>true }
        end
      end
    end
  end
end
