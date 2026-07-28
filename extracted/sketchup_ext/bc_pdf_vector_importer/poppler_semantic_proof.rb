# bc_pdf_vector_importer/poppler_semantic_proof.rb
# Exact, fixture-scoped proof for the only qualified Adobe-GB1 diagnostic.
# Ruby 2.2 compatible (SketchUp Make 2017).

require 'digest'
require 'json'

module BlueCollarSystems
  module PDFVectorImporter
    module PopplerSemanticProof
      # The diagnostic validator is deliberately limited to this public PDF.
      # Its certified SVG set was produced by the independently pinned complete
      # Poppler runtime.  Any other PDF/page/output fails closed; the target
      # integration's CairoGlyphSource matcher is the general proof authority.
      ADOBE_GB1_PAGE_CERTIFICATE = {
        :pdf_sha256 =>
          '988a2b0bd07f63eb6871ffaa5871d7b203614173d431cdfb9da23ed47ce7bde1',
        :page => 1,
        :glyph_count => 36,
        :placement_count => 44,
        :semantic_sha256 =>
          '286fc9e083803cefefd055592c60f4c47cf8912ad57d52718ebb2264a8c31698',
        :allowed_unoutlined_glyph_ids => %w[glyph-0-6 glyph-1-4].freeze
      }.freeze

      FAILURE_COLLECTIONS = [
        :unmatched_source_runs,
        :unmatched_placements,
        :missing_language_packs,
        :skipped_placements,
        :placement_failures
      ].freeze

      def self.for_svg_page(pdf_path, page_number)
        for_certificate(pdf_path, page_number, ADOBE_GB1_PAGE_CERTIFICATE)
      end

      def self.for_certificate(pdf_path, page_number, certificate)
        return nil unless certificate.is_a?(Hash)
        return nil unless page_number.to_i == certificate[:page].to_i
        source_path = pdf_path.to_s
        lambda do |evidence|
          file_sha256(source_path) == certificate[:pdf_sha256].to_s.downcase &&
            certified_svg_evidence?(evidence, certificate)
        end
      end

      def self.certified_svg_evidence?(evidence, certificate)
        return false unless evidence.is_a?(Hash)
        return false unless evidence[:renderer] == :pdftocairo
        return false unless evidence[:representation] == :glyph_geometry
        glyphs = evidence[:glyphs]
        placements = evidence[:placements]
        return false unless glyphs.is_a?(Hash) && placements.is_a?(Array)
        return false unless glyphs.length == certificate[:glyph_count].to_i
        return false unless placements.length == certificate[:placement_count].to_i
        return false unless FAILURE_COLLECTIONS.all? do |key|
          Array(evidence[key]).empty?
        end

        unoutlined = placements.map { |placement| placement[:glyph_id].to_s }.
          reject { |glyph_id| glyphs.key?(glyph_id) }.uniq.sort
        allowed_unoutlined = Array(certificate[:allowed_unoutlined_glyph_ids]).
          map { |glyph_id| glyph_id.to_s }.uniq.sort
        return false unless unoutlined == allowed_unoutlined

        semantic_fingerprint(evidence) == certificate[:semantic_sha256].to_s.downcase
      rescue StandardError
        false
      end

      def self.semantic_fingerprint(evidence)
        glyphs = evidence[:glyphs]
        placements = evidence[:placements]
        payload = {
          'glyphs' => glyphs.keys.sort.map { |glyph_id| [glyph_id, glyphs[glyph_id]] },
          'placements' => placements.map do |placement|
            [
              placement[:glyph_id].to_s,
              format('%.6f', placement[:x].to_f),
              format('%.6f', placement[:y].to_f),
              Array(placement[:matrix]).map { |value| format('%.6f', value.to_f) }
            ]
          end
        }
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def self.file_sha256(path)
        digest = Digest::SHA256.new
        File.open(path, 'rb') do |io|
          while (chunk = io.read(1024 * 1024))
            digest.update(chunk)
          end
        end
        digest.hexdigest
      rescue StandardError
        ''
      end
    end
  end
end
