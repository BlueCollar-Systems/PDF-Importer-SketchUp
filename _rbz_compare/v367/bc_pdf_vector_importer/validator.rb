# bc_pdf_vector_importer/validator.rb
# Compares dimension text to geometry. Fixed field names.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module Validator

      ValidationResult = Struct.new(
        :status, :feature_type, :dimension_text, :expected_value,
        :measured_value, :error_abs, :error_pct, :suggestion, :prim_id
      )

      def self.validate(recognition_results, text_items = [], opts = {})
        tol_pct = opts[:tolerance_percent] || 2.0
        tol_abs = opts[:tolerance_abs] || 0.015
        results = []

        # Validate holes
        (recognition_results[:holes] || []).each do |hole|
          next unless hole.diameter_note
          measured = hole.diameter_geom
          expected = hole.diameter_note
          error = (measured - expected).abs
          error_pct = expected > 0 ? (error / expected) * 100.0 : 0

          status = if error < tol_abs || error_pct < tol_pct then :ok
                   elsif error_pct < tol_pct * 3 then :warning
                   else :mismatch end

          suggestion = nil
          if status != :ok
            suggestion = "Hole: geometry #{format('%.4f', measured)} vs " \
                         "callout #{format('%.4f', expected)}, " \
                         "diff=#{format('%.4f', error)}"
          end

          results << ValidationResult.new(
            status, :hole, hole.diameter_note.to_s, expected, measured,
            error, error_pct, suggestion, hole.source_prim_id
          )
        end

        # Validate plates
        (recognition_results[:plates] || []).each do |plate|
          (plate.dimension_texts || []).each do |dim|
            next unless dim.is_a?(Hash) && dim[:value]
            expected = dim[:value].to_f
            next unless expected > 0

            w = plate.width_geom || 0
            h = plate.height_geom || 0
            candidates = [
              { label: 'width',  val: w },
              { label: 'height', val: h }
            ]
            best = candidates.min_by { |c| (c[:val] - expected).abs }
            measured = best[:val]
            error = (measured - expected).abs
            error_pct = expected > 0 ? (error / expected) * 100.0 : 0

            status = if error < tol_abs || error_pct < tol_pct then :ok
                     elsif error_pct < tol_pct * 3 then :warning
                     else :mismatch end

            suggestion = status != :ok ?
              "Plate #{best[:label]}: #{format('%.3f', measured)} vs dim #{format('%.3f', expected)}" : nil

            results << ValidationResult.new(
              status, :plate, dim[:text].to_s, expected, measured,
              error, error_pct, suggestion, plate.outer_prim_id
            )
          end
        end

        results
      end

      def self.report(results)
        return "No features validated." if results.empty?
        ok = results.count { |r| r.status == :ok }
        warn = results.count { |r| r.status == :warning }
        bad = results.count { |r| r.status == :mismatch }
        lines = ["Validation: #{ok} OK, #{warn} warnings, #{bad} mismatches"]
        results.select { |r| r.status != :ok }.first(5).each do |r|
          lines << "  #{r.suggestion}" if r.suggestion
        end
        lines.join("\n")
      end

    end
  end
end
