# corpus_paths.rb — Resolve PDF test corpus paths without Desktop-specific absolutes.
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module CorpusPaths
      DEFAULT_CORPUS_ROOTS = [
        'C:/1pdf-test-corpus',
        File.join(Dir.home, 'Desktop', 'PDFTest Files'),
        'C:/Users/Rowdy Payton/Desktop/PDFTest Files'
      ].freeze

      # Scan profiles for corpus placement CI (phase 1). Earlier entries win on
      # duplicate corpus_key collisions.
      CORPUS_SCAN_PROFILES = [
        { subdir: 'PDFTest Files', recursive: false, tag: 'corpus_pdftest' },
        { subdir: 'New folder (2)', recursive: true, tag: 'corpus_new_folder' },
        { subdir: nil, recursive: false, tag: 'corpus_root' }
      ].freeze

      DESKTOP_SCAN_PROFILES = [
        { subdir: 'PDFTest Files', recursive: false, tag: 'desktop_pdftest' },
        { subdir: 'New folder (2)', recursive: true, tag: 'desktop_new_folder' }
      ].freeze

      module_function

      def resolve_corpus_root(candidates = nil)
        env_root = ENV['BCS_CORPUS_ROOT'] || ENV['PDF_TEST_CORPUS']
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
          %w[PDFTest\ Files pdfs New\ folder\ (2)].each do |folder|
            candidate = File.join(root, folder)
            search_dirs << candidate if File.directory?(candidate)
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

      def require_corpus_root
        root = resolve_corpus_root
        raise "PDF corpus not found. Set BCS_CORPUS_ROOT or place files under C:/1pdf-test-corpus." unless root
        root
      end

      # Ordered roots used by corpus placement CI. Honors BCS_CORPUS_ROOT first,
      # then canonical corpus + Desktop mirrors.
      def corpus_scan_roots
        roots = []
        env_root = ENV['BCS_CORPUS_ROOT'] || ENV['PDF_TEST_CORPUS']
        roots << File.expand_path(env_root) if env_root && !env_root.to_s.strip.empty?
        roots.concat(DEFAULT_CORPUS_ROOTS)
        roots << File.join(Dir.home, 'Desktop', 'New folder (2)')
        roots << 'C:/Users/Rowdy Payton/Desktop/New folder (2)'
        seen = {}
        roots.each do |root|
          path = File.expand_path(root.to_s)
          next unless File.directory?(path)
          next if seen[path]
          seen[path] = true
        end
        seen.keys
      end

      # Collect unique PDFs from all configured corpus locations.
      # Returns Array<Hash> with :path, :corpus_key, :source_root, :tag.
      def collect_corpus_pdfs
        pdfs = []
        corpus_scan_roots.each do |root|
          is_env_root = !!(ENV['BCS_CORPUS_ROOT'] || ENV['PDF_TEST_CORPUS']) &&
                        File.expand_path(root) == File.expand_path(
                          (ENV['BCS_CORPUS_ROOT'] || ENV['PDF_TEST_CORPUS']).to_s
                        )
          profiles = CORPUS_SCAN_PROFILES
          profiles = DESKTOP_SCAN_PROFILES if desktop_mirror_root?(root)
          profiles.each do |profile|
            scan_dir = profile[:subdir] ? File.join(root, profile[:subdir]) : root
            next unless File.directory?(scan_dir)
            glob = profile[:recursive] ? '**/*.{pdf,Pdf,PDF}' : '*.{pdf,Pdf,PDF}'
            Dir.glob(File.join(scan_dir, glob)).sort.each do |pdf_path|
              next unless File.file?(pdf_path)
              rel = pdf_path.sub("#{scan_dir}/", '').sub("#{scan_dir}\\", '')
              tag = profile[:tag]
              tag = 'env_corpus' if is_env_root && profile[:subdir].nil?
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

      def desktop_mirror_root?(root)
        home = Dir.home.to_s.downcase
        path = File.expand_path(root).downcase
        path.include?('/desktop/') || path.include?('\\desktop\\') ||
          path.start_with?(home) && path.include?('desktop')
      end

      def baseline_slug(corpus_key)
        slug = corpus_key.to_s.gsub(/[^a-zA-Z0-9]+/, '_')
        slug = slug.gsub(/^_|_$/,'')
        slug = 'pdf' if slug.empty?
        slug[0, 120] + '.json'
      end
    end
  end
end
