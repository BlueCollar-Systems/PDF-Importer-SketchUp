# bc_pdf_vector_importer/resolved_scale.rb
# Title-block scale detection aligned with pdfcadcore resolved_scale.py.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module ResolvedScaleDetect

      SCALE_LABEL = /\b(SCALE|SC\.?|SCL\.?)\b/i.freeze
      ARCH_SCALE = /(\d+(?:\.\d+)?(?:\s*\/\s*\d+)?)\s*["\u2033]?\s*=\s*(.+)/i.freeze
      RATIO_SCALE = /\b(\d+)\s*:\s*(\d+)\b/.freeze

      module_function

      def resolve(page_data)
        best = nil

        Array(page_data.text_items).each do |txt|
          raw = (txt.text || '').strip
          next if raw.empty?

          normalized = txt.normalized || raw.upcase
          parsed = DimensionParser.parse(raw)
          factor_conf = factor_from_parsed(parsed)
          factor_conf ||= factor_from_arch_match(raw)
          unless factor_conf
            m = normalized.match(RATIO_SCALE)
            if m
              parsed = DimensionParser.parse("#{m[1]}:#{m[2]}")
              factor_conf = factor_from_parsed(parsed)
            end
          end
          next unless factor_conf

          factor, base_conf = factor_conf
          conf = base_conf + titleblock_score(page_data, txt.insertion)
          conf += 0.15 if normalized.match(SCALE_LABEL)
          tags = Array(txt.classifications)
          conf += 0.10 if tags.include?(:titleblock_like)
          conf += 0.10 if tags.include?(:scale_like)
          conf = [conf, 0.98].min

          source = conf >= 0.70 ? 'titleblock' : 'page_text'
          candidate = ResolvedScale.new(
            factor.to_f,
            raw,
            source,
            conf.round(3),
            nil
          )
          best = candidate if best.nil? || candidate.confidence > best.confidence
        end

        return best if best

        ResolvedScale.new(1.0, '1:1', 'default', 0.0, 'no_scale_detected')
      end

      def merge_best(current, candidate)
        return to_hash(candidate) if current.nil?
        return current if candidate.nil?

        cur_conf = current.is_a?(Hash) ? current[:confidence].to_f : 0.0
        return to_hash(candidate) if candidate.confidence > cur_conf

        current
      end

      def to_hash(scale)
        return nil unless scale

        out = {
          factor: scale.factor.to_f,
          notation: scale.notation.to_s,
          source: scale.source.to_s,
          confidence: scale.confidence.to_f
        }
        reason = scale.fallback_reason
        out[:fallback_reason] = reason if reason && !reason.to_s.empty?
        out
      end

      def factor_from_parsed(parsed)
        return nil unless parsed && parsed.kind == :scale && parsed.value

        val = parsed.value
        if val.is_a?(Hash) && val[:ratio]
          num, den = val[:ratio]
          return nil if num.to_f <= 0 || den.to_f <= 0
          return [den.to_f / num.to_f, 0.75]
        end
        if val.is_a?(Hash) && val[:from] && val[:to]
          paper_in = DimensionParser.parse_length_token(val[:from].to_s)
          real_in = parse_feet_inches_token(val[:to].to_s) ||
                    DimensionParser.parse_length_token(val[:to].to_s)
          if paper_in && real_in && paper_in > 0
            return [real_in / paper_in, 0.85]
          end
        end
        nil
      end

      def factor_from_arch_match(raw)
        m = raw.match(ARCH_SCALE)
        return nil unless m

        paper_in = DimensionParser.parse_length_token(m[1].to_s)
        real_in = parse_feet_inches_token(m[2].to_s) ||
                  DimensionParser.parse_length_token(m[2].to_s)
        return nil unless paper_in && real_in && paper_in > 0

        [real_in / paper_in, 0.88]
      end

      def titleblock_score(page_data, insertion)
        return 0.0 unless insertion && insertion.length >= 2

        x = insertion[0].to_f
        y = insertion[1].to_f
        score = 0.0
        score += 0.35 if y <= page_data.height.to_f * 0.35
        score += 0.35 if x >= page_data.width.to_f * 0.45
        score
      end

      def parse_feet_inches_token(token)
        return nil unless token

        s = token.strip.upcase.gsub(/["']\z/, '')
        m = s.match(
          /\A(\d+(?:\.\d+)?)\s*(?:'|\u2032|FT|FEET)?\s*[-\u2013]?\s*(\d+(?:\.\d+)?)?\s*(?:(\d+)\s*\/\s*(\d+))?\s*(?:"|\u2033|IN|INCH|INCHES)?\s*\z/
        )
        return nil unless m

        feet = m[1].to_f
        inches = m[2] ? m[2].to_f : 0.0
        if m[3] && m[4] && m[4].to_f != 0
          inches += m[3].to_f / m[4].to_f
        end
        feet * 12.0 + inches
      end

    end
  end
end
