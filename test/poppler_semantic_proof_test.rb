require 'minitest/autorun'
require 'tmpdir'

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/poppler_semantic_proof'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class PopplerSemanticProofTest < Minitest::Test
  PROOF = BlueCollarSystems::PDFVectorImporter::PopplerSemanticProof
  IMP = BlueCollarSystems::PDFVectorImporter
  SVG = BlueCollarSystems::PDFVectorImporter::SvgTextRenderer

  def exact_evidence
    {
      :renderer => :pdftocairo,
      :representation => :glyph_geometry,
      :glyphs => {
        'glyph-a' => 'M0 0L1 0Z'
      },
      :placements => [
        { :glyph_id => 'glyph-a', :x => 10.0, :y => 20.0, :matrix => nil },
        { :glyph_id => 'glyph-space', :x => 12.0, :y => 20.0, :matrix => nil }
      ],
      :unmatched_source_runs => [],
      :unmatched_placements => [],
      :missing_language_packs => [],
      :skipped_placements => [],
      :placement_failures => []
    }
  end

  def test_exact_page_certificate_rejects_partial_or_failed_span_sets
    Dir.mktmpdir('bc_semantic_proof') do |tmpdir|
      pdf = File.join(tmpdir, 'fixture.pdf')
      File.open(pdf, 'wb') { |file| file.write('%PDF-certified-source') }
      evidence = exact_evidence
      certificate = {
        :pdf_sha256 => PROOF.file_sha256(pdf),
        :page => 1,
        :glyph_count => evidence[:glyphs].length,
        :placement_count => evidence[:placements].length,
        :semantic_sha256 => PROOF.semantic_fingerprint(evidence),
        :allowed_unoutlined_glyph_ids => ['glyph-space']
      }
      proof = PROOF.for_certificate(pdf, 1, certificate)

      assert proof.respond_to?(:call)
      assert proof.call(evidence)

      partial = evidence.merge(:placements => evidence[:placements][0, 1])
      refute proof.call(partial), 'some placements must never certify a full page'

      unmatched = evidence.merge(:unmatched_source_runs => ['source-span-2'])
      refute proof.call(unmatched), 'unmatched source spans must block completion'

      File.open(pdf, 'ab') { |file| file.write('mutated') }
      refute proof.call(evidence), 'the proof must remain tied to the exact source PDF'
    end
  end

  def test_main_svg_boundary_supplies_the_fixture_scoped_proof
    Dir.mktmpdir('bc_main_semantic_proof') do |tmpdir|
      original_render = nil
      begin
        pdf = File.join(tmpdir, 'ordinary.pdf')
        File.open(pdf, 'wb') { |file| file.write('%PDF-not-certified') }
        captured = nil
        original_render = SVG.method(:render)
        SVG.define_singleton_method(:render) do |*args|
          captured = args
          { :renderer => :pdftocairo, :glyphs => 1, :edges => 1 }
        end

        result = IMP.render_svg_text_with_semantic_proof(
          Object.new, pdf, 1, [0, 0, 100, 100], :scale => 1.0
        )

        assert_equal :pdftocairo, result[:renderer]
        proof = captured[4][:semantic_complete]
        assert proof.respond_to?(:call)
        refute proof.call(exact_evidence),
          'an ordinary page with some valid glyphs must not receive fixture certification'
        main_source = File.read(File.join(
          File.expand_path('..', __dir__),
          'extracted', 'sketchup_ext', 'bc_pdf_vector_importer', 'main.rb'
        ), :encoding => 'UTF-8')
        assert_match(/svg_result\s*=\s*render_svg_text_with_semantic_proof/, main_source)
      ensure
        SVG.define_singleton_method(:render, original_render) if original_render
      end
    end
  end
end
