#!/usr/bin/env ruby
# Recovering the characters of text a PDF delivers as raw glyph codes.
#
# Every font here is built in the test from fictional shapes, so nothing
# depends on what is installed - CI runs this on Linux, where there is no
# Arial to lean on. Every string is fictional sample content.

require 'minitest/autorun'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/glyph_code_recovery'
require File.expand_path('glyph_code_font_builder', File.dirname(__FILE__))

GCRec = BlueCollarSystems::PDFVectorImporter::GlyphCodeRecovery
FB = GlyphCodeFontBuilder

class GlyphCodeRecoveryTest < Minitest::Test
  # Glyph ids deliberately unrelated to character order: anything that matched
  # a glyph id to a position would answer differently.
  LAYOUT = { 0x30 => 'M', 0x36 => 'S', 0x10 => '-', 0x16 => '3',
             0x14 => '1', 0x15 => '2', 0x03 => ' ' }.freeze

  def setup
    GCRec.clear_reference_cache
    @dir = File.join(Dir.tmpdir, "bcs-glyph-#{Process.pid}-#{object_id}")
    Dir.mkdir(@dir) unless File.directory?(@dir)
    @reference = File.join(@dir, 'samplegothic.ttf')
    File.open(@reference, 'wb') { |f| f.write(FB.reference_face('ABMS-123 ')) }
    @subset = FB.subset_face(LAYOUT)
    @widths = FB.widths_for(LAYOUT)
  end

  def teardown
    GCRec.clear_reference_cache
    Dir.entries(@dir).each do |n|
      next if n == '.' || n == '..'
      File.delete(File.join(@dir, n)) rescue nil
    end
    Dir.rmdir(@dir) rescue nil
  end

  def proof(base_font = 'ABCDEF+SampleGothic', widths = nil, program = nil)
    GCRec::FontProof.new(program || @subset, base_font,
                         widths || @widths, 1000.0, [@dir])
  end

  def recover(gids, p = nil)
    GCRec.recover_span(p || proof, gids)
  end

  # ── the defect itself ──

  def test_recovers_a_span_whose_glyph_ids_are_not_character_order
    result = recover([0x30, 0x36, 0x10, 0x16])

    assert_equal 'MS-3', result[0]
    assert_equal GCRec::ROUTE_OUTLINE_IDENTITY, result[1]
  end

  def test_printable_ascii_codes_are_recovered_not_left_looking_right
    # 0x30 and 0x36 arrive as the characters "0" and "6". A check for control
    # characters sees nothing wrong with "06".
    raw = [0x30, 0x36].map { |c| c.chr }.join
    assert raw == '06'
    assert raw.each_char.all? { |c| c.ord >= 0x20 }

    assert_equal 'MS', recover([0x30, 0x36])[0]
  end

  def test_a_glyph_that_draws_nothing_is_reported_on_its_own_route
    result = recover([0x03])

    assert_equal ' ', result[0]
    assert_equal GCRec::ROUTE_BLANK_ADVANCE, result[1]
  end

  def test_a_span_reports_the_weakest_route_any_character_needed
    result = recover([0x30, 0x03])

    assert_equal 'M ', result[0]
    assert_equal GCRec::ROUTE_BLANK_ADVANCE, result[1]
  end

  # ── all or nothing ──

  def test_one_unprovable_character_leaves_the_whole_span_alone
    # A half-read dimension reads as a measurement and is worse than raw codes.
    assert_nil recover([0x30, 0x36, 0x10, 0x16, 0x0999])
  end

  def test_an_empty_span_recovers_nothing
    assert_nil recover([])
  end

  # ── refusals ──

  def test_no_reference_face_installed_recovers_nothing
    p = GCRec::FontProof.new(@subset, 'ABCDEF+SampleGothic', @widths, 1000.0, [])

    assert_nil GCRec.recover_span(p, [0x30])
    assert_match(/no reference face/, p.reason)
    assert_equal 'samplegothic', p.looked_for
  end

  def test_a_family_that_is_not_installed_recovers_nothing
    p = proof('ABCDEF+NoSuchFaceXYZ')

    assert_nil GCRec.recover_span(p, [0x30])
    assert_equal 'nosuchfacexyz', p.looked_for
  end

  def test_a_different_width_of_the_same_family_proves_nothing
    assert_nil recover([0x30], proof('ABCDEF+SampleGothicNarrow'))
  end

  def test_a_different_weight_of_the_same_family_proves_nothing
    assert_nil recover([0x30], proof('ABCDEF+SampleGothic,Bold'))
  end

  def test_an_advance_that_contradicts_the_shape_is_refused
    wrong = {}
    @widths.each { |gid, w| wrong[gid] = w + 40.0 }

    assert_nil recover([0x30], proof('ABCDEF+SampleGothic', wrong))
  end

  def test_a_font_with_no_embedded_program_recovers_nothing
    p = GCRec::FontProof.new(nil, 'ABCDEF+SampleGothic', @widths, 1000.0, [@dir])

    refute p.usable?
    assert_nil GCRec.recover_span(p, [0x30])
    assert_match(/embeds no font program/, p.reason)
  end

  def test_an_unreadable_font_program_recovers_nothing_and_does_not_raise
    p = GCRec::FontProof.new("\x00\x01\x00\x00not a font at all",
                             'ABCDEF+SampleGothic', @widths, 1000.0, [@dir])

    refute p.usable?
    assert_nil GCRec.recover_span(p, [0x30])
  end

  # ── the subset's own map wins, and is trusted over the outlines ──

  def test_the_subsets_own_cmap_is_used_first_and_named
    subset = FB.subset_face(LAYOUT, 0x41 => 0x30) # this subset says gid 0x30 is "A"
    result = recover([0x30], proof('ABCDEF+SampleGothic', @widths, subset))

    assert_equal 'A', result[0]
    assert_equal GCRec::ROUTE_EMBEDDED_CMAP, result[1]
  end

  def test_a_private_use_mapping_is_ignored_not_answered_with
    # A cmap that "proves" a private-use codepoint proves a picture, not a
    # character. Route 1 declines it - and the shape still proves the real
    # character, so the span is recovered from the outlines instead. Being
    # ignored is the point; poisoning the glyph is not.
    subset = FB.subset_face(LAYOUT, 0xE000 => 0x30)
    result = recover([0x30], proof('ABCDEF+SampleGothic', @widths, subset))

    assert_equal 'M', result[0]
    assert_equal GCRec::ROUTE_OUTLINE_IDENTITY, result[1],
                 'the private-use cmap entry must not be the answer'
  end

  def test_a_private_use_mapping_alone_recovers_nothing
    # With no reference face there is nothing but the private-use entry, and
    # that is not a character.
    subset = FB.subset_face(LAYOUT, 0xE000 => 0x30)
    p = GCRec::FontProof.new(subset, 'ABCDEF+SampleGothic', @widths, 1000.0, [])

    assert_nil GCRec.recover_span(p, [0x30])
  end

  # ── composites ──

  def test_a_composite_glyph_is_decomposed_before_it_is_compared
    ttf = BlueCollarSystems::PDFVectorImporter::TrueTypeOutlines
    glyphs = ['', FB.simple_glyph(FB::SHAPES['M']), FB.simple_glyph(FB::SHAPES['S']),
              FB.composite_glyph(1, 2, 700)]
    face = ttf::Face.new(FB.build(glyphs, [0, 700, 640, 1340], nil))

    shape = face.contours(3)
    assert_equal 2, shape.length, 'both components should be present'
    refute_equal ttf::EMPTY_OUTLINE_SIGNATURE, face.outline_signature(3)
  end

  def test_a_composite_whose_component_is_missing_raises_rather_than_half_a_shape
    ttf = BlueCollarSystems::PDFVectorImporter::TrueTypeOutlines
    glyphs = ['', FB.simple_glyph(FB::SHAPES['M']), FB.composite_glyph(1, 9, 700)]
    face = ttf::Face.new(FB.build(glyphs, [0, 700, 1340], nil))

    assert_raises(ttf::FontError) { face.contours(2) }
  end

  # ── the candidate set and the tie-break ──

  def test_two_faces_of_the_same_family_do_not_make_a_character_ambiguous
    other = File.join(@dir, 'samplegothic-copy.ttf')
    File.open(other, 'wb') { |f| f.write(FB.reference_face('ABMS-123 ')) }
    GCRec.clear_reference_cache

    assert_equal 'MS-3', recover([0x30, 0x36, 0x10, 0x16])[0]
  end

  def test_the_candidate_set_is_what_a_drawing_carries
    assert GCRec::CANDIDATE_CODEPOINTS.include?(0x4D)   # M
    assert GCRec::CANDIDATE_CODEPOINTS.include?(0x2D)   # hyphen-minus
    refute GCRec::CANDIDATE_CODEPOINTS.include?(0x39C)  # Greek capital Mu
    refute GCRec::CANDIDATE_CODEPOINTS.include?(0x41C)  # Cyrillic capital Em
  end

  def test_an_ascii_candidate_resolves_a_tie_and_two_non_ascii_do_not
    # Arial draws hyphen-minus and soft hyphen identically; a drawing means
    # the hyphen.
    assert_equal 0x2D, GCRec.unambiguous_candidate({ 0x2D => 333.0, 0xAD => 333.0 }, 333.0)
    assert_nil GCRec.unambiguous_candidate({ 0xAD => 333.0, 0xA0 => 333.0 }, 333.0)
  end

  def test_the_advance_filter_runs_before_the_ascii_tie_break
    # Only the soft hyphen agrees on width, so the ASCII preference must not
    # override it into answering the wrong character.
    assert_equal 0xAD, GCRec.unambiguous_candidate({ 0x2D => 500.0, 0xAD => 333.0 }, 333.0)
  end

  # ── style parsing ──

  def test_a_subset_prefix_and_style_words_are_read_as_identity
    style = GCRec.parse_font_style('ABCDEF+ArialNarrow,Bold')

    assert_equal 'arial', style[:family]
    assert_equal 'narrow', style[:width]
    assert_equal true, style[:bold]
  end

  def test_a_foundry_suffix_is_not_part_of_the_family
    assert_equal 'arial', GCRec.parse_font_style('ArialMT')[:family]
  end

  # ── codes ──

  def test_identity_codes_are_read_two_bytes_at_a_time
    assert_equal [0x30, 0x36, 0x10, 0x16], GCRec.glyph_ids_from_hex('0030003600100016')
    assert_equal [], GCRec.glyph_ids_from_hex('003')
    assert_equal [], GCRec.glyph_ids_from_hex('')
  end
end
