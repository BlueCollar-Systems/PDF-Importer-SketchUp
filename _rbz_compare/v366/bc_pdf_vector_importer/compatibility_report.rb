# bc_pdf_vector_importer/compatibility_report.rb
# Runtime compatibility diagnostics for support and troubleshooting.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'tmpdir'
require 'rbconfig'

module BlueCollarSystems
  module PDFVectorImporter
    module CompatibilityReport
      class << self
        def show
          report = build_report
          saved_path = save_report(report)
          copied = copy_to_clipboard(report)
          print_to_console(report)

          lines = []
          lines << "Compatibility report generated."
          lines << ""
          lines << "Clipboard: #{copied ? 'Copied' : 'Not available'}"
          lines << "Report file: #{saved_path || 'Not available'}"
          lines << ""
          lines << "Full report also printed to Ruby Console."
          UI.messagebox(lines.join("\n"))
        rescue StandardError => e
          Logger.error("CompatibilityReport", "show failed", e)
          UI.messagebox("Compatibility report failed:\n#{e.message}")
        end

        def build_report
          model = safe_call { Sketchup.active_model }
          entities = model ? safe_call { model.active_entities } : nil
          pdftocairo = find_pdftocairo
          pdftotext = find_pdftotext

          lines = []
          lines << "=== PDF Vector Importer Compatibility Report ==="
          lines << "Generated: #{Time.now}"
          lines << ""
          lines << "[Environment]"
          lines << "SketchUp Version: #{safe_call { Sketchup.version } || 'unknown'}"
          lines << "SketchUp Version Number: #{safe_call { Sketchup.version_number } || 'unknown'}"
          lines << "SketchUp Platform: #{safe_call { Sketchup.platform } || 'unknown'}"
          lines << "SketchUp Pro: #{safe_call { Sketchup.is_pro? } || 'unknown'}"
          lines << "Ruby Version: #{RUBY_VERSION}"
          lines << "Ruby Patchlevel: #{defined?(RUBY_PATCHLEVEL) ? RUBY_PATCHLEVEL : 'unknown'}"
          lines << "Ruby Engine: #{defined?(RUBY_ENGINE) ? RUBY_ENGINE : 'ruby'}"
          lines << "Ruby Platform: #{RUBY_PLATFORM}"
          lines << "Host OS: #{safe_call { RbConfig::CONFIG['host_os'] } || 'unknown'}"
          lines << "Plugin Version: #{defined?(PLUGIN_VERSION) ? PLUGIN_VERSION : 'unknown'}"
          lines << ""
          lines << "[Capabilities]"
          lines << capability_line("UI::HtmlDialog available", html_dialog_supported?)
          lines << capability_line("UI.select_directory available", UI.respond_to?(:select_directory))
          lines << capability_line("UI clipboard API available", UI.respond_to?(:set_clipboard_data))
          lines << capability_line("Sketchup::Importer available", defined?(Sketchup::Importer) ? true : false)
          lines << capability_line("Model available", !model.nil?)
          lines << capability_line("Entities#add_image available", entities_responds?(entities, :add_image))
          lines << capability_line("Entities#add_3d_text available", entities_responds?(entities, :add_3d_text))
          lines << capability_line("Model#line_styles available", line_styles_supported?(model))
          lines << capability_line("pdftocairo found", !pdftocairo.nil?, pdftocairo)
          lines << capability_line("pdftotext found", !pdftotext.nil?, pdftotext)
          lines << ""
          lines << "[Feature Impact]"
          lines.concat(feature_impact_lines(model, entities, pdftocairo, pdftotext))
          lines << ""
          lines << "[Notes]"
          lines << "- This report is safe to share for support diagnostics."
          lines << "- It includes environment versions and local executable paths."

          lines.join("\n")
        end

        private

        def safe_call
          yield
        rescue StandardError
          nil
        end

        def entities_responds?(entities, method_name)
          return false unless entities
          entities.respond_to?(method_name)
        rescue StandardError
          false
        end

        def html_dialog_supported?
          return false unless defined?(UI::HtmlDialog)
          true
        rescue StandardError
          false
        end

        def line_styles_supported?(model)
          return false unless model && model.respond_to?(:line_styles)
          styles = model.line_styles
          !styles.nil?
        rescue StandardError
          false
        end

        def find_pdftocairo
          return nil unless defined?(SvgTextRenderer)
          SvgTextRenderer.find_pdftocairo
        rescue StandardError
          nil
        end

        def find_pdftotext
          return nil unless defined?(ExternalTextExtractor)
          ExternalTextExtractor.send(:pdftotext_executable)
        rescue StandardError
          nil
        end

        def capability_line(label, ok, detail = nil)
          state = ok ? "OK" : "MISSING"
          if detail && !detail.to_s.empty?
            "#{label}: #{state} (#{detail})"
          else
            "#{label}: #{state}"
          end
        end

        def feature_impact_lines(model, entities, pdftocairo, pdftotext)
          lines = []
          if !html_dialog_supported?
            lines << "- Dialog UI: Using basic input boxes (HtmlDialog unavailable)."
          else
            lines << "- Dialog UI: Modern HtmlDialog enabled."
          end

          if !(defined?(Sketchup::Importer) ? true : false)
            lines << "- File > Import hook: Not available; use Extensions/Plugins menu import."
          else
            lines << "- File > Import hook: Available."
          end

          if !entities_responds?(entities, :add_image)
            lines << "- Raster fallback: Not available (Entities#add_image missing)."
          else
            lines << "- Raster fallback: Available."
          end

          if !line_styles_supported?(model)
            lines << "- Native line styles: Not available; dashed lines use physical segment fallback."
          else
            lines << "- Native line styles: Available."
          end

          if pdftocairo
            lines << "- SVG/geometry text render: Enabled via pdftocairo."
          else
            lines << "- SVG/geometry text render: Disabled (pdftocairo not found)."
          end

          if pdftotext
            lines << "- External text extraction: Enabled via pdftotext."
          else
            lines << "- External text extraction: Disabled (internal parser fallback)."
          end

          lines
        end

        def save_report(report)
          dir = File.join(Dir.tmpdir, 'bc_pdf_importer')
          begin
            Dir.mkdir(dir) unless File.directory?(dir)
          rescue StandardError
            # directory might already exist or be non-creatable
          end

          path = File.join(dir, 'compatibility_report.txt')
          File.open(path, 'w') { |f| f.write(report) }
          path
        rescue StandardError => e
          Logger.warn("CompatibilityReport", "save_report failed: #{e.message}")
          nil
        end

        def copy_to_clipboard(report)
          return false unless UI.respond_to?(:set_clipboard_data)
          UI.set_clipboard_data(report)
          true
        rescue StandardError => e
          Logger.warn("CompatibilityReport", "copy_to_clipboard failed: #{e.message}")
          false
        end

        def print_to_console(report)
          puts report
        rescue StandardError
          # Ruby console may be unavailable.
        end
      end
    end
  end
end
