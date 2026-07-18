# bc_pdf_vector_importer/cairo_glyph_source.rb
# Round 23 (F-1): glyph SOURCE selection + telemetry for the requested
# Glyphs/Outlines text mode.
#
# TEXTMODE-1: the source is a decision INSIDE the delivered Glyphs mode,
# never a mode change. Sources, in preference order:
#
#   cairo_svg  - the free Poppler pdftocairo -svg pipeline when installed
#                (SvgTextRenderer). Outlines come from the PDF's own
#                embedded fonts, so condensed/anisotropic title-block runs
#                keep their declared extents. Non-embedded fonts still
#                depend on host substitution and are reported, never
#                assumed perfect (see missing_fonts /
#                missing_language_packs below).
#   mupdf_svg  - the same SVG pipeline through an installed MuPDF mutool
#                when pdftocairo is unavailable (existing shipped
#                alternative, honestly named in telemetry).
#   unavailable - no source was able to produce and certify the requested
#                 PDF glyph outlines. This is a stopped delivery, never a
#                 simplified-stroke substitution.
#
# The decision is made ONCE per import and recorded in
# stats[:glyph_source]. A missing/failed SVG source is marked unavailable
# (fallback_reason says why); generic helper failures cannot authorize a
# representation or glyph-shape substitution.
#
# R17-3: rendered glyph ink is position-matched back to extractor spans
# (pen point inside the span's declared bbox) so span_ids/provenance stay
# attached and disagreement is VISIBLE: runs_unmatched counts extractor
# spans with no glyph ink (e.g. poppler dropped a run: missing language
# pack / font); placements_unmatched counts glyph ink the extractor never
# declared. Zero glyph ink on a page where the extractor found spans is
# treated as a source failure, not success (no false green).
#
# Ruby 2.2 (SketchUp Make 2017) safe syntax throughout — the RB22 rules
# from the contributor card apply to every line of this file.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require File.join(File.dirname(__FILE__), 'svg_text_renderer')
require File.join(File.dirname(__FILE__), 'logger')

