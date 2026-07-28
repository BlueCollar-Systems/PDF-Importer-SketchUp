# bc_pdf_vector_importer/dependency_resolver.rb
# Locate bundled and system PDF helper executables with clear user guidance.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require File.join(File.dirname(__FILE__), 'command_runner')
require 'digest'
require 'json'

module BlueCollarSystems
  module PDFVectorImporter
    module DependencyResolver
      PREF_KEY = 'bc_pdf_vector_importer'.freeze
      PREF_NOTICE = 'dependency_notice_shown'.freeze
      PINNED_MEMBER_INVENTORY_SHA256 =
        'a2c5d125fee4f3af1893556501efd50455a953ed7eb77c8a0d094819db2f5654'.freeze
      RUNTIME_MEMBER_KEYS = %w[bytes category path sha256].freeze

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
        def support_dir
          File.dirname(__FILE__)
        end

        def bundled_runtime_manifest
          path = File.join(support_dir, 'poppler-runtime-manifest.json')
          return nil unless File.file?(path)
          parsed = JSON.parse(File.read(path))
          parsed.is_a?(Hash) ? parsed : nil
        rescue StandardError => e
          safe_warn('DependencyResolver', "bundled runtime manifest invalid: #{e.message}")
          nil
        end

        def bundled_bin_dir
          File.join(support_dir, 'Library', 'bin')
        end

        def bundled_bin_ready?
          # The reviewed payload is the pinned Windows PE runtime. Never mark
          # it usable on a non-Windows SketchUp host.
          return false unless windows?

          root = File.expand_path(support_dir)
          return true if @verified_bundled_runtime_root == root

          manifest = bundled_runtime_manifest
          return false unless manifest
          layout = manifest['layout']
          review = manifest['license_review']
          return false unless manifest['schema'] == 1
          return false unless layout.is_a?(Hash)
          return false unless layout['bin'] == 'Library/bin'
          return false unless layout['data'] == 'share/poppler'
          return false unless layout['manifest'] == 'poppler-runtime-manifest.json'
          return false unless review.is_a?(Hash) && review['status'] == 'approved'
          return false unless Array(review['missing']).empty?
          return false if review['reviewer'].to_s.strip.empty?
          return false if review['evidence'].to_s.strip.empty?
          reviewed_at = review['reviewed_at'].to_s
          return false unless reviewed_at =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
          return false unless bundled_runtime_integrity_valid?(root, manifest)

          # The immutable runtime is verified once per SketchUp session. A
          # failed/blocked verification is deliberately not cached so a
          # transactionally installed approved runtime can be discovered.
          @verified_bundled_runtime_root = root
          true
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

        def bundled_runtime_integrity_valid?(root, manifest)
          members = manifest['members']
          return false unless members.is_a?(Array)

          normalized = []
          expected_files = {}
          members.each do |entry|
            return false unless entry.is_a?(Hash)
            return false unless entry.keys.sort == RUNTIME_MEMBER_KEYS
            rel = entry['path']
            bytes = entry['bytes']
            digest = entry['sha256']
            return false unless safe_runtime_member_path?(rel)
            return false unless bytes.is_a?(Integer) && bytes >= 0
            return false unless digest.is_a?(String) && digest =~ /\A[0-9a-f]{64}\z/
            return false if expected_files.key?(rel)

            expected_files[rel] = entry
            normalized << {
              'bytes' => bytes,
              'category' => entry['category'],
              'path' => rel,
              'sha256' => digest
            }
          end
          canonical = JSON.generate(normalized.sort_by { |entry| entry['path'] })
          return false unless Digest::SHA256.hexdigest(canonical) ==
                              PINNED_MEMBER_INVENTORY_SHA256

          actual_files, actual_dirs = runtime_tree_inventory(root)
          return false unless actual_files.keys.sort == expected_files.keys.sort

          expected_dirs = {}
          expected_files.each_key do |rel|
            parts = rel.split('/')
            (1...parts.length).each do |length|
              expected_dirs[parts[0, length].join('/')] = true
            end
          end
          return false unless actual_dirs.keys.sort == expected_dirs.keys.sort

          expected_files.each do |rel, entry|
            path = actual_files[rel]
            return false unless File.size(path) == entry['bytes']
            return false unless sha256_file(path) == entry['sha256']
          end
          true
        rescue StandardError => e
          safe_warn('DependencyResolver',
            "bundled runtime integrity verification failed: #{e.message}")
          false
        end

        def safe_runtime_member_path?(rel)
          return false unless rel.is_a?(String) && !rel.empty?
          return false if rel.include?('\\') || rel.start_with?('/')
          parts = rel.split('/')
          return false if parts.any? { |part| part.empty? || part == '.' || part == '..' }
          parts[0] == 'Library' || parts[0, 2] == %w[share poppler]
        end

        def runtime_tree_inventory(root)
          legacy = File.join(root, 'bin')
          raise 'legacy direct bin payload is present' if File.exist?(legacy) || File.symlink?(legacy)

          files = {}
          dirs = {}
          %w[Library share].each do |relative_root|
            runtime_root = File.join(root, relative_root)
            raise "runtime root missing: #{relative_root}" unless File.directory?(runtime_root)
            raise "runtime root is a symlink: #{relative_root}" if File.symlink?(runtime_root)
            dirs[relative_root] = true
            pattern = File.join(runtime_root, '**', '*')
            Dir.glob(pattern, File::FNM_DOTMATCH).each do |path|
              base = File.basename(path)
              next if base == '.' || base == '..'
              rel = path[(root.length + 1)..-1].to_s.tr('\\', '/')
              raise "runtime member is a symlink: #{rel}" if File.symlink?(path)
              if File.directory?(path)
                dirs[rel] = true
              elsif File.file?(path)
                files[rel] = path
              else
                raise "runtime member is not a regular file: #{rel}"
              end
            end
          end
          [files, dirs]
        end

        def sha256_file(path)
          digest = Digest::SHA256.new
          File.open(path, 'rb') do |io|
            while (chunk = io.read(1024 * 1024))
              digest.update(chunk)
            end
          end
          digest.hexdigest
        end

        def bundled_executable(name)
          return nil unless bundled_bin_ready?
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
