# bc_pdf_vector_importer/text_parser.rb
# Extracts text content and positioning from PDF content streams.
# Handles BT/ET text blocks, Tm/Td positioning, Tj/TJ string operators,
# and font size tracking. Reconstructs stacked fractions to inline.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    class TextParser

      TextItem = Struct.new(
        :text,        # String content
        :x,           # X position in PDF user space
        :y,           # Y position in PDF user space
        :font_size,   # Effective font size (matrix-scaled, for text processing)
        :angle,       # Rotation angle in degrees
        :font_name,   # Font name (if available)
        :raw_font_size # Raw font size from Tf operator (for geometry rendering)
      )

      # Common structural drawing fraction denominators
      VALID_DENOMS = [2, 4, 8, 16, 32, 64].freeze

      def initialize(streams, font_maps = nil, opts = {})
        @streams = streams
        @text_items = []
        @font_maps = {}
        # Strict mode keeps raw text spans as close to source as possible.
        # Default remains false to preserve legacy behavior.
        @strict_text_fidelity = !!opts[:strict_text_fidelity]

        (font_maps || {}).each do |k, v|
          key = k.to_s
          @font_maps[key] = v
          @font_maps[key.sub(/\A\//, '')] = v
        end
      end

      def parse
        @text_items = []

        @streams.each do |stream|
          next unless stream && !stream.empty?
          extract_text_from_stream(stream)
        end

        # Post-process text items.
        if @strict_text_fidelity
          # Keep exact extracted spans; only remove exact duplicates.
          @text_items = dedupe_text_items(@text_items)
        else
          # Reconstruct stacked fractions before run-merge so slash forms survive.
          @text_items = reconstruct_fractions(@text_items)
          @text_items = merge_text_runs(@text_items)
          @text_items = fix_merged_fractions(@text_items)
          @text_items = dedupe_text_items(@text_items)
          @text_items = quality_filter(@text_items)
          @text_items = suppress_overlaps(@text_items)
        end
        @text_items
      end

      private

      def extract_text_from_stream(stream)
        # Text state
        tm = [1, 0, 0, 1, 0, 0]   # Text matrix
        tlm = [1, 0, 0, 1, 0, 0]  # Text line matrix
        font_size = 12.0
        font_name = ""
        in_text = false

        tokens = tokenize(stream)
        operand_stack = []

        tokens.each do |token|
          if token[:type] == :operator
            op = token[:value]
            nums = operand_stack.select { |t| t[:type] == :number }.map { |t| t[:value] }
            strs = operand_stack.select { |t| t[:type] == :string }.map { |t| t[:value] }
            hexs = operand_stack.select { |t| t[:type] == :hex_string }.map { |t| t[:value] }
            names = operand_stack.select { |t| t[:type] == :name }.map { |t| t[:value] }

            case op
            when 'BT'
              in_text = true
              tm = [1, 0, 0, 1, 0, 0]
              tlm = [1, 0, 0, 1, 0, 0]

            when 'ET'
              in_text = false

            when 'Tf'
              # Set font and size
              font_size = nums.last.to_f if nums.last
              font_name = names.last.to_s if names.last

            when 'Tm'
              # Set text matrix directly
              if nums.length >= 6
                tm = nums[0, 6].map(&:to_f)
                tlm = tm.dup
              end

            when 'Td'
              # Move text position
              if nums.length >= 2 && in_text
                tx, ty = nums[0].to_f, nums[1].to_f
                # PDF text translation is pre-multiplied: Tlm = T(tx,ty) * Tlm
                tlm = multiply_matrix([1, 0, 0, 1, tx, ty], tlm)
                tm = tlm.dup
              end

            when 'TD'
              # Move text position and set leading
              if nums.length >= 2 && in_text
                tx, ty = nums[0].to_f, nums[1].to_f
                # PDF text translation is pre-multiplied: Tlm = T(tx,ty) * Tlm
                tlm = multiply_matrix([1, 0, 0, 1, tx, ty], tlm)
                tm = tlm.dup
              end

            when 'T*'
              # Move to start of next line (uses leading)
              if in_text
                # Same pre-multiply rule as Td/TD
                tlm = multiply_matrix([1, 0, 0, 1, 0, -font_size * 1.2], tlm)
                tm = tlm.dup
              end

            when 'Tj'
              # Show text string
              if in_text
                raw = strs.last || hexs.last
                text = decode_text_operand(raw, font_name)
                emit_text(text, tm, font_size, font_name) if readable_text?(text)
              end

            when 'TJ'
              # Show text with individual glyph positioning (array)
              if in_text
                arr_token = operand_stack.find { |t| t[:type] == :array }
                if arr_token
                  text = extract_tj_text(arr_token[:value], font_name)
                  emit_text(text, tm, font_size, font_name) if readable_text?(text)
                end
              end

            when "'"
              # Move to next line and show text
              if in_text
                tlm = multiply_matrix([1, 0, 0, 1, 0, -font_size * 1.2], tlm)
                tm = tlm.dup
                if !strs.empty?
                  text = decode_text_operand(strs.first, font_name)
                  emit_text(text, tm, font_size, font_name) if readable_text?(text)
                end
              end

            when '"'
              # Set word/char spacing, move to next line, show text
              if in_text
                tlm = multiply_matrix([1, 0, 0, 1, 0, -font_size * 1.2], tlm)
                tm = tlm.dup
                if !strs.empty?
                  text = decode_text_operand(strs.first, font_name)
                  emit_text(text, tm, font_size, font_name) if readable_text?(text)
                end
              end
            end

            operand_stack.clear
          else
            operand_stack << token
          end
        end
      end

      def emit_text(text, tm, font_size, font_name)
        # Extract position and rotation from text matrix
        x = tm[4]
        y = tm[5]
        # Font size is scaled by the text matrix (for text processing/dedup)
        effective_size = font_size * Math.sqrt(tm[0]**2 + tm[1]**2)
        effective_size = font_size if effective_size.abs < 0.001
        # Rotation angle
        angle = -Math.atan2(tm[1], tm[0]) * 180.0 / Math::PI

        @text_items << TextItem.new(text, x, y, effective_size, angle, font_name, font_size)
      end

      def decode_text_operand(raw, font_name = nil)
        return "" unless raw
        s = raw.to_s

        bytes = if s.start_with?('<') && s.end_with?('>')
                  decode_pdf_hex_bytes(s)
                else
                  decode_pdf_string_bytes(s)
                end

        mapped = decode_bytes_with_font_map(bytes, font_name)
        text = if mapped && !mapped.empty?
                 mapped
               else
                 # Fallback for simple PDFs without ToUnicode.
                 bytes.encode(Encoding::UTF_8, Encoding::BINARY,
                              invalid: :replace, undef: :replace, replace: '')
               end
        clean_text(text)
      end

      def decode_bytes_with_font_map(bytes, font_name)
        return nil unless font_name && bytes && !bytes.empty?

        fmap = @font_maps[font_name.to_s] || @font_maps[font_name.to_s.sub(/\A\//, '')]
        return nil unless fmap.is_a?(Hash) && fmap[:map].is_a?(Hash) && !fmap[:map].empty?

        code_lengths = (fmap[:code_lengths] || [1]).map(&:to_i).select { |n| n > 0 }.uniq.sort.reverse
        code_lengths = [1] if code_lengths.empty?
        map = fmap[:map]

        out = ""
        i = 0
        while i < bytes.bytesize
          hit = nil
          code_lengths.each do |len|
            next if i + len > bytes.bytesize
            key = bytes.byteslice(i, len)
            if map.key?(key)
              hit = map[key]
              i += len
              break
            end
          end

          if hit
            out << hit
          else
            # Unknown codepoint: keep printable ASCII only as conservative fallback.
            b = bytes.getbyte(i)
            out << b.chr if b && b >= 32 && b <= 126
            i += 1
          end
        end
        out
      rescue StandardError => e
        Logger.warn("TextParser", "decode_tounicode failed: #{e.message}")
        nil
      end

      def clean_text(text)
        return "" unless text
        t = text.to_s.encode(Encoding::UTF_8, Encoding::BINARY, invalid: :replace, undef: :replace, replace: '')
        t = t.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, '')
        t = t.gsub(/[[:space:]]+/, ' ').strip
        t
      end

      def readable_text?(text)
        t = clean_text(text)
        return false if t.empty?
        return false if t.length > 200

        compact = t.gsub(/\s+/, '')
        return false if compact.empty?
        return false if compact =~ /\d{10,}/
        return false if compact =~ /\A[.\-*\/]+\z/
        return false if compact.include?('.-') || compact.include?('-.') || compact.include?('//')

        letters = compact.count('A-Za-z').to_f
        total = compact.length.to_f
        letter_ratio = total > 0 ? letters / total : 0.0

        # Normal words / part marks / callouts.
        return true if letter_ratio >= 0.15
        return true if compact =~ /\A[A-Za-z0-9][A-Za-z0-9_\-:\/\.]{0,31}\z/

        # Dimension-like numeric text.
        return true if compact =~ /\A\d+(?:\/\d+|(?:\.\d+)?(?:["']|mm|cm|in|ft)?)\z/i
        return true if compact =~ /\A\d+[-xX]\d+(?:\/\d+)?\z/

        false
      end

      def quality_filter(items)
        return items if items.empty?

        meaningful = items.count do |it|
          txt = it.text.to_s.gsub(/\s+/, '')
          txt =~ /[A-Za-z]/ ||
            txt =~ /\A\d+(?:\/\d+|(?:\.\d+)?(?:["']|mm|cm|in|ft)?)\z/i ||
            txt =~ /\A\d+[-xX]\d+(?:\/\d+)?\z/
        end

        low_info = items.count do |it|
          txt = it.text.to_s.gsub(/\s+/, '')
          txt.length <= 1 || txt =~ /\A[.\-*\/]+\z/
        end

        # If a page is mostly low-information tokens, suppress text on that page.
        if items.length >= 80 && meaningful < 10 && (low_info.to_f / items.length) > 0.70
          return []
        end

        # In dense CAD sheets, tiny one-character tokens create unreadable clutter.
        # Keep larger callouts and multi-char dimensions while dropping micro-noise.
        one_char_small = items.select do |it|
          txt = it.text.to_s.gsub(/\s+/, '')
          txt.length <= 1 && it.font_size.to_f <= 12.5
        end
        if items.length >= 200 && (one_char_small.length.to_f / items.length) > 0.40
          filtered = items.reject do |it|
            txt = it.text.to_s.gsub(/\s+/, '')
            txt.length <= 1 && it.font_size.to_f <= 12.5
          end
          return filtered unless filtered.empty?
        end

        items
      end

      # Remove text items whose bounding boxes overlap a larger/more informative
      # neighbour. Also cleans fraction residue and thins overcrowded areas.
      def suppress_overlaps(items)
        return items if items.length < 2

        # Build approximate bounding boxes: [x0, y0, x1, y1]
        bboxes = items.map do |it|
          w = estimate_text_width(it.text, it.font_size)
          h = it.font_size.to_f * 1.2
          x0 = it.x.to_f
          y0 = it.y.to_f - h * 0.2
          [x0, y0, x0 + w, y0 + h]
        end

        drop = Array.new(items.length, false)

        # ── Pass 1: Fraction residue cleanup ──
        # Drop stacked numerator/denominator digits that survived reconstruction.
        # CRITICAL: only drop digits that are VERTICALLY offset from the fraction
        # (actual stacked residue). Digits to the LEFT are whole-number parts
        # of the dimension (e.g., "3" in "3 15/16") and must be kept.
        items.each_with_index do |frac_item, fi|
          next if drop[fi]
          next unless frac_item.text =~ /\d+\/\d+/
          fb = bboxes[fi]
          frac_cx = (fb[0] + fb[2]) / 2.0
          frac_cy = (fb[1] + fb[3]) / 2.0
          frac_h = fb[3] - fb[1]

          items.each_with_index do |digit, di|
            next if di == fi || drop[di]
            next unless digit.text =~ /\A\d{1,2}\z/
            dcx = (bboxes[di][0] + bboxes[di][2]) / 2.0
            dcy = (bboxes[di][1] + bboxes[di][3]) / 2.0

            # Only drop if vertically offset (above or below the fraction)
            # NOT if horizontally adjacent (that's a whole number like "3" in "3 15/16")
            dy = (dcy - frac_cy).abs
            dx = (dcx - frac_cx).abs

            # Must be vertically stacked: significant Y offset, small X offset
            is_stacked = dy > frac_h * 0.3 && dx < frac_item.font_size.to_f * 1.5

            if is_stacked
              # Verify the digit matches the fraction's numerator or denominator
              d_val = digit.text.to_i
              frac_parts = frac_item.text.scan(/(\d+)\/(\d+)/).flatten.map(&:to_i)
              if frac_parts.include?(d_val)
                drop[di] = true
              end
            end
          end
        end

        # ── Pass 2: Drop lone single-char digits truly overlapping multi-char items ──
        # Very conservative: tight bbox overlap only, and never drop digits
        # that could be whole-number parts of dimensions
        items.each_with_index do |multi, mi|
          next if drop[mi]
          mt = multi.text.to_s.gsub(/\s/, '')
          next if mt.length < 3
          next if mt =~ /\d+\/\d+/  # don't eat digits near fractions
          mb = bboxes[mi]
          pad = multi.font_size.to_f * 0.3  # very tight — truly on top

          items.each_with_index do |single, si|
            next if si == mi || drop[si]
            txt = single.text.to_s.gsub(/\s/, '')
            next unless txt.length == 1 && txt =~ /\d/

            # Never drop a digit if there's any fraction item nearby —
            # it's likely "3" in "3 15/16" or "2" in "R 2 1/2"
            has_nearby_frac = false
            items.each_with_index do |other, oi|
              next if oi == si || drop[oi]
              if other.text =~ /\d+\/\d+/
                odist = Math.sqrt((other.x.to_f - single.x.to_f)**2 +
                                  (other.y.to_f - single.y.to_f)**2)
                if odist < single.font_size.to_f * 5
                  has_nearby_frac = true
                  break
                end
              end
            end
            next if has_nearby_frac

            scx = (bboxes[si][0] + bboxes[si][2]) / 2.0
            scy = (bboxes[si][1] + bboxes[si][3]) / 2.0
            if scx >= mb[0] - pad && scx <= mb[2] + pad &&
               scy >= mb[1] - pad && scy <= mb[3] + pad
              drop[si] = true
            end
          end
        end

        # ── Pass 3: General overlap — keep the more informative item ──
        # Uses a spatial grid for O(n) average performance instead of O(n^2).
        # But never drop a digit adjacent to a fraction.
        overlap_cell = 30.0  # grid cell size in PDF points
        grid = {}
        items.each_with_index do |_item, idx|
          next if drop[idx]
          bb = bboxes[idx]
          cx0 = (bb[0] / overlap_cell).floor
          cy0 = (bb[1] / overlap_cell).floor
          cx1 = (bb[2] / overlap_cell).floor
          cy1 = (bb[3] / overlap_cell).floor
          (cx0..cx1).each do |cx|
            (cy0..cy1).each do |cy|
              key = (cx << 16) | (cy & 0xFFFF)
              (grid[key] ||= []) << idx
            end
          end
        end

        checked = {}
        grid.each_value do |cell_indices|
          cell_indices.each do |i|
            next if drop[i]
            ab = bboxes[i]
            a = items[i]

            cell_indices.each do |j|
              next if j <= i || drop[j]
              pair = (i << 20) | j
              next if checked[pair]
              checked[pair] = true

              bb = bboxes[j]
              b = items[j]

              next if ab[2] < bb[0] || bb[2] < ab[0] ||
                      ab[3] < bb[1] || bb[3] < ab[1]

              ox = [0, [ab[2], bb[2]].min - [ab[0], bb[0]].max].max
              oy = [0, [ab[3], bb[3]].min - [ab[1], bb[1]].max].max
              overlap = ox * oy
              area_a = [(ab[2] - ab[0]) * (ab[3] - ab[1]), 0.001].max
              area_b = [(bb[2] - bb[0]) * (bb[3] - bb[1]), 0.001].max
              min_area = [area_a, area_b].min

              next unless (overlap / min_area) > 0.30

              a_is_digit = a.text.to_s =~ /\A\d{1,2}\z/
              b_is_digit = b.text.to_s =~ /\A\d{1,2}\z/
              a_is_frac = a.text.to_s =~ /\d+\/\d+/
              b_is_frac = b.text.to_s =~ /\d+\/\d+/
              next if (a_is_digit && b_is_frac) || (b_is_digit && a_is_frac)

              score_a = a.text.to_s.length + (a.text =~ /[A-Za-z]/ ? 5 : 0) +
                         (a.text =~ /\d+\/\d+/ ? 3 : 0)
              score_b = b.text.to_s.length + (b.text =~ /[A-Za-z]/ ? 5 : 0) +
                         (b.text =~ /\d+\/\d+/ ? 3 : 0)
              if score_a >= score_b
                drop[j] = true
              else
                drop[i] = true
                break
              end
            end
          end
        end

        # ── Pass 4: Density thinning ──
        # Thin truly overcrowded areas but protect dimensions and part marks
        surviving = []
        items.each_with_index { |it, i| surviving << [it, bboxes[i], i] unless drop[i] }

        if surviving.length > 100
          cell_size = 60.0
          cells = {}
          surviving.each do |it, bb, idx|
            cx = (bb[0] / cell_size).floor
            cy = (bb[1] / cell_size).floor
            key = [cx, cy]
            cells[key] ||= []
            cells[key] << [it, idx]
          end

          cells.each do |_, group|
            next if group.length <= 5
            ranked = group.sort_by do |it, _|
              txt = it.text.to_s
              score = txt.length
              score += 20 if txt =~ /[A-Za-z]{2,}/
              score += 15 if txt =~ /\d+\/\d+/
              score += 15 if txt =~ /\d+['-]/
              score += 10 if txt =~ /SECTION|DETAIL|MITER|PIPE|GALV/i
              -score
            end
            ranked[5..-1].each do |it, idx|
              txt = it.text.to_s
              # Protect critical text
              next if txt =~ /\d+\/\d+/
              next if txt =~ /\d+['']\s*[-–]?\s*\d/
              next if txt =~ /\b[mp]\d{3,}/i
              next if txt =~ /SECTION|DETAIL/i
              drop[idx] = true
            end
          end
        end

        result = []
        items.each_with_index { |it, i| result << it unless drop[i] }
        result
      rescue StandardError => e
        Logger.warn("TextParser", "suppress_overlaps failed: #{e.message}")
        items
      end

      def merge_text_runs(items)
        return items if items.length < 2

        # Group by similar orientation/font and near-baseline, then merge nearby glyph runs.
        buckets = {}
        items.each do |it|
          angle_key = (it.angle.to_f / 2.0).round
          size_key = (it.font_size.to_f / 0.5).round
          font_key = it.font_name.to_s
          key = [angle_key, size_key, font_key]
          (buckets[key] ||= []) << it
        end

        merged = []
        buckets.each_value do |group|
          next merged.concat(group) if group.length < 2

          rows = []
          group.sort_by { |it| [-it.y.to_f, it.x.to_f] }.each do |it|
            placed = false
            rows.each do |row|
              y_tol = [0.9, row[:size] * 0.28].max
              if (it.y.to_f - row[:y]).abs <= y_tol
                row[:items] << it
                row[:y_sum] += it.y.to_f
                row[:count] += 1
                row[:y] = row[:y_sum] / row[:count]
                placed = true
                break
              end
            end
            unless placed
              rows << {
                y: it.y.to_f,
                y_sum: it.y.to_f,
                count: 1,
                size: it.font_size.to_f,
                items: [it]
              }
            end
          end

          rows.each do |row|
            line = row[:items].sort_by { |it| it.x.to_f }
            run = []
            line.each do |it|
              if run.empty?
                run << it
                next
              end

              prev = run.last
              prev_width = estimate_text_width(prev.text, prev.font_size.to_f)
              gap = it.x.to_f - (prev.x.to_f + prev_width)
              max_join_gap = [prev.font_size.to_f * 2.2, 4.0].max
              min_overlap = -[prev.font_size.to_f * 0.9, 4.0].max

              if gap <= max_join_gap && gap >= min_overlap
                run << it
              else
                merged << merge_run(run)
                run = [it]
              end
            end
            merged << merge_run(run) unless run.empty?
          end
        end

        merged
      rescue StandardError => e
        Logger.warn("TextParser", "merge_text_runs failed: #{e.message}")
        items
      end

      # Fix fractions that merge_text_runs joined with a space instead of a slash.
      # "5 16" → "5/16", "7 16" → "7/16", "15 16" → "15/16"
      # Also handles mid-string: "1'-4 5 16" → "1'-4 5/16"
      def fix_merged_fractions(items)
        items.map do |it|
          text = it.text.to_s
          # Pattern: standalone "N DD" where DD is a valid denominator and N < DD
          fixed = text.gsub(/\b(\d{1,2}) (\d{1,2})\b/) do |match|
            num = $1.to_i
            den = $2.to_i
            if VALID_DENOMS.include?(den) && num > 0 && num < den
              "#{$1}/#{$2}"
            else
              match
            end
          end
          if fixed != text
            TextItem.new(fixed, it.x, it.y, it.font_size, it.angle, it.font_name, it.raw_font_size || it.font_size)
          else
            it
          end
        end
      rescue StandardError => e
        Logger.warn("TextParser", "fix_merged_fractions failed: #{e.message}")
        items
      end

      def merge_run(run)
        return run.first if run.length == 1

        text = ""
        cursor = run.first.x.to_f
        run.each_with_index do |it, idx|
            if idx > 0
              gap = it.x.to_f - cursor
              prev_txt = run[idx - 1].text.to_s
              curr_txt = it.text.to_s

              # Keep mixed dimensions readable: avoid "11/6" from "1" + "1/6".
              force_space =
                (prev_txt =~ /\d\z/ && curr_txt =~ /\A\d+\s*\/\s*\d+/) ||
                (prev_txt =~ /\A\d+\s*\/\s*\d+\z/ && curr_txt =~ /\A\d\z/) ||
                (prev_txt =~ /[A-Za-z]\z/ && curr_txt =~ /\A\d/)

              # Insert space for meaningful gap
              space_gap = [it.font_size.to_f * 0.35, 1.2].max
              text << " " if force_space || gap > space_gap
            end
          text << it.text.to_s
          width = estimate_text_width(it.text, it.font_size.to_f)
          cursor = [cursor, it.x.to_f + width].max
        end

        base = run.first
        TextItem.new(
          clean_text(text),
          base.x,
          base.y,
          base.font_size,
          base.angle,
          base.font_name,
          base.raw_font_size || base.font_size
        )
      end

      def estimate_text_width(text, font_size)
        chars = [text.to_s.length, 1].max
        [font_size.to_f * 0.24 * chars, font_size.to_f * 0.25].max
      end

      def dedupe_text_items(items)
        return items if items.length < 2

        seen = {}
        out = []
        items.each do |it|
          txt = clean_text(it.text)
          next if txt.empty?
          key = [
            txt,
            (it.x.to_f * 2.0).round / 2.0,
            (it.y.to_f * 2.0).round / 2.0,
            (it.font_size.to_f * 2.0).round / 2.0,
            (it.angle.to_f * 2.0).round / 2.0
          ]
          next if seen[key]
          seen[key] = true
          out << it
        end
        out
      rescue StandardError => e
        Logger.warn("TextParser", "deduplicate_text failed: #{e.message}")
        items
      end

      def multiply_matrix(m1, m2)
        [
          m1[0] * m2[0] + m1[1] * m2[2],
          m1[0] * m2[1] + m1[1] * m2[3],
          m1[2] * m2[0] + m1[3] * m2[2],
          m1[2] * m2[1] + m1[3] * m2[3],
          m1[4] * m2[0] + m1[5] * m2[2] + m2[4],
          m1[4] * m2[1] + m1[5] * m2[3] + m2[5]
        ]
      end

      # ---------------------------------------------------------------
      # Fraction reconstruction
      # ---------------------------------------------------------------
      def reconstruct_fractions(items)
        return items if items.length < 2

        # Group text items by proximity on the same Y coordinate
        # Then look for stacked numerator/denominator pairs
        result = []
        used = Array.new(items.length, false)

        items.each_with_index do |item, i|
          next if used[i]

          # Check if this is a small-font digit that might be a fraction part
          if item.text =~ /\A\d{1,2}\z/ && items.length > i + 1
            # Look for a nearby denominator
            items.each_with_index do |other, j|
              next if j <= i || used[j]
              next unless other.text =~ /\A\d{1,2}\z/

              # Check proximity (same X region, different Y = stacked)
              dx = (item.x - other.x).abs
              dy = (item.y - other.y).abs

              # Stacked fractions: similar X, offset Y
              if dx < item.font_size * 3 && dy < item.font_size * 2.0 && dy > 0.3
                num_val = item.text.to_i
                den_val = other.text.to_i

                # Determine which is numerator (higher Y in PDF = visually on top)
                if item.y > other.y
                  numerator, denominator = num_val, den_val
                  base_item = item
                else
                  numerator, denominator = den_val, num_val
                  base_item = other
                end

                if VALID_DENOMS.include?(denominator) && numerator > 0 && numerator < denominator
                  # Found a fraction! Reconstruct as inline
                  frac_text = "#{numerator}/#{denominator}"
                  mid_y = (item.y + other.y) / 2.0
                  result << TextItem.new(
                    frac_text,
                    [item.x, other.x].min,
                    mid_y,
                    [item.font_size, other.font_size].max,
                    item.angle,
                    item.font_name,
                    [item.raw_font_size || item.font_size, other.raw_font_size || other.font_size].max
                  )
                  used[i] = true
                  used[j] = true
                  break
                end
              end
            end
          end

          unless used[i]
            # Try splitting combined digit strings (e.g., "1516" → "15/16")
            if item.text =~ /\A\d{3,4}\z/
              frac = try_split_fraction(item.text)
              if frac
                result << TextItem.new(
                  "#{frac[0]}/#{frac[1]}",
                  item.x, item.y, item.font_size, item.angle, item.font_name,
                  item.raw_font_size || item.font_size
                )
                used[i] = true
                next
              end
            end

            result << item
            used[i] = true
          end
        end

        result
      end

      def try_split_fraction(text)
        return nil if text.length < 3

        best = nil
        (1...text.length).each do |i|
          num_s = text[0, i]
          den_s = text[i..-1]
          begin
            num = num_s.to_i
            den = den_s.to_i
            if VALID_DENOMS.include?(den) && num > 0 && num < den
              if best.nil? || den < best[1]
                best = [num, den]
              end
            end
          rescue StandardError => e
            Logger.warn("TextParser", "parse_fraction failed: #{e.message}")
            next
          end
        end
        best
      end

      # ---------------------------------------------------------------
      # PDF string decoding
      # ---------------------------------------------------------------
      def decode_pdf_string_bytes(str)
        return "".b unless str
        s = str.to_s
        # Remove parentheses wrapper
        if s.start_with?('(') && s.end_with?(')')
          s = s[1..-2]
        end

        out = "".b
        i = 0
        while i < s.length
          ch = s[i]
          if ch == '\\'
            i += 1
            break if i >= s.length
            esc = s[i]

            case esc
            when 'n' then out << "\n".b
            when 'r' then out << "\r".b
            when 't' then out << "\t".b
            when 'b' then out << "\b".b
            when 'f' then out << "\f".b
            when '\\' then out << "\\".b
            when '(' then out << "(".b
            when ')' then out << ")".b
            when "\n"
              # Line continuation: swallow escaped newline
            when "\r"
              # CR or CRLF continuation
              i += 1 if i + 1 < s.length && s[i + 1] == "\n"
            when /[0-7]/
              oct = esc
              j = 0
              while j < 2 && i + 1 < s.length && s[i + 1] =~ /[0-7]/
                i += 1
                oct << s[i]
                j += 1
              end
              out << oct.to_i(8).chr(Encoding::BINARY)
            else
              out << esc.b
            end
          else
            out << ch.b
          end
          i += 1
        end

        out
      end

      def decode_pdf_hex_bytes(str)
        s = str.to_s
        s = s[1..-2] if s.start_with?('<') && s.end_with?('>')
        hex = s.gsub(/[^0-9A-Fa-f]/, '')
        hex = hex + '0' if hex.length.odd?

        [hex].pack('H*')
      end

      def extract_tj_text(array_str, font_name = nil)
        # TJ arrays contain strings and numbers: [(Hello ) -250 (World)]
        arr = array_str.to_s
        chunks = arr.scan(/\((?:\\.|[^\\)])*\)|<[^>]*>/)
        text = ""
        chunks.each do |chunk|
          text << decode_text_operand(chunk, font_name)
        end
        clean_text(text)
      end

      # ---------------------------------------------------------------
      # Tokenizer (simplified for text extraction)
      # ---------------------------------------------------------------
      def tokenize(stream)
        tokens = []
        i = 0
        len = stream.length

        while i < len
          c = stream[i]

          if c =~ /[\s\x00]/
            i += 1; next
          end

          if c == '%'
            eol = stream.index(/[\r\n]/, i) || len
            i = eol + 1; next
          end

          if c == '('
            depth = 1; j = i + 1
            while j < len && depth > 0
              if stream[j] == '\\'; j += 2; next; end
              depth += 1 if stream[j] == '('
              depth -= 1 if stream[j] == ')'
              j += 1
            end
            tokens << { type: :string, value: stream[i...j] }
            i = j; next
          end

          if c == '<' && (i + 1 >= len || stream[i + 1] != '<')
            j = stream.index('>', i) || len
            tokens << { type: :hex_string, value: stream[i..j] }
            i = j + 1; next
          end

          if c == '/'
            j = i + 1
            while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/; j += 1; end
            tokens << { type: :name, value: stream[i...j] }
            i = j; next
          end

          if c == '['
            depth = 1; j = i + 1
            while j < len && depth > 0
              depth += 1 if stream[j] == '['
              depth -= 1 if stream[j] == ']'
              j += 1
            end
            tokens << { type: :array, value: stream[i...j] }
            i = j; next
          end

          if c == ']'; i += 1; next; end

          if c == '<' && i + 1 < len && stream[i + 1] == '<'
            depth = 1; j = i + 2
            while j < len - 1 && depth > 0
              if stream[j, 2] == '<<'; depth += 1; j += 2
              elsif stream[j, 2] == '>>'; depth -= 1; j += 2
              else j += 1; end
            end
            tokens << { type: :dict, value: stream[i...j] }
            i = j; next
          end

          if c == '>' && i + 1 < len && stream[i + 1] == '>'; i += 2; next; end

          j = i
          while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/; j += 1; end
          word = stream[i...j]
          if word =~ /\A[+-]?\d*\.?\d+\z/
            tokens << { type: :number, value: word.to_f }
          else
            tokens << { type: :operator, value: word }
          end
          i = j
        end

        tokens
      end

    end
  end
end
