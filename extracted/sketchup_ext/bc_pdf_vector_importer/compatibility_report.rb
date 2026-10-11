# bc_pdf_vector_importer/compatibility_report.rb
# Runtime compatibility diagnostics for support and troubleshooting.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'rbconfig'
require File.join(File.dirname(__FILE__), 'safe_temp')

module BlueCollarSystems
  module PDFVectorImporter
    module CompatibilityReport
      REDACTED_PATH_DETAIL = '[path redacted]'.freeze

      class << self
        def show
          report = build_report
          saved_path = save_report(report)
          copied = copy_to_clipboard(report)
          print_to_console(report)
          # SketchUp 2017 through 2023.0 have no clipboard API: open the
          # saved report in the PC's text editor so it can still be shared.
          opened = !copied && saved_path ? open_report_file(saved_path) : false

          lines = []
          lines << "Compatibility report generated."
          lines << ""
          if copied
            lines << "Clipboard: Copied"
          else
            lines << "Clipboard: Not available in this SketchUp version."
          end
          report_file = if saved_path
                          'Saved locally (path hidden for privacy)'
                        else
                          'Not available'
                        end
          lines << "Report file: #{report_file}"
          lines << ""
          lines.concat(summary_lines(report))
          lines << ""
          lines << if copied
                     "Use the clipboard or Ruby Console to access the full report."
                   elsif opened
                     "The full report opened in #{text_editor_name}. " \
                       'It is also printed in Window > Ruby Console.'
                   else
                     'The full report is printed in Window > Ruby Console.'
                   end
          UI.messagebox(lines.join("\n"))
        rescue StandardError => e
          Logger.error("CompatibilityReport", "show failed", e)
          UI.messagebox(
            "Compatibility report failed.\n" \
            'See the local importer log for diagnostic details, then retry.'
          )
        end

        def build_report
          model = safe_call { Sketchup.active_model }
          entities = model ? safe_call { model.active_entities } : nil
          status = dependency_status
          pdftocairo = status[:pdftocairo]
          mutool = status[:mutool]
          pdftotext = status[:pdftotext]
          pdffonts = status[:pdffonts]
          ghostscript = status[:ghostscript]

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
          lines << "Extension Directory: #{REDACTED_PATH_DETAIL}"
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
          lines << path_capability_line("Bundled bin folder ready", status[:bundled_bin], DependencyResolver.bundled_bin_dir)
          lines << path_capability_line("pdftocairo found", !pdftocairo.nil?, pdftocairo)
          lines << path_capability_line("mutool found", !mutool.nil?, mutool)
          lines << path_capability_line("pdftotext found", !pdftotext.nil?, pdftotext)
          lines << path_capability_line("pdffonts found", !pdffonts.nil?, pdffonts)
          lines << path_capability_line("Ghostscript found", !ghostscript.nil?, ghostscript)
          lines << ""
          lines << "[Feature Impact]"
          lines.concat(feature_impact_lines(model, entities, pdftocairo, mutool, pdftotext, pdffonts, ghostscript))
          lines << ""
          lines << "[Other PDF extensions]"
          others = other_pdf_extensions
          if others.empty?
            lines << "- None found."
          else
            others.each { |entry| lines << "- #{entry}" }
            lines << "- Another PDF importer may answer File > Import for .pdf files; " \
                     "if results differ from this importer, turn it off in Window > Extension Manager."
          end
          missing = DependencyResolver.missing_recommended(status)
          unless missing.empty?
            lines << ""
            lines << "[Recommended Downloads]"
            DependencyResolver.download_lines(missing).each { |line| lines << line }
          end
          lines << ""
          lines << "[Notes]"
          lines << "- This report is safe to share for support diagnostics."
          lines << "- Local executable and extension paths are redacted."
          lines << "- Test PDFs are regression examples; importer behavior should generalize to supported PDFs on any supported PC."

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

        def dependency_status
          DependencyResolver.scan
        rescue StandardError
          {}
        end

        def capability_line(label, ok, detail = nil)
          state = ok ? "OK" : "MISSING"
          if detail && !detail.to_s.empty?
            "#{label}: #{state} (#{detail})"
          else
            "#{label}: #{state}"
          end
        end

        def path_capability_line(label, ok, detail)
          redacted = if detail && !detail.to_s.empty?
                       REDACTED_PATH_DETAIL
                     end
          capability_line(label, ok, redacted)
        end

        def importer_registered?
          importer = BlueCollarSystems::PDFVectorImporter
          importer.respond_to?(:importer_registered?) && importer.importer_registered? == true
        rescue StandardError
          false
        end

        # Helper status and what works, taken from the already redacted
        # report text, so the box can never show a local path.
        def summary_lines(report)
          helpers = []
          impact = []
          others = []
          section = nil
          report.to_s.split("\n").each do |line|
            if line =~ /\A\[(.+)\]\z/
              section = $1
              next
            end
            next if line.strip.empty?
            case section
            when 'Capabilities'
              if line =~ /found:|Bundled bin folder ready:/
                helpers << "- #{line.sub(/ \(\[path redacted\]\)\z/, '')}"
              end
            when 'Feature Impact'
              impact << line
            when 'Other PDF extensions'
              others << line
            end
          end
          lines = ['Helpers:'] + helpers
          lines << '' << 'What works:'
          lines.concat(impact)
          lines << '' << 'Other PDF extensions:'
          lines.concat(others)
          lines
        end

        def open_report_file(saved_path)
          return false unless UI.respond_to?(:openURL)
          path = saved_path.to_s.tr('\\', '/')
          path = path.gsub('%', '%25').gsub(' ', '%20').gsub('#', '%23')
          path = path.sub(%r{\A/+}, '')
          UI.openURL("file:///#{path}")
          true
        rescue StandardError => e
          Logger.warn("CompatibilityReport", "open report failed: #{e.class}")
          false
        end

        # UI.openURL opens the report in whatever program Windows has set
        # for .txt files, which is usually, but not always, Notepad.
        def text_editor_name
          platform = safe_call { Sketchup.platform }
          platform.to_s =~ /win/i ? 'your text editor (usually Notepad)' : 'your text editor'
        end

        # Loaded extensions other than this one whose name or description
        # mentions PDF (for example a second PDF importer).
        def other_pdf_extensions
          return [] unless defined?(Sketchup) && Sketchup.respond_to?(:extensions)
          list = Sketchup.extensions
          return [] unless list.respond_to?(:each)
          found = []
          list.each do |extension|
            name = extension_text(extension, :name)
            creator = extension_text(extension, :creator)
            next if creator =~ /BlueCollar/i || name == 'PDF Vector Importer'
            next unless "#{name} #{extension_text(extension, :description)}" =~ /pdf/i
            next if extension.respond_to?(:loaded?) && !extension.loaded?
            version = extension_text(extension, :version)
            entry = name.dup
            entry << " #{version}" unless version.empty?
            entry << " by #{creator}" unless creator.empty?
            found << entry
          end
          found
        rescue StandardError
          []
        end

        def extension_text(extension, attribute)
          return '' unless extension.respond_to?(attribute)
          extension.send(attribute).to_s.strip
        rescue StandardError
          ''
        end

        def feature_impact_lines(model, entities, pdftocairo, mutool, pdftotext, pdffonts, ghostscript)
          lines = []
          lines << "- Core vector parser: Built-in Ruby parser available; no helper executable required for baseline vector extraction."

          if !html_dialog_supported?
            lines << "- Dialog UI: Using basic input boxes (HtmlDialog unavailable)."
          else
            lines << "- Dialog UI: Modern HtmlDialog enabled."
          end

          if !(defined?(Sketchup::Importer) ? true : false)
            lines << "- File > Import hook: Not available; use Extensions > PDF Vector Importer > Import PDF..."
          elsif importer_registered?
            lines << "- File > Import hook: Available."
          else
            lines << "- File > Import hook: Not registered; use Extensions > PDF Vector Importer > Import PDF..."
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
          elsif mutool
            lines << "- SVG/geometry text render: Enabled via mutool."
          else
            lines << "- SVG/geometry text render: Disabled (pdftocairo/mutool not found)."
          end

          if pdftotext
            lines << "- External text extraction: Enabled via pdftotext."
          else
            lines << "- External text extraction: Disabled (internal parser fallback)."
          end

          if pdffonts && ghostscript
            lines << "- Non-embedded font repair: Enabled via pdffonts + Ghostscript."
          elsif pdffonts && !ghostscript
            lines << "- Non-embedded font repair: Detection enabled, repair disabled (Ghostscript not found)."
          elsif ghostscript && !pdffonts
            lines << "- Non-embedded font repair: Ghostscript found, but pdffonts preflight unavailable."
          else
            lines << "- Non-embedded font repair: Disabled (pdffonts/Ghostscript not found)."
          end

          lines
        end

        def save_report(report)
          # Preserve the host details behind each returned support artifact.
          # Another SketchUp process must not replace this report in place.
          dir = SafeTemp.mktmpdir('bc_compat_')
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
