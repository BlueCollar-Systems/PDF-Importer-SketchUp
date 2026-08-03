# bc_pdf_vector_importer/external_text_extractor.rb
# Optional high-fidelity text extraction via Poppler's pdftotext -bbox-layout.
# Falls back to internal TextParser when pdftotext is unavailable.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'cgi'
require 'tmpdir'
require File.join(File.dirname(__FILE__), 'command_runner')
require File.join(File.dirname(__FILE__), 'dependency_resolver')
require File.join(File.dirname(__FILE__), 'poppler_result_validator')

module BlueCollarSystems
  module PDFVectorImporter
    module ExternalTextExtractor
      class << self
        # Returns Array<TextParser::TextItem>
        # opts:
        #   :offset_x_pts, :offset_y_pts — added to extracted PDF coordinates
        #   to map crop-space coordinates back into media-space coordinates.
        def extract(pdf_path, page_number, opts = {})
          exe = pdftotext_executable
          return [] unless exe && File.exist?(pdf_path.to_s)

          out_html = File.join(
            Dir.tmpdir,
            "bc_pdf_text_bbox_#{Process.pid}_#{Time.now.to_i}_#{rand(100000)}.html"
          )

          base_args = [
            exe.to_s,
            '-f', page_number.to_i.to_s,
            '-l', page_number.to_i.to_s,
            '-bbox-layout'
          ]
          # Prefer crop box for coordinate fidelity, but some pdftotext builds
          # reject -cropbox with -bbox-layout. Retry without -cropbox.
          arg_variants = [
            base_args + ['-cropbox', pdf_path.to_s, out_html.to_s],
            base_args + [pdf_path.to_s, out_html.to_s]
          ]

          arg_variants.each_with_index do |args, idx|
            begin
              File.delete(out_html) if File.exist?(out_html)
            rescue StandardError
              # best-effort cleanup
            end

            run = CommandRunner.run(
              args,
              timeout_s: 45,
              context: 'ExternalTextExtractor.pdftotext'
            )
            validation = PopplerResultValidator.validate(
              run,
              :executable => exe,
              :argv => args,
              :context => 'ExternalTextExtractor.pdftotext',
              :page => page_number,
              :attempt => idx + 1,
              :representation => :text_bbox,
              :artifacts => [out_html],
              :artifact_policy => :all_nonempty
            )
            unless validation[:ok]
              PopplerResultValidator.log_rejection(
                validation, 'ExternalTextExtractor'
              )
              begin
                File.delete(out_html) if File.exist?(out_html)
              rescue StandardError
                # The method-level ensure makes one final cleanup attempt.
              end
              break if run[:timed_out]
              next
            end

            if idx == 1
              Logger.warn(
                'ExternalTextExtractor',
                "pdftotext -cropbox unavailable on page #{page_number}; using media box fallback"
              )
            end

            html = File.read(out_html, encoding: 'UTF-8')
            # Round 13: nominal text sizes from the content stream
            # (Tf * vertical_scale(Tm . CTM)) so size never depends on the
            # producer's encoding or on bbox extents. bbox stays fallback.
            unless opts.key?(:nominal_anchors)
              anchors = begin
                require_relative 'nominal_text_scanner'
                parser = PDFParser.new(pdf_path)
                parser.parse
                info = parser.page_data(page_number)
                streams = info ? (info[:content_streams] || []) : []
                NominalTextScanner.scan(streams)
              rescue StandardError
                []
              end
              opts = opts.merge(nominal_anchors: anchors)
            end
            return parse_bbox_html(html, opts)
          end

          []
        rescue StandardError => e
          begin
            Logger.warn('ExternalTextExtractor', "pdftotext fallback: #{e.message}")
          rescue StandardError
            # Logger may be unavailable in stripped test/runtime contexts.
          end
          []
        ensure
          begin
            File.delete(out_html) if out_html && File.exist?(out_html)
          rescue StandardError => e
            Logger.warn("ExternalTextExtractor", "cleanup temp html failed: #{e.message}")
          end
        end

        private

        def pdftotext_executable
          DependencyResolver.find_pdftotext
        rescue StandardError => e
          Logger.warn('ExternalTextExtractor', "pdftotext lookup failed: #{e.message}")
          nil
        end

        def parse_bbox_html(html, opts = {})
          return [] if html.to_s.empty?

          page_h = html[/<page[^>]*height="([0-9.]+)"/i, 1].to_f
          return [] if page_h <= 0.0
          offset_x = opts[:offset_x_pts].to_f
          offset_y = opts[:offset_y_pts].to_f

          items = []

          html.scan(/<line\s+([^>]+)>(.*?)<\/line>/mi) do |line_attrs, inner|
            words = inner.scan(/<word\s+([^>]+)>(.*?)<\/word>/mi).map do |attrs, txt|
              {
                attrs: attrs,
                text: normalize_word_text(CGI.unescapeHTML(txt.to_s))
              }
            end.reject { |w| w[:text].empty? }
            next if words.empty?

            # Join words as they appear on the line.
            line_text = normalize_line_text(words.map { |w| w[:text] }.join(' '))
            next if line_text.empty?

            x_min = attr_value(line_attrs, 'xMin').to_f
            x_max = attr_value(line_attrs, 'xMax').to_f
            y_min = attr_value(line_attrs, 'yMin').to_f
            y_max = attr_value(line_attrs, 'yMax').to_f

            bbox_w = (x_max - x_min).abs
            bbox_h = (y_max - y_min).abs

            angle = estimate_angle(words, line_attrs)
            # CAD weld/fraction callouts and TYP notes are horizontal in SU even when
            # pdftotext word boxes imply a mild diagonal baseline.
            angle = 0.0 if line_text =~ /\A\d{1,2}\/\d{1,2}"?\z/
            angle = 0.0 if line_text =~ /\ATYP\.?\z/i

            # Round 13: prefer the nominal size/rotation recorded from the
            # content stream (encoding-independent, exact). Match this line
            # to the nearest text-show anchor at its start/baseline point.
            anchor = nil
            anchors = opts[:nominal_anchors]
            if anchors && !anchors.empty?
              ax = x_min
              ay = page_h - y_max # pdftotext top-down -> PDF y-up (box bottom)
              max_d = [bbox_w, bbox_h, 12.0].max
              anchor = NominalTextScanner.nearest(anchors, ax, ay, max_d)
              if anchor.nil?
                ay2 = page_h - y_min
                anchor = NominalTextScanner.nearest(anchors, ax, ay2, max_d)
              end
            end

            raw_font_size = nil
            if anchor && anchor.size_pt > 0.05
              font_size = anchor.size_pt
              angle = anchor.angle_deg
              # Keep the CAD callout horizontal overrides authoritative.
              angle = 0.0 if line_text =~ /\A\d{1,2}\/\d{1,2}"?\z/
              angle = 0.0 if line_text =~ /\ATYP\.?\z/i
            elsif angle.abs > 20 && angle.abs < 160
              # Fallback (no anchor): rotated bbox — the SHORTER dimension is
              # the character height; the LONGER is the string length.
              font_size = [bbox_w, bbox_h].min
            else
              # Fallback (no anchor): horizontal-ish — use bbox height.
              font_size = bbox_h
            end

            # A near-horizontal, tall/narrow line whose reported size follows
            # the AABB long side is an orientation ambiguity, not a giant font.
            # Resolve its nominal glyph height to the short side here so every
            # renderer can continue trusting TextItem#font_size (SIZE-1). Keep
            # the scanner value as raw evidence for vertical-run inference.
            if angle.to_f.abs < 12.0 && bbox_h > bbox_w * 1.5 &&
               font_size.to_f > bbox_w * 1.5
              raw_font_size = font_size.to_f
              font_size = [bbox_w, bbox_h].min
            end
            font_size = [font_size, 1.0].max

            x_pdf = x_min + offset_x
            y_pdf = (page_h - y_max) + offset_y
            bbox_x0 = x_min + offset_x
            bbox_x1 = x_max + offset_x
            bbox_y0 = (page_h - y_max) + offset_y
            bbox_y1 = (page_h - y_min) + offset_y

            items << TextParser::TextItem.new(
              line_text,
              x_pdf,
              y_pdf,
              font_size,
              angle,
              'pdftotext',
              raw_font_size,
              bbox_x0,
              bbox_y0,
              bbox_x1,
              bbox_y1
            )
          end

          if opts[:strict_text_fidelity]
            items
          else
            stitch_fragmented_dimensions(items)
          end
        end

        def attr_value(attrs, name)
          attrs[/\b#{Regexp.escape(name)}="([^"]+)"/i, 1] || ''
        end

        def normalize_word_text(text)
          t = text.to_s
          t = t.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
          t = t.gsub(/\s+/, ' ').strip
          t
        end

        def normalize_line_text(text)
          t = text.to_s
          return '' if t.empty?

          # Clean common dimension spacing artifacts from bbox output.
          t = t.gsub(/(\d)\s*\/\s*(\d)/, '\\1/\\2')
          # Do NOT blindly rewrite denominator digits here (e.g. /1 -> /16):
          # that can silently corrupt valid dimensions. Denominator repair is
          # handled later by context-aware merge/rebuild heuristics.
          t = t.gsub(/(\d)\s*'\s*-\s*(\d)/, "\\1'-\\2")
          t = t.gsub(/(\d)\s*-\s*(\d)/, '\\1-\\2')
          t = t.gsub(/\s+"/, '"')
          t = t.gsub(/\s+/, ' ').strip

          t
        end

        # Join common split dimension fragments emitted by bbox extraction,
        # e.g. "3 15/1" + "6" -> "3 15/16", "2 7 /" + "16" -> "2 7/16".
        def stitch_fragmented_dimensions(items)
          return items if items.length < 2

          used = Array.new(items.length, false)
          out = []

          items.each_with_index do |it, i|
            next if used[i]

            text = it.text.to_s
            needs_tail_digit = text =~ /(?:\/\s*|\/1\s*)\z/
            needs_hyphen_tail = text =~ /-\s*\z/
            unless needs_tail_digit || needs_hyphen_tail
              out << it
              used[i] = true
              next
            end

            candidate_idx = nil
            best_score = Float::INFINITY

            items.each_with_index do |other, j|
              next if i == j
              # Allow already-output tiny numeric fragments to still serve as
              # denominator tails for later slash fragments.
              if used[j] && numeric_tail_candidate(other.text.to_s).nil?
                next
              end
              ot = other.text.to_s.strip
              next if ot.empty?

              # For dangling slash/hyphen, we only want compact numeric tails.
              tail_candidate = numeric_tail_candidate(ot)
              next unless tail_candidate

              dy = (other.y.to_f - it.y.to_f).abs
              dx = other.x.to_f - it.x.to_f
              next if dy > [it.font_size.to_f * 1.25, 24.0].max
              next if dx < -[it.font_size.to_f * 0.5, 4.0].max
              next if dx > [it.font_size.to_f * 2.5, 32.0].max

              score = (dy * 10.0) + dx.abs
              if score < best_score
                best_score = score
                candidate_idx = j
              end
            end

            if candidate_idx
              tail = numeric_tail_candidate(items[candidate_idx].text.to_s.strip) ||
                     items[candidate_idx].text.to_s.strip
              merged = normalize_line_text(merge_head_tail(text, tail))
              merged_bbox = merged_text_item_bbox(
                [it, items[candidate_idx]]
              )
              merged_item = TextParser::TextItem.new(
                merged,
                it.x.to_f,
                it.y.to_f,
                [it.font_size.to_f, items[candidate_idx].font_size.to_f].max,
                merge_angle(it.angle, items[candidate_idx].angle),
                it.font_name,
                it.respond_to?(:raw_font_size) ? it.raw_font_size : nil,
                merged_bbox[0],
                merged_bbox[1],
                merged_bbox[2],
                merged_bbox[3]
              )
              # Merged fragments keep the head item's span identity (corrective §1).
              if it.respond_to?(:source_span_id)
                merged_item.source_span_id = it.source_span_id
              end
              out << merged_item
              used[i] = true
              used[candidate_idx] = true
            else
              out << it
              used[i] = true
            end
          end

          out = repair_whole_fraction_pairs(out)
          out = stitch_angle_mark_fragments(out)
          out = drop_orphan_fraction_fragments(out)
          drop_redundant_fragments(out)
        rescue StandardError => e
          Logger.warn("ExternalTextExtractor", "merge_split_dimension_labels failed: #{e.message}")
          items
        end

        # Diagonal angle-member marks in shop drawings can arrive as three bbox
        # lines with variable numeric splits, e.g. "a1" + "00" + "5" or
        # "a1" + "0" + "20". Rebuild into one rotated a-prefixed part-mark
        # item (pattern: a + four digits).
        def stitch_angle_mark_fragments(items)
          return items if items.length < 3

          used = Array.new(items.length, false)
          merged = []
          a1_indices = items.each_index.select { |idx| items[idx].text.to_s.strip =~ /\Aa1\z/i }
          numeric_indices = items.each_index.select do |idx|
            items[idx].text.to_s.strip =~ /\A\d{1,2}\z/
          end

          a1_indices.each do |ai|
            next if used[ai]
            a1 = items[ai]
            best = nil

            numeric_indices.each do |middle_idx|
              next if used[middle_idx] || middle_idx == ai
              middle = items[middle_idx]
              next unless angle_mark_fragment_neighbor?(a1, middle)

              numeric_indices.each do |tail_idx|
                next if used[tail_idx] || tail_idx == ai || tail_idx == middle_idx
                tail = items[tail_idx]
                suffix = middle.text.to_s.strip + tail.text.to_s.strip
                next unless suffix.length == 3
                next unless angle_mark_fragment_neighbor?(middle, tail)
                next unless angle_mark_fragment_neighbor?(a1, tail, 4.0)

                angle = fragment_angle(a1, tail)
                next if angle.abs < 15.0 || angle.abs > 75.0
                score = fragment_distance(a1, middle) +
                        fragment_distance(middle, tail) +
                        (fragment_collinearity(a1, middle, tail) * 10.0)
                candidate = [score, middle_idx, tail_idx, angle]
                best = candidate if best.nil? || score < best[0]
              end
            end

            next unless best
            _, middle_idx, tail_idx, angle = best
            merged << build_angle_mark_item(
              a1, items[middle_idx], items[tail_idx], angle
            )
            used[ai] = true
            used[middle_idx] = true
            used[tail_idx] = true
          end

          out = []
          items.each_with_index { |it, idx| out << it unless used[idx] }
          out + merged
        rescue StandardError => e
          Logger.warn("ExternalTextExtractor", "stitch_angle_mark_fragments failed: #{e.message}")
          items
        end

        def angle_mark_fragment_neighbor?(a, b, factor = 2.8)
          ax, ay = fragment_center(a)
          bx, by = fragment_center(b)
          fs = [a.font_size.to_f, b.font_size.to_f, 1.0].max
          fragment_distance_xy(ax, ay, bx, by) <= fs * factor
        rescue StandardError
          false
        end

        def fragment_center(item)
          if item.bbox_x0 && item.bbox_x1 && item.bbox_y0 && item.bbox_y1
            [
              (item.bbox_x0.to_f + item.bbox_x1.to_f) * 0.5,
              (item.bbox_y0.to_f + item.bbox_y1.to_f) * 0.5
            ]
          else
            [item.x.to_f, item.y.to_f]
          end
        rescue StandardError
          [0.0, 0.0]
        end

        def fragment_distance(a, b)
          ax, ay = fragment_center(a)
          bx, by = fragment_center(b)
          fragment_distance_xy(ax, ay, bx, by)
        rescue StandardError
          Float::INFINITY
        end

        def fragment_distance_xy(ax, ay, bx, by)
          Math.sqrt(((bx - ax) ** 2) + ((by - ay) ** 2))
        rescue StandardError
          Float::INFINITY
        end

        def fragment_angle(a, b)
          ax, ay = fragment_center(a)
          bx, by = fragment_center(b)
          angle = Math.atan2(by - ay, bx - ax) * 180.0 / Math::PI
          angle += 180.0 while angle <= -90.0
          angle -= 180.0 while angle > 90.0
          angle
        rescue StandardError
          0.0
        end

        def fragment_collinearity(a, b, c)
          ax, ay = fragment_center(a)
          bx, by = fragment_center(b)
          cx, cy = fragment_center(c)
          dx = cx - ax
          dy = cy - ay
          len = Math.sqrt((dx * dx) + (dy * dy))
          return Float::INFINITY if len <= 1.0e-6
          (((bx - ax) * dy) - ((by - ay) * dx)).abs / len
        rescue StandardError
          Float::INFINITY
        end

        def build_angle_mark_item(a1, middle, tail, angle)
          items = [a1, middle, tail]
          xs0 = items.map { |it| it.bbox_x0 || it.x }.map(&:to_f)
          ys0 = items.map { |it| it.bbox_y0 || it.y }.map(&:to_f)
          xs1 = items.map { |it| it.bbox_x1 || it.x }.map(&:to_f)
          ys1 = items.map { |it| it.bbox_y1 || it.y }.map(&:to_f)
          bx0 = xs0.min
          by0 = ys0.min
          bx1 = xs1.max
          by1 = ys1.max
          merged_text = items.map { |item| item.text.to_s.strip }.join
          TextParser::TextItem.new(
            merged_text,
            bx0,
            by0,
            items.map { |it| it.font_size.to_f }.max,
            angle,
            'pdftotext',
            nil,
            bx0,
            by0,
            bx1,
            by1,
            a1.respond_to?(:layer_name) ? a1.layer_name : nil,
            # Merged angle marks keep the leading item's span identity (corrective §1).
            a1.respond_to?(:source_span_id) ? a1.source_span_id : nil
          )
        rescue StandardError
          a1
        end

        # For patterns like "R 2 2" + nearby "1/2" => "R 2 1/2"
        # and "9 1" + nearby "3/16" => "9 3/16".
        def repair_whole_fraction_pairs(items)
          return items if items.length < 2

          used = Array.new(items.length, false)
          out = []

          items.each_with_index do |it, i|
            next if used[i]
            text = normalize_line_text(it.text.to_s)

            unless text =~ /\A(?:R\s+\d+|\d+'-\d+|\d+-\d+|(?:R\s+)?\d+\s+\d)\z/
              out << it
              used[i] = true
              next
            end

            candidate_idx = nil
            candidate_frac = nil
            best_score = Float::INFINITY

            items.each_with_index do |other, j|
              next if i == j
              frac = fraction_hint_from_candidate(text, other.text.to_s)
              next unless frac

              dy = (other.y.to_f - it.y.to_f).abs
              dx = other.x.to_f - it.x.to_f
              next if dy > [it.font_size.to_f * 1.3, 24.0].max
              next if dx < -[it.font_size.to_f * 0.8, 8.0].max
              next if dx > [it.font_size.to_f * 3.5, 52.0].max

              score = (dy * 10.0) + dx.abs
              if score < best_score
                best_score = score
                candidate_idx = j
                candidate_frac = frac
              end
            end

            if candidate_idx && candidate_frac
              rebuilt = replace_trailing_whole_with_fraction(text, candidate_frac)
              merged_bbox = merged_text_item_bbox(
                [it, items[candidate_idx]]
              )
              rebuilt_item = TextParser::TextItem.new(
                normalize_line_text(rebuilt),
                it.x.to_f,
                it.y.to_f,
                [it.font_size.to_f, items[candidate_idx].font_size.to_f].max,
                merge_angle(it.angle, items[candidate_idx].angle),
                it.font_name,
                it.respond_to?(:raw_font_size) ? it.raw_font_size : nil,
                merged_bbox[0],
                merged_bbox[1],
                merged_bbox[2],
                merged_bbox[3]
              )
              # Repaired pairs keep the head item's span identity (corrective §1).
              if it.respond_to?(:source_span_id)
                rebuilt_item.source_span_id = it.source_span_id
              end
              out << rebuilt_item
              used[i] = true
              used[candidate_idx] = true
            else
              out << it
              used[i] = true
            end
          end

          out
        rescue StandardError => e
          Logger.warn("ExternalTextExtractor", "repair_whole_fraction_pairs failed: #{e.message}")
          items
        end

        def merged_text_item_bbox(items)
          boxes = Array(items).map do |item|
            names = [:bbox_x0, :bbox_y0, :bbox_x1, :bbox_y1]
            next nil unless item && names.all? { |name| item.respond_to?(name) }
            values = names.map { |name| item.send(name) }
            next nil if values.any? { |value| value.nil? }
            values.map { |value| value.to_f }
          end
          return [nil, nil, nil, nil] if boxes.any? { |box| box.nil? }
          [
            boxes.map { |box| [box[0], box[2]].min }.min,
            boxes.map { |box| [box[1], box[3]].min }.min,
            boxes.map { |box| [box[0], box[2]].max }.max,
            boxes.map { |box| [box[1], box[3]].max }.max
          ]
        rescue StandardError
          [nil, nil, nil, nil]
        end

        def merge_head_tail(head_text, tail_text)
          head = head_text.to_s.rstrip
          tail = tail_text.to_s.strip
          return head if tail.empty?

          # Common truncation: "/1" + "6" or "/1" + "16" should become "/16".
          if head =~ /\/1\s*\z/
            if tail == '6'
              return "#{head}6"
            elsif tail == '16'
              return head.sub(/\/1\s*\z/, '/16')
            end
          end

          # Dangling slash/hyphen tails append directly.
          return "#{head}#{tail}" if head =~ /(?:\/\s*|-\s*)\z/

          "#{head} #{tail}"
        end

        def numeric_tail_candidate(text)
          t = text.to_s.strip
          return t if t =~ /\A\d{1,2}\z/
          # Some fragments appear as "8 8"; first value is the usable tail.
          return Regexp.last_match(1) if t =~ /\A(\d{1,2})\s+\d{1,2}\z/
          nil
        end

        def normalized_fraction_text(text)
          t = normalize_line_text(text.to_s)
          m = /\A(\d{1,2})\/(\d{1,2})\z/.match(t)
          return nil unless m

          valid_fraction(m[1].to_i, m[2].to_i)
        end

        def fraction_hint_from_candidate(whole_text, candidate_text)
          # Direct fraction candidate first.
          direct = normalized_fraction_text(candidate_text)
          return direct if direct

          whole_tail_tok = whole_text.to_s.split(/\s+/).last.to_s
          return nil unless whole_tail_tok =~ /\A\d{1,2}\z/
          whole_tail = whole_tail_tok.to_i

          t = normalize_line_text(candidate_text.to_s)

          # "/ 8" means denominator present, numerator is from whole tail.
          m = /\A\/\s*(\d{1,2})\z/.match(t)
          if m
            frac = valid_fraction(whole_tail, m[1].to_i)
            return frac if frac
          end

          # "1 /" or "8 /" could be either num/whole or whole/den depending on
          # which option produces a valid structural denominator.
          m = /\A(\d{1,2})\s*\/\z/.match(t)
          if m
            a = m[1].to_i
            frac = valid_fraction(a, whole_tail)
            return frac if frac
            frac = valid_fraction(whole_tail, a)
            return frac if frac
          end

          nil
        end

        def valid_fraction(num, den)
          return nil if num <= 0 || den <= 0
          valid = [2, 4, 8, 16, 32, 64]
          return nil unless valid.include?(den)
          return nil if num >= den  # e.g. 8/8 is not a valid fraction display
          "#{num}/#{den}"
        end

        def replace_trailing_whole_with_fraction(text, frac)
          # "R 2" + "1/2" => "R 2 1/2"
          if text =~ /\AR\s+\d+\z/
            return "#{text} #{frac}"
          end

          # "1'-0" + "1/16" => "1'-0 1/16"
          if text =~ /\A\d+'-\d+\z/ || text =~ /\A\d+-\d+\z/
            return "#{text} #{frac}"
          end

          parts = text.to_s.split(/\s+/)
          return text if parts.empty?

          # If OCR duplicated a single digit pair ("8 8"), prefer fraction only.
          if parts.length == 2 && parts[0] == parts[1]
            return frac
          end

          parts[-1] = frac
          parts.join(' ')
        end

        def drop_orphan_fraction_fragments(items)
          items.reject do |it|
            t = it.text.to_s.strip
            t =~ /\A\/\s*\d{1,2}\z/ || t =~ /\A\d{1,2}\s*\/\z/
          end
        end

        # Remove tiny leftovers when a nearby merged composite already contains
        # the same value (e.g., keep "R 2 1/2", drop nearby standalone "1/2").
        def drop_redundant_fragments(items)
          # Ruby 2.2 compat: .reject.with_index requires 2.4+.
          # Use explicit loop to build the filtered list.
          reject_indices = []
          items.each_with_index do |it, idx|
            t = it.text.to_s.strip

            should_reject = if t =~ /\A\d{1,2}\/(?:2|4|8|16|32|64)\z/
              items.each_with_index.any? do |other, j|
                next false if idx == j
                ot = other.text.to_s
                next false unless ot.length > t.length + 2
                next false unless ot.include?(t)
                dx = (other.x.to_f - it.x.to_f).abs
                dy = (other.y.to_f - it.y.to_f).abs
                dx <= [it.font_size.to_f * 3.0, 42.0].max &&
                  dy <= [it.font_size.to_f * 1.8, 30.0].max
              end
            elsif t == '0'
              items.any? do |other|
                next false if other.equal?(it)
                ot = other.text.to_s.strip
                next false unless ot =~ /\A\d+'-0(?:\s+\d{1,2}\/\d{1,2})?\z/ ||
                                  ot =~ /\A\d+-0(?:\s+\d{1,2}\/\d{1,2})?\z/
                dx = (other.x.to_f - it.x.to_f).abs
                dy = (other.y.to_f - it.y.to_f).abs
                dx <= [it.font_size.to_f * 3.0, 42.0].max &&
                  dy <= [it.font_size.to_f * 1.8, 30.0].max
              end
            elsif t =~ /\A(2|4|8|16|32|64)\z/
              den = Regexp.last_match(1)
              # Example: stray "16" near "15/16" after split/merge cleanup.
              items.any? do |other|
                next false if other.equal?(it)
                ot = other.text.to_s.strip
                next false unless ot =~ /\A\d{1,2}\/#{Regexp.escape(den)}\z/
                dx = (other.x.to_f - it.x.to_f).abs
                dy = (other.y.to_f - it.y.to_f).abs
                da = (other.angle.to_f - it.angle.to_f).abs
                dx <= [it.font_size.to_f * 3.0, 42.0].max &&
                  dy <= [it.font_size.to_f * 1.8, 30.0].max &&
                  da <= 35.0
              end
            else
              false
            end

            reject_indices << idx if should_reject
          end
          result = []
          items.each_with_index { |it2, i| result << it2 unless reject_indices.include?(i) }
          result
        end

        def estimate_angle(words, line_attrs = nil)
          if words.length < 2
            # Single-word lines have no reliable baseline vector.
            return 0.0
          end

          # Stacked-fraction dimensions (e.g. "1 1/2") place glyphs vertically
          # inside a tight bbox. First/last word centers then look ~vertical even
          # though the annotation is horizontal in the drawing.
          return 0.0 if stacked_fraction_line?(words)

          first = word_center(words.first[:attrs])
          last = word_center(words.last[:attrs])
          return 0.0 unless first && last

          dx = last[0] - first[0]
          dy_screen = last[1] - first[1]
          return 0.0 if dx.abs < 0.001 && dy_screen.abs < 0.001

          # Convert top-down screen Y to PDF-style Y-up angle.
          dy_pdf = -dy_screen
          angle = Math.atan2(dy_pdf, dx) * 180.0 / Math::PI
          # Mild tilt from fraction kerning should not rotate SU labels.
          angle.abs < 8.0 ? 0.0 : angle
        rescue StandardError => e
          Logger.warn("ExternalTextExtractor", "compute_line_angle failed: #{e.message}")
          0.0
        end

        # Detect vertically stacked numerator/denominator columns.
        def stacked_fraction_line?(words)
          return false if words.length < 2

          xmins = words.map { |w| attr_value(w[:attrs], 'xMin').to_f }
          xmaxs = words.map { |w| attr_value(w[:attrs], 'xMax').to_f }
          ymins = words.map { |w| attr_value(w[:attrs], 'yMin').to_f }
          ymaxs = words.map { |w| attr_value(w[:attrs], 'yMax').to_f }
          x_span = xmaxs.max - xmins.min
          y_span = ymaxs.max - ymins.min
          return false if x_span < 0.5 || y_span < 4.0

          y_span > x_span * 0.85
        rescue StandardError
          false
        end

        def merge_angle(a, b)
          aa = a.to_f
          bb = b.to_f
          return bb if aa.abs < 1.0 && bb.abs >= 1.0
          return aa if bb.abs < 1.0 && aa.abs >= 1.0
          aa.abs >= bb.abs ? aa : bb
        rescue StandardError => e
          Logger.warn("ExternalTextExtractor", "merge_angle failed: #{e.message}")
          a.to_f
        end

        def word_center(attrs)
          x0 = attr_value(attrs, 'xMin').to_f
          y0 = attr_value(attrs, 'yMin').to_f
          x1 = attr_value(attrs, 'xMax').to_f
          y1 = attr_value(attrs, 'yMax').to_f
          return nil if x1 <= x0 || y1 <= y0
          [(x0 + x1) * 0.5, (y0 + y1) * 0.5]
        end
      end
    end
  end
end
