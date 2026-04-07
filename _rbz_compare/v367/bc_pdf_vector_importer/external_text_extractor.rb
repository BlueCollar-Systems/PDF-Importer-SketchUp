# bc_pdf_vector_importer/external_text_extractor.rb
# Optional high-fidelity text extraction via Poppler's pdftotext -bbox-layout.
# Falls back to internal TextParser when pdftotext is unavailable.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'cgi'
require 'tmpdir'
require File.join(File.dirname(__FILE__), 'command_runner')

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
            break if run[:timed_out]
            next unless run[:ok] && File.exist?(out_html)

            if idx == 1
              Logger.warn(
                'ExternalTextExtractor',
                "pdftotext -cropbox unavailable on page #{page_number}; using media box fallback"
              )
            end

            html = File.read(out_html, encoding: 'UTF-8')
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
          # 1) Explicit override
          env = ENV['BC_PDFTOTEXT_PATH']
          return env if env && !env.empty? && File.exist?(env)

          # 2) Common Windows install path (MiKTeX)
          candidates = []
          candidates << 'C:\\Program Files\\poppler\\Library\\bin\\pdftotext.exe'
          candidates << 'C:\\Program Files\\poppler\\bin\\pdftotext.exe'
          if ENV['LOCALAPPDATA'] && !ENV['LOCALAPPDATA'].empty?
            candidates << File.join(
              ENV['LOCALAPPDATA'],
              'Programs', 'MiKTeX', 'miktex', 'bin', 'x64', 'pdftotext.exe'
            )
          end
          candidates << 'C:\\Program Files\\MiKTeX\\miktex\\bin\\x64\\pdftotext.exe'
          # FreeCAD bundled (matches pdftocairo search)
          candidates << File.join('C:', 'Program Files', 'FreeCAD 1.1', 'bin', 'pdftotext.exe')
          # Glob patterns (matches pdftocairo search)
          Dir.glob('C:/Program Files/FreeCAD*/bin/pdftotext.exe').each { |p| candidates << p }
          Dir.glob('C:/poppler*/bin/pdftotext.exe').each { |p| candidates << p }
          Dir.glob('C:/tools/poppler*/bin/pdftotext.exe').each { |p| candidates << p }
          candidates.each { |p| return p if File.exist?(p) }

          # 3) PATH
          begin
            probe = CommandRunner.run(['pdftotext', '-v'],
              timeout_s: 10,
              context: 'ExternalTextExtractor.pdftotext_probe')
            return 'pdftotext' if probe[:ok]
          rescue StandardError => e
            Logger.warn('ExternalTextExtractor', "PATH probe failed: #{e.message}")
          end

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

            # For rotated text, the bbox is rotated too.
            # The SHORTER dimension of the bbox is the character height;
            # the LONGER dimension is the string length.
            # For horizontal text (angle near 0/180), height = bbox_h.
            # For vertical text (angle near 90/270), height = bbox_w.
            if angle.abs > 20 && angle.abs < 160
              # Significantly rotated — use shorter bbox dimension
              font_size = [bbox_w, bbox_h].min
            else
              # Horizontal-ish — use bbox height
              font_size = bbox_h
            end
            font_size = [font_size, 1.0].max

            x_pdf = x_min + offset_x
            y_pdf = (page_h - y_max) + offset_y

            items << TextParser::TextItem.new(
              line_text,
              x_pdf,
              y_pdf,
              font_size,
              angle,
              'pdftotext'
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
              out << TextParser::TextItem.new(
                merged,
                it.x.to_f,
                it.y.to_f,
                [it.font_size.to_f, items[candidate_idx].font_size.to_f].max,
                merge_angle(it.angle, items[candidate_idx].angle),
                it.font_name
              )
              used[i] = true
              used[candidate_idx] = true
            else
              out << it
              used[i] = true
            end
          end

          out = repair_whole_fraction_pairs(out)
          out = drop_orphan_fraction_fragments(out)
          drop_redundant_fragments(out)
        rescue StandardError => e
          Logger.warn("ExternalTextExtractor", "merge_split_dimension_labels failed: #{e.message}")
          items
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
              out << TextParser::TextItem.new(
                normalize_line_text(rebuilt),
                it.x.to_f,
                it.y.to_f,
                [it.font_size.to_f, items[candidate_idx].font_size.to_f].max,
                merge_angle(it.angle, items[candidate_idx].angle),
                it.font_name
              )
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

          first = word_center(words.first[:attrs])
          last = word_center(words.last[:attrs])
          return 0.0 unless first && last

          dx = last[0] - first[0]
          dy_screen = last[1] - first[1]
          return 0.0 if dx.abs < 0.001 && dy_screen.abs < 0.001

          # Convert top-down screen Y to PDF-style Y-up angle.
          dy_pdf = -dy_screen
          Math.atan2(dy_pdf, dx) * 180.0 / Math::PI
        rescue StandardError => e
          Logger.warn("ExternalTextExtractor", "compute_line_angle failed: #{e.message}")
          0.0
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
