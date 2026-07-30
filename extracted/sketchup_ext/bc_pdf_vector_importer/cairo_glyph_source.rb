require 'digest/md5'

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
      SPAN_MATCH_GRID_CELL_PT = 32.0
      MAX_SPAN_GRID_CELLS = 4_096

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
          placements_unmatched: 0,
          candidate_pair_checks: 0
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

        spatial_index = build_span_spatial_index(rows)
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
            pen_record = {
              :pen_index => enumerated_index,
              :placement_index => placement_index,
              :placement => pen, :ink_bbox => ink_bbox,
              :row_candidates => []
            }
            pen_records << pen_record
            candidate_rows = span_spatial_candidate_rows(
              spatial_index, px, py, ink_bbox
            )
            result[:candidate_pair_checks] += candidate_rows.length
            candidate_rows.each do |row|
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
              candidate = {
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
              row[:candidates] << candidate
              pen_record[:row_candidates] << [row, candidate]
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

      # Exact spatial preselection for glyph/span matching. Rows are indexed by
      # their tolerance-expanded source boxes. A placement queries both its pen
      # point and physical ink box, then the existing exact predicates remain
      # authoritative. Oversized or malformed ranges deliberately fall back to
      # the full row inventory so indexing can never hide a valid association.
      def self.build_span_spatial_index(rows)
        index = {
          :cell_size => SPAN_MATCH_GRID_CELL_PT,
          :buckets => Hash.new { |hash, key| hash[key] = [] },
          :overflow_rows => [],
          :all_rows => Array(rows)
        }
        Array(rows).each do |row|
          cells = span_grid_cells_for_box(
            [row[:x0], row[:y0], row[:x1], row[:y1]],
            index[:cell_size]
          )
          if cells.nil?
            index[:overflow_rows] << row
          else
            cells.each { |cell| index[:buckets][cell] << row }
          end
        end
        index
      end

      def self.span_spatial_candidate_rows(index, px, py, ink_bbox)
        return Array(index[:all_rows]) unless index.is_a?(Hash)

        ranges = [[px, py, px, py]]
        ranges << ink_bbox if ink_bbox.is_a?(Array) && ink_bbox.length >= 4
        seen = {}
        candidates = []
        ranges.each do |box|
          cells = span_grid_cells_for_box(box, index[:cell_size])
          return Array(index[:all_rows]) if cells.nil?
          cells.each do |cell|
            Array(index[:buckets][cell]).each do |row|
              row_id = row[:index]
              next if seen[row_id]
              seen[row_id] = true
              candidates << row
            end
          end
        end
        Array(index[:overflow_rows]).each do |row|
          row_id = row[:index]
          next if seen[row_id]
          seen[row_id] = true
          candidates << row
        end
        candidates.sort_by { |row| row[:index] }
      rescue StandardError
        Array(index[:all_rows])
      end

      def self.span_grid_cells_for_box(box, cell_size)
        values = Array(box)[0, 4].map { |value| value.to_f }
        return nil unless values.length == 4
        return nil unless values.all? do |value|
          !value.respond_to?(:finite?) || value.finite?
        end
        size = cell_size.to_f
        return nil unless size > 0.0

        x0, x1 = [values[0], values[2]].minmax
        y0, y1 = [values[1], values[3]].minmax
        cell_x0 = (x0 / size).floor
        cell_x1 = (x1 / size).floor
        cell_y0 = (y0 / size).floor
        cell_y1 = (y1 / size).floor
        width = cell_x1 - cell_x0 + 1
        height = cell_y1 - cell_y0 + 1
        return nil if width <= 0 || height <= 0
        return nil if width * height > MAX_SPAN_GRID_CELLS

        cells = []
        (cell_x0..cell_x1).each do |cell_x|
          (cell_y0..cell_y1).each do |cell_y|
            cells << [cell_x, cell_y]
          end
        end
        cells
      rescue StandardError
        nil
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
          row_candidates = record[:row_candidates]
          row_candidates = rows.map do |row|
            candidate = row[:candidates].find do |entry|
              entry[:pen_index] == record[:pen_index]
            end
            candidate ? [row, candidate] : nil
          end.compact unless row_candidates.is_a?(Array)
          row_candidates.each do |pair|
            row, candidate = pair
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
        axis = source_run_axis(row, candidates)
        perpendicular = [-axis[1], axis[0]]
        source_points = bbox_corners([
          row[:box_x0], row[:box_y0], row[:box_x1], row[:box_y1]
        ])
        ink_points = source_ink_projection_points(candidates)
        source_min, source_max = projected_extent(source_points, axis)
        ink_min, ink_max = projected_extent(ink_points, axis)
        cross_min, cross_max = projected_extent(source_points, perpendicular)
        cross_span = cross_max - cross_min
        edge_tolerance = source_edge_tolerance(
          row[:item], tolerance, cross_span, axis
        )
        start_gap = [ink_min - source_min, 0.0].max
        end_gap = [source_max - ink_max, 0.0].max
        minimum_shaped_count = minimum_shaped_glyph_count(row[:item])
        count_plausible = observed >= minimum_shaped_count
        # Unicode scalar/grapheme count is not an authoritative lower bound on
        # a font shaper's physical glyph count (contextual forms and arbitrary
        # font ligatures may contract multiple clusters into one outline).
        # Keep the estimate as telemetry only. Independent raw-SVG binding and
        # physical ink coverage are the acceptance authorities.
        verified = (ink_max - ink_min) > 1.0e-9 &&
          start_gap <= edge_tolerance && end_gap <= edge_tolerance
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
          :primary_axis => axis[0].abs >= axis[1].abs ? :x : :y,
          :baseline_axis_pdf => axis,
          :start_edge_gap_pt => start_gap,
          :end_edge_gap_pt => end_gap,
          :edge_tolerance_pt => edge_tolerance,
          :character_count_parity => observed == expected,
          :shaped_glyph_count_verified => count_plausible,
          :shaped_glyph_count_telemetry_only => true,
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

      def self.source_run_axis(row, candidates)
        pens = Array(candidates).map do |candidate|
          assignment = candidate[:assignment]
          placement = assignment.is_a?(Hash) ? assignment[:placement] : nil
          next unless placement.is_a?(Hash)
          x = placement[:x].to_f
          y = placement[:y].to_f
          next unless x.finite? && y.finite?
          [x, y]
        end.compact.uniq
        if pens.length >= 2
          mean_x = pens.inject(0.0) { |sum, point| sum + point[0] } / pens.length
          mean_y = pens.inject(0.0) { |sum, point| sum + point[1] } / pens.length
          xx = 0.0
          yy = 0.0
          xy = 0.0
          pens.each do |point|
            dx = point[0] - mean_x
            dy = point[1] - mean_y
            xx += dx * dx
            yy += dy * dy
            xy += dx * dy
          end
          if (xx + yy) > 1.0e-12
            angle = 0.5 * Math.atan2(2.0 * xy, xx - yy)
            return [Math.cos(angle), Math.sin(angle)]
          end
        end

        angle = source_item_angle_degrees(row[:item])
        if angle
          radians = angle * Math::PI / 180.0
          return [Math.cos(radians), Math.sin(radians)]
        end
        axes = Array(candidates).map do |candidate|
          assignment = candidate[:assignment]
          placement = assignment.is_a?(Hash) ? assignment[:placement] : nil
          placement.is_a?(Hash) ? placement[:source_primary_axis] : nil
        end.compact.uniq
        return [0.0, 1.0] if axes.length == 1 && axes.first.to_s == 'y'
        width = row[:box_x1] - row[:box_x0]
        height = row[:box_y1] - row[:box_y0]
        width >= height ? [1.0, 0.0] : [0.0, 1.0]
      end

      def self.source_item_angle_degrees(item)
        value = if item.respond_to?(:angle)
                  item.angle
                elsif item.is_a?(Hash)
                  item[:angle] || item['angle']
                end
        return nil if value.nil?
        number = value.to_f
        number.finite? ? number : nil
      rescue StandardError
        nil
      end

      def self.source_ink_projection_points(candidates)
        points = []
        Array(candidates).each do |candidate|
          assignment = candidate[:assignment]
          placement = assignment.is_a?(Hash) ? assignment[:placement] : nil
          raw = placement.is_a?(Hash) ? placement[:ink_points_pdf] : nil
          valid = Array(raw).map do |point|
            values = Array(point).first(2).map { |value| value.to_f }
            values if values.length == 2 && values.all?(&:finite?)
          end.compact
          if valid.empty?
            valid = bbox_corners(candidate[:ink_bbox])
          end
          points.concat(valid)
        end
        raise 'source ink has no finite projection points' if points.empty?
        points
      end

      def self.bbox_corners(box)
        values = Array(box).first(4).map { |value| value.to_f }
        return [] unless values.length == 4 && values.all?(&:finite?)
        x0, x1 = [values[0], values[2]].minmax
        y0, y1 = [values[1], values[3]].minmax
        [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]
      end

      def self.projected_extent(points, axis)
        values = Array(points).map do |point|
          (point[0].to_f * axis[0]) + (point[1].to_f * axis[1])
        end
        raise 'projection extent is unavailable' if values.empty?
        [values.min, values.max]
      end

      def self.source_edge_tolerance(item, tolerance, cross_span, axis = nil)
        font_size = if item.respond_to?(:font_size)
                      item.font_size.to_f
                    elsif item.is_a?(Hash)
                      (item[:font_size] || item['font_size']).to_f
                    else
                      0.0
                    end
        typographic = if font_size.finite? && font_size > 0.0
                        font_size * 2.0
                      else
                        components = Array(axis).first(2).map do |value|
                          value.to_f.abs
                        end
                        cardinal = components.length == 2 &&
                          components.min <= 1.0e-6 &&
                          (components.max - 1.0).abs <= 1.0e-6
                        cardinal ? cross_span.to_f.abs :
                          [cross_span.to_f.abs, 12.0].min
                      end
        [tolerance.to_f, typographic].max
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

      # Exact semantic content is part of the source-item identity and must
      # never pass through a matching-key normalization. In particular, an
      # all-space span still exists even when the renderer later proves that
      # its exact source glyphs own no painted ink.
      def self.item_text(item)
        if item.respond_to?(:text)
          item.text.to_s
        else
          ''
        end
      rescue StandardError
        ''
      end

      # Heuristics may use a separately named key, but it must never be stored
      # as delivered content, source evidence, or zero-ink authority.
      def self.item_matching_text(item)
        item_text(item).strip
      rescue StandardError
        ''
      end

      # Some extractors expose the source span bbox as [x0, y0, x1, y1]
      # through a single method, while others expose four separate accessors.
      def self.bbox_values_from_item(item)
        return nil unless item
        names = [:bbox_x0, :bbox_y0, :bbox_x1, :bbox_y1]
        if names.all? { |name| item.respond_to?(name) }
          return names.map { |name| item.send(name) }
        end
        if item.respond_to?(:bbox)
          bbox = item.bbox
          return bbox if bbox.is_a?(Array) && bbox.length == 4
        end
        nil
      rescue StandardError
        nil
      end

      # Span bbox in the same space as SvgTextRenderer placements_pdf:
      # PDF points relative to the media-box origin, y-up. External
      # (pdftotext) items are already offset into that space; internal
      # content-stream items carry absolute user-space coordinates, so the
      # media origin is subtracted.
      def self.item_bbox_media_relative(item, base_x, base_y)
        vals = bbox_values_from_item(item)
        return nil unless vals
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
        vals = bbox_values_from_item(item)
        return nil unless vals
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
        canonical_unit = PDF_PT_TO_INCH
        glyph_paths = {}
        defs.each do |glyph_id, path_d|
          next if path_d.to_s.strip.empty?
          paths = SvgTextRenderer.svg_path_to_points(
            path_d, canonical_unit, canonical_unit, point_factory
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
          ink_loops = local.map do |points|
            points.map do |point|
              # Curves are flattened once at the canonical 1x physical unit.
              # Convert those canonical inch coordinates back to SVG units
              # before applying the raw-SVG affine matrix.
              lx = point.x.to_f / canonical_unit
              ly = point.y.to_f / canonical_unit
              [
                tx + (a * lx) - (c * ly),
                ty - (b * lx) + (d * ly)
              ]
            end
          end
          ink_points = ink_loops.flatten(1)
          xs = ink_points.map { |point| point[0] }
          ys = ink_points.map { |point| point[1] }
          pens << {
            x: tx,
            y: ty,
            placement_index: placement_index,
            glyph_id: p[:glyph_id],
            fill_rgb: p[:fill_rgb] && p[:fill_rgb].dup,
            fill_opacity: p[:fill_opacity],
            source_primary_axis: source_primary_axis_for_matrix(m),
            ink_points_pdf: ink_points,
            ink_loops_pdf: ink_loops,
            ink_bbox_pdf: [xs.min, ys.min, xs.max, ys.max]
          }
        end
        pens
      end

      # A second identical use of the same source outline at the same affine
      # placement contributes no additional visible ink. Keep one physical
      # outline so duplicate PDF content streams cannot create coincident 3D
      # solids or masquerade as surplus glyph coverage. Nearby placements are
      # distinct. Float hash/equality preserves the parsed numeric value; do
      # not round a nearby physical placement into an apparent duplicate.
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
        [
          p[:glyph_id].to_s,
          effective,
          SvgTextRenderer.svg_paint_signature(p)
        ]
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
        svg_page_box = opts[:svg_page_box] || media_box
        scale = (opts[:scale] || 1.0).to_f
        y_offset = (opts[:y_offset] || 0.0).to_f
        cache_enabled = opts[:cache_model_space_loops] != false
        cache_key = nil
        if cache_enabled
          cache_key = [
            svg.respond_to?(:length) ? Digest::MD5.hexdigest(svg) : svg.object_id,
            scale, y_offset, svg_page_box, media_box
          ]
          @model_space_loops_cache ||= {}
          cached = @model_space_loops_cache[cache_key]
          return copy_model_space_loop_value(cached) if cached
        end

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
          # Keep the physical source contour inventory independent of import
          # scale. Scale the already-flattened canonical points below; never
          # let curve subdivision change merely because the user chose a
          # different output size.
          subpaths = SvgTextRenderer.svg_path_to_points(
            path_d, PDF_PT_TO_INCH, PDF_PT_TO_INCH
          )
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
          cache_local_loops = []
          local.each do |pts|
            loop_pts = []
            cache_loop_pts = []
            pts.each do |pt|
              # Local glyph points are already inch-scaled and Y-flipped
              # (svg_path_to_points). Apply the same axes SvgTextRenderer
              # uses for placement: x' = a*x - c*y, y' = -b*x + d*y.
              lx = pt.x.to_f * scale
              ly = pt.y.to_f * scale
              local_x = (a * lx) - (c * ly)
              local_y = -(b * lx) + (d * ly)
              wx = tx + local_x
              wy = ty + local_y
              cache_loop_pts << Geom::Point3d.new(local_x, local_y, 0.0)
              loop_pts << Geom::Point3d.new(wx, wy, 0.0)
            end
            if loop_pts.length >= 2
              loops << loop_pts
              cache_local_loops << cache_loop_pts
            end
          end
          next if loops.empty?

          ink_points = loops.flatten
          ink_x = ink_points.map { |point| point.x.to_f / unit }
          ink_y = ink_points.map do |point|
            (point.y.to_f - y_offset) / unit
          end
          ink_loops_pdf = loops.map do |loop_points|
            loop_points.map do |point|
              [
                point.x.to_f / unit,
                (point.y.to_f - y_offset) / unit
              ]
            end
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
            ink_points_pdf: ink_loops_pdf.flatten(1),
            ink_loops_pdf: ink_loops_pdf,
            ink_bbox_pdf: [ink_x.min, ink_y.min, ink_x.max, ink_y.max],
            fill_rgb: p[:fill_rgb] && p[:fill_rgb].dup,
            fill_opacity: p[:fill_opacity],
            cache_local_loops: cache_local_loops,
            cache_origin: [tx, ty, 0.0],
            loops: loops
          }
        end
        if cache_enabled
          @model_space_loops_cache[cache_key] = out
          copy_model_space_loop_value(out)
        else
          out
        end
      end

      # Cached outline entries are canonical source evidence. Renderers hand
      # their points to host geometry APIs, which are allowed to retain or
      # mutate those point objects. Never expose the cache's canonical object
      # graph to a caller.
      def self.copy_model_space_loop_value(value)
        if defined?(Geom::Point3d) && value.is_a?(Geom::Point3d)
          return Geom::Point3d.new(value.x.to_f, value.y.to_f, value.z.to_f)
        end
        case value
        when Array
          value.map { |item| copy_model_space_loop_value(item) }
        when Hash
          copy = {}
          value.each do |key, item|
            copy[key] = copy_model_space_loop_value(item)
          end
          copy
        when String
          value.dup
        else
          value
        end
      end

      # Bind model-space physical loops back to an independent raw-SVG parse.
      # A sidecar pen/bbox cannot certify geometry: each placement index, glyph,
      # pen, and ink extent must agree with both the raw SVG and the actual loops.
      def self.verify_model_loop_bindings(svg, media_box, placed, opts = {})
        raw = pen_placements_pdf(svg, media_box, opts)
        failures = []
        raw_by_index = unique_placement_index_map(raw, :raw_svg, failures)
        model_by_index = unique_placement_index_map(
          Array(placed), :model_loops, failures
        )
        raw_indices = raw_by_index.keys.sort
        model_indices = model_by_index.keys.sort
        unless raw_indices == model_indices
          failures << {
            :reason => :placement_index_inventory_mismatch,
            :raw_indices => raw_indices,
            :model_indices => model_indices
          }
        end

        scale = (opts[:scale] || 1.0).to_f
        unit = PDF_PT_TO_INCH * scale
        y_offset = (opts[:y_offset] || 0.0).to_f
        unless unit.finite? && unit != 0.0 && y_offset.finite?
          failures << { :reason => :invalid_model_loop_coordinate_scale }
        end

        (raw_indices & model_indices).each do |placement_index|
          source = raw_by_index[placement_index]
          model = model_by_index[placement_index]
          if source[:glyph_id].to_s != model[:glyph_id].to_s
            failures << {
              :reason => :glyph_identity_mismatch,
              :placement_index => placement_index,
              :raw_glyph_id => source[:glyph_id].to_s,
              :model_glyph_id => model[:glyph_id].to_s
            }
            next
          end
          inspection = inspect_model_loop_binding(
            source[:ink_loops_pdf], model, unit, y_offset
          )
          actual_bbox = inspection[:bbox]
          compare_loop_binding_values(
            failures, placement_index, :pen,
            [source[:x], source[:y]], model[:pen_pdf]
          )
          compare_loop_binding_values(
            failures, placement_index, :raw_svg_ink_bbox,
            source[:ink_bbox_pdf], actual_bbox
          )
          compare_loop_binding_values(
            failures, placement_index, :reported_model_ink_bbox,
            model[:ink_bbox_pdf], actual_bbox
          )
          unless inspection[:contours_valid]
            failures << {
              :reason => :physical_loop_contour_mismatch,
              :placement_index => placement_index,
              :field => :source_contours,
              :expected_loop_lengths => inspection[:expected_loop_lengths],
              :actual_loop_lengths => inspection[:actual_loop_lengths]
            }
          end
        end if unit.finite? && unit != 0.0

        {
          :ok => failures.empty?,
          :raw_placement_count => raw.length,
          :model_placement_count => Array(placed).length,
          :failures => failures
        }
      rescue StandardError => e
        {
          :ok => false,
          :raw_placement_count => 0,
          :model_placement_count => Array(placed).length,
          :failures => [{
            :reason => :source_loop_binding_exception,
            :error_class => e.class.to_s,
            :detail => e.message.to_s
          }]
        }
      end

      def self.unique_placement_index_map(entries, source, failures)
        mapped = {}
        Array(entries).each do |entry|
          index = entry[:placement_index].to_i
          if mapped.key?(index)
            failures << {
              :reason => :duplicate_placement_index,
              :source => source, :placement_index => index
            }
          else
            mapped[index] = entry
          end
        end
        mapped
      end

      def self.inspect_model_loop_binding(expected, entry, unit, y_offset)
        expected_loops = Array(expected)
        actual_loops = Array(entry[:loops])
        valid = !expected_loops.empty? &&
          expected_loops.length == actual_loops.length
        min_x = nil
        min_y = nil
        max_x = nil
        max_y = nil
        actual_loops.each_with_index do |actual_points, loop_index|
          model_points = Array(actual_points)
          expected_points = Array(expected_loops[loop_index])
          valid = false if model_points.empty? ||
                           model_points.length != expected_points.length
          model_points.each_with_index do |point, point_index|
            x = point.x.to_f / unit
            y = (point.y.to_f - y_offset) / unit
            unless x.finite? && y.finite?
              valid = false
              next
            end
            min_x = x if min_x.nil? || x < min_x
            max_x = x if max_x.nil? || x > max_x
            min_y = y if min_y.nil? || y < min_y
            max_y = y if max_y.nil? || y > max_y
            expected_pair = Array(expected_points[point_index])
            if expected_pair.length < 2
              valid = false
              next
            end
            expected_x = expected_pair[0].to_f
            expected_y = expected_pair[1].to_f
            valid = false unless expected_x.finite? && expected_y.finite? &&
                                 (expected_x - x).abs <= 1.0e-7 &&
                                 (expected_y - y).abs <= 1.0e-7
          end
        end
        raise 'model placement has no physical loop points' if min_x.nil?
        {
          :bbox => [min_x, min_y, max_x, max_y],
          :contours_valid => valid,
          :expected_loop_lengths => expected_loops.map { |loop_points| Array(loop_points).length },
          :actual_loop_lengths => actual_loops.map { |loop_points| Array(loop_points).length }
        }
      end

      def self.compare_loop_binding_values(failures, placement_index, field,
                                           expected, actual)
        expected_values = Array(expected).map { |value| value.to_f }
        actual_values = Array(actual).map { |value| value.to_f }
        valid = expected_values.length == actual_values.length &&
          !expected_values.empty? &&
          expected_values.all?(&:finite?) && actual_values.all?(&:finite?) &&
          expected_values.each_with_index.all? do |value, index|
            (value - actual_values[index]).abs <= 1.0e-7
          end
        return if valid
        failures << {
          :reason => :physical_loop_value_mismatch,
          :placement_index => placement_index,
          :field => field,
          :expected => expected_values,
          :actual => actual_values
        }
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
