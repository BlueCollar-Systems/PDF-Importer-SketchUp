# Exact planar composition for earlier, opaque PDF fills and flat text.
# The caller owns the import operation. Optional per-mask continuation accepts
# only failures whose private stage and source visibility were safely restored.
# No text geometry, representation, identity, or depth is changed here.
require File.join(File.dirname(__FILE__), 'representation_fidelity')
require File.join(File.dirname(__FILE__), 'import_run_control')
require File.join(File.dirname(__FILE__), 'svg_region_boundary')
require File.join(File.dirname(__FILE__), 'planar_region_partition')

module BlueCollarSystems
  module PDFVectorImporter
    module PlanarWhiteKnockout
      CONSTRUCTION_SCALE = 1000.0
      NATIVE_VERTEX_TOLERANCE = 0.001
      CONSTRUCTION_CLEARANCE = NATIVE_VERTEX_TOLERANCE * 8.0
      MAX_CONSTRUCTION_SCALE_STEPS = 30
      MAX_CONSTRUCTION_COORDINATE = 2.0**40
      PLANE_TOLERANCE = 1.0e-7
      DICTIONARY = 'BC_PDF_Importer'.freeze
      GRID_SIZE = 0.25
      MAX_INDEX_CELLS = 4096
      MAX_MASK_FAILURE_DETAILS = 32

      class RestoredMaskFailure < StandardError
        attr_reader :details
        def initialize(details)
          @details = details
          super(details[:detail])
        end
      end

      # Diagnostic output only. Flush selected attempt/outcome records and at
      # most one coarse checkpoint every ten seconds; never flush each cell.
      # A blocked host call cannot emit a heartbeat until control returns.
      # Only the binding/composition options receive this narrow proxy.
      # Delegate first: return values and terminal exception objects are owned
      # by the original controller, and logging never replaces those decisions.
      class CheckpointProgressProxy
        def initialize(controller, opts)
          @controller = controller
          @opts = opts
        end

        def checkpoint!(stage, detail = {})
          result = @controller.checkpoint!(stage, detail)
          begin
            sampled = detail.is_a?(Hash) ? detail.merge(:phase => stage) : { :phase => stage }
            PlanarWhiteKnockout.log_progress!(@opts, :progress, sampled)
          rescue StandardError
            # Only diagnostic preparation is guarded; delegation above is not.
          end
          result
        end
      end

      def self.progress_controller(controller, opts)
        return controller unless opts[:mask_progress].is_a?(Hash) &&
          controller && controller.respond_to?(:checkpoint!)
        CheckpointProgressProxy.new(controller, opts)
      end

      def self.white_mask_progress_clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rescue StandardError
        Time.now.to_f
      end

      def self.log_progress!(opts, event, detail = {}, force = false)
        state = opts[:mask_progress]
        return false unless state.is_a?(Hash) && defined?(Logger)
        now = white_mask_progress_clock
        last = state[:last_record_at]
        return false unless force || last.nil? || now - last >= 10.0
        elapsed = [now - state[:started_at], 0.0].max.round(3)
        fields = ["page=#{opts[:page_number]}", "event=#{event}", "elapsed_s=#{elapsed}"]
        [:mask_index, :mask_total, :pdf_paint_order, :svg_paint_order].each do |key|
          fields << "#{key}=#{state[key].inspect}" if state.key?(key)
        end
        if state[:mask_started_at]
          fields << "mask_elapsed_s=#{[now - state[:mask_started_at], 0.0].max.round(3)}"
        end
        detail.each { |key, value| fields << "#{key}=#{safe_error_detail(value.inspect)}" }
        Logger.info('WhiteMaskProgress', fields.join('; '))
        Logger.flush_log # Ruby-buffer flush, not fsync or a durable write claim.
        state[:last_record_at] = now
        true
      rescue StandardError
        false # Logging failure never changes delivery or cancellation.
      end

      def self.run_checkpoint!(opts, stage, completed, total)
        controller = opts[:run_controller]
        controlled = controller && controller.respond_to?(:checkpoint!)
        if controlled
          controller.checkpoint!(stage, :completed => completed, :total => total,
            :page => opts[:page_number])
        end
        log_progress!(opts, :progress,
          :phase => stage, :completed => completed, :total => total)
        !!controlled
      end

      # All transformations map to the same page coordinate system. A record's
      # :transformation is the complete transform of its group, not its parent.
      # :before_text must come from source paint order, never build order.
      # Text roots can instead be bare groups directly inside the page context.
      def self.compose!(fill_only_groups, text_roots, opts = {})
        ink = opts.key?(:ink_faces) ? opts[:ink_faces] : collect_text_faces(text_roots, opts)
        fail_contract('prebound physical ink faces must be an array') unless ink.is_a?(Array)
        result = { :white_groups => 0, :opaque_groups => 0, :composed_groups => 0,
                   :ink_faces => ink.length, :removed_area => 0.0,
                   :removed_area_basis => 'exact_source_partition',
                   :skipped_unproven_order => 0, :skipped_nonwhite => 0,
                   :unchanged_no_ink_groups => 0, :failed_groups => 0,
                   :mask_failures => [], :mask_failure_details_omitted => 0 }
        masks = Array(fill_only_groups)
        masks.each_with_index do |record, mask_index|
          if opts[:mask_progress].is_a?(Hash)
            opts[:mask_progress].merge!(:mask_index => mask_index,
              :mask_total => masks.length, :mask_started_at => nil,
              :pdf_paint_order => (record.is_a?(Hash) ? record[:pdf_paint_order] || record[:paint_order] : nil),
              :svg_paint_order => (record.is_a?(Hash) ? record[:paint_order] : nil))
          end
          run_checkpoint!(opts, :white_mask, mask_index, masks.length)
          unless opaque_fill?(record)
            result[:skipped_nonwhite] += 1
            next
          end
          result[:opaque_groups] += 1
          result[:white_groups] += 1 if opaque_white?(record)
          group = record[:group]
          transform = record[:transformation] || group.transformation
          white = snapshots(group, transform, false, false, nil, [], nil, opts)
          next if white.empty?
          unless white.all? { |face| opaque_material?(face[:material]) }
            result[:skipped_nonwhite] += 1
            next
          end
          unless white.all? { |face| planar?(face) }
            fail_contract('white mask is not on the page plane')
          end
          box = union_bounds(white)
          overlaps = ink.select { |face| boxes_overlap?(box, face[:bounds]) }
          candidates = overlaps.select { |face| earlier_mask?(record, face, opts) }
          result[:skipped_unproven_order] += overlaps.length - candidates.length
          next if candidates.empty?
          if opts[:mask_progress].is_a?(Hash)
            opts[:mask_progress][:mask_started_at] = white_mask_progress_clock
          end
          log_progress!(opts, :mask_attempt,
            { :phase => :exact_partition, :source_faces => white.length,
              :candidate_ink_faces => candidates.length }, true)
          begin
            removed_area = compose_group!(group, transform, white, candidates,
              opts.merge(:preserve_source => record[:preserve_source] == true,
                :mask_context => { :mask_index => mask_index,
                  :pdf_paint_order => record[:pdf_paint_order] || record[:paint_order],
                  :svg_paint_order => record[:paint_order] }))
          rescue RestoredMaskFailure => error
            log_progress!(opts, :mask_restored_failure,
              { :error_class => error.details[:error_class],
                :detail => error.details[:detail] }, true)
            raise unless opts[:continue_mask_failures] == true
            result[:failed_groups] += 1
            if result[:mask_failures].length < MAX_MASK_FAILURE_DETAILS
              result[:mask_failures] << error.details
            else
              result[:mask_failure_details_omitted] += 1
            end
            next
          end
          log_progress!(opts, :mask_completed,
            { :outcome => removed_area.nil? ? :unchanged_exact_no_ink : :composed,
              :removed_area => removed_area }, true)
          if removed_area.nil?
            result[:unchanged_no_ink_groups] += 1
            next
          end
          result[:removed_area] += removed_area
          group.erase! if child_entities(group).to_a.empty?
          result[:composed_groups] += 1
        end
        run_checkpoint!(opts, :white_mask, masks.length, masks.length)
        result
      rescue ImportRunControl::ImportCancelled, ImportRunControl::RollbackFailure,
             ImportRunControl::ResumeMismatch
        raise
      rescue RepresentationFidelity::ContractError
        raise
      rescue StandardError => error
        # Generic host failure is never affirmative evidence for a text fallback.
        # The failing line of this module is named so a host log says WHERE
        # the API refused, not only that it did.
        site = Array(error.backtrace).find { |line| line.include?('planar_white_knockout') }
        site = site ? site[/planar_white_knockout\.rb:\d+/] : nil
        fail_contract("native white-mask composition failed (#{error.class}" +
                      (site ? " at #{site}" : '') + '): ' +
                      safe_error_detail(error.message))
      end

      def self.safe_error_detail(message)
        message.to_s.gsub(%r{https?://\S+}, '[url]').
          gsub(/[A-Za-z]:[\\\/][^\r\n]*/, '[path]').
          gsub(%r{(?:/[\w. -]+){2,}}, '[path]').
          gsub(/[\x00-\x1f\x7f]/, ' ')[0, 180]
      end

      def self.earlier_mask?(mask, ink, opts = {})
        return true if mask[:before_text] == true || opts[:white_precedes_text] == true
        earlier = mask[:paint_order]
        later = ink[:paint_order]
        return false unless valid_order?(earlier) && valid_order?(later)
        (earlier <=> later) == -1
      end

      def self.valid_order?(order)
        order.is_a?(Array) && order.length == 2 &&
          order.all? { |value| value.is_a?(Integer) && value >= 0 }
      end

      def self.opaque_white?(record)
        opaque_fill?(record) && record[:fill_rgb].all? { |value| (value - 1.0).abs < 1.0e-9 }
      end

      def self.opaque_fill?(record)
        return false unless record.is_a?(Hash) && record[:group]
        rgb = record[:fill_rgb]
        return false unless rgb.is_a?(Array) && rgb.length == 3 && rgb.all? do |value|
          # Ruby 2.2 only supplies finite? on Float. Keep integer/rational
          # range checks exact: conversion could round an invalid channel in.
          real = value.is_a?(Integer) || value.is_a?(Rational) || value.is_a?(Float)
          real && (!value.is_a?(Float) || value.finite?) && value >= 0 && value <= 1
        end
        alpha = record.key?(:opacity) ? record[:opacity] : 1.0
        alpha.is_a?(Numeric) && alpha == 1.0
      end

      def self.collect_text_faces(roots, opts = {})
        result = []
        rows = Array(roots)
        rows.each_with_index do |root, index|
          run_checkpoint!(opts, :white_mask_ink, index, rows.length) if (index % 64).zero?
          record = root.is_a?(Hash) ? root : { :group => root }
          group = record[:group]
          next unless group
          transform = record[:transformation] || group.transformation
          faces = if group.typename.to_s == 'Image'
                    image = image_snapshot(group, transform)
                    image ? [image] : []
                  else
                    snapshots(group, transform, true, record[:verified_source_unit] == true,
                              nil, [], nil, opts)
                  end
          # A positive-depth text item is already physically in front. Do not
          # punch white masks using its coplanar bottom faces alone.
          next unless faces.all? { |face| planar?(face) }
          faces = faces.select { |face| opaque_material?(face[:material]) }
          faces.each do |face|
            face[:paint_order] = record[:paint_order]
            face[:source_span_id] = source_id_for(group) if face[:source_span_id].to_s.empty?
            face[:source_placements] = record[:source_placements] if record[:source_placements].is_a?(Array)
          end
          result.concat(faces)
        end
        run_checkpoint!(opts, :white_mask_ink, rows.length, rows.length)
        result.uniq { |face| [face[:entity_id], face[:loops]] }
      end

      def self.snapshots(group, transform, require_owner, inherited_owner = false,
                         inherited_material = nil, inherited_indices = [],
                         inherited_source_id = nil, opts = {})
        owner = inherited_owner || source_owner?(group)
        material = (group.material if group.respond_to?(:material)) || inherited_material
        indices = source_indices_for(group, inherited_indices)
        source_id = source_id_for(group, inherited_source_id)
        result = []
        children = child_entities(group).to_a
        children.each_with_index do |entity, index|
          if index > 0 && (index % 64).zero?
            run_checkpoint!(opts, :white_mask_ink, 0, 0)
          end
          next if entity.respond_to?(:valid?) && !entity.valid?
          next if entity.respond_to?(:hidden?) && entity.hidden? &&
                  entity.respond_to?(:get_attribute) &&
                  entity.get_attribute(DICTIONARY, 'source_fill_original', false) == true
          kind = entity.typename.to_s
          if kind == 'Face'
            next if require_owner && !owner
            loops = [entity.outer_loop] + entity.loops.to_a.reject do |loop|
              loop == entity.outer_loop
            end
            points = loops.map do |loop|
              loop.vertices.map do |vertex|
                point = vertex.position.transform(transform)
                [point.x.to_f, point.y.to_f, point.z.to_f]
              end
            end
            record = face_record(points, entity)
            record[:material] ||= material
            record[:back_material] ||= material
            record[:source_placement_indices] = source_indices_for(entity, indices)
            record[:source_span_id] = source_id_for(entity, source_id)
            result << record
          elsif kind == 'Group' || kind == 'ComponentInstance'
            result.concat(snapshots(entity, transform * entity.transformation,
                                    require_owner, owner, material, indices, source_id, opts))
          elsif kind != 'Edge' && !require_owner
            fail_contract('white fill-only group contains unrelated entities')
          end
        end
        result
      end

      def self.source_id_for(entity, inherited = nil)
        return inherited unless entity.respond_to?(:get_attribute)
        value = entity.get_attribute(DICTIONARY, 'source_span_id', '').to_s
        value.empty? ? inherited : value
      end

      def self.source_indices_for(entity, inherited = [])
        return inherited unless entity.respond_to?(:get_attribute)
        value = entity.get_attribute(DICTIONARY, 'source_placement_indices', nil)
        return inherited if value.nil?
        if value.is_a?(Array)
          return [] unless value.all? { |index| index.is_a?(Integer) && index >= 0 }
          return value.dup
        end
        return [] unless value.is_a?(String) && /\A\d+(?:,\d+)*\z/ =~ value
        value.split(',').map { |index| index.to_i }
      end

      def self.opaque_material?(material)
        return true unless material && material.respond_to?(:alpha)
        (material.alpha.to_f - 1.0).abs < 1.0e-9
      end

      # A verified crop of the transparent *whole source page* repaints the
      # opaque white pixels wherever its rectangle overlaps an earlier mask.
      # Generic transparent images do not have that property and are excluded.
      def self.image_snapshot(image, transform)
        return nil unless source_owner?(image)
        return nil unless ['pdftocairo_transparent_page_crop',
                           'ghostscript_transparent_page_crop'].include?(
          image.get_attribute(DICTIONARY, 'renderer', ''))
        proof_keys = ['raster_alpha_verified', 'raster_transparent_background_verified',
                      'raster_page_render_once_verified', 'raster_visible_pixel_verified']
        return nil unless proof_keys.all? { |key| image.get_attribute(DICTIONARY, key, false) == true }
        digest = image.get_attribute(DICTIONARY, 'raster_source_pdf_sha256', '').to_s
        return nil unless /\A[0-9a-f]{64}\z/i =~ digest
        matrix = image.transformation.to_a
        x_length = Math.sqrt(matrix.values_at(0, 1, 2).inject(0.0) { |sum, v| sum + v.to_f * v.to_f })
        y_length = Math.sqrt(matrix.values_at(4, 5, 6).inject(0.0) { |sum, v| sum + v.to_f * v.to_f })
        width, height = image.width.to_f, image.height.to_f
        unless [x_length, y_length, width, height].all? { |v| v.finite? && v > 0.0 }
          fail_contract('physical item raster has an invalid planar size')
        end
        w, h = width / x_length, height / y_length
        local = [[0.0, 0.0, 0.0], [w, 0.0, 0.0], [w, h, 0.0], [0.0, h, 0.0]]
        physical = local.map { |p| Geom::Point3d.new(*p).transform(image.transformation) }
        [0, 1, 2].each do |axis|
          values = physical.map { |p| [p.x, p.y, p.z][axis] }
          minimum = [image.bounds.min.x, image.bounds.min.y, image.bounds.min.z][axis]
          maximum = [image.bounds.max.x, image.bounds.max.y, image.bounds.max.z][axis]
          tolerance = [width, height, 1.0].max * 1.0e-7
          unless (values.min - minimum).abs <= tolerance && (values.max - maximum).abs <= tolerance
            fail_contract('physical item raster corners disagree with host image bounds')
          end
        end
        points = local.map do |p|
          point = Geom::Point3d.new(*p).transform(transform)
          [point.x.to_f, point.y.to_f, point.z.to_f]
        end
        record = face_record([points])
        record[:entity_id] = image.object_id
        record[:source_span_id] = source_id_for(image)
        record[:source_placement_indices] = source_indices_for(image)
        page = image.get_attribute(DICTIONARY, 'raster_page_number', nil)
        source_page = /\Atext_span:(\d+):\d+\z/.match(record[:source_span_id].to_s)
        # This flag is evidence for the caller's source-order binder, not a
        # blanket order override here. A final page crop can repaint its own
        # earlier page masks only when its source page identity also matches.
        if page.is_a?(Integer) && page > 0 && source_page && source_page[1].to_i == page
          record[:final_page_crop] = true
          record[:raster_page_number] = page
          record[:source_pdf_sha256] = digest
        end
        record
      end

      def self.child_entities(entity)
        entity.respond_to?(:entities) ? entity.entities : entity.definition.entities
      end

      def self.source_owner?(entity)
        return false unless entity.respond_to?(:get_attribute)
        !entity.get_attribute(DICTIONARY, 'source_span_id', '').to_s.empty?
      end

      def self.face_record(loops, entity = nil)
        unless loops.length > 0 && loops.all? do |loop|
          loop.length >= 3 && loop.all? { |point| point.length == 3 && point.all? { |v| v.to_f.finite? } }
        end
          fail_contract('invalid physical face contour in planar composition')
        end
        points = loops.flatten(1)
        { :loops => loops,
          :bounds => [points.map { |p| p[0] }.min, points.map { |p| p[1] }.min,
                      points.map { |p| p[0] }.max, points.map { |p| p[1] }.max],
          :entity_id => entity ? entity.object_id : nil,
          :material => entity && entity.material,
          :back_material => entity && entity.back_material,
          :layer => entity && entity.layer }
      end

      def self.planar?(face)
        face[:loops].all? { |loop| loop.all? { |point| point[2].abs <= PLANE_TOLERANCE } }
      end

      def self.union_bounds(faces)
        boxes = faces.map { |face| face[:bounds] }
        [boxes.map { |b| b[0] }.min, boxes.map { |b| b[1] }.min,
         boxes.map { |b| b[2] }.max, boxes.map { |b| b[3] }.max]
      end

      def self.boxes_overlap?(a, b)
        a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]
      end

      def self.contains?(face, point)
        box = face[:bounds]
        return false if point[0] < box[0] || point[0] > box[2] ||
                        point[1] < box[1] || point[1] > box[3]
        point_in_loop?(point, face[:loops][0]) &&
          !face[:loops].drop(1).any? { |loop| point_in_loop?(point, loop) }
      end

      def self.point_in_loop?(point, loop)
        inside = false
        previous = loop[-1]
        loop.each do |current|
          if (current[1] > point[1]) != (previous[1] > point[1])
            x = current[0] + (point[1] - current[1]) *
                (previous[0] - current[0]) / (previous[1] - current[1])
            inside = !inside if point[0] < x
          end
          previous = current
        end
        inside
      end

      def self.region_at(point, white, ink)
        return :outside unless point_candidates(white, point).any? { |face| contains?(face, point) }
        point_candidates(ink, point).any? { |face| contains?(face, point) } ? :ink : :white
      end

      def self.spatial_index(records)
        grid = {}
        large = []
        records.each do |record|
          box = record[:bounds]
          x0, y0, x1, y1 = box.map { |value| (value / GRID_SIZE).floor }
          if (x1 - x0 + 1) * (y1 - y0 + 1) > MAX_INDEX_CELLS
            large << record
            next
          end
          (x0..x1).each do |x|
            (y0..y1).each { |y| (grid[[x, y]] ||= []) << record }
          end
        end
        { :grid => grid, :large => large }
      end

      def self.point_candidates(records, point)
        return records unless records.is_a?(Hash)
        key = [(point[0] / GRID_SIZE).floor, (point[1] / GRID_SIZE).floor]
        Array(records[:grid][key]) + records[:large]
      end

      def self.loop_area(loop)
        area = 0.0
        previous = loop[-1]
        loop.each do |point|
          area += previous[0] * point[1] - point[0] * previous[1]
          previous = point
        end
        area.abs * 0.5
      end

      def self.source_area(faces)
        faces.inject(0.0) do |sum, face|
          sum + loop_area(face[:loops][0]) -
            face[:loops].drop(1).inject(0.0) { |holes, loop| holes + loop_area(loop) }
        end
      end

      def self.compose_group!(group, transform, white, ink, opts = {})
        # The geometric operation preserves original face materials/alpha.
        # compose! supplies the opaque-source-fill eligibility policy; callers
        # proving another exact source-composite relationship may use this
        # operation directly for colored or translucent source fill groups.
        entities = child_entities(group)
        originals = entities.to_a
        original_visibility = []
        if opts[:preserve_source] == true
          originals.each do |entity|
            original_visibility << [entity, entity.hidden?] if entity.respond_to?(:hidden?)
          end
        end
        stage = nil
        begin
          box = union_bounds(white)
          origin = [(box[0] + box[2]) * 0.5, (box[1] + box[3]) * 0.5, 0.0]
          source_cells = PlanarRegionPartition.partition(white, ink, opts)
          if !source_cells.empty? && source_cells.all? { |cell| cell[:region] == :white }
            unless source_cells.all? do |cell|
              loop = cell[:loop]
              cell[:area].is_a?(Rational) && cell[:area] > 0 &&
                loop.is_a?(Array) && loop.length >= 3 && loop.all? { |point|
                  point.is_a?(Array) && point.length == 3 &&
                    point.all? { |value| value.is_a?(Rational) && value.to_f.finite? } && point[2] == 0
                } && SvgRegionBoundary.signed_area2(loop) == cell[:area] * 2
            end
              fail_contract('exact no-op white-mask partition has invalid source cells')
            end
            partition_clearance_squared(source_cells) # Topology only; unchanged cells need no host scale.
            expected = source_area(white)
            area = source_cells.inject(0.to_r) { |sum, cell| sum + cell[:area] }.to_f
            tolerance = [expected.abs * 1.0e-7, 1.0e-10].max
            unless expected.finite? && expected > 0.0 && area.finite? && (area - expected).abs <= tolerance
              fail_contract('native white-mask partition changed source white area')
            end
            verify_mask_owner!(group)
            verify_preserved_source!(originals) if opts[:preserve_source] == true
            run_checkpoint!(opts, :white_mask_verify, source_cells.length, source_cells.length)
            return nil # Exact unchanged outcome, never a rounded numeric zero.
          end
          begin
            scale = partition_construction_scale(source_cells)
          rescue ConstructionScaleBudgetError
            # One exact alternate slab direction can remove artificial skinny
            # decomposition cells without changing any source contour or limit.
            source_cells = rotated_construction_partition(white, ink, source_cells, opts)
            scale = partition_construction_scale(source_cells)
          end
          # Retain the complete exact partition/clearance proof even though
          # ink cells need not become temporary native geometry. Area is still
          # certified against the original physical mask, not the kept subset.
          source_areas = { :white => 0.to_r, :ink => 0.to_r }
          source_cells.each_with_index do |cell, index|
            run_checkpoint!(opts, :white_mask_partition, index, source_cells.length) if (index % 64).zero?
            unless source_areas.key?(cell[:region]) && cell[:area].is_a?(Rational) && cell[:area] > 0 &&
                SvgRegionBoundary.signed_area2(cell[:loop]) == cell[:area] * 2
              fail_contract('exact white-mask partition has invalid source class or area')
            end
            source_areas[cell[:region]] += cell[:area]
          end
          expected = source_area(white)
          source_partition_area = source_areas.values.inject(0.to_r, :+).to_f
          tolerance = [expected.abs * 1.0e-7, 1.0e-10].max
          unless expected.finite? && expected > 0.0 && source_partition_area.finite? &&
              (source_partition_area - expected).abs <= tolerance
            fail_contract('exact white-mask partition changed source white area')
          end
          white_cells = source_cells.select { |cell| cell[:region] == :white }
          kept_only = !white_cells.empty?
          construction_cells = kept_only ? white_cells : source_cells
          stage = entities.add_group
          stage.name = 'PDF planar white composition' if stage.respond_to?(:name=)
          origin, scale, point_map = partition_construction_frame!(
            stage, source_cells, origin, scale, transform)
          created_faces = nil
          if kept_only && white.length == 1 && defined?(Geom::PolygonMesh) &&
              stage.entities.respond_to?(:fill_from_mesh)
            created_faces = try_bulk_partition_cells!(group, entities, stage,
              originals, construction_cells, point_map, scale, tolerance, white.first, opts)
          end
          unless created_faces
            created_faces = {}
            construction_cells.each_with_index do |cell, index|
              run_checkpoint!(opts, :white_mask_cells, index, construction_cells.length) if (index % 64).zero?
              # A convex source cell has no holes and cannot cross a source
              # boundary. Keep cells in separate identity groups so legacy host
              # face discovery cannot merge adjacent regions across that boundary.
              container = stage.entities.add_group
              points = cell[:loop].map { |point| point_map.fetch(point) }
              face = container.entities.add_face(points)
              fail_contract('native exact white-mask cell construction failed') unless face
              verify_partition_face!(face, points)
              if kept_only
                identity = face.respond_to?(:entityID) ? face.entityID : nil
                unless identity.is_a?(Integer) && identity > 0 && !created_faces.key?(identity)
                  fail_contract('native kept white-mask cell has no unique entity identity')
                end
                created_faces[identity] = face
              end
            end
          end
          run_checkpoint!(opts, :white_mask_cells, construction_cells.length, construction_cells.length)
          cells = partition_faces(stage.entities)
          fail_contract('native white-mask subdivision produced no faces') if cells.empty?
          if kept_only
            actual_ids = {}
            unless created_faces.length == construction_cells.length &&
                created_faces.values.all?(&:valid?) && cells.length == created_faces.length &&
                cells.all? do |face|
                  identity = face.respond_to?(:entityID) ? face.entityID : nil
                  retained = created_faces[identity]
                  unique = !actual_ids.key?(identity)
                  actual_ids[identity] = true
                  unique && retained && face == retained
                end
              fail_contract('native kept white-mask cell roster changed during construction')
            end
          end
          white_index = spatial_index(white)
          ink_index = spatial_index(ink)
          plan = classify_cells(cells, origin, white_index, ink_index, scale, opts)
          if kept_only && !plan.all? { |cell| cell[:region] == :white }
            fail_contract('native kept white-mask cell changed exact source class')
          end
          if kept_only && !plan.all? { |cell| cell[:area].finite? && cell[:area] > 0.0 }
            fail_contract('native kept white-mask cell has invalid area')
          end
          expected_native = kept_only ? source_areas[:white].to_f : expected
          partition_area = plan.inject(0.0) do |sum, cell|
            cell[:region] == :outside ? sum : sum + cell[:area]
          end
          if !partition_area.finite? || !expected_native.finite? ||
              (partition_area - expected_native).abs > tolerance
            fail_contract('native white-mask partition changed source white area')
          end
          kept = plan.select { |cell| cell[:region] == :white }
          verify_ink_samples!(ink, white_index, spatial_index(kept), origin, ink_index, opts)
          plan.each_with_index do |cell, index|
            run_checkpoint!(opts, :white_mask_style, index, plan.length) if (index % 64).zero?
            face = cell[:face]
            if cell[:region] == :white
              style = white.find { |record| contains?(record, cell[:sample]) }
              face.material = style[:material]
              face.back_material = style[:back_material]
              face.layer = style[:layer] if style[:layer]
              face.reverse! if face.normal.z < 0
            else
              face.erase!
            end
          end
          clean_partition_edges!(stage.entities)
          # Cancel before changing source visibility or erasing originals.
          run_checkpoint!(opts, :white_mask_style, plan.length, plan.length)
          if opts[:preserve_source] == true
            verify_preserved_source!(originals)
            originals.each { |entity| entity.hidden = true }
            fail_contract('native host did not hide composed source fill') unless originals.all?(&:hidden?)
          else
            entities.erase_entities(originals)
          end
          # The legacy host purges empty groups at commit. Remove our empty
          # construction container now, before the retained-entity certificate.
          if stage.entities.to_a.empty?
            stage.erase!
          else
            stage.set_attribute(DICTIONARY, 'planar_white_knockout', true)
            stage.set_attribute(DICTIONARY, 'source_fill_composed_visible', true)
          end
          # Public numeric result is the exact source-partition ink area;
          # compose! labels this basis explicitly, including the ink-only path.
          source_areas[:ink].to_f
        rescue StandardError => error
          terminal = error.is_a?(ImportRunControl::ImportCancelled) ||
                     error.is_a?(ImportRunControl::ResumeMismatch) ||
                     error.is_a?(ImportRunControl::RollbackFailure)
          begin
            stage.erase! if stage && stage.valid?
            if stage && stage.valid?
              raise ImportRunControl::RollbackFailure, 'white-mask stage remains live after erase'
            end
            verify_mask_owner!(group)
            unless originals.all? { |entity| entity.respond_to?(:valid?) && entity.valid? }
              raise ImportRunControl::RollbackFailure, 'original white-mask source was destroyed'
            end
            original_visibility.each do |entity, hidden|
              if entity.hidden? != hidden
                unless entity.respond_to?(:hidden=)
                  raise ImportRunControl::RollbackFailure, 'source fill visibility is not restorable'
                end
                entity.hidden = hidden
              end
              unless entity.hidden? == hidden
                raise ImportRunControl::RollbackFailure, 'source fill visibility restoration failed readback'
              end
            end
          rescue StandardError => cleanup_error
            prefix = terminal ? 'cancelled white-mask rollback failed: ' : 'white-mask rollback failed: '
            raise ImportRunControl::RollbackFailure,
              prefix + cleanup_error.class.to_s + ': ' + cleanup_error.message.to_s
          end
          raise error if terminal
          partition_diagnostic(opts, white, ink, origin, error)
          if opts[:continue_mask_failures] == true
            raise RestoredMaskFailure.new(restored_mask_failure_details(
              group, white, ink, error, opts[:mask_context] || {}))
          end
          if error.is_a?(RepresentationFidelity::ContractError)
            bounds = union_bounds(white).map { |value| format('%.8g', value) }.join(',')
            owners = ink.map { |face| face[:source_span_id] }.compact.uniq.first(6).join(',')
            fail_contract("#{error.message}; white_bbox=[#{bounds}]; " \
                          "ink_faces=#{ink.length}; spans=#{owners}")
          end
          raise
        end
      end

      # Bulk emission changes only the private native staging representation.
      # Every exact cell still owns one verified Face; shared boundary Edges
      # are allowed, merged/split Faces and newly rounded points are not.
      # A rejected private mesh may use the existing isolated constructor only
      # after its own container is erased and source ownership/visibility plus
      # the empty, already-verified construction frame are read back unchanged.
      def self.try_bulk_partition_cells!(group, entities, stage, originals, cells,
                                         point_map, scale, tolerance, style, opts)
        visibility = originals.map { |entity| [entity, entity.respond_to?(:hidden?) ? entity.hidden? : nil] }
        frame = stage.transformation.to_a
        container = nil
        begin
          fail_contract('bulk white-mask frame is not empty') unless stage.entities.to_a.empty?
          container = stage.entities.add_group
          container.transformation = Geom::Transformation.new
          mesh = Geom::PolygonMesh.new(point_map.length, cells.length)
          indices, native_points = {}, {}
          cells.each_with_index do |cell, index|
            run_checkpoint!(opts, :white_mask_cells, index, cells.length) if (index % 64).zero?
            cell[:loop].each do |source|
              next if indices.key?(source)
              point = point_map.fetch(source)
              expected = [point.x.to_f, point.y.to_f, point.z.to_f]
              transformed = point.transform(container.transformation)
              unless [transformed.x.to_f, transformed.y.to_f, transformed.z.to_f] == expected
                fail_contract('bulk white-mask child frame changed source points')
              end
              native = mesh.add_point(point)
              unless native.is_a?(Integer) && native > 0 && !native_points.key?(native)
                fail_contract('bulk white-mask mesh collapsed source points')
              end
              actual = mesh.point_at(native)
              unless [actual.x.to_f, actual.y.to_f, actual.z.to_f] == expected
                fail_contract('bulk white-mask mesh changed source points')
              end
              native_points[native] = expected
              indices[source] = native
            end
          end
          polygons, expected_cells = {}, {}
          cells.each_with_index do |cell, index|
            run_checkpoint!(opts, :white_mask_cells, index, cells.length) if (index % 64).zero?
            points = cell[:loop].map { |source| point_map.fetch(source) }
            key = canonical_loop(points.map { |point| [point.x.to_f, point.y.to_f, point.z.to_f] })
            fail_contract('bulk white-mask source cell is duplicated') if expected_cells.key?(key)
            expected_cells[key] = cell
            polygon = mesh.add_polygon(cell[:loop].map { |source| indices.fetch(source) })
            unless polygon.is_a?(Integer) && polygon > 0 && !polygons.key?(polygon)
              fail_contract('bulk white-mask mesh rejected a source cell')
            end
            polygons[polygon] = true
            loop = mesh.polygon_at(polygon)
            unless loop.all? { |native| native.is_a?(Integer) && native_points.key?(native) } &&
                canonical_loop(loop.map { |native| native_points.fetch(native) }) == key
              fail_contract('bulk white-mask mesh changed a source cell')
            end
          end
          unless mesh.count_points == indices.length && mesh.count_polygons == cells.length
            fail_contract('bulk white-mask mesh roster changed')
          end
          run_checkpoint!(opts, :white_mask_cells, 0, cells.length)
          unless container.entities.fill_from_mesh(mesh, true, 0, style[:material], style[:back_material]) == true
            fail_contract('bulk white-mask native construction failed')
          end
          run_checkpoint!(opts, :white_mask_cells, cells.length, cells.length)
          unless stage.transformation.to_a == frame
            fail_contract('bulk white-mask construction frame changed')
          end
          indices.each_key do |source|
            point = point_map.fetch(source)
            actual = point.transform(container.transformation)
            unless [actual.x.to_f, actual.y.to_f, actual.z.to_f] == [point.x.to_f, point.y.to_f, point.z.to_f]
              fail_contract('bulk white-mask child frame changed during construction')
            end
          end
          created, matched, boundaries = {}, {}, {}
          native_entities = container.entities.to_a
          native_entities.each_with_index do |face, index|
            next unless face.typename.to_s == 'Face'
            run_checkpoint!(opts, :white_mask_cells, index, native_entities.length) if (index % 64).zero?
            unless face.valid? && face.loops.to_a.length == 1
              fail_contract('bulk white-mask native cell changed topology')
            end
            key = canonical_loop(face.outer_loop.vertices.map { |v| p = v.position; [p.x.to_f, p.y.to_f, p.z.to_f] })
            cell = expected_cells[key]
            identity = face.respond_to?(:entityID) ? face.entityID : nil
            unless cell && !matched.key?(key) && identity.is_a?(Integer) && identity > 0 && !created.key?(identity)
              fail_contract('bulk white-mask native cells merged, split or changed identity')
            end
            verify_partition_face!(face, cell[:loop].map { |source| point_map.fetch(source) })
            area = face.area.to_f / (scale * scale)
            unless area.finite? && area > 0.0 && (area - cell[:area].to_f).abs <= tolerance
              fail_contract('bulk white-mask native cell area changed')
            end
            matched[key] = true
            created[identity] = face
            key.each_with_index do |point, index|
              edge = [point, key[(index + 1) % key.length]].sort
              (boundaries[edge] ||= {})[identity] = face
            end
          end
          fail_contract('bulk white-mask native cell is missing') unless created.length == cells.length
          actual_edges, edge_ids = {}, {}
          native_entities.each do |entity|
            next if entity.typename.to_s == 'Face'
            unless entity.valid? && entity.typename.to_s == 'Edge' &&
                !entity.soft? && !entity.smooth? && entity.vertices.length == 2
              fail_contract('bulk white-mask native edge ownership changed')
            end
            edge = entity.vertices.map { |v| p = v.position; [p.x.to_f, p.y.to_f, p.z.to_f] }.sort
            expected = boundaries[edge]
            identity = entity.respond_to?(:entityID) ? entity.entityID : nil
            actual = entity.faces.to_a
            unless expected && !actual_edges.key?(edge) && identity.is_a?(Integer) && identity > 0 &&
                !edge_ids.key?(identity) && actual.length >= 1 && actual.length <= 2 &&
                actual.map(&:entityID).sort == expected.keys.sort &&
                actual.all? { |face| created[face.entityID] == face }
              fail_contract('bulk white-mask native edge boundary changed')
            end
            actual_edges[edge] = true
            edge_ids[identity] = true
          end
          fail_contract('bulk white-mask native edge is missing') unless actual_edges.length == boundaries.length
          created
        rescue StandardError => error
          # Terminal stops never retry another native representation.
          raise error if error.is_a?(ImportRunControl::ImportCancelled) ||
            error.is_a?(ImportRunControl::ResumeMismatch) || error.is_a?(ImportRunControl::RollbackFailure)
          begin
            container.erase! if container && container.valid?
            if (container && container.valid?) || !stage.valid? || !stage.entities.to_a.empty? ||
                stage.transformation.to_a != frame
              raise ImportRunControl::RollbackFailure, 'bulk white-mask private container was not erased'
            end
            verify_mask_owner!(group)
            current, expected_ids = {}, {}
            (originals + [stage]).each do |entity|
              identity = entity.respond_to?(:entityID) ? entity.entityID : nil
              unless entity.valid? && identity.is_a?(Integer) && identity > 0 && !expected_ids.key?(identity)
                raise ImportRunControl::RollbackFailure, 'bulk white-mask fallback original identity is unavailable'
              end
              expected_ids[identity] = entity
            end
            entities.to_a.each do |entity|
              identity = entity.respond_to?(:entityID) ? entity.entityID : nil
              if current.key?(identity) || !expected_ids.key?(identity) || entity != expected_ids[identity]
                raise ImportRunControl::RollbackFailure, 'bulk white-mask fallback source roster changed'
              end
              current[identity] = true
            end
            unless current.length == expected_ids.length &&
                visibility.all? { |entity, hidden| hidden.nil? || entity.hidden? == hidden }
              raise ImportRunControl::RollbackFailure, 'bulk white-mask fallback source roster or visibility changed'
            end
          rescue StandardError => cleanup_error
            raise ImportRunControl::RollbackFailure,
              'bulk white-mask fallback cleanup failed: ' + cleanup_error.message.to_s
          end
          nil # Source and frame are unchanged; the isolated path remains available.
        end
      end

      def self.verify_mask_owner!(group)
        unless group.respond_to?(:valid?) && group.valid?
          raise ImportRunControl::RollbackFailure, 'original white-mask owner was destroyed'
        end
      end

      def self.verify_preserved_source!(originals)
        unless originals.all? do |entity|
          entity.respond_to?(:hidden=) && entity.respond_to?(:hidden?) &&
            entity.respond_to?(:get_attribute) &&
            entity.get_attribute(DICTIONARY, 'source_fill_original', false) == true
        end
          fail_contract('opaque mask lacks separately owned editable source fill')
        end
      end

      # Emitted only after compose_group! has proved its local cleanup. Detail
      # strings and retained records are bounded; totals never imply success.
      def self.restored_mask_failure_details(group, white, ink, error, context)
        identity = begin
          group.respond_to?(:persistent_id) ? group.persistent_id :
            (group.respond_to?(:entityID) ? group.entityID : nil)
        rescue StandardError
          nil
        end
        { :local_cleanup_verified => true, :mask_index => context[:mask_index],
          :source_group_id => identity,
          :pdf_paint_order => context[:pdf_paint_order],
          :svg_paint_order => context[:svg_paint_order],
          :white_bbox => union_bounds(white), :ink_faces => ink.length,
          :source_span_ids => ink.map { |face| face[:source_span_id].to_s }.
            reject(&:empty?).uniq.first(6).map { |id| id[0, 120] },
          :error_class => error.class.to_s[0, 120],
          :detail => safe_error_detail(error.message) }
      end

      def self.verify_partition_face!(face, points)
        unless face.typename.to_s == 'Face' && face.valid? && face.loops.to_a.length == 1
          fail_contract('native exact white-mask cell changed face topology')
        end
        expected = points.map { |point| [point.x.to_f, point.y.to_f, point.z.to_f] }
        actual = face.outer_loop.vertices.map do |vertex|
          point = vertex.position
          [point.x.to_f, point.y.to_f, point.z.to_f]
        end
        unless canonical_loop(actual) == canonical_loop(expected)
          fail_contract('native exact white-mask cell changed source boundary vertices')
        end
      end

      # Minimum exact distance between cell vertices and between each corner
      # and its opposite chord. The latter also protects a thin, almost straight
      # corner whose vertex pairs are all farther apart than host tolerance.
      # Cells remain separate, so unrelated vertices in different cells do not
      # impose an unnecessary scale. No nonzero source feature is discarded.
      def self.partition_clearance_squared(cells)
        minimum = nil
        cells.each do |cell|
          loop = cell[:loop]
          loop.each_with_index do |a, i|
            loop.drop(i + 1).each do |b|
              distance = (b[0] - a[0])**2 + (b[1] - a[1])**2
              fail_contract('exact white-mask cell repeats a source vertex') unless distance > 0
              minimum = distance if minimum.nil? || distance < minimum
            end
            b, c = loop[(i + 1) % loop.length], loop[(i + 2) % loop.length]
            cross = SvgRegionBoundary.cross(SvgRegionBoundary.minus(b, a), SvgRegionBoundary.minus(c, b))
            chord = (c[0] - a[0])**2 + (c[1] - a[1])**2
            fail_contract('exact white-mask cell has a nonconvex source corner') unless cross > 0 && chord > 0
            altitude = cross * cross / chord
            minimum = altitude if minimum.nil? || altitude < minimum
          end
        end
        minimum
      end

      ConstructionScaleBudgetError = Class.new(RepresentationFidelity::ContractError)

      def self.partition_construction_scale(cells)
        clearance = partition_clearance_squared(cells)
        return CONSTRUCTION_SCALE unless clearance
        target = CONSTRUCTION_CLEARANCE.to_r**2
        scale = CONSTRUCTION_SCALE
        (MAX_CONSTRUCTION_SCALE_STEPS + 1).times do
          return scale if clearance * scale.to_r**2 >= target
          scale *= 2.0
        end
        raise ConstructionScaleBudgetError,
              'exact white-mask construction scale budget exceeded'
      end

      def self.rotated_construction_partition(white, ink, original_cells, opts = {})
        rotate = lambda do |regions|
          regions.map do |region|
            region.merge(:loops => region[:loops].map do |loop|
              loop.map do |point|
                [point[1].to_r, -point[0].to_r, point.length > 2 ? point[2].to_r : 0.to_r]
              end
            end)
          end
        end
        alternate = PlanarRegionPartition.partition(rotate.call(white), rotate.call(ink), opts)
        restored = alternate.each_with_index.map do |cell, index|
          run_checkpoint!(opts, :white_mask_partition, index, alternate.length) if (index % 64).zero?
          copy = cell.merge(:loop => cell[:loop].map { |point| [-point[1], point[0], point[2]] })
          unless SvgRegionBoundary.signed_area2(copy[:loop]) / 2 == cell[:area]
            fail_contract('alternate white-mask partition changed exact cell area or orientation')
          end
          copy
        end
        areas = lambda do |cells|
          cells.inject(Hash.new(0)) do |totals, cell|
            totals[cell[:region]] += cell[:area]
            totals
          end
        end
        unless areas.call(restored) == areas.call(original_cells)
          fail_contract('alternate white-mask partition changed exact source coverage')
        end
        run_checkpoint!(opts, :white_mask_partition, restored.length, restored.length)
        restored
      end

      # Only exact frame-roundtrip rejection permits the one bounded alternate
      # frame. Topology, coordinate/scale budgets and host failures stay terminal.
      ConstructionFrameError = Class.new(RepresentationFidelity::ContractError)

      def self.partition_construction_frame!(stage, cells, origin, scale, transform)
        begin
          mapped = partition_construction_points(cells, origin, scale)
          inverse_scale = 1.0 / scale
          # The three-axis overload avoids SketchUp2017's homogeneous weight.
          page = Geom::Transformation.translation(Geom::Point3d.new(*origin)) *
                 Geom::Transformation.scaling(inverse_scale, inverse_scale, inverse_scale)
          stage.transformation = transform.inverse * page
          verify_adaptive_page_points!(mapped, origin, scale, page, transform, stage.transformation)
          return [origin, scale, mapped]
        rescue ConstructionFrameError
          # Multiplication/division by a pure power of two needs no decimal
          # reciprocal or translation addition. Actual host transforms must
          # still prove exact source coordinates before any face is emitted.
          binary_scale = 1.0
          binary_scale *= 2.0 while binary_scale < scale
          origin, scale = [0.0, 0.0, 0.0], binary_scale
        end
        mapped = partition_construction_points(cells, origin, scale)
        inverse_scale = 1.0 / scale
        page = Geom::Transformation.scaling(inverse_scale, inverse_scale, inverse_scale)
        stage.transformation = transform.inverse * page
        verify_adaptive_page_points!(mapped, origin, scale, page, transform, stage.transformation)
        [origin, scale, mapped]
      end

      # Adaptive native and composed-world points must recover the source
      # Float coordinates exactly. An already-rounded 1000x frame is not source
      # authority; even a sub-tolerance displacement remains a rejected frame.
      def self.verify_adaptive_page_points!(mapped, origin, scale, page_transform,
                                           transform, stage_transform)
        return if scale == CONSTRUCTION_SCALE
        world = transform * stage_transform
        mapped.each do |source, point|
          expected = [source[0].to_f, source[1].to_f, 0.0]
          on_page = point.transform(page_transform)
          unless [on_page.x.to_f, on_page.y.to_f, on_page.z.to_f] == expected &&
                 page_point(point, origin, scale) == expected
            raise ConstructionFrameError, 'adaptive white-mask construction cannot restore exact page coordinates'
          end
          current = point.transform(world)
          after = [current.x.to_f, current.y.to_f, current.z.to_f]
          unless after == expected
            raise ConstructionFrameError, 'adaptive white-mask construction changed the final page transform'
          end
        end
      end

      def self.partition_construction_points(cells, origin, scale = CONSTRUCTION_SCALE)
        real_scale = scale.is_a?(Float) || scale.is_a?(Integer) || scale.is_a?(Rational)
        unless real_scale && scale.to_f.finite? && scale >= CONSTRUCTION_SCALE &&
               scale <= CONSTRUCTION_SCALE * (2.0**MAX_CONSTRUCTION_SCALE_STEPS)
          fail_contract('invalid exact white-mask construction scale')
        end
        mapped, owners = {}, {}
        cells.each do |cell|
          cell[:loop].each do |point|
            next if mapped.key?(point)
            values = [0, 1].map do |axis|
              ((point[axis] - origin[axis].to_r) * scale.to_r).to_f
            end + [0.0]
            fail_contract('exact white-mask cell has nonfinite host coordinates') unless values.all?(&:finite?)
            if scale != CONSTRUCTION_SCALE && values.any? { |value| value.abs > MAX_CONSTRUCTION_COORDINATE }
              fail_contract('adaptive white-mask host coordinate budget exceeded')
            end
            if owners.key?(values) && owners[values] != point
              fail_contract('exact white-mask vertices collapse in host coordinates')
            end
            owners[values] = point
            mapped[point] = Geom::Point3d.new(*values)
          end
          native = cell[:loop].map { |point| p = mapped.fetch(point); [p.x.to_r, p.y.to_r] }
          unless SvgRegionBoundary.signed_area2(native) > 0
            fail_contract('exact white-mask cell collapses or reverses in host coordinates')
          end
          native.each_index do |i|
            a, b, c = native[i], native[(i + 1) % native.length], native[(i + 2) % native.length]
            turn = SvgRegionBoundary.cross(SvgRegionBoundary.minus(b, a), SvgRegionBoundary.minus(c, b))
            unless turn > 0
              fail_contract('exact white-mask cell loses a convex corner in host coordinates')
            end
          end
          if scale != CONSTRUCTION_SCALE &&
             partition_clearance_squared([:loop => native]) < (CONSTRUCTION_CLEARANCE * 0.5).to_r**2
            fail_contract('adaptive white-mask native cell lost construction clearance')
          end
        end
        mapped
      end

      # An explicit harness callback may save private source contours outside
      # the repository. Normal imports never log or write those coordinates.
      def self.partition_diagnostic(opts, white, ink, origin, error)
        callback = opts[:partition_diagnostic]
        return unless callback.respond_to?(:call)
        copy = lambda do |records|
          records.map do |record|
            { :loops => record[:loops].map { |loop| loop.map(&:dup) },
              :source_span_id => record[:source_span_id] }
          end
        end
        callback.call(:schema => 'bcs.planar_partition_diagnostic/1',
                      :white => copy.call(white), :ink => copy.call(ink),
                      :origin => origin && origin.dup, :error => error.message.to_s)
      rescue StandardError
        # Failure to collect optional evidence cannot replace the import error.
        nil
      end

      def self.construction_ink_loops(ink)
        original = ink.flat_map { |record| record[:loops] }
        return original unless ink.length > 1
        crops = ink.select { |record| record[:final_page_crop] == true }
        return original if crops.empty?
        identities = crops.map { |record| [record[:source_pdf_sha256], record[:raster_page_number]] }.uniq
        return original unless identities.length == 1 &&
          /\A[0-9a-f]{64}\z/i =~ identities[0][0].to_s &&
          identities[0][1].is_a?(Integer) && identities[0][1] > 0
        return original unless ink.all? do |record|
          next true if record[:final_page_crop] == true
          source = /\Atext_span:(\d+):\d+\z/.match(record[:source_span_id].to_s)
          source && source[1].to_i == identities[0][1] && valid_order?(record[:paint_order])
        end
        # Legacy native face discovery can leave the white boundary unsplit
        # inside overlapping image rectangles, including a rectangle over
        # source-ordered glyph faces from its same page. Construct their union
        # boundary first; every classification, area and coverage gate below
        # still uses the original physical records, without altering text/images.
        # Unsupported point-touch topology keeps the existing native route and
        # its unchanged verification; it never authorizes approximate contours.
        SvgRegionBoundary.normalize(ink, :native_union) || original
      end

      def self.partition_faces(entities)
        entities.to_a.inject([]) do |faces, entity|
          next faces unless entity.valid?
          if entity.typename.to_s == 'Face'
            faces << entity
          elsif entity.typename.to_s == 'Group'
            # Only the identity-transform groups created by topology repair are
            # present inside this private construction stage.
            faces.concat(partition_faces(entity.entities))
          end
          faces
        end
      end

      def self.clean_partition_edges!(entities)
        entities.to_a.each do |entity|
          # An earlier edge erase can invalidate a later cached edge.
          next unless entity.valid?
          if entity.typename.to_s == 'Group'
            clean_partition_edges!(entity.entities)
            entity.erase! if entity.entities.to_a.empty?
          elsif entity.typename.to_s == 'Edge'
            entity.faces.empty? ? entity.erase! : (entity.hidden = true)
          end
        end
      end

      def self.loop_bounds2(loop)
        [loop.map { |p| p[0] }.min, loop.map { |p| p[1] }.min,
         loop.map { |p| p[0] }.max, loop.map { |p| p[1] }.max]
      end

      def self.point_in_closed_bounds?(point, box)
        point[0] >= box[0] && point[0] <= box[2] &&
          point[1] >= box[1] && point[1] <= box[3]
      end

      def self.strict_loop_inside?(point, loop, box = nil)
        return false if box && !point_in_closed_bounds?(point, box)
        return false if loop.each_index.any? do |i|
          SvgRegionBoundary.on_segment?(point, loop[i], loop[(i + 1) % loop.length])
        end
        SvgRegionBoundary.winding(point, loop) != 0
      end

      def self.invalid_native_holes?(loops)
        return false if loops.length < 2
        rational = loops.map { |loop| loop.map { |p| [p[0].to_r, p[1].to_r] } }
        outer, holes = rational.first, rational.drop(1)
        outer_bounds = loop_bounds2(outer)
        hole_bounds = holes.map { |hole| loop_bounds2(hole) }
        # Legacy find_faces can attach a hole outside its outer shell, or attach
        # a counter again inside an existing hole. Both produce invalid native
        # faces (even negative Face#area), although their edge coordinates remain.
        holes.each do |hole|
          return true if hole.any? do |p|
            !point_in_closed_bounds?(p, outer_bounds) ||
              (SvgRegionBoundary.winding(p, outer) == 0 &&
              !outer.each_index.any? { |i| SvgRegionBoundary.on_segment?(p, outer[i], outer[(i + 1) % outer.length]) }
              )
          end
        end
        holes.each_with_index do |hole, index|
          holes.each_with_index do |other, other_index|
            next if index == other_index
            return true if hole.any? { |p| strict_loop_inside?(p, other, hole_bounds[other_index]) }
          end
        end
        false
      end

      def self.repair_native_hole_topology!(entities)
        partition_faces(entities).each do |face|
          ordered = [face.outer_loop] + face.loops.to_a.reject { |loop| loop == face.outer_loop }
          raw = ordered.map do |loop|
            loop.vertices.map { |v| [v.position.x.to_f, v.position.y.to_f, v.position.z.to_f] }
          end
          next unless invalid_native_holes?(raw)
          normalized = SvgRegionBoundary.normalize([{ :loops => raw }], :native_union)
          fail_contract('native white-mask hole topology could not be reconstructed') unless normalized
          outers, holes = normalized.partition { |loop| SvgRegionBoundary.signed_area2(loop) > 0 }
          # Keep each connected region isolated: putting it back into the same
          # legacy edge graph can recreate the malformed nested/outside holes.
          groups = outers.map do |outer|
            group = entities.add_group
            shell = distinct_loop_points(outer.map { |p| Geom::Point3d.new(*p) })
            fail_contract('native white-mask outer reconstruction is degenerate') unless shell.length >= 3
            created = group.entities.add_face(shell)
            fail_contract('native white-mask outer reconstruction failed') unless created
            [outer, group]
          end
          holes.each do |hole|
            point = hole.first.first(2).map(&:to_r)
            owners = groups.select do |pair|
              strict_loop_inside?(point, pair[0].map { |p| p.first(2).map(&:to_r) })
            end
            fail_contract('native white-mask counter has no unique reconstructed shell') unless owners.length == 1
            counter = distinct_loop_points(hole.map { |p| Geom::Point3d.new(*p) })
            fail_contract('native white-mask counter reconstruction is degenerate') unless counter.length >= 3
            cut = owners[0][1].entities.add_face(counter)
            fail_contract('native white-mask counter reconstruction failed') unless cut
            cut.erase!
          end
          face.erase!
        end
      end

      def self.subdivide_native_boundaries!(entities)
        unless entities.respond_to?(:intersect_with)
          fail_contract('native white-mask boundary intersection API unavailable')
        end
        identity = Geom::Transformation.new
        # add_face alone can leave overlapping coplanar faces unsplit in the
        # legacy host. Explicitly intersect all boundaries in this construction
        # context before classifying cells. The permanent 1/1000 group transform
        # is deliberately absent here, preserving safe construction tolerance.
        entities.intersect_with(false, identity, entities, identity, true, entities.to_a)
        # The legacy host needs face discovery after intersection for crossing
        # boundaries. It may also create exactly coincident duplicate faces.
        # Remove only those exact loop duplicates, not overlapping polygons or
        # approximate neighbors. All boundary/area/coverage checks remain active.
        entities.to_a.each do |entity|
          next unless entity.valid?
          entity.find_faces if entity.typename.to_s == 'Edge'
        end
        remove_duplicate_faces!(entities)
      end

      def self.canonical_loop(points)
        minimum = points.min
        candidates = []
        [points, points.reverse].each do |direction|
          direction.each_index do |index|
            next unless direction[index] == minimum
            candidates << direction.rotate(index)
          end
        end
        candidates.min
      end

      def self.face_loop_signature(face)
        loops = [face.outer_loop] + face.loops.to_a.reject { |loop| loop == face.outer_loop }
        keys = loops.map do |loop|
          canonical_loop(loop.vertices.map do |vertex|
            point = vertex.position
            [point.x.to_f, point.y.to_f, point.z.to_f]
          end)
        end
        [keys.first, keys.drop(1).sort]
      end

      def self.remove_duplicate_faces!(entities)
        seen = {}
        entities.to_a.each do |entity|
          next unless entity.valid?
          next unless entity.typename.to_s == 'Face'
          key = face_loop_signature(entity)
          if seen.key?(key)
            entity.erase!
          else
            seen[key] = true
          end
        end
      end

      def self.construction_point(point, origin, scale = CONSTRUCTION_SCALE)
        Geom::Point3d.new((point[0] - origin[0]) * scale,
                         (point[1] - origin[1]) * scale, 0.0)
      end

      # SketchUp's add_face raises "Duplicate points in array" for consecutive
      # points closer than its 0.001 in vertex tolerance and for a closing
      # point that repeats the first. Source loops can carry both (a fill
      # contour whose last vertex closes on its first, or two vertices a
      # sub-tolerance apart): drop the repeats, keep the loop's shape.
      def self.distinct_loop_points(points)
        kept = []
        points.each do |point|
          last = kept.last
          next if last && same_native_point?(last, point)
          kept << point
        end
        kept.pop while kept.length > 1 && same_native_point?(kept.first, kept.last)
        kept
      end

      def self.same_native_point?(a, b)
        (a.x.to_f - b.x.to_f).abs < NATIVE_VERTEX_TOLERANCE &&
          (a.y.to_f - b.y.to_f).abs < NATIVE_VERTEX_TOLERANCE &&
          (a.z.to_f - b.z.to_f).abs < NATIVE_VERTEX_TOLERANCE
      end

      def self.page_point(point, origin, scale = CONSTRUCTION_SCALE)
        [point.x.to_f / scale + origin[0],
         point.y.to_f / scale + origin[1], 0.0]
      end

      # Several interior barycentric probes per native triangle prevent an
      # unsplit face that crosses a mask/glyph boundary being erased wholesale.
      def self.face_samples(face, origin, scale = CONSTRUCTION_SCALE)
        mesh = face.mesh(0)
        mesh.polygons.inject([]) do |samples, polygon|
          native = polygon.map { |index| mesh.point_at(index.abs) }
          fail_contract('native face mesh is not triangulated') unless native.length == 3
          next samples if degenerate_mesh_triangle?(native)
          points = native.map { |point| page_point(point, origin, scale) }
          [[1.0 / 3, 1.0 / 3, 1.0 / 3], [0.8, 0.1, 0.1],
           [0.1, 0.8, 0.1], [0.1, 0.1, 0.8]].each do |weights|
            samples << [0, 1, 2].map do |axis|
              points.each_with_index.inject(0.0) { |sum, (p, i)| sum + p[axis] * weights[i] }
            end
          end
          samples
        end
      end

      def self.degenerate_mesh_triangle?(points)
        x0, y0 = points[0].x.to_f, points[0].y.to_f
        term1 = (points[1].x.to_f - x0) * (points[2].y.to_f - y0)
        term2 = (points[1].y.to_f - y0) * (points[2].x.to_f - x0)
        # Face#mesh can return zero-area triangles along an existing straight
        # glyph edge. Such triangles have no interior; world-space rounding
        # can otherwise put their barycentric probes on either side of ink.
        # This is an arithmetic cancellation bound, not a small-area cutoff:
        # genuinely thin triangles with a nonzero determinant are retained.
        (term1 - term2).abs <= 8.0 * Float::EPSILON * (term1.abs + term2.abs)
      end

      def self.classify_cells(cells, origin, white, ink, scale = CONSTRUCTION_SCALE, opts = {})
        cells.each_with_index.map do |face, index|
          run_checkpoint!(opts, :white_mask_verify, index, cells.length) if (index % 64).zero?
          samples = face_samples(face, origin, scale)
          regions = samples.map { |point| region_at(point, white, ink) }.uniq
          unless regions.length == 1
            probes = regions.first(3).map do |region|
              point = samples.find { |sample| region_at(sample, white, ink) == region }
              "#{region}@#{point.first(2).map { |value| format('%.8g', value) }.join(',')}"
            end
            fail_contract('native white-mask face still crosses a source paint boundary: ' +
                          probes.join(' / '))
          end
          loops = [face.outer_loop] + face.loops.to_a.reject { |loop| loop == face.outer_loop }
          { :face => face, :region => regions[0], :sample => samples[0],
            :area => face.area.to_f / (scale * scale),
            :loops => loops.map { |loop| loop.vertices.map { |v| page_point(v.position, origin, scale) } },
            :bounds => page_point(face.bounds.min, origin, scale).first(2) +
                       page_point(face.bounds.max, origin, scale).first(2) }
        end
      end

      def self.verify_ink_samples!(ink, white, kept, origin, ink_index = ink, opts = {})
        # Check every source contour edge on both sides in addition to native
        # tessellation. This catches a small uncut glyph inside a large white
        # triangle whose ordinary centroid probes all fall outside the glyph.
        ink.each_with_index do |record, index|
          run_checkpoint!(opts, :white_mask_coverage, index, ink.length) if (index % 16).zero?
          record[:loops].each do |loop|
            previous = loop[-1]
            loop.each do |point|
              dx = point[0] - previous[0]
              dy = point[1] - previous[1]
              length = Math.sqrt(dx * dx + dy * dy)
              if length > 1.0e-12
                distance = [length * 0.001, 1.0e-6].min
                [-1.0, 1.0].each do |side|
                  probe = [(previous[0] + point[0]) * 0.5 - side * dy / length * distance,
                           (previous[1] + point[1]) * 0.5 + side * dx / length * distance, 0.0]
                  expected = region_at(probe, white, ink_index)
                  next if expected == :outside
                  covered = point_candidates(kept, probe).any? { |cell| contains?(cell, probe) }
                  if expected == :ink && covered
                    fail_contract('white face still covers physical glyph ink')
                  elsif expected == :white && !covered
                    fail_contract('native composition removed a white counter or surrounding mask')
                  end
                end
              end
              previous = point
            end
          end
        end
      end

      def self.fail_contract(message)
        raise RepresentationFidelity::ContractError, message
      end
    end
  end
end
