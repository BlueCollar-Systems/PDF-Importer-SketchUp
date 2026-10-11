# bc_pdf_vector_importer/unit_parser.rb
# Parses dimension strings into inches (SketchUp's internal unit).
# Handles: feet-inches compound (5'-6"), mixed fractions (1 1/2 in),
# pure fractions (3/8"), decimals with units, and metric.
#
# Mirrors the FreeCAD version's parse_dimension_mm but outputs inches.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module UnitParser

      MAX_TEXT_BYTES = 128
      DECIMAL_NUMBER = '(?:\\d+(?:\\.\\d*)?|\\.\\d+)'.freeze
      BARE_VALUE = "(?:#{DECIMAL_NUMBER}\\s+\\d+\\s*/\\s*\\d+|\\d+\\s*/\\s*\\d+|#{DECIMAL_NUMBER})".freeze

      # Unit → inches conversion
      UNITS_TO_INCHES = {
        'in'          => 1.0,
        'inch'        => 1.0,
        'inches'      => 1.0,
        '"'           => 1.0,
        'ft'          => 12.0,
        'foot'        => 12.0,
        'feet'        => 12.0,
        "'"           => 12.0,
        'mm'          => 1.0 / 25.4,
        'millimeter'  => 1.0 / 25.4,
        'millimeters' => 1.0 / 25.4,
        'cm'          => 10.0 / 25.4,
        'centimeter'  => 10.0 / 25.4,
        'centimeters' => 10.0 / 25.4,
        'm'           => 1000.0 / 25.4,
        'meter'       => 1000.0 / 25.4,
        'meters'      => 1000.0 / 25.4,
        'yd'          => 36.0,
        'yard'        => 36.0,
        'yards'       => 36.0,
      }.freeze

      # ---------------------------------------------------------------
      # Parse a dimension string → value in inches.
      # Returns nil if unparseable.
      #
      # Examples:
      #   "5'-6\""        → 66.0
      #   "1'-4"          → 16.0
      #   "5' 6 1/2\""    → 66.5
      #   "1 1/2 in"      → 1.5
      #   "3/8"           → 0.375 (assumes inches)
      #   "406.4 mm"      → 16.0
      #   "2.5 ft"        → 30.0
      #   "120"           → 120.0 (standalone inches)
      # ---------------------------------------------------------------
      def self.parse_inches(text)
        text = normalized_input(text)
        return nil unless text

        # 1. Feet-inches compound: 5'-6"  5' 6 1/2"  5ft 6in  1'-4
        result = try_feet_inches(text)
        return finite_dimension(result) unless result.nil?

        # 2. Mixed number + unit: 1 1/2 in  3 3/4 ft
        result = try_mixed(text)
        return finite_dimension(result) unless result.nil?

        # 3. Pure fraction + unit: 3/8  1/2 in
        result = try_fraction(text)
        return finite_dimension(result) unless result.nil?

        # 4. Decimal + unit: 406.4 mm  4.92 in  120
        result = try_decimal(text)
        return finite_dimension(result) unless result.nil?

        nil
      end

      # ---------------------------------------------------------------
      # Parse a dimension string → value in the model's current unit.
      # Convenience for the scale tool — uses SketchUp's unit settings.
      # ---------------------------------------------------------------
      def self.parse_model_units(text)
        # Validate the entire grammar before the host can accept a prefix.
        inches = parse_inches(text)
        return nil if inches.nil?
        bare = /\A#{BARE_VALUE}\z/.match(normalized_input(text))
        # Explicit units have exact arithmetic and do not depend on locale.
        return inches unless bare
        # Standalone/headless use has no model-unit parser; preserve inches.
        return inches unless text.respond_to?(:to_l)
        begin
          len = text.to_l
          # Length ceased inheriting Float in SketchUp 2015.
          return nil unless len.is_a?(Numeric) || (defined?(::Length) && len.is_a?(::Length))
          return finite_dimension(len.to_f) # host storage is inches
        rescue StandardError => e
          if defined?(Logger) && Logger.respond_to?(:warn)
            Logger.warn('UnitParser', "parse_model_units SketchUp parse failed: #{e.message.to_s[0,160]}")
          end
          # A valid bare value must not silently become inches after failure
          # in a host whose model units may instead be millimeters or feet.
          nil
        end
      end

      private

      def self.normalized_input(text)
        return nil unless text.is_a?(String) && text.bytesize <= MAX_TEXT_BYTES && text.valid_encoding?
        return nil unless text.encoding.ascii_compatible?
        return nil unless text.ascii_only? || text.encoding == Encoding::UTF_8
        return nil if text =~ /[\x00-\x08\x0a-\x1f\x7f]/
        text = text.strip
        text = text[1..-1].strip if text.start_with?('+')
        text.empty? ? nil : text
      end

      def self.finite_dimension(value)
        return nil unless value.is_a?(Numeric)
        number = value.to_f
        number.finite? && number >= 0.0 ? number : nil
      end

      def self.try_feet_inches(text)
        # Pattern: 5'-6"  5'-6 1/2"  5' 6"  5ft 6in  5'6  1'-4
        match = /\A\s*(#{DECIMAL_NUMBER})\s*(?:'|ft|foot|feet)(?:\s*[-–]?\s*(#{BARE_VALUE})\s*(?:"|in|inch|inches)?)?\s*\z/i.match(text)
        if match
          feet = match[1].to_f
          inches = match[2] ? parse_inches(match[2]) : 0.0
          return nil if inches.nil?
          return feet * 12.0 + inches
        end
        nil
      end

      def self.try_mixed(text)
        # Pattern: 1 1/2 in  3 3/4 ft  2 5/8
        if text =~ /\A\s*(#{DECIMAL_NUMBER})\s+(\d+)\s*\/\s*(\d+)\s*([a-zA-Z"']+)?\s*\z/
          whole = $1.to_f
          return nil unless $3.to_f > 0.0
          frac = $2.to_f / $3.to_f
          unit_str = $4
          value = whole + frac
          factor = unit_factor(unit_str)
          return nil unless factor
          return value * factor
        end
        nil
      end

      def self.try_fraction(text)
        # Pattern: 1/2  3/8 in  1/4"
        if text =~ /\A\s*(\d+)\s*\/\s*(\d+)\s*([a-zA-Z"']+)?\s*\z/
          return nil unless $2.to_f > 0.0
          value = $1.to_f / $2.to_f
          unit_str = $3
          factor = unit_factor(unit_str)
          return nil unless factor
          return value * factor
        end
        nil
      end

      def self.try_decimal(text)
        # Pattern: 406.4 mm  4.92 in  120  2.5ft
        if text =~ /\A\s*(#{DECIMAL_NUMBER})\s*([a-zA-Z"']+)?\s*\z/
          value = $1.to_f
          unit_str = $2
          factor = unit_factor(unit_str)
          return nil unless factor
          return value * factor
        end
        nil
      end

      def self.unit_factor(unit_str)
        return 1.0 unless unit_str
        key = unit_str.strip.downcase.gsub(/[.]/, '')
        UNITS_TO_INCHES[key]
      end

    end
  end
end
