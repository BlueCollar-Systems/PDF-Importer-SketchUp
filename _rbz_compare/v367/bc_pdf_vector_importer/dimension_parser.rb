# bc_pdf_vector_importer/dimension_parser.rb
# Converts raw dimension text into structured ParsedDimension.
# Separates semantic parsing (what KIND of dimension) from
# token parsing (what NUMERIC VALUE).
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module DimensionParser

      # ---------------------------------------------------------------
      # Parse dimension text → ParsedDimension
      # ---------------------------------------------------------------
      def self.parse(text, config = nil)
        raw = text.to_s
        s = normalize(raw)

        result = ParsedDimension.new(raw, :unknown, nil, nil, nil, s, 0.0, [])

        # Extract quantity prefix: "4-13/16 DIA" → qty=4
        qty = extract_quantity(s)
        result.quantity = qty if qty

        # 1. Slot pattern: 13/16 x 1 1/4 SLOT
        slot = match_slot_size(s)
        if slot
          result.kind = :slot
          result.value = slot
          result.units = :in
          result.confidence = 0.95
          return result
        end

        # 2. Diameter marker: Ø13/16, 13/16 DIA
        if has_diameter_marker?(s)
          val = parse_length_token(remove_diameter_words(s))
          if val
            result.kind = :diameter
            result.value = val
            result.units = :in
            result.confidence = 0.95
            return result
          end
        end

        # 3. Radius marker: R2.5, RAD 1/2
        if has_radius_marker?(s)
          val = parse_length_token(remove_radius_words(s))
          if val
            result.kind = :radius
            result.value = val
            result.units = :in
            result.confidence = 0.90
            return result
          end
        end

        # 4. Feet-inches: 1'-4", 5' 6 1/2"
        fi = parse_feet_inches(s)
        if fi
          result.kind = :linear
          result.value = fi
          result.units = :in
          result.confidence = 0.95
          return result
        end

        # 5. Imperial fraction/decimal with inch mark
        imp = parse_imperial(s)
        if imp
          result.kind = :linear
          result.value = imp
          result.units = :in
          result.confidence = 0.85
          return result
        end

        # 6. Metric: 406.4 mm, 25 cm
        met = parse_metric(s)
        if met
          result.kind = :linear
          result.value = met[:value]
          result.units = met[:units]
          result.confidence = 0.90
          return result
        end

        # 7. Scale: 1/4" = 1'-0", 1:50
        sc = parse_scale(s)
        if sc
          result.kind = :scale
          result.value = sc
          result.units = nil
          result.confidence = 0.80
          return result
        end

        # 8. Plain number (ambiguous)
        if s =~ /\A\s*(\d+(?:\.\d+)?)\s*\z/
          result.kind = :linear
          result.value = $1.to_f
          result.units = :unknown
          result.confidence = 0.40
          result.warnings << "Ambiguous plain number — units unknown"
          return result
        end

        result.confidence = 0.1
        result.warnings << "Could not parse dimension text"
        result
      end

      private

      # ── Normalization ────────────────────────────────────────────
      def self.normalize(text)
        s = text.dup
        s.gsub!(/[\u2018\u2019\u201C\u201D]/, "'")  # smart quotes
        s.gsub!(/\u2013|\u2014/, '-')                 # en/em dash
        s.gsub!(/\u2044/, '/')                        # fraction slash
        s.gsub!(/DIA\.?/i, 'DIA')
        s.gsub!(/\bHOLES?\b/i, 'HOLE')
        s.gsub!(/\bSLOTS?\b/i, 'SLOT')
        s.gsub!(/\s+/, ' ')
        s.strip
      end

      # ── Quantity extraction ──────────────────────────────────────
      def self.extract_quantity(s)
        # (4) 13/16, 4-13/16, 2x Ø3/4
        if s =~ /\A\s*\((\d+)\)/
          return $1.to_i
        end
        if s =~ /\A\s*(\d+)\s*[-xX]\s*(?:Ø|\d)/
          return $1.to_i
        end
        nil
      end

      # ── Slot size ────────────────────────────────────────────────
      def self.match_slot_size(s)
        if s =~ /(\d+(?:\.\d+)?(?:\s*\/\s*\d+)?)\s*"?\s*[xX×]\s*(\d+(?:\.\d+)?(?:\s+\d+\s*\/\s*\d+)?(?:\s*\/\s*\d+)?)\s*"?\s*(?:SLOT|SSL|LSL)/i
          w = parse_length_token($1)
          l = parse_length_token($2)
          return { width: w, length: l } if w && l
        end
        nil
      end

      # ── Diameter / Radius markers ────────────────────────────────
      def self.has_diameter_marker?(s)
        s =~ /Ø|DIA\b|\bHOLE\b/i
      end

      def self.has_radius_marker?(s)
        s =~ /\AR\s*\d|RAD\b/i
      end

      def self.remove_diameter_words(s)
        s.gsub(/Ø|DIA\b|\bHOLE\b|\(\d+\)|\d+\s*[-xX]\s*/i, ' ').strip
      end

      def self.remove_radius_words(s)
        s.gsub(/\AR\s*|\bRAD\b/i, ' ').strip
      end

      # ── Feet-inches ──────────────────────────────────────────────
      def self.parse_feet_inches(s)
        if s =~ /(\d+(?:\.\d+)?)\s*['']\s*[-–]?\s*(\d+(?:\.\d+)?)?\s*(?:(\d+)\s*\/\s*(\d+))?\s*[""]?\s*\z/
          feet = $1.to_f
          inches = $2 ? $2.to_f : 0.0
          inches += $3.to_f / $4.to_f if $3 && $4 && $4.to_f != 0
          return feet * 12.0 + inches
        end
        nil
      end

      # ── Imperial fraction/decimal ────────────────────────────────
      def self.parse_imperial(s)
        # Mixed: 1 1/2", 3 3/4
        if s =~ /(\d+)\s+(\d+)\s*\/\s*(\d+)\s*[""]?/
          return $1.to_f + ($3.to_f != 0 ? $2.to_f / $3.to_f : 0.0)
        end
        # Pure fraction: 13/16, 15/16"
        if s =~ /\A\s*(\d+)\s*\/\s*(\d+)\s*[""]?\s*\z/
          return $1.to_f / $2.to_f
        end
        # Decimal with inch mark: 0.8125", 12.5"
        if s =~ /(\d+(?:\.\d+)?)\s*[""]/ 
          return $1.to_f
        end
        nil
      end

      # ── Metric ───────────────────────────────────────────────────
      def self.parse_metric(s)
        if s =~ /(\d+(?:\.\d+)?)\s*(MM|CM|M)\b/i
          val = $1.to_f
          unit = $2.upcase.to_sym
          return { value: val, units: unit }
        end
        nil
      end

      # ── Scale ────────────────────────────────────────────────────
      def self.parse_scale(s)
        if s =~ /(\d+(?:\.\d+)?(?:\s*\/\s*\d+)?)\s*"?\s*=\s*(\S+)/
          return { from: $1, to: $2 }
        end
        if s =~ /(\d+)\s*:\s*(\d+)/
          return { ratio: [$1.to_f, $2.to_f] }
        end
        nil
      end

      # ── Generic length token → Float ─────────────────────────────
      def self.parse_length_token(s)
        return nil unless s
        s = s.strip.gsub(/["']\z/, '')

        # Mixed: 1 1/4
        if s =~ /\A(\d+)\s+(\d+)\s*\/\s*(\d+)\z/
          return $1.to_f + ($3.to_f != 0 ? $2.to_f / $3.to_f : 0.0)
        end
        # Fraction: 13/16
        if s =~ /\A(\d+)\s*\/\s*(\d+)\z/
          return $1.to_f / $2.to_f
        end
        # Decimal
        if s =~ /\A(\d+(?:\.\d+)?)\z/
          return $1.to_f
        end
        nil
      end

    end
  end
end
