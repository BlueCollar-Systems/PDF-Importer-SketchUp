# bc_pdf_vector_importer/report_dialog.rb
# Post-import report v3 — plain-English summary, confidence language,
# guided next steps, post-import action prompt.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module ReportDialog

      # ---------------------------------------------------------------
      # Show import report + offer next-step actions
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
        lines << "Import Complete!"
        lines << ""

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
