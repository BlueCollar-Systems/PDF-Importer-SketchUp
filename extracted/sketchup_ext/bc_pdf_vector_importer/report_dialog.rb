# bc_pdf_vector_importer/report_dialog.rb
# Post-import report v3 — plain-English summary, confidence language,
# guided next steps, post-import action prompt.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module ReportDialog

      # ---------------------------------------------------------------
      # Non-blocking completion notice (default on every import).
      # Owner rule: NO gratuitous every-import modal. A concise result
      # goes to the status bar; the full plain-English summary lives in
      # import_report.json and Extensions > Import Health (on demand).
      # ---------------------------------------------------------------
      def self.announce(stats)
        return unless defined?(Sketchup) && Sketchup.respond_to?(:status_text=)
        Sketchup.status_text = completion_status(stats)
      rescue StandardError
        nil
      end

      # One end-of-import line: pages imported, any page delivered as a raster
      # image (with the reason), and any page that failed and was skipped.
      def self.completion_status(stats)
        pg = (stats[:pages] || 0).to_i
        edges = stats[:edges] || 0
        text = stats[:text] || 0
        elapsed = stats[:elapsed_seconds]
        time_str = elapsed ? " — #{elapsed}s" : ""
        failed = failed_page_records(stats)
        head = failed.empty? ? 'PDF import complete' : 'PDF import finished with problems'
        line = "#{head} — #{pg} page#{pg == 1 ? '' : 's'}, " \
               "#{edges} edges, #{text} text#{time_str}."
        raster = raster_fallback_pages(stats)
        unless raster.empty?
          line += " Raster image page#{raster.length == 1 ? '' : 's'}: " +
                  raster.map { |page, reason| "#{page} (#{short_raster_reason(reason)})" }.join(', ') + '.'
        end
        skipped = inline_image_skipped_pages(stats)
        unless skipped.empty?
          line += " Inline images not placed on page#{skipped.length == 1 ? '' : 's'} " +
                  format_page_list(skipped.map { |entry| entry[0] }) + ' (vectors kept).'
        end
        unless failed.empty?
          line += " Failed page#{failed.length == 1 ? '' : 's'} skipped: " +
                  format_page_list(failed.map { |f| f[:page] }) + '.'
        end
        line + ' See Extensions > Import Health for details.'
      end

      RASTER_REASON_TEXT = {
        'inline_image_paint_order_requires_terminal_page_raster' =>
          'the page contains inline images, so Auto/Hybrid delivered the ' \
          'whole page as one verified image',
        'visible_nontext_source_only' =>
          'the page has no importable vector or text content (image/scan only)'
      }.freeze

      RASTER_REASON_SHORT = {
        'inline_image_paint_order_requires_terminal_page_raster' => 'inline images',
        'visible_nontext_source_only' => 'image-only page'
      }.freeze

      def self.stat_value(entry, key)
        return nil unless entry.is_a?(Hash)
        entry.key?(key) ? entry[key] : entry[key.to_s]
      end

      # [[page, reason_code], ...] for pages the importer delivered as a raster
      # image although the user did not ask for Raster.
      def self.raster_fallback_pages(stats)
        seen = {}
        Array(stat_value(stats, :page_representation_fallbacks)).each do |entry|
          next unless stat_value(entry, :delivered_mode).to_s == 'raster'
          next if stat_value(entry, :explicit_request) == true
          page = stat_value(entry, :page).to_i
          next if page <= 0 || seen.key?(page)
          seen[page] = stat_value(entry, :reason_code).to_s
        end
        seen.keys.sort.map { |page| [page, seen[page]] }
      rescue StandardError
        []
      end

      def self.short_raster_reason(code)
        RASTER_REASON_SHORT[code.to_s] || (code.to_s.empty? ? 'raster fallback' : code.to_s.tr('_', ' '))
      end

      def self.long_raster_reason(code)
        RASTER_REASON_TEXT[code.to_s] || short_raster_reason(code)
      end

      # Pages whose vector paths were kept although the page also paints
      # inline (BI/ID/EI) images. The SketchUp host does not yet place inline
      # images as image entities, so say so instead of implying they landed.
      def self.inline_image_skipped_pages(stats)
        Array(stat_value(stats, :inline_image_vector_retentions)).map do |entry|
          [stat_value(entry, :page).to_i,
           stat_value(entry, :inline_image_instance_count).to_i]
        end.select { |page, count| page > 0 && count > 0 }.sort
      rescue StandardError
        []
      end

      def self.failed_page_records(stats)
        Array(stat_value(stats, :failed_pages)).map do |entry|
          {
            :page => stat_value(entry, :page).to_i,
            :error_class => stat_value(entry, :error_class).to_s,
            :message => stat_value(entry, :message).to_s
          }
        end
      rescue StandardError
        []
      end

      def self.cancelled_status(stats)
        retained = Array(stats[:retained_pages]).map { |page| page.to_i }.sort
        kept = if retained.empty?
                 'no completed pages kept'
               elsif retained.length == 1
                 "page #{retained.first} kept"
               else
                 "pages #{format_page_list(retained)} kept"
               end
        resume = stats[:next_page] ?
          "; resume starts at page #{stats[:next_page].to_i}" : ''
        "PDF import cancelled — #{kept}#{resume}."
      end

      def self.announce_cancelled(stats)
        return unless defined?(Sketchup) && Sketchup.respond_to?(:status_text=)
        Sketchup.status_text = cancelled_status(stats)
      rescue StandardError
        nil
      end

      # ---------------------------------------------------------------
      # On-demand summary (Import Health / menu only — never auto-fired
      # as a blocking modal after import).
      # ---------------------------------------------------------------
      def self.show_report(stats)
        msg = build_summary(stats)
        UI.messagebox(msg)
      end

      # ---------------------------------------------------------------
      # Build the plain-English summary
      # ---------------------------------------------------------------
      def self.build_summary(stats)
        lines = []
        cancelled = stats[:cancelled] == true
        lines << (cancelled ? 'Import Cancelled' : 'Import Complete!')
        lines << ""

        if cancelled
          retained = Array(stats[:retained_pages]).map { |page| page.to_i }.sort
          if retained.empty?
            lines << 'No completed pages were kept.'
          elsif retained.length == 1
            lines << "Page #{retained.first} was kept."
          else
            lines << "Pages #{format_page_list(retained)} were kept."
          end
          if stats[:next_page]
            lines << "Resume starts at page #{stats[:next_page].to_i}."
          end
          lines << ''
        end

        # What happened
        pg = stats[:pages] || 0
        elapsed = stats[:elapsed_seconds]
        time_str = elapsed ? " in #{elapsed}s" : ""
        lines << "#{pg} page#{pg == 1 ? '' : 's'} imported successfully#{time_str}."

        edges = stats[:edges] || 0
        lines << "#{edges} edges created." if edges > 0

        faces = stats[:faces] || 0
        lines << "#{faces} faces created." if faces > 0

        arcs = stats[:arcs] || 0
        lines << "#{arcs} curves rebuilt as arcs." if arcs > 0

        text = stats[:text] || 0
        if text > 0
          mode_label = case stats[:text_mode]
                       when :geometry then "as geometry"
                       when :glyphs then "as glyph geometry"
                       when :text3d then "as 3D text"
                       when :labels then "as labels"
                       else ""
                       end
          lines << "#{text} text items imported#{mode_label.empty? ? '.' : ' ' + mode_label + '.'}"
        end

        append_text_renderer_lines(lines, stats)

        failures = Array(stats[:text_delivery_failures])
        unless failures.empty?
          lines << ""
          lines << "#{failures.length} text span(s) were not certified; " \
                   'geometry and certified text were kept.'
          failures.first(8).each do |failure|
            source_id = (failure[:source_span_id] ||
                         failure['source_span_id']).to_s
            reason = (failure[:reason] || failure['reason']).to_s
            lines << "  #{source_id}: #{reason}" unless source_id.empty?
          end
        end

        append_unattended_run_lines(lines, stats)

        comps = stats[:components] || 0
        lines << "#{comps} repeated symbols converted to components." if comps > 0

        # PDF layers
        if stats[:layers] && !stats[:layers].empty?
          lines << "#{stats[:layers].length} PDF layers mapped to Tags."
        end
        if stats[:layer_warning]
          lines << stats[:layer_warning]
        end

        # Document analysis (generic recognition)
        if stats[:generic]
          g = stats[:generic]
          lines << ""

          # Describe what the document looks like
          profile = g[:profile]
          case profile
          when :fabrication
            lines << "This looks like a fabrication/shop drawing."
          when :cad_drawing
            lines << "This looks like a CAD/technical drawing."
          when :architectural
            lines << "This looks like an architectural plan."
          when :vector_art
            lines << "This looks like vector artwork or a logo."
          when :raster_only
            lines << "This page appears to be scanned (no vectors found)."
          else
            lines << "Document type: #{profile}"
          end

          circles = g[:circles] || 0
          lines << "#{circles} circles detected." if circles > 0

          tb = g[:title_block]
          lines << "Title block detected." if tb

          patterns = g[:patterns] || 0
          lines << "#{patterns} repeated geometry patterns found." if patterns > 0

          tables = g[:tables] || 0
          lines << "#{tables} table regions found." if tables > 0

          dims = g[:dimensions] || 0
          lines << "#{dims} dimensions associated with geometry." if dims > 0
        end

        # Cleanup summary
        if stats[:cleanup] && !stats[:cleanup].empty?
          cleaned = stats[:cleanup].select { |_, v| v > 0 }
          if cleaned.any?
            lines << ""
            lines << "Cleanup: " + cleaned.map { |k, v| "#{v} #{k}" }.join(", ")
          end
        end

        # Recognition mode used
        if stats[:mode_used]
          lines << ""
          lines << "Detection mode: #{stats[:mode_used]}"
        end

        # Quality confidence
        lines << ""
        total = (edges + faces + arcs)
        if total > 50
          lines << "Import quality: High — good vector content."
        elsif total > 10
          lines << "Import quality: Moderate — some geometry imported."
        elsif total > 0
          lines << "Import quality: Low — limited vector content found."
        else
          lines << "No geometry was found in this PDF."
        end

        log_path = stats[:log_path].to_s
        unless log_path.empty?
          lines << ""
          lines << "Import log:"
          lines << log_path
        end

        lines.join("\n")
      end

      def self.append_unattended_run_lines(lines, stats)
        raster = raster_fallback_pages(stats)
        unless raster.empty?
          lines << ""
          lines << "#{raster.length} page(s) were imported as a raster image " \
                   'instead of editable geometry:'
          raster.each do |page, code|
            lines << "  Page #{page}: #{long_raster_reason(code)}."
          end
        end

        skipped = inline_image_skipped_pages(stats)
        unless skipped.empty?
          lines << ""
          lines << 'Vector geometry and text were kept on pages that also contain ' \
                   'inline images; those inline images were not placed:'
          skipped.each do |page, count|
            lines << "  Page #{page}: #{count} inline image piece(s) (for example a logo or stamp)."
          end
        end

        failed = failed_page_records(stats)
        unless failed.empty?
          lines << ""
          lines << "#{failed.length} page(s) failed and were skipped; the " \
                   'other pages were imported:'
          failed.each do |failure|
            lines << "  Page #{failure[:page]}: #{failure[:message]}"
          end
        end

        heavy = Array(stat_value(stats, :complexity_notices))
        unless heavy.empty?
          pages = heavy.map { |entry| stat_value(entry, :page) }
          lines << ""
          lines << "Large page(s) imported without stopping for confirmation: " \
                   "#{format_page_list(pages)}."
        end
      end

      def self.append_text_renderer_lines(lines, stats)
        entries = stats[:text_renderers] || []
        return if entries.empty?

        grouped = {}
        entries.each do |entry|
          renderer = entry[:renderer] || entry['renderer'] || :unknown
          degraded = entry[:degraded] || entry['degraded'] ? true : false
          key = [renderer.to_s, degraded]
          grouped[key] ||= []
          grouped[key] << entry
        end

        lines << ""
        lines << "Text renderer details:"
        grouped.keys.sort.each do |key|
          renderer_key, degraded = key
          pages = grouped[key].map { |entry| entry[:page] || entry['page'] }
          page_word = pages.compact.length == 1 ? "page" : "pages"
          notes = grouped[key].map { |entry| entry[:note] || entry['note'] }.compact.map(&:to_s).reject(&:empty?).uniq
          note_suffix = degraded && !notes.empty? ? " — #{notes.join('; ')}" : ""
          suffix = degraded ? " (degraded)#{note_suffix}." : "."
          lines << "#{text_renderer_label(renderer_key)}: #{page_word} #{format_page_list(pages)}#{suffix}"
        end
        if dense_glyph_component_text?(entries)
          lines << "Dense text used reusable glyph components for performance; outlines remain vector geometry."
        end
      end

      def self.dense_glyph_component_text?(entries)
        Array(entries).any? do |entry|
          mode = entry[:text_performance_mode] || entry['text_performance_mode']
          mode.to_s == 'glyph_components'
        end
      rescue StandardError
        false
      end

      def self.text_renderer_label(renderer)
        case renderer.to_s
        when 'pdftocairo'
          'Poppler SVG (pdftocairo)'
        when 'mutool'
          'MuPDF SVG (mutool)'
        when 'add_3d_text'
          'SketchUp 3D text fallback'
        when 'labels'
          'SketchUp label fallback'
        when 'internal_parser'
          'Internal PDF text parser'
        else
          renderer.to_s.empty? ? 'Unknown text renderer' : renderer.to_s
        end
      end

      def self.format_page_list(pages)
        nums = pages.compact.map { |p| p.to_i }.select { |p| p > 0 }.sort.uniq
        return "" if nums.empty?

        ranges = []
        start_page = nums[0]
        prev_page = nums[0]
        nums[1..-1].to_a.each do |page|
          if page == prev_page + 1
            prev_page = page
          else
            ranges << page_range_label(start_page, prev_page)
            start_page = page
            prev_page = page
          end
        end
        ranges << page_range_label(start_page, prev_page)
        ranges.join(', ')
      end

      def self.page_range_label(first_page, last_page)
        first_page == last_page ? first_page.to_s : "#{first_page}-#{last_page}"
      end

      # ---------------------------------------------------------------
      # Post-import next-step actions
      # ---------------------------------------------------------------
      def self.show_next_steps(stats)
        total = (stats[:edges] || 0) + (stats[:faces] || 0)
        return if total == 0

        prompts = ["What would you like to do next?"]
        defaults = ["Continue working"]
        options = [
          "Continue working|" \
          "View Geometry Only (hide text)|" \
          "Scale by Reference|" \
          "Run Cleanup on imported groups|" \
          "Show Feature Inventory"
        ]

        result = UI.inputbox(prompts, defaults, options, "Next Steps")
        return unless result

        case result[0]
        when /Geometry Only/
          geometry_only
        when /Scale by Reference/
          ScaleTool.activate
        when /Cleanup/
          BlueCollarSystems::PDFVectorImporter.cleanup_selected
        when /Feature Inventory/
          BlueCollarSystems::PDFVectorImporter.feature_inventory
        end
      end

      # ---------------------------------------------------------------
      # Tag visibility controls
      # ---------------------------------------------------------------
      def self.show_visibility_menu
        model = Sketchup.active_model
        return unless model

        tags = model.layers.to_a.select { |l| pdf_layer_name?(l.name) }
        if tags.empty?
          UI.messagebox("No PDF tags found. Import a PDF first.")
          return
        end

        prompts = tags.map { |t| "#{t.name}:" }
        defaults = tags.map { |t| t.visible? ? 'Visible' : 'Hidden' }
        dropdowns = tags.map { 'Visible|Hidden' }

        result = UI.inputbox(prompts, defaults, dropdowns, "PDF Tag Visibility")
        return unless result

        result.each_with_index do |val, i|
          tags[i].visible = (val == 'Visible')
        end
      end

      def self.geometry_only
        model = Sketchup.active_model
        return unless model
        model.layers.each do |l|
          next unless pdf_layer_name?(l.name)
          # Keep hidden/dashed geometry visible; only hide annotation-like layers.
          if l.name =~ /Text|Dimension|TitleBlock|Notes/i || l.name =~ /:Text\z/i
            l.visible = false
          else
            l.visible = true
          end
        end
      end

      def self.show_all
        model = Sketchup.active_model
        return unless model
        model.layers.each { |l| l.visible = true if pdf_layer_name?(l.name) }
      end

      def self.pdf_layer_name?(name)
        n = name.to_s
        imported = PDFVectorImporter.last_import_layer_names
        return true if imported.include?(n)
        return true if n.start_with?('PDF::')
        return true if n =~ /\APDF(?:\b|:|\s)/i
        return true if n == 'Dashed' || n == 'Dashdot' || n == 'Dash Dot'
        false
      end

    end
  end
end
