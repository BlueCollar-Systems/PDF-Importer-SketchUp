# bc_pdf_vector_importer/resolved_scale.rb
# Title-block scale detection aligned with pdfcadcore resolved_scale.py.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require_relative 'unit_parser'

module BlueCollarSystems
  module PDFVectorImporter
    module ResolvedScaleDetect

      SCALE_LABEL = /\b(SCALE|SC\.?|SCL\.?)\b/i.freeze
      ARCH_SCALE = /(\d+(?:\.\d+)?(?:\s*\/\s*\d+)?)\s*["\u2033]?\s*=\s*(.+)/i.freeze
      RATIO_SCALE = /\b(\d+)\s*:\s*(\d+)\b/.freeze
      TYPED_NUMBER = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/.freeze
      TYPED_RATIO = /\A(\d+(?:\.\d+)?|\.\d+)\s*:\s*(\d+(?:\.\d+)?|\.\d+)\z/.freeze
      TYPED_FRACTION = /\A(\d+(?:\.\d+)?)\s*\/\s*(\d+(?:\.\d+)?)\z/.freeze
      # 1-1/2"=1'-0" (a whole number plus a fraction of an inch on paper)
      TYPED_MIXED_ARCH = /\A(\d+)\s*[- ]\s*(\d+)\s*\/\s*(\d+)\s*["\u2033]?\s*=\s*(.+)\z/.freeze
      # A 'SCALE:' word in front of a pasted scale.
      TYPED_LABEL = /\A(?:SCALE|SCL\.?|SC\.?)(?=\s|[:=]|\z)\s*[:=]?\s*/i.freeze
      # paper = real
      TYPED_EQUATION = /\A([^=]+?)\s*=\s*([^=]+)\z/.freeze
      # Inches: 3, 1/4, 1-1/2 or 1 1/2, with an optional inch mark (group 4).
      TYPED_INCHES = /\A(?:(\d+)\s*[- ]\s*)?(\d+(?:\.\d+)?|\.\d+)(?:\s*\/\s*(\d+(?:\.\d+)?))?\s*("|\u2033|in\.?|inch(?:es)?)?\z/i.freeze

      module_function

      # The paper-to-real multiplier for a scale typed the way drawings print
      # it, or nil when the text cannot be read as a positive scale:
      #   '48' -> 48, '0.5' -> 0.5 (a plain number is the multiplier itself)
      #   '1:48' -> 48, '1/48' -> 48 (paper : real)
      #   1/4"=1'-0" -> 48, 3/8"=1' -> 32, 1"=10' -> 120
      #   1/4"=12" -> 48 (a real side with only an inch mark is inches)
      #   1=48 -> 48 (bare numbers on both sides are a ratio)
      # Extra ':' or '=' parts (1:48:2) are refused rather than guessed.
      def enlargement_from_text(text)
        return nil unless text.is_a?(String) && text.bytesize <= UnitParser::MAX_TEXT_BYTES
        return nil unless text.valid_encoding? && text.encoding.ascii_compatible?
        return nil unless text.ascii_only? || text.encoding == Encoding::UTF_8
        return nil if text =~ /[\x00-\x08\x0a-\x1f\x7f]/
        typed = text.to_s.strip.sub(TYPED_LABEL, '')
        return nil if typed.empty?
        return positive_factor(typed.to_f) if typed =~ TYPED_NUMBER
        return nil if typed.count(':') > 1 || typed.count('=') > 1

        equation = typed.match(TYPED_EQUATION)
        if equation
          return equation_factor(equation[1].strip, equation[2].strip)
        end

        ratio = typed.match(TYPED_RATIO) || typed.match(TYPED_FRACTION)
        if ratio
          paper = ratio[1].to_f
          return nil unless paper > 0.0
          return positive_factor(ratio[2].to_f / paper)
        end

        mixed = typed.match(TYPED_MIXED_ARCH)
        if mixed
          return nil unless mixed[3].to_f > 0.0
          paper = mixed[1].to_f + mixed[2].to_f / mixed[3].to_f
          real = typed_real_inches(mixed[4].to_s)
          return nil unless real && paper > 0.0
          return positive_factor(real.to_f / paper)
        end

        # Title-block detection intentionally searches within a note. Typed
        # input must consume the whole entry; never borrow that loose parser.
        nil
      rescue StandardError
        nil
      end

      # paper = real, both read as inches. A real side with no unit is feet
      # when the paper side has a unit (1"=10' engineering scales), and a
      # plain ratio when neither side has one (1=48).
      def equation_factor(paper_text, real_text)
        if paper_text =~ TYPED_NUMBER && real_text =~ TYPED_NUMBER
          paper = paper_text.to_f
          return nil unless paper > 0.0
          return positive_factor(real_text.to_f / paper)
        end
        paper = typed_inches(paper_text, false)
        return nil unless paper && paper > 0.0
        real = typed_real_inches(real_text)
        return nil unless real
        positive_factor(real.to_f / paper)
      end

      # An unmarked engineering-scale real side means feet (1"=10).
      # Explicit dimensions use the strict standalone parser, including its
      # zero-denominator/unknown-unit checks, independently of model units.
      def typed_real_inches(text)
        token = text.to_s.strip.tr("\u2032\u2033", "'\"")
        token = token.sub(/\b(in|ft)\.\z/i, '\\1')
        value = UnitParser.parse_inches(token)
        return nil if value.nil?
        token =~ TYPED_NUMBER ? value * 12.0 : value
      end

      # Inches from 3, 1/4", 1-1/2" or 6 in; nil when the text is not that
      # shape. With mark_required, a bare number is not read as inches.
      def typed_inches(text, mark_required)
        m = text.to_s.strip.match(TYPED_INCHES)
        return nil unless m
        return nil if mark_required && m[4].nil?
        whole, number, denominator = m[1], m[2], m[3]
        return nil if whole && denominator.nil?
        value = number.to_f
        if denominator
          return nil unless denominator.to_f > 0.0
          value /= denominator.to_f
        end
        value += whole.to_f if whole
        value
      end

      def positive_factor(value)
        return nil if value.nil?
        number = value.to_f
        number.finite? && number > 0.0 ? number : nil
      end

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
