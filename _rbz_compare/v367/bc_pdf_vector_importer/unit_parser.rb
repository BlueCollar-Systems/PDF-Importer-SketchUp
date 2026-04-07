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
      #   "120"           → 120.0 (assumes model units)
      # ---------------------------------------------------------------
      def self.parse_inches(text)
        return nil unless text.is_a?(String)
        text = text.strip
        return nil if text.empty?

        # 1. Feet-inches compound: 5'-6"  5' 6 1/2"  5ft 6in  1'-4
        result = try_feet_inches(text)
        return result if result

        # 2. Mixed number + unit: 1 1/2 in  3 3/4 ft
        result = try_mixed(text)
        return result if result

        # 3. Pure fraction + unit: 3/8  1/2 in
        result = try_fraction(text)
        return result if result

        # 4. Decimal + unit: 406.4 mm  4.92 in  120
        result = try_decimal(text)
        return result if result

        nil
      end

      # ---------------------------------------------------------------
      # Parse a dimension string → value in the model's current unit.
      # Convenience for the scale tool — uses SketchUp's unit settings.
      # ---------------------------------------------------------------
      def self.parse_model_units(text)
        # First try SketchUp's built-in parser
        begin
          len = text.to_l
          return len.to_f  # returns inches
        rescue StandardError => e
          Logger.warn("UnitParser", "parse_model_units SketchUp parse failed: #{e.message}")
        end
        parse_inches(text)
      end

      private

      def self.try_feet_inches(text)
        # Pattern: 5'-6"  5'-6 1/2"  5' 6"  5ft 6in  5'6  1'-4
        if text =~ /\A\s*(\d+(?:\.\d+)?)\s*(?:'|ft|feet)\s*[-–]?\s*(\d+(?:\.\d+)?)?\s*(?:(\d+)\s*\/\s*(\d+))?\s*(?:"|in|inch|inches)?\s*\z/i
          feet = $1.to_f
          inches = $2 ? $2.to_f : 0.0
          if $3 && $4 && $4.to_f != 0
            frac = $3.to_f / $4.to_f
            inches += frac
          end
          return feet * 12.0 + inches
        end
        nil
      end

      def self.try_mixed(text)
        # Pattern: 1 1/2 in  3 3/4 ft  2 5/8
        if text =~ /\A\s*(\d+(?:\.\d+)?)\s+(\d+)\s*\/\s*(\d+)\s*([a-zA-Z"']+)?\s*\z/
          whole = $1.to_f
          frac = $3.to_f != 0 ? $2.to_f / $3.to_f : 0.0
          unit_str = $4
          value = whole + frac
          factor = unit_factor(unit_str)
          return value * factor
        end
        nil
      end

      def self.try_fraction(text)
        # Pattern: 1/2  3/8 in  1/4"
        if text =~ /\A\s*(\d+)\s*\/\s*(\d+)\s*([a-zA-Z"']+)?\s*\z/
          value = $1.to_f / $2.to_f
          unit_str = $3
          factor = unit_factor(unit_str)
          return value * factor
        end
        nil
      end

      def self.try_decimal(text)
        # Pattern: 406.4 mm  4.92 in  120  2.5ft
        if text =~ /\A\s*(\d+(?:\.\d+)?)\s*([a-zA-Z"']+)?\s*\z/
          value = $1.to_f
          unit_str = $2
          factor = unit_factor(unit_str)
          return value * factor
        end
        nil
      end

      def self.unit_factor(unit_str)
        return 1.0 unless unit_str
        key = unit_str.strip.downcase.gsub(/[.]/, '')
        UNITS_TO_INCHES[key] || 1.0
      end

    end
  end
end