module BlueCollarSystems
  module PDFVectorImporter
    module CairoGlyphSource

      PDF_PT_TO_INCH = 1.0 / 72.0

      NumericPoint = Struct.new(:x, :y, :z) do
        def distance(other)
          dx = x.to_f - other.x.to_f
          dy = y.to_f - other.y.to_f
          dz = z.to_f - other.z.to_f
          Math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
        end
      end

      SOURCE_CAIRO = 'cairo_svg'.freeze
      SOURCE_MUPDF = 'mupdf_svg'.freeze
      SOURCE_UNAVAILABLE = 'unavailable'.freeze

      # Pen-in-bbox tolerance (PDF points). Probe: first-glyph pen sits
      # within 0.39 pt of the declared span xMin; 2 pt absorbs baseline vs
      # box-bottom semantics without crossing to neighbouring spans.
      SPAN_MATCH_TOLERANCE_PT = 2.0

      # ------------------------------------------------------------------
      # Per-import decision
      # ------------------------------------------------------------------

      # Returns the single per-import glyph-source decision, creating and
      # recording it in stats[:glyph_source] on first use.
      def self.import_decision(stats)
        return nil unless stats.is_a?(Hash)
        existing = stats[:glyph_source]
        return existing if existing.is_a?(Hash)
        decision = new_decision
        stats[:glyph_source] = decision
        decision
      end

      def self.new_decision
        kind = preferred_renderer_kind
        if kind == :pdftocairo
          base_decision(SOURCE_CAIRO, nil)
        elsif kind == :mutool
          base_decision(SOURCE_MUPDF, 'pdftocairo_missing')
        else
          decision = base_decision(SOURCE_UNAVAILABLE, 'pdftocairo_missing')
          decision[:locked] = true
          decision
        end
      end

      def self.base_decision(source, fallback_reason)
        {
          source: source,
          fallback_reason: fallback_reason,
          locked: false,
          pages: 0,
          runs_matched: 0,
          runs_unmatched: 0,
          placements_unmatched: 0,
          missing_fonts: [],
          missing_language_packs: []
        }
      end

      def self.preferred_renderer_kind
        renderer = SvgTextRenderer.find_svg_renderer
        renderer ? renderer[:kind] : nil
      rescue StandardError => e
        warn_safe("preferred_renderer_kind failed: #{e.message}")
        nil
      end

      def self.svg_source?(decision)
        return false unless decision.is_a?(Hash)
        decision[:source] == SOURCE_CAIRO || decision[:source] == SOURCE_MUPDF
      end

      def self.unavailable_source?(decision)
        decision.is_a?(Hash) && decision[:source] == SOURCE_UNAVAILABLE
      end

      # Record that the requested glyph source could not be certified.  This
      # is deliberately not a demotion to simplified stroke lettering.
      def self.mark_unavailable!(decision, reason)
        return false unless decision.is_a?(Hash)
        unless decision[:source] == SOURCE_UNAVAILABLE
          decision[:attempted_source] = decision[:source]
        end
        decision[:source] = SOURCE_UNAVAILABLE
        decision[:fallback_reason] = reason.to_s.empty? ? 'svg_source_failed' : reason.to_s
        decision[:locked] = true
        Logger.warn('CairoGlyphSource',
          "Glyphs mode SVG source unavailable (#{decision[:fallback_reason]}); " \
          'the requested Glyphs delivery is stopped without substitution.')
        true
      rescue StandardError
        false
      end

      # Map an SvgTextRenderer failure_info sink to a fallback reason.
      def self.failure_reason(failure_info)
        info = failure_info.is_a?(Hash) ? failure_info : {}
        case info[:reason].to_s
        when 'no_renderer' then 'pdftocairo_missing'
        when 'timeout' then 'pdftocairo_timeout'
        when 'svg_zero_placements' then 'svg_zero_placements'
        when '' then 'pdftocairo_failed'
        else 'pdftocairo_failed'
        end
      end

      # False-green guard (R23, forward-fix of the pinned review finding):
      # an SVG render that produced NO glyph ink on a page where the
      # extractor found text spans must count as a source failure.
      def self.zero_placement_false_green?(svg_result, text_items)
        return false unless svg_result.is_a?(Hash)
        return false if svg_result[:glyphs].to_i > 0
        span_count = 0
        Array(text_items).each do |item|
          span_count += 1 unless item_text(item).empty?
        end
        span_count > 0
      rescue StandardError
        false
      end

      # ------------------------------------------------------------------
      # Page recording + span matching (R17-3)
      # ------------------------------------------------------------------

      # Build the only evidence eligible to complete a deferred Poppler
      # diagnostic. This runs after SVG parsing and host placement, and after
      # matching those placed pens to the current extractor source spans.
      # Missing evidence is represented as a nonempty failure collection;
      # absence can never masquerade as zero failures.
      def self.semantic_completion_evidence(svg_result, text_items, media_box,
                                            allowed_unoutlined_ids = [])
        result = svg_result.is_a?(Hash) ? svg_result : {}
        match = match_spans(result[:placements_pdf], text_items, media_box)
        source_items = Array(text_items).select do |item|
          !item_text(item).empty?
        end
        source_ids = source_items.map { |item| source_span_id_for(item) }
        matched_ids = Array(match[:matched_items]).map do |item|
          source_span_id_for(item)
        end
        unmatched_runs = Array(match[:unmatched_source_runs]).map do |item|
          source_span_evidence(item)
        end

        if source_ids.empty?
          unmatched_runs << { :reason => :source_span_set_empty }
        elsif source_ids.any? { |span_id| span_id.empty? }
          unmatched_runs << { :reason => :source_span_id_missing }
        elsif source_ids.uniq.length != source_ids.length
          unmatched_runs << { :reason => :source_span_id_duplicate }
        elsif matched_ids.sort != source_ids.sort
          unmatched_runs << { :reason => :source_span_set_incomplete }
        end

        glyphs = result[:semantic_svg_glyphs]
        placements = result[:semantic_svg_placements]
        allowed_unoutlined = Array(allowed_unoutlined_ids).map do |glyph_id|
          glyph_id.to_s
        end.uniq.sort
        skipped_placements = required_array_evidence(
          result, :skipped_placement_evidence,
          :skipped_placement_evidence_missing
        )
        unoutlined = required_array_evidence(
          result, :unoutlined_placement_evidence,
          :unoutlined_placement_evidence_missing
        )
        unoutlined.each do |entry|
          glyph_id = entry.is_a?(Hash) ? entry[:glyph_id].to_s : ''
          skipped_placements << entry unless
            allowed_unoutlined.include?(glyph_id)
        end
        placement_failures = required_array_evidence(
          result, :placement_failure_evidence,
          :placement_failure_evidence_missing
        )
        unless glyphs.is_a?(Hash) && placements.is_a?(Array) &&
               !glyphs.empty? && !placements.empty?
          placement_failures << { :reason => :semantic_svg_evidence_missing }
        end

        {
          :renderer => result[:renderer],
          :representation => :glyph_geometry,
          :glyphs => glyphs,
          :placements => placements,
          :matched_source_span_ids => matched_ids,
          :allowed_unoutlined_glyph_ids => allowed_unoutlined,
          :unmatched_source_runs => unmatched_runs,
          :unmatched_placements => Array(match[:unmatched_placements]),
          :missing_language_packs => required_array_evidence(
            result, :missing_language_packs,
            :missing_language_pack_evidence_missing
          ),
          :skipped_placements => skipped_placements,
          :placement_failures => placement_failures
        }
      rescue StandardError => e
        {
          :renderer => nil,
          :representation => :glyph_geometry,
          :glyphs => nil,
          :placements => nil,
          :matched_source_span_ids => [],
          :allowed_unoutlined_glyph_ids => [],
          :unmatched_source_runs => [{ :reason => :evidence_exception,
                                       :detail => e.message.to_s }],
          :unmatched_placements => [{ :reason => :evidence_exception }],
          :missing_language_packs => [{ :reason => :evidence_exception }],
          :skipped_placements => [{ :reason => :evidence_exception }],
          :placement_failures => [{ :reason => :evidence_exception }]
        }
      end

      def self.required_array_evidence(result, key, missing_reason)
        return [{ :reason => missing_reason }] unless result.key?(key)
        value = result[key]
        return [{ :reason => missing_reason }] unless value.is_a?(Array)
        value.dup
      rescue StandardError
        [{ :reason => missing_reason }]
      end

      def self.source_span_id_for(item)
        return '' unless item.respond_to?(:source_span_id)
        item.source_span_id.to_s
      rescue StandardError
        ''
      end

      def self.source_span_evidence(item)
        {
          :source_span_id => source_span_id_for(item),
          :text => item_text(item)
        }
      end

      # Record a successful SVG-source page: accumulates telemetry and
      # attaches provenance entries for matched spans. Returns the match
      # result hash.
      def self.record_svg_page!(decision, page_num, svg_result, text_items,
                                media_box, provenance_bucket)
        return nil unless decision.is_a?(Hash)
        placements = svg_result.is_a?(Hash) ? svg_result[:placements_pdf] : nil
        match = match_spans(placements, text_items, media_box)
        decision[:pages] = decision[:pages].to_i + 1
        decision[:runs_matched] = decision[:runs_matched].to_i + match[:runs_matched].to_i
        decision[:runs_unmatched] = decision[:runs_unmatched].to_i + match[:runs_unmatched].to_i
        decision[:placements_unmatched] =
          decision[:placements_unmatched].to_i + match[:placements_unmatched].to_i
        merge_names!(decision, :missing_fonts, svg_result[:missing_fonts])
        merge_names!(decision, :missing_language_packs, svg_result[:missing_language_packs])
        record_span_provenance(provenance_bucket, page_num,
                               match[:matched_items], decision[:source])
        if match[:runs_unmatched].to_i > 0
          Logger.warn('CairoGlyphSource',
            "Page #{page_num}: #{match[:runs_unmatched]} extractor text span(s) " \
            'have no rendered glyph ink at their declared position — see ' \
            'extra.glyph_source in the import report.')
        end
        match
      rescue StandardError => e
        warn_safe("record_svg_page! failed: #{e.message}")
        nil
      end

      def self.merge_names!(decision, key, names)
        list = decision[key]
        list = decision[key] = [] unless list.is_a?(Array)
        Array(names).each do |name|
          s = name.to_s
          next if s.empty?
          list << s unless list.include?(s)
        end
        list
      rescue StandardError
        nil
      end

      # Position-match rendered glyph pen points (PDF points, media-origin
      # relative, y-up) against extractor span bboxes. Returns counts plus
      # the matched item objects (for provenance).
      def self.match_spans(placements_pdf, text_items, media_box)
        result = {
          matched_items: [], placement_matches: [],
          unmatched_source_runs: [], unmatched_placements: [],
          coverage_failures: [], source_ink_matches: [],
          runs_matched: 0, runs_unmatched: 0,
          placements_unmatched: 0
        }
        pens = Array(placements_pdf)
        base_x = media_box.is_a?(Array) && media_box.length >= 2 ?
          media_box[0].to_f : 0.0
        base_y = media_box.is_a?(Array) && media_box.length >= 2 ?
          media_box[1].to_f : 0.0
        tol = SPAN_MATCH_TOLERANCE_PT
        rows = []
        invalid_items = []

        Array(text_items).each_with_index do |item, index|
          next if item_text(item).empty?
          box = item_bbox_media_relative(item, base_x, base_y)
          if box.nil?
            invalid_items << item
            next
          end
          x0, x1 = [box[0].to_f, box[2].to_f].minmax
          y0, y1 = [box[1].to_f, box[3].to_f].minmax
          rows << {
            item: item, index: index,
            box_x0: x0, box_y0: y0, box_x1: x1, box_y1: y1,
            x0: x0 - tol, y0: y0 - tol,
            x1: x1 + tol, y1: y1 + tol,
            expected_count: visible_source_glyph_count(item),
            candidates: []
          }
        end

        pen_records = []
        pens.each_with_index do |pen, enumerated_index|
          begin
            placement_index = if pen.is_a?(Hash) && pen.key?(:placement_index)
                                pen[:placement_index].to_i
                              else
                                enumerated_index
                              end
            px = pen[:x].to_f
            py = pen[:y].to_f
            ink_bbox = source_ink_bbox(pen)
            pen_records << {
              :pen_index => enumerated_index,
              :placement_index => placement_index,
              :placement => pen, :ink_bbox => ink_bbox
            }
            rows.each do |row|
              pen_inside = px >= row[:x0] && px <= row[:x1] &&
                py >= row[:y0] && py <= row[:y1]
              ink_inside = ink_bbox.is_a?(Array) &&
                source_ink_overlap_ratio(ink_bbox, row) > 0.0
              # Overhanging and negatively offset glyphs can put their pen
              # outside the extractor span while their physical ink is fully
              # inside it. Ink-aware matching must not inherit the legacy pen
              # gate; pen-only callers retain the original behavior.
              next unless pen_inside || ink_inside
              width = [row[:x1] - row[:x0], 1.0].max
              height = [row[:y1] - row[:y0], 1.0].max
              dx = (px - ((row[:x0] + row[:x1]) * 0.5)) / width
              dy = (py - ((row[:y0] + row[:y1]) * 0.5)) / height
              row[:candidates] << {
                :pen_index => enumerated_index,
                :placement_index => placement_index,
                :ink_bbox => ink_bbox,
                :score => (dx * dx) + (dy * dy),
                :assignment => {
                  :placement_index => placement_index,
                  :source_span_id => source_span_id_for(row[:item]),
                  :item => row[:item], :placement => pen
                }
              }
            end
          rescue StandardError
            pen_records << {
              :pen_index => enumerated_index,
              :placement_index => enumerated_index,
              :placement => pen, :invalid => true
            }
          end
        end

        rows.each do |row|
          row[:candidates] = row[:candidates].sort_by do |candidate|
            [candidate[:score], candidate[:placement_index]]
          end
        end

        rows_by_index = {}
        rows.each { |row| rows_by_index[row[:index]] = row }
        accepted = {}
        pen_slot = {}
        slot_pen = {}
        source_ink_mode = pen_records.any? do |record|
          record[:ink_bbox].is_a?(Array)
        end

        if source_ink_mode
          allocate_source_ink_rows!(
            rows, pen_records, accepted, pen_slot, slot_pen, tol
          )
        else
        # Treat every visible source character as a capacity slot. An
        # augmenting-path allocation can move a shared pen from a broad bbox to
        # the narrow span that needs it. The old nearest-center greedy pass
        # could falsely prove both spans impossible even when a complete,
        # one-to-one page assignment existed.
        ordered_rows = rows.select do |row|
          row[:expected_count].to_i > 0 &&
            row[:candidates].length >= row[:expected_count].to_i
        end.sort_by do |row|
          [
            row[:candidates].length - row[:expected_count].to_i,
            row[:candidates].length, row[:index]
          ]
        end
        ordered_rows.each do |row|
          if activate_complete_span_row!(
            row, rows_by_index, pen_slot, slot_pen
          )
            accepted[row[:index]] = true
          end
        end

        # Capacity fulfillment is necessary but not sufficient: an unowned
        # pen still inside an accepted span's bbox is surplus physical ink, so
        # the association is not one-to-one. Demotion may expose the same
        # ambiguity in an overlapping peer, therefore close to a fixed point.
        loop do
          ambiguous = rows.select do |row|
            accepted[row[:index]] && row[:candidates].any? do |candidate|
              !pen_slot.key?(candidate[:pen_index])
            end
          end
          break if ambiguous.empty?
          ambiguous.each do |row|
            accepted.delete(row[:index])
            owned_slots = slot_pen.keys.select do |slot|
              slot[0] == row[:index]
            end
            owned_slots.each do |slot|
              pen_index = slot_pen.delete(slot)
              pen_slot.delete(pen_index) if pen_slot[pen_index] == slot
            end
          end
        end
        end

        rows.each do |row|
          expected_count = row[:expected_count].to_i
          if accepted[row[:index]]
            pen_indices = slot_pen.select do |slot, _pen_index|
              slot[0] == row[:index]
            end.values.sort
            assignments = pen_indices.map do |pen_index|
              candidate = row[:candidates].find do |record|
                record[:pen_index] == pen_index
              end
              candidate && candidate[:assignment]
            end.compact.sort_by { |entry| entry[:placement_index] }
            result[:runs_matched] += 1
            result[:matched_items] << row[:item]
            result[:placement_matches].concat(assignments)
            if row[:source_ink_evidence]
              result[:source_ink_matches] << row[:source_ink_evidence]
            end
          else
            result[:runs_unmatched] += 1
            result[:unmatched_source_runs] << row[:item]
            candidate_pen_indices = row[:candidates].map do |candidate|
              candidate[:pen_index]
            end.uniq
            unless candidate_pen_indices.empty?
              evidence = row[:coverage_evidence]
              unless evidence
                reason = candidate_pen_indices.length == expected_count ?
                  :source_ownership_conflict : :glyph_coverage_mismatch
                evidence = {
                :reason => reason,
                :source_span_id => source_span_id_for(row[:item]),
                :expected_glyph_count => expected_count,
                :observed_glyph_count => candidate_pen_indices.length,
                :placement_indices => row[:candidates].map do |candidate|
                  candidate[:placement_index]
                end.uniq.sort
                }
              end
              result[:coverage_failures] << evidence
              row[:coverage_evidence] = evidence
            end
          end
        end

        # Do not render a rejected span's partial ink anonymously beside its
        # item fallback. Truly unassociated placements keep their independent
        # page-scoped physical identity and remain eligible for source 3D.
        reserved = {}
        rows.reject { |row| accepted[row[:index]] }.each do |row|
          evidence = row[:coverage_evidence]
          next unless evidence
          row[:candidates].each do |candidate|
            pen_index = candidate[:pen_index]
            next if pen_slot.key?(pen_index) || reserved.key?(pen_index)
            reserved[pen_index] = evidence
          end
        end
        pen_records.each do |record|
          pen_index = record[:pen_index]
          next if pen_slot.key?(pen_index)
          result[:placements_unmatched] += 1
          evidence = reserved[pen_index]
          if evidence
            result[:unmatched_placements] << evidence.merge(
              :placement => record[:placement]
            )
          else
            result[:unmatched_placements] << record[:placement]
          end
        end
        result[:runs_unmatched] += invalid_items.length
        result[:unmatched_source_runs].concat(invalid_items)
        result[:placement_matches] = result[:placement_matches].sort_by do |entry|
          entry[:placement_index]
        end
        result
      end

      # Allocate real SVG ink by its physical overlap with extractor rows.
      # This is deliberately separate from the legacy character-capacity
      # matcher: Unicode scalar count is not a glyph count after shaping
      # (ligatures, combining marks, and contextual forms). Every physical
      # placement still has one owner, and the union of its independently
      # derived outline bounds must cover the declared source span.
      def self.allocate_source_ink_rows!(rows, pen_records, accepted,
                                         pen_slot, slot_pen, tolerance)
        owned = Hash.new { |hash, key| hash[key] = [] }
        pen_records.each do |record|
          ink_bbox = record[:ink_bbox]
          next unless ink_bbox.is_a?(Array)
          contenders = []
          rows.each do |row|
            candidate = row[:candidates].find do |entry|
              entry[:pen_index] == record[:pen_index]
            end
            next unless candidate
            overlap = source_ink_overlap_ratio(ink_bbox, row)
            next unless overlap > 0.0
            center_distance = source_ink_center_distance(ink_bbox, row)
            contenders << [row, candidate, overlap, center_distance]
          end
          next if contenders.empty?
          winner = contenders.sort_by do |entry|
            row = entry[0]
            [-entry[2], entry[3], row[:candidates].length, row[:index]]
          end.first
          owned[winner[0][:index]] << winner[1]
        end

        rows.each do |row|
          candidates = owned[row[:index]].sort_by do |candidate|
            [candidate[:placement_index], candidate[:pen_index]]
          end
          evidence = source_ink_coverage_evidence(
            row, candidates, tolerance
          )
          row[:coverage_evidence] = evidence
          next unless evidence[:source_ink_coverage_verified] == true

          accepted[row[:index]] = true
          row[:source_ink_evidence] = evidence
          candidates.each_with_index do |candidate, sequence|
            slot = [row[:index], sequence]
            pen_index = candidate[:pen_index]
            pen_slot[pen_index] = slot
            slot_pen[slot] = pen_index
          end
        end
      end

      def self.source_ink_bbox(pen)
        return nil unless pen.is_a?(Hash)
        raw = pen[:ink_bbox_pdf]
        raw = pen['ink_bbox_pdf'] unless raw.is_a?(Array)
        return nil unless raw.is_a?(Array) && raw.length >= 4
        values = raw.first(4).map { |value| value.to_f }
        return nil unless values.all? { |value| value.finite? }
        x0, x1 = [values[0], values[2]].minmax
        y0, y1 = [values[1], values[3]].minmax
        return nil if (x1 - x0) <= 1.0e-9 || (y1 - y0) <= 1.0e-9
        [x0, y0, x1, y1]
      rescue StandardError
        nil
      end

      def self.source_ink_overlap_ratio(ink_bbox, row)
        ix0 = [ink_bbox[0], row[:box_x0]].max
        iy0 = [ink_bbox[1], row[:box_y0]].max
        ix1 = [ink_bbox[2], row[:box_x1]].min
        iy1 = [ink_bbox[3], row[:box_y1]].min
        overlap_w = [ix1 - ix0, 0.0].max
        overlap_h = [iy1 - iy0, 0.0].max
        area = (ink_bbox[2] - ink_bbox[0]) *
          (ink_bbox[3] - ink_bbox[1])
        return 0.0 unless area > 0.0
        (overlap_w * overlap_h) / area
      rescue StandardError
        0.0
      end

      def self.source_ink_center_distance(ink_bbox, row)
        ink_x = (ink_bbox[0] + ink_bbox[2]) * 0.5
        ink_y = (ink_bbox[1] + ink_bbox[3]) * 0.5
        row_x = (row[:box_x0] + row[:box_x1]) * 0.5
        row_y = (row[:box_y0] + row[:box_y1]) * 0.5
        width = [row[:box_x1] - row[:box_x0], 1.0].max
        height = [row[:box_y1] - row[:box_y0], 1.0].max
        dx = (ink_x - row_x) / width
        dy = (ink_y - row_y) / height
        (dx * dx) + (dy * dy)
      rescue StandardError
        Float::INFINITY
      end

      def self.source_ink_coverage_evidence(row, candidates, tolerance)
        boxes = Array(candidates).map { |entry| entry[:ink_bbox] }.compact
        observed = boxes.length
        expected = row[:expected_count].to_i
        indices = Array(candidates).map do |entry|
          entry[:placement_index]
        end.uniq.sort
        if boxes.empty?
          return {
            :reason => :source_ownership_conflict,
            :source_span_id => source_span_id_for(row[:item]),
            :expected_glyph_count => expected,
            :observed_glyph_count => 0,
            :placement_indices => [],
            :source_ink_coverage_verified => false
          }
        end

        ink = [
          boxes.map { |box| box[0] }.min,
          boxes.map { |box| box[1] }.min,
          boxes.map { |box| box[2] }.max,
          boxes.map { |box| box[3] }.max
        ]
        width = row[:box_x1] - row[:box_x0]
        height = row[:box_y1] - row[:box_y0]
        axes = Array(candidates).map do |candidate|
          assignment = candidate[:assignment]
          placement = assignment.is_a?(Hash) ? assignment[:placement] : nil
          placement.is_a?(Hash) ? placement[:source_primary_axis] : nil
        end.compact.uniq
        horizontal = if axes.length == 1
                       axes.first.to_s == 'x'
                     else
                       width >= height
                     end
        source_min = horizontal ? row[:box_x0] : row[:box_y0]
        source_max = horizontal ? row[:box_x1] : row[:box_y1]
        ink_min = horizontal ? ink[0] : ink[1]
        ink_max = horizontal ? ink[2] : ink[3]
        cross_span = horizontal ? height : width
        edge_tolerance = [tolerance.to_f, cross_span.abs].max
        start_gap = [ink_min - source_min, 0.0].max
        end_gap = [source_max - ink_max, 0.0].max
        minimum_shaped_count = minimum_shaped_glyph_count(row[:item])
        count_plausible = observed >= minimum_shaped_count
        verified = (ink_max - ink_min) > 1.0e-9 &&
          start_gap <= edge_tolerance && end_gap <= edge_tolerance &&
          count_plausible
        {
          :reason => verified ? :source_ink_coverage_verified :
            :source_ink_coverage_incomplete,
          :source_span_id => source_span_id_for(row[:item]),
          :expected_glyph_count => expected,
          :minimum_shaped_glyph_count => minimum_shaped_count,
          :observed_glyph_count => observed,
          :placement_indices => indices,
          :source_bbox_pdf => [row[:box_x0], row[:box_y0],
                               row[:box_x1], row[:box_y1]],
          :source_ink_bbox_pdf => ink,
          :primary_axis => horizontal ? :x : :y,
          :start_edge_gap_pt => start_gap,
          :end_edge_gap_pt => end_gap,
          :edge_tolerance_pt => edge_tolerance,
          :character_count_parity => observed == expected,
          :shaped_glyph_count_verified => count_plausible,
          :source_ink_coverage_verified => verified
        }
      rescue StandardError => e
        {
          :reason => :source_ink_coverage_incomplete,
          :source_span_id => source_span_id_for(row[:item]),
          :expected_glyph_count => row[:expected_count].to_i,
          :observed_glyph_count => 0,
          :placement_indices => [],
          :source_ink_coverage_verified => false,
          :detail => e.message.to_s
        }
      end

      # Conservative lower bound for Unicode shaping. ASCII text may contract
      # only through an explicit finite set of common typographic ligatures;
      # a long unrelated string can never be certified by one partial glyph.
      # Non-ASCII text uses extended grapheme clusters when the host regex
      # engine supports them, preserving combining/ZWJ sequences without
      # equating raw Unicode scalar count to physical glyph count.
      def self.minimum_shaped_glyph_count(item)
        text = item_text(item)
        return 0 if text.empty?
        if text.respond_to?(:ascii_only?) && text.ascii_only?
          return text.split(/\s+/).inject(0) do |sum, token|
            sum + minimum_ascii_ligature_glyphs(token)
          end
        end
        clusters = begin
          # Compile at runtime so an older host regex engine that does not
          # implement extended grapheme clusters can take the conservative
          # each_char path instead of failing while this file is loaded.
          text.scan(Regexp.new('\\X'))
        rescue StandardError
          chars = []
          text.each_char { |character| chars << character }
          chars
        end
        clusters.count { |cluster| cluster !~ /\A\s+\z/u }
      rescue StandardError
        visible_source_glyph_count(item)
      end

      def self.minimum_ascii_ligature_glyphs(token)
        chars = token.to_s.downcase.each_char.to_a
        return 0 if chars.empty?
        ligatures = ['ffi', 'ffl', 'ff', 'fi', 'fl', 'st', 'ct']
        best = Array.new(chars.length + 1, chars.length + 1)
        best[0] = 0
        (0...chars.length).each do |index|
          next if best[index] > chars.length
          best[index + 1] = [best[index + 1], best[index] + 1].min
          ligatures.each do |sequence|
            length = sequence.length
            next if index + length > chars.length
            slice = chars[index, length].join
            next unless slice == sequence
            best[index + length] = [
              best[index + length], best[index] + 1
            ].min
          end
        end
        best[chars.length]
      rescue StandardError
        token.to_s.length
      end

      def self.activate_complete_span_row!(row, rows_by_index, pen_slot,
                                           slot_pen)
        owner_snapshot = pen_slot.dup
        assignment_snapshot = slot_pen.dup
        row[:expected_count].to_i.times do |slot_number|
          slot = [row[:index], slot_number]
          unless augment_span_slot!(
            slot, rows_by_index, pen_slot, slot_pen, {}
          )
            pen_slot.replace(owner_snapshot)
            slot_pen.replace(assignment_snapshot)
            return false
          end
        end
        true
      end

      def self.augment_span_slot!(slot, rows_by_index, pen_slot, slot_pen,
                                  seen_pens)
        row = rows_by_index[slot[0]]
        return false unless row
        row[:candidates].each do |candidate|
          pen_index = candidate[:pen_index]
          next if seen_pens[pen_index]
          seen_pens[pen_index] = true
          owner_slot = pen_slot[pen_index]
          if owner_slot.nil? || augment_span_slot!(
            owner_slot, rows_by_index, pen_slot, slot_pen, seen_pens
          )
            pen_slot[pen_index] = slot
            slot_pen[slot] = pen_index
            return true
          end
        end
        false
      end

      # Legacy lower bound for callers that provide only pen positions. Real
      # SVG delivery also supplies independently derived outline ink bounds,
      # where match_spans uses physical coverage plus a finite shaping bound
      # instead of incorrectly equating Unicode characters with glyphs.
      def self.visible_source_glyph_count(item)
        count = 0
        item_text(item).each_char do |character|
          count += 1 unless character =~ /\s/
        end
        count
      rescue StandardError
        0
      end

      def self.item_text(item)
        if item.respond_to?(:text)
          item.text.to_s.strip
        else
          ''
        end
      rescue StandardError
        ''
      end

      # Span bbox in the same space as SvgTextRenderer placements_pdf:
      # PDF points relative to the media-box origin, y-up. External
      # (pdftotext) items are already offset into that space; internal
      # content-stream items carry absolute user-space coordinates, so the
      # media origin is subtracted.
      def self.item_bbox_media_relative(item, base_x, base_y)
        return nil unless item.respond_to?(:bbox_x0)
        vals = [item.bbox_x0, item.bbox_y0, item.bbox_x1, item.bbox_y1]
        return nil if vals.any? { |v| v.nil? }
        x0 = vals[0].to_f
        y0 = vals[1].to_f
        x1 = vals[2].to_f
        y1 = vals[3].to_f
        return nil if (x1 - x0).abs <= 1.0e-6 || (y1 - y0).abs <= 1.0e-6
        external = false
        begin
          external = item.respond_to?(:font_name) && item.font_name.to_s == 'pdftotext'
        rescue StandardError
          external = false
        end
        unless external
          x0 -= base_x
          x1 -= base_x
          y0 -= base_y
          y1 -= base_y
        end
        [x0, y0, x1, y1]
      rescue StandardError
        nil
      end

      # R17-3: matched spans keep their deterministic source-span identity
      # in the provenance sidecar even though glyph geometry is stamped by
      # the SVG renderer rather than per-span builders.
      def self.record_span_provenance(bucket, page_num, matched_items, source)
        return unless bucket.is_a?(Array)
        Array(matched_items).each do |item|
          idx = bucket.length
          entry = {
            object_id: "text_span:#{page_num}:#{idx}",
            page: page_num.to_i,
            source_kind: 'text_span',
            created_entity_type: 'glyph_outline',
            glyph_source: source.to_s
          }
          begin
            if item.respond_to?(:source_span_id) && item.source_span_id
              entry[:span_id] = item.source_span_id
            end
          rescue StandardError
            # keep entry without span_id (never fabricate one — RB-01)
          end
          bbox = raw_item_bbox(item)
          entry[:source_bbox_pdf] = bbox if bbox
          bucket << entry
        end
        nil
      rescue StandardError => e
        warn_safe("record_span_provenance failed: #{e.message}")
        nil
      end

      def self.raw_item_bbox(item)
        return nil unless item.respond_to?(:bbox_x0)
        vals = [item.bbox_x0, item.bbox_y0, item.bbox_x1, item.bbox_y1]
        return nil if vals.any? { |v| v.nil? }
        vals.map { |v| v.to_f }
      rescue StandardError
        nil
      end

      # ------------------------------------------------------------------
      # Headless helpers (CLI report parity — no SketchUp APIs involved)
      # ------------------------------------------------------------------

      # Render one page to SVG with the preferred renderer and return
      # { :svg, :renderer, :missing_fonts, :missing_language_packs } or nil.
      # opts[:failure_info] = {} receives [:reason] on nil (same vocabulary
      # as SvgTextRenderer.render).
      def self.render_page_svg(pdf_path, page_num, opts = {})
        failure_info = opts[:failure_info].is_a?(Hash) ? opts[:failure_info] : nil
        renderer = SvgTextRenderer.find_svg_renderer
        unless renderer
          failure_info[:reason] = 'no_renderer' if failure_info
          return nil
        end
        svg_path = SvgTextRenderer.temp_svg_path
        ok = false
        stderr = ''
        attempt_number = 0
        rendered_with_cropbox = false
        SvgTextRenderer.svg_render_arg_variants(
          renderer, pdf_path, svg_path, page_num,
          opts[:use_cropbox] == true
        ).each do |args|
          attempt_number += 1
          begin
            File.delete(svg_path) if File.exist?(svg_path)
          rescue StandardError
            # best-effort cleanup
          end
          run = CommandRunner.run(args, timeout_s: 90,
                                  context: 'CairoGlyphSource.headless')
          attempt_ok = if renderer[:kind] == :pdftocairo
                         validation = PopplerResultValidator.validate(
                           run,
                           :executable => renderer[:exe],
                           :argv => args,
                           :context => 'CairoGlyphSource.headless',
                           :page => page_num,
                           :attempt => attempt_number,
                           :representation => :glyph_geometry,
                           :artifacts => [svg_path],
                           :artifact_policy => :all_nonempty
                         )
                         unless validation[:ok]
                           PopplerResultValidator.log_rejection(
                             validation, 'CairoGlyphSource'
                           )
                           failure_info[:reason] = validation[:reason].to_s if
                             failure_info
                         end
                         validation[:ok]
                       else
                         run[:ok] && File.file?(svg_path) &&
                           File.size(svg_path).to_i > 0
                       end
          if attempt_ok
            stderr = run[:stderr].to_s
            rendered_with_cropbox = SvgTextRenderer.cropbox_args?(args)
            failure_info.delete(:reason) if failure_info
            ok = true
            break
          end
          if run[:timed_out]
            failure_info[:reason] = 'timeout' if failure_info
            break
          end
        end
        unless ok
          if failure_info && failure_info[:reason].to_s.empty?
            failure_info[:reason] = 'render_failed'
          end
          return nil
        end
        svg = File.read(svg_path, encoding: 'UTF-8')
        {
          svg: svg,
          renderer: renderer[:kind],
          render_box_used: rendered_with_cropbox ? :crop_box : :media_box,
          cropbox_fallback: opts[:use_cropbox] == true &&
            !rendered_with_cropbox,
          missing_fonts: SvgTextRenderer.missing_display_fonts(stderr),
          missing_language_packs: SvgTextRenderer.missing_language_packs(stderr)
        }
      rescue StandardError => e
        warn_safe("render_page_svg failed: #{e.message}")
        failure_info[:reason] = 'exception' if failure_info && failure_info[:reason].to_s.empty?
        nil
      ensure
        begin
          File.delete(svg_path) if svg_path && File.exist?(svg_path)
        rescue StandardError
          # best-effort cleanup
        end
      end

      # Pen positions of placed glyphs (defs with actual outline data only)
      # in PDF points relative to the media-box origin, y-up — the exact
      # space match_spans expects. Pure string parsing; no SketchUp/Geom
      # dependency, so it runs in the headless CLI.
      def self.pen_placements_pdf(svg, media_box, opts = {})
        svg_page_box = opts[:svg_page_box] || media_box
        media_min_x = media_box.is_a?(Array) ? media_box[0].to_f : 0.0
        media_min_y = media_box.is_a?(Array) ? media_box[1].to_f : 0.0
        svg_min_x = svg_page_box.is_a?(Array) ? svg_page_box[0].to_f : 0.0
        svg_min_y = svg_page_box.is_a?(Array) ? svg_page_box[1].to_f : 0.0
        vb = SvgTextRenderer.parse_viewbox(svg)
        vb_min_x = vb[0].to_f
        vb_min_y = vb[1].to_f
        vb_h = vb[3].to_f
        if vb_h <= 0.0 && svg_page_box.is_a?(Array) && svg_page_box.length >= 4
          vb_h = (svg_page_box[3] - svg_page_box[1]).abs.to_f
        end
        pen_dx = svg_min_x - media_min_x
        pen_dy = svg_min_y - media_min_y

        defs = SvgTextRenderer.parse_glyph_defs(svg)
        point_factory = lambda do |x, y, z|
          NumericPoint.new(x, y, z)
        end
        glyph_paths = {}
        defs.each do |glyph_id, path_d|
          next if path_d.to_s.strip.empty?
          paths = SvgTextRenderer.svg_path_to_points(
            path_d, 1.0, 1.0, point_factory
          )
          glyph_paths[glyph_id] = paths unless paths.empty?
        end
        pens = []
        seen_physical = {}
        SvgTextRenderer.parse_use_placements(svg).each_with_index do |p, placement_index|
          local = glyph_paths[p[:glyph_id]]
          next unless local
          physical_key = exact_source_placement_key(p)
          next if seen_physical.key?(physical_key)
          seen_physical[physical_key] = placement_index
          m = p[:matrix]
          if m.is_a?(Array) && m.length >= 6
            a = m[0].to_f
            b = m[1].to_f
            c = m[2].to_f
            d = m[3].to_f
            e = m[4].to_f + p[:x].to_f
            f = m[5].to_f + p[:y].to_f
          else
            a = 1.0
            b = 0.0
            c = 0.0
            d = 1.0
            e = p[:x].to_f
            f = p[:y].to_f
          end
          tx = (e - vb_min_x) + pen_dx
          ty = (vb_h + vb_min_y - f) + pen_dy
          xs = []
          ys = []
          local.each do |points|
            points.each do |point|
              lx = point.x.to_f
              ly = point.y.to_f
              xs << (tx + (a * lx) - (c * ly))
              ys << (ty - (b * lx) + (d * ly))
            end
          end
          pens << {
            x: tx,
            y: ty,
            placement_index: placement_index,
            glyph_id: p[:glyph_id],
            source_primary_axis: source_primary_axis_for_matrix(m),
            ink_bbox_pdf: [xs.min, ys.min, xs.max, ys.max]
          }
        end
        pens
      end

      # A second identical use of the same source outline at the same affine
      # placement contributes no additional visible ink. Keep one physical
      # outline so duplicate PDF content streams cannot create coincident 3D
      # solids or masquerade as surplus glyph coverage. Nearby placements are
      # distinct; rounding is only below the renderer's numeric precision.
      def self.exact_source_placement_key(placement)
        p = placement.is_a?(Hash) ? placement : {}
        matrix = p[:matrix]
        matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0] unless
          matrix.is_a?(Array) && matrix.length >= 6
        values = matrix.first(6).map { |value| value.to_f }
        effective = values.first(4) + [
          values[4] + p[:x].to_f,
          values[5] + p[:y].to_f
        ]
        [p[:glyph_id].to_s,
         effective.map { |value| value.round(9) }]
      rescue StandardError
        [placement.object_id]
      end

      def self.source_primary_axis_for_matrix(matrix)
        values = matrix.is_a?(Array) && matrix.length >= 4 ? matrix :
          [1.0, 0.0, 0.0, 1.0]
        values[0].to_f.abs >= values[1].to_f.abs ? :x : :y
      rescue StandardError
        :x
      end

      # ------------------------------------------------------------------
      # Pure SVG -> model-space outline loops (fixture-tested; also the
      # core reused by the corpus oracle work, F-2).
      # ------------------------------------------------------------------

      # Parses a pdftocairo -svg document (glyph <defs> + <use> placements)
      # and returns GeometryBuilder-ready outline loops in model inches:
      # an array of { :glyph_id, :pen_pdf => [x_pt, y_pt], :loops =>
      # [[Geom::Point3d, ...], ...] } — one entry per placed glyph. The
      # coordinate mapping is the probe-verified production mapping
      # (SvgTextRenderer): SVG user unit == PDF point; single page-height
      # Y flip; glyph-local outlines baseline-relative with Y negated.
      def self.model_space_loops(svg, media_box, opts = {})
        scale = (opts[:scale] || 1.0).to_f
        y_offset = (opts[:y_offset] || 0.0).to_f
        svg_page_box = opts[:svg_page_box] || media_box
        media_min_x = media_box.is_a?(Array) ? media_box[0].to_f : 0.0
        media_min_y = media_box.is_a?(Array) ? media_box[1].to_f : 0.0
        svg_min_x = svg_page_box.is_a?(Array) ? svg_page_box[0].to_f : 0.0
        svg_min_y = svg_page_box.is_a?(Array) ? svg_page_box[1].to_f : 0.0
        box_offset_x_in = (svg_min_x - media_min_x) * PDF_PT_TO_INCH * scale
        box_offset_y_in = (svg_min_y - media_min_y) * PDF_PT_TO_INCH * scale

        unit = PDF_PT_TO_INCH * scale
        vb = SvgTextRenderer.parse_viewbox(svg)
        vb_min_x = vb[0].to_f
        vb_min_y = vb[1].to_f
        vb_h = vb[3].to_f
        if vb_h <= 0.0 && svg_page_box.is_a?(Array) && svg_page_box.length >= 4
          vb_h = (svg_page_box[3] - svg_page_box[1]).abs.to_f
        end

        glyph_paths = {}
        SvgTextRenderer.parse_glyph_defs(svg).each do |glyph_id, path_d|
          next if path_d.strip.empty?
          subpaths = SvgTextRenderer.svg_path_to_points(path_d, unit, unit)
          glyph_paths[glyph_id] = subpaths unless subpaths.empty?
        end

        out = []
        seen_physical = {}
        SvgTextRenderer.parse_use_placements(svg).each_with_index do |p, placement_index|
          local = glyph_paths[p[:glyph_id]]
          next unless local
          physical_key = exact_source_placement_key(p)
          next if seen_physical.key?(physical_key)
          seen_physical[physical_key] = placement_index

          m = p[:matrix]
          if m.is_a?(Array) && m.length >= 6
            a = m[0].to_f
            b = m[1].to_f
            c = m[2].to_f
            d = m[3].to_f
            e = m[4].to_f + p[:x].to_f
            f = m[5].to_f + p[:y].to_f
          else
            a = 1.0
            b = 0.0
            c = 0.0
            d = 1.0
            e = p[:x].to_f
            f = p[:y].to_f
          end

          tx = (e - vb_min_x) * unit + box_offset_x_in
          ty = (vb_h + vb_min_y - f) * unit + y_offset + box_offset_y_in

          loops = []
          local.each do |pts|
            loop_pts = []
            pts.each do |pt|
              # Local glyph points are already inch-scaled and Y-flipped
              # (svg_path_to_points). Apply the same axes SvgTextRenderer
              # uses for placement: x' = a*x - c*y, y' = -b*x + d*y.
              lx = pt.x.to_f
              ly = pt.y.to_f
              wx = tx + (a * lx) - (c * ly)
              wy = ty - (b * lx) + (d * ly)
              loop_pts << Geom::Point3d.new(wx, wy, 0.0)
            end
            loops << loop_pts if loop_pts.length >= 2
          end
          next if loops.empty?

          ink_points = loops.flatten
          ink_x = ink_points.map { |point| point.x.to_f / unit }
          ink_y = ink_points.map do |point|
            (point.y.to_f - y_offset) / unit
          end

          pen_x_pdf = (e - vb_min_x) + (svg_min_x - media_min_x)
          pen_y_pdf = (vb_h + vb_min_y - f) + (svg_min_y - media_min_y)
          out << {
            glyph_id: p[:glyph_id],
            placement_index: placement_index,
            svg_matrix: m.is_a?(Array) ? m.map { |value| value.to_f } :
              [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            source_primary_axis: source_primary_axis_for_matrix(m),
            pen_pdf: [pen_x_pdf, pen_y_pdf],
            ink_bbox_pdf: [ink_x.min, ink_y.min, ink_x.max, ink_y.max],
            loops: loops
          }
        end
        out
      end

      # Combined extent of loops from model_space_loops, in model inches:
      # [min_x, min_y, max_x, max_y] or nil.
      def self.loops_extent(placed)
        min_x = nil
        min_y = nil
        max_x = nil
        max_y = nil
        Array(placed).each do |entry|
          Array(entry.is_a?(Hash) ? entry[:loops] : entry).each do |pts|
            Array(pts).each do |pt|
              x = pt.x.to_f
              y = pt.y.to_f
              min_x = x if min_x.nil? || x < min_x
              max_x = x if max_x.nil? || x > max_x
              min_y = y if min_y.nil? || y < min_y
              max_y = y if max_y.nil? || y > max_y
            end
          end
        end
        return nil if min_x.nil?
        [min_x, min_y, max_x, max_y]
      end

      def self.warn_safe(message)
        Logger.warn('CairoGlyphSource', message)
      rescue StandardError
        # Logger may be unavailable in minimal runtime/test contexts.
      end

    end
  end
end
