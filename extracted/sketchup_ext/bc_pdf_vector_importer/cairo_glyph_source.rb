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
          coverage_failures: [], runs_matched: 0, runs_unmatched: 0,
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
            pen_records << {
              :pen_index => enumerated_index,
              :placement_index => placement_index,
              :placement => pen
            }
            rows.each do |row|
              next unless px >= row[:x0] && px <= row[:x1] &&
                          py >= row[:y0] && py <= row[:y1]
              width = [row[:x1] - row[:x0], 1.0].max
              height = [row[:y1] - row[:y0], 1.0].max
              dx = (px - ((row[:x0] + row[:x1]) * 0.5)) / width
              dy = (py - ((row[:y0] + row[:y1]) * 0.5)) / height
              row[:candidates] << {
                :pen_index => enumerated_index,
                :placement_index => placement_index,
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

        # Treat every visible source character as a capacity slot. An
        # augmenting-path allocation can move a shared pen from a broad bbox to
        # the narrow span that needs it. The old nearest-center greedy pass
        # could falsely prove both spans impossible even when a complete,
        # one-to-one page assignment existed.
        rows_by_index = {}
        rows.each { |row| rows_by_index[row[:index]] = row }
        ordered_rows = rows.select do |row|
          row[:expected_count].to_i > 0 &&
            row[:candidates].length >= row[:expected_count].to_i
        end.sort_by do |row|
          [
            row[:candidates].length - row[:expected_count].to_i,
            row[:candidates].length, row[:index]
          ]
        end
        accepted = {}
        pen_slot = {}
        slot_pen = {}
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
          else
            result[:runs_unmatched] += 1
            result[:unmatched_source_runs] << row[:item]
            candidate_pen_indices = row[:candidates].map do |candidate|
              candidate[:pen_index]
            end.uniq
            unless candidate_pen_indices.empty?
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

      # A bbox overlap proves only location. It does not prove that the
      # renderer supplied every glyph belonging to the source item. Require a
      # one-to-one physical placement for every visible source character; a
      # short or overfull match remains explicit unmatched evidence. This is
      # intentionally conservative for ligatures/combining sequences because
      # an inferred equivalence would be a false success.
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
        pens = []
        SvgTextRenderer.parse_use_placements(svg).each_with_index do |p, placement_index|
          next unless defs[p[:glyph_id]]
          m = p[:matrix]
          if m.is_a?(Array) && m.length >= 6
            e = m[4].to_f + p[:x].to_f
            f = m[5].to_f + p[:y].to_f
          else
            e = p[:x].to_f
            f = p[:y].to_f
          end
          pens << { x: (e - vb_min_x) + pen_dx, y: (vb_h + vb_min_y - f) + pen_dy }
        end
        pens
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
        SvgTextRenderer.parse_use_placements(svg).each_with_index do |p, placement_index|
          local = glyph_paths[p[:glyph_id]]
          next unless local

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

          pen_x_pdf = (e - vb_min_x) + (svg_min_x - media_min_x)
          pen_y_pdf = (vb_h + vb_min_y - f) + (svg_min_y - media_min_y)
          out << {
            glyph_id: p[:glyph_id],
            placement_index: placement_index,
            svg_matrix: m.is_a?(Array) ? m.map { |value| value.to_f } :
              [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            pen_pdf: [pen_x_pdf, pen_y_pdf],
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
