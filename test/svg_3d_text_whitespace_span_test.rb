require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/representation_fidelity'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer'

# A source glyph mapped to U+0020 can have visible ink. Unicode predicates are
# matching hints only; they cannot advance a representation fallback ladder.
class Svg3DTextWhitespaceSpanTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::Svg3DTextRenderer
  Item = Struct.new(:text, :source_span_id)
  def item(text); Item.new(text, 'text_span:10:80'); end

  def test_ascii_and_unicode_whitespace_are_matching_hints
    [' ', '  ', "\t", " \t ", " ", "  ", "​", "　"].each do |text|
      assert R.whitespace_only_item?(item(text))
    end
  end
  def test_empty_and_visible_text_are_not_whitespace_hints
    ['', 'A', 'TraceMonkey', ' must ', '.', " x"].each do |text|
      refute R.whitespace_only_item?(item(text))
    end
  end
  def test_bad_items_do_not_become_empty_ink_proofs
    refute R.whitespace_only_item?(nil)
    refute R.whitespace_only_item?(Object.new)
    refute R.respond_to?(:whitespace_only_proof)
  end
end
