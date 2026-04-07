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
                       when :text3d then "as 3D text"
                       when :labels then "as labels"
                       else ""
                       end
          lines << "#{text} text items imported#{mode_label.empty? ? '.' : ' ' + mode_label + '.'}"
        end

        comps = stats[:components] || 0
        lines << "#{comps} repeated symbols converted to components." if comps > 0

        # PDF layers
        if stats[:layers] && !stats[:layers].empty?
          lines << "#{stats[:layers].length} PDF layers mapped to Tags."
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
        return true if n.start_with?('PDF::')
        return true if n =~ /\APDF(?:\b|:|\s)/i
        return true if n == 'Dashed' || n == 'Dashdot' || n == 'Dash Dot'
        false
      end

    end
  end
end
