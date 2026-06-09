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
        root = resolve_corpus_root
        return nil unless root

        rel = relative_name.to_s
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
        nil
      end

      def require_corpus_root
        root = resolve_corpus_root
        raise "PDF corpus not found. Set BCS_CORPUS_ROOT or place files under C:/1pdf-test-corpus." unless root
        root
      end
    end
  end
end
