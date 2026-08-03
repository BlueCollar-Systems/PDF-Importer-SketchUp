# corpus_paths.rb - Resolve private validation PDF paths via BCS_PRIVATE_VALIDATION_ROOT.
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'json'

module BlueCollarSystems
  module PDFVectorImporter
    module CorpusPaths
      DEFAULT_CORPUS_ROOTS = [].freeze

      class AcceptanceInputError < StandardError; end

      # Scan profiles for private validation CI (phase 1). Earlier entries win on
      # duplicate corpus_key collisions.
      CORPUS_SCAN_PROFILES = [
        { subdir: 'private/user', recursive: false, tag: 'private_validation_user' },
        { subdir: 'private/web', recursive: true, tag: 'private_validation_web' },
        { subdir: 'private-secondary/web', recursive: true, tag: 'private_validation_secondary_web' },
        { subdir: 'web-acquired', recursive: true, tag: 'private_validation_external' },
        { subdir: nil, recursive: false, tag: 'private_validation_root' }
      ].freeze

      module_function

      def resolve_private_validation_root(candidates = nil)
        env_root = ENV['BCS_PRIVATE_VALIDATION_ROOT'] || ENV['PDF_PRIVATE_VALIDATION_ROOT']
        ordered = []
        ordered << env_root if env_root && !env_root.to_s.strip.empty?
        ordered.concat(Array(candidates || DEFAULT_CORPUS_ROOTS))
        ordered.each do |root|
          path = root.to_s
          return File.expand_path(path) if File.directory?(path)
        end
        nil
      end

      def configured_private_validation_root
        values = [
          ENV['BCS_PRIVATE_VALIDATION_ROOT'],
          ENV['PDF_PRIVATE_VALIDATION_ROOT']
        ].compact.map { |value| value.to_s.strip }.reject { |value| value.empty? }
        return nil if values.empty?

        paths = values.map { |value| File.expand_path(value) }
        comparison_paths = if File::ALT_SEPARATOR
                             paths.map { |path| path.downcase }
                           else
                             paths
                           end
        if comparison_paths.uniq.length > 1
          raise AcceptanceInputError,
                'Configured private validation roots are ambiguous'
        end

        path = paths.first
        unless File.directory?(path)
          raise AcceptanceInputError,
                'Configured private validation root does not exist or is not a directory'
        end
        path
      end

      def resolve_corpus_pdf(relative_name, subdir: '')
        rel = relative_name.to_s
        corpus_scan_roots.each do |root|
          search_dirs = [root]
          search_dirs.unshift(File.join(root, subdir)) unless subdir.to_s.empty?
          %w[private/user private/web private-secondary/web web-acquired pdfs].each do |folder|
            candidate = File.join(root, folder)
            search_dirs << candidate if File.directory?(candidate)
          end

          # Allow manifest-style paths relative to private validation root (e.g. private/user/foo.pdf)
          if rel.include?('/')
            nested = File.join(root, rel.tr('/', File::SEPARATOR))
            return File.expand_path(nested) if File.file?(nested)
          end

          search_dirs.each do |base|
            direct = File.join(base, rel)
            return File.expand_path(direct) if File.file?(direct)
            unless File.extname(rel).casecmp('.pdf').zero?
              with_pdf = File.join(base, "#{File.basename(rel)}.pdf")
              return File.expand_path(with_pdf) if File.file?(with_pdf)
            end
          end
        end
        nil
      end

      def require_private_validation_root
        root = resolve_private_validation_root
        raise "Private validation PDFs not found. Set BCS_PRIVATE_VALIDATION_ROOT." unless root
        root
      end

      # Ordered roots used by private validation CI. An explicit private
      # validation root restricts the scan to that root.
      def corpus_scan_roots
        env_root = ENV['BCS_PRIVATE_VALIDATION_ROOT'] || ENV['PDF_PRIVATE_VALIDATION_ROOT']
        if env_root && !env_root.to_s.strip.empty?
          path = File.expand_path(env_root)
          return File.directory?(path) ? [path] : []
        end
        DEFAULT_CORPUS_ROOTS.map { |root| File.expand_path(root) }.select { |path| File.directory?(path) }.uniq
      end

      # Collect unique PDFs from all configured corpus locations.
      # Returns Array<Hash> with :path, :corpus_key, :source_root, :tag.
      def collect_corpus_pdfs
        pdfs = []
        corpus_scan_roots.each do |root|
          is_env_root = !!(ENV['BCS_PRIVATE_VALIDATION_ROOT'] || ENV['PDF_PRIVATE_VALIDATION_ROOT']) &&
                        File.expand_path(root) == File.expand_path(
                          (ENV['BCS_PRIVATE_VALIDATION_ROOT'] || ENV['PDF_PRIVATE_VALIDATION_ROOT']).to_s
                        )
          CORPUS_SCAN_PROFILES.each do |profile|
            scan_dir = profile[:subdir] ? File.join(root, profile[:subdir]) : root
            next unless File.directory?(scan_dir)
            glob = profile[:recursive] ? '**/*.{pdf,Pdf,PDF}' : '*.{pdf,Pdf,PDF}'
            Dir.glob(File.join(scan_dir, glob)).sort.each do |pdf_path|
              next unless File.file?(pdf_path)
              rel = pdf_path.sub("#{scan_dir}/", '').sub("#{scan_dir}\\", '')
              tag = profile[:tag]
              tag = 'env_private_validation' if is_env_root && profile[:subdir].nil?
              corpus_key = "#{tag}/#{rel}"
              pdfs << {
                path: File.expand_path(pdf_path),
                corpus_key: corpus_key,
                source_root: scan_dir,
                tag: tag
              }
            end
          end
        end

        dedup = {}
        pdfs.each do |info|
          dedup[info[:corpus_key]] ||= info
        end
        dedup.values.sort_by { |info| info[:corpus_key].downcase }
      end

      def baseline_slug(corpus_key)
        slug = baseline_key_to_slug(canonical_baseline_key(corpus_key))[0, 120] + '.json'
      end

      def baseline_slug_candidates(corpus_key)
        key = corpus_key.to_s
        keys = [canonical_baseline_key(key)]
        keys.uniq.map do |candidate|
          baseline_key_to_slug(candidate)[0, 120] + '.json'
        end
      end

      def baseline_key_to_slug(corpus_key)
        slug = corpus_key.to_s.gsub(/[^a-zA-Z0-9]+/, '_')
        slug = slug.gsub(/^_|_$/,'')
        slug.empty? ? 'pdf' : slug
      end

      def canonical_baseline_key(corpus_key)
        key = corpus_key.to_s
        key = key.sub(%r{\Aenv_private_validation/}, 'private_validation_root/')
        key
      end

      def load_manifest(root = nil)
        private_validation_root = root || resolve_private_validation_root
        return nil unless private_validation_root

        manifest_path = File.join(private_validation_root, 'manifest.json')
        return nil unless File.file?(manifest_path)

        JSON.parse(File.read(manifest_path))
      end

      def load_acceptance_manifest(root)
        manifest_path = File.join(root, 'manifest.json')
        unless File.file?(manifest_path)
          raise AcceptanceInputError,
                'Configured private validation root manifest.json is missing'
        end
        JSON.parse(File.read(manifest_path))
      rescue JSON::ParserError, IOError, SystemCallError => e
        raise AcceptanceInputError,
              "Configured private validation manifest.json is malformed: #{e.class}"
      end

      def resolve_manifest_pdf(entry_id, root = nil)
        manifest = load_manifest(root)
        return nil unless manifest

        manifest.fetch('entries', []).each do |entry|
          next unless entry['id'].to_s == entry_id.to_s

          rel = entry['local_path']
          next if rel.to_s.empty?

          found = resolve_corpus_pdf(rel.to_s)
          return found if found
        end
        nil
      end

      def resolve_acceptance_pdf(acceptance_key, override_env = nil)
        root = configured_private_validation_root
        entries = nil
        if root
          manifest = load_acceptance_manifest(root)
          entries = manifest.is_a?(Hash) ? manifest['entries'] : nil
          unless entries.is_a?(Array)
            raise AcceptanceInputError,
                  'Configured private validation manifest.json entries must be an array'
          end
          unless entries.all? { |candidate| candidate.is_a?(Hash) }
            raise AcceptanceInputError,
                  'Configured private validation manifest.json entries must contain objects'
          end
        end

        override_value = override_env ? ENV[override_env.to_s].to_s.strip : ''
        unless override_value.empty?
          override_path = File.expand_path(override_value)
          is_pdf = File.extname(override_path).casecmp('.pdf').zero?
          unless is_pdf && File.file?(override_path) && File.readable?(override_path)
            raise AcceptanceInputError,
                  "Configured #{override_env} does not resolve to a readable PDF"
          end
          return override_path
        end
        return nil unless root

        matches = entries.select do |candidate|
          candidate['acceptance_key'].to_s == acceptance_key.to_s
        end
        if matches.empty?
          raise AcceptanceInputError,
                "Required acceptance_key #{acceptance_key.inspect} was not found in manifest.json"
        end
        if matches.length > 1
          raise AcceptanceInputError,
                "Required acceptance_key #{acceptance_key.inspect} is ambiguous in manifest.json"
        end
        entry = matches.first

        relative_path = entry['local_path'].to_s.tr('\\/', File::SEPARATOR)
        if relative_path.strip.empty?
          raise AcceptanceInputError,
                "Required acceptance_key #{acceptance_key.inspect} has no local_path"
        end
        path = File.expand_path(File.join(root, relative_path))
        root_prefix = File.expand_path(root) + File::SEPARATOR
        inside_root = path.downcase.start_with?(root_prefix.downcase)
        is_pdf = File.extname(path).casecmp('.pdf').zero?
        unless inside_root && is_pdf && File.file?(path) && File.readable?(path)
          raise AcceptanceInputError,
                "Required acceptance_key #{acceptance_key.inspect} does not resolve to a readable PDF"
        end
        path
      end
    end
  end
end
