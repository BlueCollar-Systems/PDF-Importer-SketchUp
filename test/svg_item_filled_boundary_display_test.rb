require 'minitest/autorun'
$LOAD_PATH.unshift(File.expand_path('../extracted/sketchup_ext', __dir__))
require 'bc_pdf_vector_importer/svg_item_representation_renderer'
require 'bc_pdf_vector_importer/pdf_parser'

class SvgItemFilledBoundaryDisplayTest < Minitest::Test
  Renderer = BlueCollarSystems::PDFVectorImporter::SvgItemRepresentationRenderer
  ContractError = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity::ContractError
  SID = 'text_span:1:0'.freeze
  DICT = 'BC_PDF_Importer'.freeze

  class Node
    attr_accessor :hidden, :layer, :ignore_policy
    attr_reader :persistent_id, :attributes
    def initialize(id, type, mode = 'geometry', source = SID, glyph = nil)
      @persistent_id, @type, @hidden = id, type, false
      @attributes = { 'representation' => mode,
        'source_kind' => source ? 'text_span' : 'shared_glyph_outline' }
      @attributes['source_span_id'] = source if source
      @attributes['source_glyph_id'] = glyph || 'glyph-0-0'
      @attributes['source_placement_indices'] = [0] if source
    end
    def typename; @type; end
    def hidden?; @hidden; end
    def valid?; true; end
    def material;nil;end
    def soft?;false;end
    def smooth?;false;end
    def curve;nil;end
    def casts_shadows?;true;end
    def attribute_dictionaries;@attributes.empty? ? nil : [@attributes];end
    def get_attribute(dictionary, key, default = nil)
      dictionary == DICT ? @attributes.fetch(key,default) : default
    end
    def set_attribute(dictionary, key, value)
      return if @ignore_policy && key.include?('contour')
      @attributes[key] = value if dictionary == DICT
    end
  end

  class Edge < Node
    attr_accessor :faces, :failure
    attr_reader :points, :hidden_write_count
    def initialize(id, mode = 'geometry', source = SID, glyph = nil)
      super(id, 'Edge', mode, source, glyph)
      @points = [[id.to_f,0.0,0.0],[id.to_f+1.0,0.0,0.0]]
      @faces = []
      @hidden_write_count = 0
    end
    ContourPoint = Struct.new(:x,:y,:z)
    ContourVertex = Struct.new(:position)
    def start;ContourVertex.new(ContourPoint.new(*@points.first));end
    def end;ContourVertex.new(ContourPoint.new(*@points.last));end
    def hidden=(value)
      @hidden_write_count += 1
      raise 'native hidden setter failed' if @failure == :raise
      @hidden = value unless @failure == :ignore
    end
  end

  class Face < Node
    attr_reader :edges
    ContourLoop=Struct.new(:edges)
    def loops;[ContourLoop.new(@edges)];end
    def initialize(id, edges, mode = 'geometry', source = SID, glyph = nil)
      super(id,'Face',mode,source,glyph)
      @edges = edges
      edges.each { |edge| edge.faces << self }
    end
  end

  class Group < Node
    attr_reader :entities
    def initialize(id, members = [], mode = 'geometry', source = SID)
      super(id,'Group',mode,source)
      @entities = members
    end
  end

  Definition = Struct.new(:entities)
  class Instance < Node
    attr_reader :definition
    def initialize(id, definition, glyph)
      super(id,'ComponentInstance','glyphs',SID,glyph)
      @definition = definition
    end
  end

  def qualified_proof
    q=BlueCollarSystems::PDFVectorImporter::SourceFillOnlyPaint
    svg='<svg><defs><g id="glyph-0-0"><path d="M 0 0 L 2 0 L 2 2 Z"/></g></defs><use xlink:href="#glyph-0-0"/></svg>'
    q.prepare(['BT /F1 16 Tf (ABO) Tj ET'],[{:resource=>'/F1',:subtype=>'/Type1'}],false,svg,'1'*64,1)
  end
  def govern(root,sid,ink,proof=qualified_proof)
    Renderer.govern_filled_glyph_contours!(root,sid,ink,proof,
      :source_pdf_sha256=>'1'*64,:page=>1,:source_svg_sha256=>qualified_proof[:source_svg_sha256])
  end

  def filled(mode = 'geometry', shared = false)
    source = shared ? nil : SID
    glyph = shared ? 'font-0:7' : nil
    edges = (1..8).map { |id| Edge.new(id,mode,source,glyph) }
    # One source face with outer boundary and a counter boundary. Hiding the
    # contour leaves the same native face and both boundary loops editable.
    face = Face.new(9,edges,mode,source,glyph)
    [edges,face]
  end

  def test_filled_outer_and_counter_edges_hide_without_changing_geometry_or_open_strokes
    edges,face = filled
    open_stroke = Edge.new(10)
    page_peer = Edge.new(11)
    group = Group.new(12,edges+[face,open_stroke])
    geometry = Marshal.dump([edges.map(&:points),face.edges.map(&:persistent_id),group.entities.map(&:persistent_id)])
    result = govern(group,SID,true)
    assert edges.all?(&:hidden?)
    refute face.hidden?
    refute open_stroke.hidden?
    refute page_peer.hidden?
    assert_equal 8,result[:hidden_filled_contour_edge_count]
    assert_equal 1,result[:preserved_unfaced_source_edge_count]
    assert_equal geometry,Marshal.dump([edges.map(&:points),face.edges.map(&:persistent_id),group.entities.map(&:persistent_id)])
    assert Renderer.verify_visible_tree!(group,SID)
  end

  def test_source_ink_readback_is_required_before_any_filled_edge_is_hidden
    edges,face=filled
    group=Group.new(12,edges+[face])
    assert_raises(ContractError) { govern(group,SID,false) }
    assert edges.none?(&:hidden?)
    assert_equal 0,edges.map(&:hidden_write_count).inject(0,:+)
  end

  def test_unfaced_source_outlines_are_preserved_and_not_qualified_as_hidden_fill
    edge=Edge.new(1)
    group=Group.new(2,[edge])
    result=govern(group,SID,false)
    assert_equal 0,result[:hidden_filled_contour_edge_count]
    assert_equal 1,result[:preserved_unfaced_source_edge_count]
    refute edge.hidden?
    assert Renderer.verify_visible_tree!(group,SID)
  end

  def test_shared_definition_is_governed_once_without_collapsing_instances
    edges,face=filled('glyphs',true)
    definition=Definition.new(edges+[face])
    first=Instance.new(20,definition,'font-0:7')
    second=Instance.new(21,definition,'font-0:7')
    root=Group.new(22,[first,second],'glyphs')
    result=govern(root,SID,true)
    assert_equal [first,second],root.entities
    assert_equal 8,result[:hidden_filled_contour_edge_count]
    assert_equal 1,result[:filled_contour_shared_definition_count]
    assert edges.all?(&:hidden?)
    assert_equal [1]*8,edges.map(&:hidden_write_count)
    govern(root,SID,true)
    assert_equal [1]*8,edges.map(&:hidden_write_count)
    assert Renderer.verify_visible_tree!(root,SID)
  end

  def test_shared_definition_cannot_claim_conflicting_glyph_identities
    edges,face=filled('glyphs',true)
    definition=Definition.new(edges+[face])
    root=Group.new(22,[Instance.new(20,definition,'font-0:7'),Instance.new(21,definition,'font-0:8')],'glyphs')
    assert_raises(ContractError) { govern(root,SID,true) }
    assert edges.none?(&:hidden?)
  end

  def test_foreign_edge_or_foreign_attached_face_remains_visible_without_mode_fallback
    [:edge,:face].each do |kind|
      edges,face=filled
      group=Group.new(12,edges+[face])
      if kind==:edge
        group.entities << Edge.new(13,'geometry','text_span:1:99')
      else
        edges.first.faces << Face.new(14,[],'geometry','text_span:1:99')
      end
      result=govern(group,SID,true)
      if kind==:edge
        refute group.entities.last.hidden?
      else
        refute edges.first.hidden?
      end
      assert_operator result[:preserved_unqualified_contour_edge_count],:>,0
    end
  end

  def test_native_setter_raise_or_ignored_readback_cannot_advertise_policy
    [:raise,:ignore].each do |failure|
      edges,face=filled
      edges.first.failure=failure
      group=Group.new(12,edges+[face])
      assert_raises(StandardError) { govern(group,SID,true) }
      assert_nil group.get_attribute(DICT,'filled_contour_edge_policy')
    end
  end

  def test_missing_policy_readback_and_later_visible_contour_are_rejected
    edges,face=filled
    group=Group.new(12,edges+[face]);group.ignore_policy=true
    assert_raises(ContractError) { govern(group,SID,true) }
    group.ignore_policy=false
    govern(group,SID,true)
    edges.first.hidden=false
    assert_raises(ContractError) { Renderer.verify_visible_tree!(group,SID) }
    refute edges.first.hidden?, 'verification must not silently repair the observed state'
  end

  def test_hidden_open_edges_and_hidden_layers_are_not_allowed_by_contour_policy
    edges,face=filled
    open_stroke=Edge.new(10);open_stroke.hidden=true
    group=Group.new(12,edges+[face,open_stroke])
    assert_raises(ContractError) { govern(group,SID,true) }
    open_stroke.hidden=false
    govern(group,SID,true)
    layer=Object.new
    def layer.visible?;false;end
    edges.first.layer=layer
    assert_raises(ContractError) { Renderer.verify_visible_tree!(group,SID) }
  end

  def test_source_fill_stroke_and_stroke_only_proofs_preserve_native_edges
    q=BlueCollarSystems::PDFVectorImporter::SourceFillOnlyPaint
    [1,2].each do |mode|
      svg='<svg><defs><g id="glyph-0-0"><path d="M 0 0 L 2 0 L 2 2 Z"/></g></defs><use xlink:href="#glyph-0-0"/></svg>'
      proof=q.prepare(['BT /F1 16 Tf '+mode.to_s+' Tr (ABO) Tj ET'],[{:resource=>'/F1',:subtype=>'/Type1'}],false,svg,'1'*64,1)
      edges,face=filled
      open_stroke=Edge.new(10)
      group=Group.new(12,edges+[face,open_stroke])
      result=Renderer.govern_filled_glyph_contours!(group,SID,true,proof,
        :source_pdf_sha256=>'1'*64,:page=>1,:source_svg_sha256=>Digest::SHA256.hexdigest(svg))
      assert_equal q::PRESERVED,result[:filled_contour_edge_policy]
      assert_equal 0,result[:hidden_filled_contour_edge_count]
      assert edges.none?(&:hidden?)
      assert_equal 0,edges.map(&:hidden_write_count).inject(0,:+)
      refute open_stroke.hidden?
      assert Renderer.verify_visible_tree!(group,SID)
    end
  end

  def test_unknown_or_source_binding_mismatch_keeps_filled_and_open_edges_visible
    [nil,qualified_proof.merge(:source_pdf_sha256=>'2'*64),qualified_proof.merge(:source_svg_sha256=>'3'*64)].each do |proof|
      edges,face=filled;group=Group.new(12,edges+[face])
      result=govern(group,SID,true,proof)
      assert_equal 0,result[:hidden_filled_contour_edge_count]
      assert edges.none?(&:hidden?)
      assert Renderer.verify_visible_tree!(group,SID)
    end
  end

  def test_preserved_policy_does_not_silently_accept_already_hidden_shared_definition
    edges,face=filled('glyphs',true)
    root=Group.new(22,[Instance.new(20,Definition.new(edges+[face]),'font-0:7')],'glyphs')
    edges.first.hidden=true
    assert_raises(ContractError) { govern(root,SID,true,nil) }
    assert_equal 1,edges.select(&:hidden?).length
  end

  Point = Struct.new(:x,:y,:z) do
    def distance(other);Math.sqrt((x-other.x)**2+(y-other.y)**2+(z-other.z)**2);end
  end
  def test_shared_definition_cache_separates_fill_only_from_preserved_paint
    q=BlueCollarSystems::PDFVectorImporter::SourceFillOnlyPaint
    entry={:glyph_id=>'glyph-0-0',:cache_definition_loops=>[[Point.new(0,0,0),Point.new(1,0,0),Point.new(1,1,0),Point.new(0,0,0)]]}
    default=Renderer.glyph_definition_cache_key(entry)
    preserved=Renderer.glyph_definition_cache_key(entry.merge(:source_paint_contour_policy=>q::PRESERVED))
    hidden=Renderer.glyph_definition_cache_key(entry.merge(:source_paint_contour_policy=>Renderer::FILLED_CONTOUR_EDGE_POLICY))
    assert_equal default,preserved
    refute_equal preserved,hidden
    assert_equal hidden,Renderer.glyph_definition_cache_key(entry.merge(:source_paint_contour_policy=>Renderer::FILLED_CONTOUR_EDGE_POLICY))
  end

  def test_later_policy_readback_failure_cannot_mutate_successful_shared_peer
    edges,face=filled('glyphs',true)
    definition=Definition.new(edges+[face])
    first=Group.new(22,[Instance.new(20,definition,'font-0:7')],'glyphs')
    govern(first,SID,true)
    writes=edges.map(&:hidden_write_count)
    geometry=Marshal.dump(edges.map(&:points))
    later=Group.new(23,[Instance.new(21,definition,'font-0:7')],'glyphs')
    later.ignore_policy=true
    assert_raises(ContractError) { govern(later,SID,true) }
    assert_equal writes,edges.map(&:hidden_write_count)
    assert_equal geometry,Marshal.dump(edges.map(&:points))
    assert edges.all?(&:hidden?)
    assert Renderer.verify_visible_tree!(first,SID)
  end

  def native_closure_pair
    tagged=Edge.new(1)
    closure=Edge.new(2)
    tagged.points.replace([[0.0,0.0,0.0],[2.0,0.0,0.0]])
    closure.points.replace(tagged.points.map(&:dup))
    tagged.attributes['source_placement_indices']='8'
    closure.attributes.clear
    face=Face.new(3,[closure])
    face.attributes['source_placement_indices']='8'
    root=Group.new(4,[tagged,closure,face])
    [root,tagged,closure,face]
  end

  def test_exact_source_loose_duplicate_and_anonymous_face_closure_hide_without_erasing
    root,tagged,closure,face=native_closure_pair
    before=Marshal.dump([root.entities.map(&:persistent_id),tagged.points,closure.points,face.edges.map(&:persistent_id)])
    result=govern(root,SID,true)
    assert tagged.hidden?
    assert closure.hidden?
    assert closure.attributes.empty?, 'anonymous native closure is not relabelled as canonical text'
    assert_equal 1,result[:hidden_attached_filled_contour_edge_count]
    assert_equal 1,result[:hidden_duplicate_filled_contour_edge_count]
    assert_equal 2,result[:hidden_filled_contour_edge_count]
    assert_equal 0,result[:preserved_unfaced_source_edge_count]
    assert_equal before,Marshal.dump([root.entities.map(&:persistent_id),tagged.points,closure.points,face.edges.map(&:persistent_id)])
    assert Renderer.verify_visible_tree!(root,SID)
  end

  def test_near_foreign_glyph_placement_style_or_nonempty_anonymous_attributes_cannot_qualify
    [:near,:glyph,:placement,:malformed_placement,:style,:attributes,:face_loop].each do |change|
      root,tagged,closure,face=native_closure_pair
      case change
      when :near;tagged.points.last[0]+=1.0e-12
      when :glyph;tagged.attributes['source_glyph_id']='different-glyph'
      when :placement;tagged.attributes['source_placement_indices']=[1]
      when :malformed_placement;tagged.attributes['source_placement_indices']='08'
      when :style
        def tagged.smooth?;true;end
      when :attributes;closure.attributes['foreign_custom_stroke']='keep'
      when :face_loop;face.edges.clear
      end
      result=govern(root,SID,true)
      refute tagged.hidden?,change.to_s
      refute closure.hidden?,change.to_s
      assert_equal 0,result[:hidden_duplicate_filled_contour_edge_count]
      assert_equal 1,result[:preserved_unfaced_source_edge_count]
      assert Renderer.verify_visible_tree!(root,SID)
    end
  end

  def test_source_stroke_or_unknown_paint_preserves_even_exact_duplicate_closure_pair
    [nil,qualified_proof.merge(:status=>'source_strokes_or_unknown_paint_preserved',:reason=>'source text stroke')].each do |proof|
      root,tagged,closure,_face=native_closure_pair
      result=govern(root,SID,true,proof)
      refute tagged.hidden?
      refute closure.hidden?
      assert_equal 0,result[:hidden_filled_contour_edge_count]
      assert_equal 1,result[:preserved_unfaced_source_edge_count]
      assert Renderer.verify_visible_tree!(root,SID)
    end
  end
end
