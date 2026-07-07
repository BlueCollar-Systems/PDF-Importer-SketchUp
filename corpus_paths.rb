# corpus_paths.rb - Resolve private validation PDF paths via BCS_PRIVATE_VALIDATION_ROOT.
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require 'json'

module BlueCollarSystems
  module PDFVectorImporter
    module CorpusPaths
      DEFAULT_CORPUS_ROOTS = [].freeze

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
    end
  end
end
