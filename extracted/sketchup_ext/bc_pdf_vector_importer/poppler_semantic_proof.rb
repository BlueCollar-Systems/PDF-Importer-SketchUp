# bc_pdf_vector_importer/poppler_semantic_proof.rb
# Exact fixture certificate plus strict full-page failure evidence.
# Ruby 2.2 compatible (SketchUp Make 2017).

require 'digest'
require 'json'

module BlueCollarSystems
  module PDFVectorImporter
    module PopplerSemanticProof
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
        certificate = certificate_for_svg_page(pdf_path, page_number)
        return nil unless certificate
        for_certificate(pdf_path, page_number, certificate)
      end

      def self.certificate_for_svg_page(pdf_path, page_number)
        certificate = ADOBE_GB1_PAGE_CERTIFICATE
        return nil unless page_number.to_i == certificate[:page].to_i
        return nil unless file_sha256(pdf_path.to_s) ==
                          certificate[:pdf_sha256].to_s.downcase
        certificate
      rescue StandardError
        nil
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

      # Absence is not evidence of success. Every collection must be supplied
      # by the post-render source matcher/placement boundary as an Array, and
      # every one must be empty.
      def self.complete_failure_evidence?(evidence)
        return false unless evidence.is_a?(Hash)
        FAILURE_COLLECTIONS.all? do |key|
          evidence.key?(key) && evidence[key].is_a?(Array) &&
            evidence[key].empty?
        end
      rescue StandardError
        false
      end

      def self.certified_svg_evidence?(evidence, certificate)
        return false unless evidence.is_a?(Hash)
        return false unless evidence[:renderer] == :pdftocairo
        return false unless evidence[:representation] == :glyph_geometry
        return false unless complete_failure_evidence?(evidence)
        glyphs = evidence[:glyphs]
        placements = evidence[:placements]
        return false unless glyphs.is_a?(Hash) && placements.is_a?(Array)
        return false unless glyphs.length == certificate[:glyph_count].to_i
        return false unless placements.length ==
                            certificate[:placement_count].to_i

        unoutlined = placements.map do |placement|
          placement[:glyph_id].to_s
        end.reject { |glyph_id| glyphs.key?(glyph_id) }.uniq.sort
        allowed = Array(certificate[:allowed_unoutlined_glyph_ids]).map do |id|
          id.to_s
        end.uniq.sort
        return false unless unoutlined == allowed

        semantic_fingerprint(evidence) ==
          certificate[:semantic_sha256].to_s.downcase
      rescue StandardError
        false
      end

      def self.semantic_fingerprint(evidence)
        glyphs = evidence[:glyphs]
        placements = evidence[:placements]
        payload = {
          'glyphs' => glyphs.keys.sort.map do |glyph_id|
            [glyph_id, glyphs[glyph_id]]
          end,
          'placements' => placements.map do |placement|
            [
              placement[:glyph_id].to_s,
              format('%.6f', placement[:x].to_f),
              format('%.6f', placement[:y].to_f),
              Array(placement[:matrix]).map do |value|
                format('%.6f', value.to_f)
              end
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
