# bc_pdf_vector_importer/dependency_resolver.rb
# Locate bundled and system PDF helper executables with clear user guidance.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require File.join(File.dirname(__FILE__), 'command_runner')

module BlueCollarSystems
  module PDFVectorImporter
    module DependencyResolver
      PREF_KEY = 'bc_pdf_vector_importer'.freeze
      PREF_NOTICE = 'dependency_notice_shown'.freeze

      DOWNLOADS = {
        poppler: {
          label: 'Poppler for Windows (pdftocairo, pdftotext, pdffonts)',
          url: 'https://github.com/oschwartz10612/poppler-windows/releases/latest',
          detail: 'Official Windows RBZ builds bundle these tools. Source builds can run ' \
                  'tools/fetch_third_party_binaries.ps1 or install Poppler to Program Files.'
        },
        ghostscript: {
          label: 'Ghostscript 64-bit (font repair for non-embedded PDF fonts)',
          url: 'https://ghostscript.com/releases/gsdnld.html',
          detail: 'Install the 64-bit Windows release. The importer finds gswin64c.exe automatically.'
        }
      }.freeze

      class << self
        def bundled_bin_dir
          @bundled_bin_dir ||= File.join(File.dirname(__FILE__), 'bin')
        end

        def bundled_bin_ready?
          dir = bundled_bin_dir
          return false unless File.directory?(dir)

          names = windows? ? %w[pdftocairo.exe pdftotext.exe pdffonts.exe] : %w[pdftocairo pdftotext pdffonts]
          names.all? { |name| File.file?(File.join(dir, name)) }
        end

        def scan
          pdftocairo = find_pdftocairo
          {
            bundled_bin: bundled_bin_ready?,
            pdftocairo: pdftocairo,
            pdftotext: find_pdftotext,
            pdffonts: find_pdffonts(pdftocairo),
            ghostscript: find_ghostscript,
            mutool: find_mutool
          }
        end

        def missing_recommended(status = scan)
          missing = []
          missing << :poppler unless status[:pdftocairo] || status[:mutool]
          missing << :pdftotext unless status[:pdftotext]
          missing << :ghostscript unless status[:ghostscript]
          missing
        end

        def download_lines(missing)
          lines = []
          lines << 'Recommended helper downloads (one-time, no admin for portable ZIP installs):'
          if missing.include?(:poppler) || missing.include?(:pdftotext)
            info = DOWNLOADS[:poppler]
            lines << "- #{info[:label]}"
            lines << "  #{info[:url]}"
            lines << "  #{info[:detail]}"
          end
          if missing.include?(:ghostscript)
            info = DOWNLOADS[:ghostscript]
            lines << "- #{info[:label]}"
            lines << "  #{info[:url]}"
            lines << "  #{info[:detail]}"
          end
          lines
        end

        def build_notice_message(status = scan)
          missing = missing_recommended(status)
          return nil if missing.empty?

          lines = []
          lines << 'PDF Vector Importer — optional helpers not found'
          lines << ''
          lines << 'Core vector import works without these tools.'
          lines << 'For best text, raster, and font fidelity, install:'
          lines << ''
          lines.concat(download_lines(missing))
          lines << ''
          lines << 'After installing, use Extensions > PDF Vector Importer > Compatibility Report.'
          lines << 'Bundled copy path (if shipped):'
          lines << "  #{bundled_bin_dir}"
          lines.join("\n")
        end

        def maybe_show_first_run_notice
          return unless defined?(Sketchup) && Sketchup.respond_to?(:read_default)

          notice_key = "#{PREF_NOTICE}_#{defined?(PLUGIN_VERSION) ? PLUGIN_VERSION : 'unknown'}"
          return if Sketchup.read_default(PREF_KEY, notice_key, false)

          message = build_notice_message
          return unless message

          UI.messagebox(message)
          Sketchup.write_default(PREF_KEY, notice_key, true)
        rescue StandardError => e
          safe_warn('DependencyResolver', "first-run notice failed: #{e.message}")
        end

        def find_pdftocairo
          find_executable(
            windows? ? ['pdftocairo.exe'] : ['pdftocairo'],
            env_var: 'BC_PDFTOCAIRO_PATH',
            extra_candidates: pdftocairo_system_candidates
          )
        end

        def find_pdftotext
          find_executable(
            windows? ? ['pdftotext.exe'] : ['pdftotext'],
            env_var: 'BC_PDFTOTEXT_PATH',
            extra_candidates: pdftotext_system_candidates,
            path_probe: 'pdftotext'
          )
        end

        def find_mutool
          find_executable(
            windows? ? ['mutool.exe'] : ['mutool'],
            env_var: 'BC_MUTOOL_PATH',
            extra_candidates: mutool_system_candidates
          )
        end

        def find_pdffonts(pdftocairo_exe = find_pdftocairo)
          bundled = bundled_executable(windows? ? 'pdffonts.exe' : 'pdffonts')
          return bundled if bundled

          return nil unless pdftocairo_exe

          sibling = File.join(File.dirname(pdftocairo_exe.to_s), windows? ? 'pdffonts.exe' : 'pdffonts')
          File.exist?(sibling) ? sibling : nil
        end

        def find_ghostscript
          find_executable(
            windows? ? ['gswin64c.exe', 'gswin32c.exe'] : ['gs'],
            env_var: 'BC_GHOSTSCRIPT_PATH',
            extra_candidates: ghostscript_system_candidates
          )
        end

        private

        def windows?
          RUBY_PLATFORM =~ /mswin|mingw|cygwin/
        end

        def bundled_executable(name)
          path = File.join(bundled_bin_dir, name)
          File.file?(path) ? path : nil
        end

        def find_executable(exe_names, env_var:, extra_candidates: [], path_probe: nil)
          env = ENV[env_var.to_s]
          return env if env && !env.to_s.empty? && File.exist?(env)

          Array(exe_names).each do |name|
            bundled = bundled_executable(name)
            return bundled if bundled
          end

          extra_candidates.each do |candidate|
            return candidate if candidate && File.exist?(candidate)
          end

          if path_probe
            begin
              probe = CommandRunner.run([path_probe, '-v'],
                timeout_s: 10,
                context: "DependencyResolver.#{path_probe}_probe")
              return path_probe if probe[:ok]
            rescue StandardError => e
              safe_warn('DependencyResolver', "PATH probe failed for #{path_probe}: #{e.message}")
            end
          end

          Array(exe_names).each do |name|
            found = path_lookup(name)
            return found if found
          end

          nil
        end

        def path_lookup(exe_name)
          if windows?
            r = `where #{exe_name} 2>NUL`.strip
          else
            r = `which #{exe_name} 2>/dev/null`.strip
          end
          return nil if r.empty?

          r.split("\n").first.to_s.strip
        rescue StandardError => e
          safe_warn('DependencyResolver', "path lookup failed for #{exe_name}: #{e.message}")
          nil
        end

        def pdftocairo_system_candidates
          return [] unless windows?

          candidates = [
            'C:\\Program Files\\poppler\\Library\\bin\\pdftocairo.exe',
            'C:\\Program Files\\poppler\\bin\\pdftocairo.exe',
            'C:\\Program Files\\FreeCAD 1.1\\bin\\pdftocairo.exe'
          ]
          if ENV['LOCALAPPDATA'] && !ENV['LOCALAPPDATA'].empty?
            candidates << File.join(
              ENV['LOCALAPPDATA'],
              'Programs', 'MiKTeX', 'miktex', 'bin', 'x64', 'pdftocairo.exe'
            )
          end
          candidates << 'C:\\Program Files\\MiKTeX\\miktex\\bin\\x64\\pdftocairo.exe'
          Dir.glob('C:/Program Files/FreeCAD*/bin/pdftocairo.exe').each { |p| candidates << p }
          Dir.glob('C:/poppler*/bin/pdftocairo.exe').each { |p| candidates << p }
          Dir.glob('C:/tools/poppler*/bin/pdftocairo.exe').each { |p| candidates << p }
          candidates
        end

        def pdftotext_system_candidates
          return [] unless windows?

          candidates = [
            'C:\\Program Files\\poppler\\Library\\bin\\pdftotext.exe',
            'C:\\Program Files\\poppler\\bin\\pdftotext.exe',
            'C:\\Program Files\\FreeCAD 1.1\\bin\\pdftotext.exe',
            'C:\\Program Files\\MiKTeX\\miktex\\bin\\x64\\pdftotext.exe'
          ]
          if ENV['LOCALAPPDATA'] && !ENV['LOCALAPPDATA'].empty?
            candidates << File.join(
              ENV['LOCALAPPDATA'],
              'Programs', 'MiKTeX', 'miktex', 'bin', 'x64', 'pdftotext.exe'
            )
          end
          Dir.glob('C:/Program Files/FreeCAD*/bin/pdftotext.exe').each { |p| candidates << p }
          Dir.glob('C:/poppler*/bin/pdftotext.exe').each { |p| candidates << p }
          Dir.glob('C:/tools/poppler*/bin/pdftotext.exe').each { |p| candidates << p }
          candidates
        end

        def mutool_system_candidates
          return [] unless windows?

          candidates = [
            'C:\\Program Files\\MuPDF\\mutool.exe'
          ]
          Dir.glob('C:/Program Files/MuPDF*/mutool.exe').each { |p| candidates << p }
          Dir.glob('C:/Program Files/mupdf*/mutool.exe').each { |p| candidates << p }
          candidates
        end

        def ghostscript_system_candidates
          if windows?
            matches = []
            ['C:/Program Files/gs/gs*/bin/gswin64c.exe',
             'C:/Program Files (x86)/gs/gs*/bin/gswin32c.exe'].each do |pat|
              Dir.glob(pat).each { |p| matches << p }
            end
            return matches.sort
          end

          []
        end

        def safe_warn(context, msg)
          Logger.warn(context, msg)
        rescue StandardError
          # Logger may be unavailable in minimal test contexts.
        end
      end
    end
  end
end
