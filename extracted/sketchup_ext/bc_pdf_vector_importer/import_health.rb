# bc_pdf_vector_importer/import_health.rb
# At-a-glance last import snapshot for support and self-diagnosis.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module ImportHealth

      @snapshot = nil

      module_function

      def record!(stats, pdf_path = nil)
        return unless stats.is_a?(Hash)

        @snapshot = {
          pdf_path: pdf_path.to_s,
          import_report_path: stats[:import_report_path].to_s,
          log_path: stats[:log_path].to_s,
          text_mode: stats[:text_mode].to_s,
          actual_text_entity_types: stats[:actual_text_entity_types],
          performance_hint: stats[:performance_hint].to_s,
          resolved_scale: stats[:resolved_scale],
          elapsed_seconds: stats[:elapsed_seconds],
          pages: stats[:pages].to_i,
          edges: stats[:edges].to_i,
          text: stats[:text].to_i,
          layers: Array(stats[:layers]).length,
          human_summary: stats[:human_summary].to_s,
          scale_crosscheck: stats[:scale_crosscheck],
          import_contract_ready: stats[:import_contract_ready],
          representation_fidelity: stats[:representation_fidelity],
          result_status: stat_value(stats, :result_status).to_s,
          requested_pages: stat_value(stats, :requested_pages),
          retained_pages: stat_value(stats, :retained_pages),
          failed_pages: Array(stat_value(stats, :failed_pages)),
          cancelled: stat_value(stats, :cancelled) == true,
          recorded_at: Time.now
        }
      end

      def snapshot
        @snapshot
      end

      def show
        snap = @snapshot
        unless snap
          UI.messagebox(
            "No import recorded yet in this SketchUp session.\n\n" \
            "Run Import PDF... first, then reopen Import Health to see timing, " \
            "text mode, scale, and the import_report.json path."
          )
          return
        end

        lines = []
        lines << 'Import Health — last run'
        lines << ''
        lines << "PDF: #{short_path(snap[:pdf_path])}" unless snap[:pdf_path].to_s.empty?
        lines << "Pages: #{snap[:pages]}  |  Time: #{snap[:elapsed_seconds]}s"
        lines << "Edges: #{snap[:edges]}  |  Text: #{snap[:text]}  |  Layers: #{snap[:layers]}"
        lines << "Text mode: #{snap[:text_mode].empty? ? 'n/a' : snap[:text_mode]}"

        failed_pages = snap[:failed_pages].map do |entry|
          stat_value(entry, :page).to_i
        end.select { |page| page > 0 }.uniq.sort
        requested = Array(snap[:requested_pages]).map { |page| page.to_i }
        retained = Array(snap[:retained_pages]).map { |page| page.to_i }
        missing = requested - retained
        has_page_ledger = !snap[:requested_pages].nil? ||
                          !snap[:retained_pages].nil?
        pages_ready = snap[:failed_pages].empty? && !snap[:cancelled] &&
          (snap[:result_status].empty? || snap[:result_status] == 'success')
        if has_page_ledger
          pages_ready &&= snap[:requested_pages].is_a?(Array) &&
            snap[:retained_pages].is_a?(Array) && missing.empty? &&
            (retained - requested).empty?
          lines << "Requested pages: #{requested.join(', ')}"
          lines << "Retained pages: #{retained.join(', ')}"
        end
        status = if snap[:cancelled] || snap[:result_status] == 'cancelled'
                   'cancelled'
                 elsif !pages_ready
                   'incomplete'
                 else
                   snap[:result_status]
                 end
        lines << "Result: #{status}" unless status.empty?
        unless snap[:failed_pages].empty?
          numbers = failed_pages.empty? ? 'unknown' : failed_pages.join(', ')
          lines << "Failed pages: #{numbers}"
          snap[:failed_pages].each do |entry|
            message = stat_value(entry, :message).to_s
            next if message.empty?
            lines << "Page #{stat_value(entry, :page)}: #{message}"
          end
        end
        lines << "Pages not retained: #{missing.join(', ')}" unless missing.empty?

        contract = snap[:import_contract_ready]
        ready = contract.is_a?(Hash) &&
          (contract[:ready] == true || contract['ready'] == true) &&
          pages_ready
        lines << "QA contract: #{ready ? 'READY' : 'NOT READY'}"
        unless ready
          fidelity = snap[:representation_fidelity]
          errors = if fidelity.is_a?(Hash)
                     fidelity[:errors] || fidelity['errors']
                   end
          errors = contract[:errors] || contract['errors'] if
            Array(errors).empty? && contract.is_a?(Hash)
          unless Array(errors).empty?
            lines << "Fidelity errors: #{Array(errors).join(', ')}"
          end
        end

        entity_info = snap[:actual_text_entity_types]
        if entity_info.is_a?(Hash) && entity_info[:count].to_i > 0
          bucket = entity_info[:entity_type] || entity_info['entity_type'] || snap[:text_mode]
          lines << "Text entities: #{entity_info[:count] || entity_info['count']} as #{bucket}"
        end

        perf_hint = snap[:performance_hint].to_s.strip
        unless perf_hint.empty?
          lines << ''
          lines << "Performance: #{perf_hint}"
        end

        scale = snap[:resolved_scale]
        if scale.is_a?(Hash) && scale[:factor]
          notation = scale[:notation] || scale['notation']
          factor = scale[:factor] || scale['factor']
          lines << "Scale: #{notation || factor} (#{scale[:source] || scale['source'] || 'resolved'})"
        else
          lines << 'Scale: not resolved (use Scale to Real Dimensions if needed)'
        end

        crosscheck = snap[:scale_crosscheck]
        if crosscheck.is_a?(Hash)
          banner = crosscheck[:banner] || crosscheck['banner']
          unless banner.to_s.strip.empty?
            lines << ''
            lines << "Scale warning: #{banner}"
          end
        end

        lines << ''
        unless snap[:human_summary].to_s.empty?
          lines << 'Summary:'
          lines << snap[:human_summary].to_s
          lines << ''
        end

        lines << "import_report.json:"
        lines << short_path(snap[:import_report_path])
        lines << ''
        lines << 'Import log:'
        lines << short_path(snap[:log_path])

        UI.messagebox(lines.join("\n"))
      end

      def short_path(path)
        text = path.to_s
        return 'n/a' if text.empty?
        return text if text.length <= 72
        "...#{text[-69, 69]}"
      end

      def stat_value(hash, key)
        return nil unless hash.is_a?(Hash)
        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

    end
  end
end
