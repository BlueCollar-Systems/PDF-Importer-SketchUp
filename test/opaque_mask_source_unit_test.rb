require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class OpaqueMaskSourceUnitTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  Fidelity = IMP::RepresentationFidelity
  Claim = Struct.new(:attributes) do
    def get_attribute(_dictionary,key,default); attributes.fetch(key,default); end
  end

  def setup
    @physical = {:physical_geometry_sha256=>'a'*64,:physical_style_sha256=>'b'*64,
                 :physical_entity_count=>7}
    @expected = @physical.merge(:schema=>'bcs.source_unit_expected/1.0',
      :source_unit_id=>'svg_glyph_placements:page:1', :representation=>:glyphs,
      :source_identity=>{:svg_sha256=>'c'*64,:placement_indices=>[0,1,2],
                        :glyph_ids=>['g0','g1','g2'],:source_extent=>[0,2,3,4]})
    @expected[:evidence_sha256] = Fidelity.canonical_sha256(@expected)
    @row = {:source_unit_id=>@expected[:source_unit_id],:expected_evidence=>@expected}
    @claim = Claim.new({'source_unit_id'=>@expected[:source_unit_id],
      'source_claim_root'=>true, 'source_kind'=>'svg_glyph_placement',
      'representation'=>'glyphs', 'source_placement_indices'=>[0,1,2],
      'source_evidence_sha256'=>@expected[:evidence_sha256]})
  end

  def verify
    Fidelity.stub(:physical_evidence,@physical) { IMP.verify_composition_source_unit!(@claim,@row) }
  end

  def test_exact_nonsemantic_physical_unit_is_accepted_without_inventing_span
    assert verify
    refute @claim.attributes.key?('source_span_id')
  end

  def test_changed_physical_geometry_or_style_cannot_supply_mask_ink
    [:physical_geometry_sha256,:physical_style_sha256,:physical_entity_count].each do |key|
      previous = @physical[key]
      @physical[key] = key == :physical_entity_count ? 8 : 'd'*64
      assert_raises(Fidelity::ContractError) { verify }
      @physical[key] = previous
    end
  end

  def test_claim_type_placement_identity_and_semantic_collision_are_rejected
    {'source_span_id'=>'text_span:1:1','source_kind'=>'text_span','source_unit_id'=>'svg_glyph_placements:page:2',
     'source_claim_root'=>false,'representation'=>'text3d','source_placement_indices'=>[0,1]}.each do |key,value|
      original = @claim.attributes.dup
      @claim.attributes[key] = value
      assert_raises(Fidelity::ContractError,key) { verify }
      @claim.attributes = original
    end
  end

  def test_stale_or_modified_expected_proof_cannot_certify_source_unit
    @expected[:source_identity][:svg_sha256] = 'e'*64
    assert_raises(Fidelity::ContractError) { verify }
  end
end
