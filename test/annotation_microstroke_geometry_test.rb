require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/annotation_microstroke_geometry'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/annotation_microstroke_display'

class AnnotationMicrostrokeGeometryTest < Minitest::Test
  Importer = BlueCollarSystems::PDFVectorImporter
  Subject = Importer::AnnotationMicrostrokeGeometry
  Error = Importer::RepresentationFidelity::ContractError
  Point = Struct.new(:x,:y,:z) do
    def to_a; [x,y,z]; end
  end
  Vertex = Struct.new(:position)
  Curve = Struct.new(:center,:radius,:normal,:start_angle,:end_angle)
  Edge = Struct.new(:start,:end,:curve) do
    def valid?; true; end
  end
  Display = Importer::AnnotationMicrostrokeDisplay

  class DisplayEntity
    attr_reader :persistent_id, :typename, :attributes
    attr_accessor :name, :ignore_hidden, :source_geometry
    def initialize(id,kind)
      @persistent_id,@typename,@attributes,@hidden = id,kind,{},false
    end
    def valid?; true; end
    def hidden?; @hidden; end
    def hidden=(value); @hidden = value unless @ignore_hidden; end
    def get_attribute(_dictionary,key,default = nil); @attributes.fetch(key,default); end
    def set_attribute(_dictionary,key,value); @attributes[key] = value; end
  end

  def source
    { :start_pdf=>[30.0,40.0], :end_pdf=>[30.014,40.0], :radius_pdf=>2.0,
      :stroke_rgb=>[1.0,0.5,0.25], :original_geometry_verified=>true, :full_capsule_clip_verified=>true,
      :page_clip_polygons_pdf=>[[[0,0],[200,0],[200,200],[0,200]]] }
  end

  def context
    { :media_box=>[0,0,200,200], :page_rotation=>0, :scale=>1.0, :page_y_offset=>0.0 }
  end

  def transform(matrix,p)
    [matrix[0]*p[0]+matrix[4]*p[1]+matrix[8]*p[2]+matrix[12],
      matrix[1]*p[0]+matrix[5]*p[1]+matrix[9]*p[2]+matrix[13],
      matrix[2]*p[0]+matrix[6]*p[1]+matrix[10]*p[2]+matrix[14]]
  end

  def test_tiny_original_centerline_survives_scale_safe_local_construction
    plan = Subject.plan(source,context)
    assert_operator plan[:local_length], :>, 0.01
    [[0,0,0],[plan[:local_length],0,0]].zip([source[:start_pdf],source[:end_pdf]]).each do |local,pdf|
      actual = transform(plan[:transform],local)
      assert_in_delta pdf[0]/72.0,actual[0],1.0e-12
      assert_in_delta pdf[1]/72.0,actual[1],1.0e-12
      assert_equal 0.0,actual[2]
    end
    assert_in_delta 2.0/72,plan[:source_radius_inches],1.0e-12
    assert_operator plan[:source_analytic_area_inches2], :>,
      plan[:expected_local_face_area]/Subject::CONSTRUCTION_SCALE**2
  end

  def test_page_rotation_scale_and_stack_offset_do_not_change_original_geometry
    [0,90,180,270].each do |rotation|
      plan = Subject.plan(source,context.merge(:page_rotation=>rotation,:scale=>2.0,:page_y_offset=>5.0))
      start = Importer::PageTransform.transform_point(30,40,[0,0,200,200],rotation)
      assert_in_delta start[0]*2/72.0,plan[:world_start][0],1.0e-12
      assert_in_delta start[1]*2/72.0+5,plan[:world_start][1],1.0e-12
      assert_in_delta 0.014*2/72.0,plan[:source_length_inches],1.0e-12
      assert_in_delta 2.0*2/72,plan[:source_radius_inches],1.0e-12
    end
  end

  def test_existing_long_strokes_never_enter_the_new_microline_route
    long = source.merge(:end_pdf=>[30.1,40])
    refute Importer::AnnotationCompositeProvider.eligible_microline?(long)
    assert_raises(Error) { Subject.plan(long,context) }
    assert_raises(Error) { Subject.plan(source.merge(:original_geometry_verified=>false),context) }
  end

  def arc(inward = false)
    center = Point.new(3.0,0.0,0.0)
    curve = Curve.new(center,2.0,Point.new(0,0,1),0.0,Math::PI)
    pts = (0..Subject::ARC_SEGMENTS).map do |index|
      angle = Math::PI*index/Subject::ARC_SEGMENTS
      Point.new(3.0+(inward ? -1 : 1)*2*Math.sin(angle),-2*Math.cos(angle),0.0)
    end
    pts.each_cons(2).map { |a,b| Edge.new(Vertex.new(a),Vertex.new(b),curve) }
  end

  def test_true_outward_semicircle_is_required_not_just_circular_vertices
    assert Subject.verify_arc!(arc,[3,0,0],2,:right)
    assert_raises(Error) { Subject.verify_arc!(arc(true),[3,0,0],2,:right) }
    missing = arc
    missing.pop
    assert_raises(Error) { Subject.verify_arc!(missing,[3,0,0],2,:right) }
  end

  def test_host_changed_radius_center_sweep_or_plane_cannot_certify_source_arc
    [[:radius,1.0],[:center,Point.new(3.1,0,0)],[:normal,Point.new(0,1,0)],[:end_angle,Math::PI/2]].each do |key,value|
      edges = arc
      edges.first.curve[key] = value
      assert_raises(Error) { Subject.verify_arc!(edges,[3,0,0],2,:right) }
    end
    edges = arc
    edges.first.start.position.z = 0.1
    assert_raises(Error) { Subject.verify_arc!(edges,[3,0,0],2,:right) }
  end

  def test_reversed_native_edge_retains_original_segment_but_shifted_endpoint_does_not
    edge = Edge.new(Vertex.new(Point.new(2,0,0)),Vertex.new(Point.new(0,0,0)),nil)
    assert Subject.same_segment?(edge,[0,0,0],[2,0,0])
    edge.end.position.x = 0.01
    refute Subject.same_segment?(edge,[0,0,0],[2,0,0])
  end

  def native_snapshot
    plan = Subject.plan(source,context)
    length,radius = plan.values_at(:local_length,:local_radius)
    neutral = { :typename=>'Group', :valid=>true, :hidden=>false, :layer=>'PDF', :material=>nil,
      :transformation=>Importer::ItemRasterDisplay::IDENTITY }
    edge = { :typename=>'Edge', :valid=>true, :hidden=>true, :layer=>'PDF', :material=>nil }
    arcs = [[length,0,0],[0,0,0]].each_with_index.map do |center,index|
      { :index=>index, :center=>center, :radius=>radius, :normal=>[0,0,1], :start_angle=>0.0, :end_angle=>Math::PI }
    end
    edges = [edge.merge(:points=>[[0,-radius,0],[length,-radius,0]]),
      edge.merge(:points=>[[0,radius,0],[length,radius,0]])]
    arc_points = []
    arcs.each_with_index do |curve,index|
      points = (0..Subject::ARC_SEGMENTS).map do |i|
        angle = Math::PI*i/Subject::ARC_SEGMENTS
        x = curve[:center][0] + (index == 0 ? 1 : -1)*radius*Math.sin(angle)
        y = (index == 0 ? -1 : 1)*radius*Math.cos(angle)
        # Shared native vertices have exact endpoint identity.
        x = curve[:center][0] if i == 0 || i == Subject::ARC_SEGMENTS
        [x,y,0.0]
      end
      arc_points << points
      points.each_cons(2) { |a,b| edges << edge.merge(:arc_index=>index,:points=>[a,b]) }
    end
    edges.each { |item| item[:points] = item[:points].map { |point| point.map(&:to_f) } }
    fill = { :rgb=>[255,128,64], :alpha=>1.0, :textured=>false }
    face = { :typename=>'Face', :valid=>true, :hidden=>false, :layer=>'PDF', :material=>fill,
      :back_material=>fill, :area=>plan[:expected_local_face_area],
      :loops=>[[[0.0,-radius,0.0]]+arc_points[0]+arc_points[1][0...-1]] }
    boundary = neutral.merge(:boundary=>true,:centerline=>false,:entities=>edges+[face],:arcs=>arcs)
    line = neutral.merge(:boundary=>false,:centerline=>true,
      :entities=>[edge.merge(:points=>[[length,0,0],[0,0,0]])],:arcs=>[])
    [neutral.merge(:transformation=>plan[:transform].dup,:children=>[boundary,line]),plan]
  end

  def test_saved_geometry_proof_survives_json_roundtrip_and_native_edge_orientation
    snapshot,plan = native_snapshot
    assert Subject.verify_snapshot!(JSON.parse(JSON.generate(snapshot)),JSON.parse(JSON.generate(plan)))
  end

  def test_saved_arc_face_centerline_placement_and_style_mutations_fail
    mutations = [
      lambda { |row| row[:transformation][12] += 0.01 },
      lambda { |row| row[:hidden] = true },
      lambda { |row| row[:children].pop },
      lambda { |row| row[:children][0][:transformation] = row[:children][0][:transformation].dup.tap { |matrix| matrix[14] = 0.1 } },
      lambda { |row| row[:children][0][:arcs][0][:radius] *= 0.9 },
      lambda { |row| row[:children][0][:arcs][0][:end_angle] = Math::PI/2 },
      lambda { |row| row[:children][0][:entities][2][:points][0][2] = 0.1 },
      lambda { |row| row[:children][0][:entities][0][:hidden] = false },
      lambda { |row| row[:children][0][:entities][-1][:area] *= 0.9 },
      lambda { |row| row[:children][0][:entities][-1][:loops][0].pop },
      lambda { |row| row[:children][0][:entities][-1][:back_material] = nil },
      lambda { |row| row[:children][1][:entities][0][:points][0][0] += 0.1 },
      lambda do |row|
        points = row[:children][0][:entities][-1][:loops][0]
        points[3],points[7] = points[7],points[3]
      end,
      lambda do |row|
        edges = row[:children][0][:entities]
        edges[3][:points][1],edges[7][:points][1] = edges[7][:points][1],edges[3][:points][1]
      end
    ]
    mutations.each_with_index do |mutation,index|
      snapshot,plan = native_snapshot
      mutation.call(snapshot)
      assert_raises(Error,"mutation #{index}") { Subject.verify_snapshot!(snapshot,plan) }
    end
  end

  def display_manifest
    snapshot,plan = native_snapshot
    snapshot[:hidden] = true
    source_record = source.merge(:source_pdf_sha256=>'a'*64,:page_number=>1,:annotation_ref=>'7 0 R')
    plan[:source] = source_record
    counter = 20
    ([snapshot]+snapshot[:children]+snapshot[:children].flat_map { |row| row[:entities] }).each do |row|
      row[:entity_id] = 'persistent_id:' + counter.to_s
      counter += 1
    end
    proof = context.merge(:schema=>Importer::AnnotationMicrostrokeDisplay::SCHEMA,
      :policy=>Importer::AnnotationMicrostrokeDisplay::POLICY,:page=>1,:source_pdf_sha256=>'a'*64,
      :page_group_id=>'persistent_id:10',:highest_prior_native_z=>0.0,:display_gap_inches=>0.01,:display_z=>0.01)
    crop = Importer::AnnotationCompositeSource.crop_plan(source_record,context[:media_box],0)
    pixels = { :pixel_width=>crop[:pixel_width],:pixel_height=>crop[:pixel_height],
      :transparent_pixel_present=>false,:visible_pixel_present=>true,
      :visual_pixel_sha256=>'b'*64,:content_sha256=>'c'*64 }
    background = { :source_pdf_sha256=>'a'*64,:page_number=>1,:original_byte_prefix_unchanged=>true,
      :overridden_key=>'/Annots',:other_annotations_disjoint=>[], :all_crop_glyph_bounds_disjoint=>true,
      :flattened_image_bounds_disjoint=>true,
      :font_scope=>{:type3_and_pattern_programs_absent=>true,:text_clipping_modes_absent=>true,:text_stroke_modes_absent=>true},
      :clip_mask_visibility_narrowing_ignored=>true,:possible_glyph_count=>12,
      :source_crop_boxes_svg=>[crop[:source_box_svg]],:crop_count=>1,:svg_sha256=>'d'*64 }
    display = { :source=>source_record,:crop=>crop,:pixels=>pixels,:background_proof=>background,:image_entity_id=>'persistent_id:11' }
    corners = Importer::AnnotationMicrostrokeDisplay.crop_placement(display,proof,0.01)
    display[:image_matrix] = corners[:matrix]
    display[:expected_corners] = corners[:corners]
    proof[:placements] = [{:source=>source_record,:geometry_plan=>plan,:capsule_entity_id=>'persistent_id:20',
      :native_geometry=>snapshot,:display=>display,
      :display_replacement=>Display.replacement_binding('persistent_id:20','persistent_id:11')}]
    neutral = { :valid=>true,:deleted=>false,:style_evidence=>{:entity_visible=>true,:layer_visible=>true},:children=>[] }
    image = neutral.merge(:typename=>'Image',:persistent_id=>11,:entity_id=>11,:annotation_composite_image=>true,
      :transformation=>display[:image_matrix].dup,
      :annotation_source_binding=>{:source_pdf_sha256=>'a'*64,:page=>1,:annotation_ref=>'7 0 R'},
      :content_evidence=>{:host_texture_export_verified=>true,:host_texture_export_byte_size=>123,
        :host_visual_pixel_sha256=>'b'*64,:host_pixel_width=>crop[:pixel_width],:host_pixel_height=>crop[:pixel_height],
        :display_width=>corners[:matrix][0],:display_height=>corners[:matrix][5]})
    capsule = neutral.merge(:typename=>'Group',:persistent_id=>20,:entity_id=>20,:original_annotation_capsule=>true,
      :style_evidence=>{:entity_visible=>false,:layer_visible=>true},
      :annotation_native_geometry=>Marshal.load(Marshal.dump(snapshot)))
    page = neutral.merge(:typename=>'Group',:persistent_id=>10,:entity_id=>10,
      :transformation=>Importer::ItemRasterDisplay::IDENTITY,:children=>[capsule,image],:annotation_highest_other_z=>0.0)
    stats = { :original_annotation_placements=>[proof],
      :original_annotation_ink=>[{:eligible_geometry_count=>1,:composite_count=>1}] }
    [stats,[page]]
  end

  def test_saved_annotation_image_requires_real_pixels_exact_lattice_and_geometry_inventory
    stats,manifest = display_manifest
    assert Importer::AnnotationMicrostrokeDisplay.verify_manifest!(JSON.parse(JSON.generate(stats)),JSON.parse(JSON.generate(manifest)))
    mutations = [
      lambda { |s,m| m[0][:children][1][:content_evidence][:host_texture_export_verified] = false },
      lambda { |s,m| m[0][:children][1][:content_evidence][:host_texture_export_byte_size] = 0 },
      lambda { |s,m| m[0][:children][1][:content_evidence][:host_visual_pixel_sha256] = 'e'*64 },
      lambda { |s,m| m[0][:children][1][:content_evidence][:host_pixel_width] += 1 },
      lambda { |s,m| m[0][:children][1][:transformation][12] += 0.001 },
      lambda { |s,m| m[0][:children][1][:annotation_source_binding][:source_pdf_sha256] = 'e'*64 },
      lambda { |s,m| m[0][:children][1][:style_evidence] = {:entity_visible=>false,:layer_visible=>true} },
      lambda { |s,m| m[0][:children].pop },
      lambda { |s,m| s[:original_annotation_placements][0][:placements][0][:display][:background_proof][:all_crop_glyph_bounds_disjoint] = false },
      lambda { |s,m| s[:original_annotation_placements][0][:placements][0][:display][:background_proof][:source_crop_boxes_svg] = [] },
      lambda { |s,m| s[:original_annotation_placements][0][:placements][0][:display][:crop][:pixel_box][0] += 1 },
      lambda { |s,m| s[:original_annotation_ink][0][:composite_count] = 0 },
      lambda { |s,m| m[0][:annotation_highest_other_z] = 0.02 },
      lambda { |s,m| s[:original_annotation_placements][0][:placements][0].delete(:display_replacement) },
      lambda { |s,m| s[:original_annotation_placements][0][:placements][0][:display_replacement][:image_entity_id] = 'persistent_id:99' },
      lambda { |s,m| m[0][:children][0][:style_evidence][:entity_visible] = true },
      lambda { |s,m| m[0][:children][0][:annotation_native_geometry][:hidden] = false },
      lambda { |s,m| m[0][:children][0][:annotation_native_geometry][:children][0][:entities][-1][:area] *= 0.9 }
    ]
    mutations.each_with_index do |mutation,index|
      s,m = display_manifest
      mutation.call(s,m)
      assert_raises(Error,"display mutation #{index}") { Importer::AnnotationMicrostrokeDisplay.verify_manifest!(s,m) }
    end
  end

  def test_source_geometry_without_composite_remains_visible_and_editable
    stats,manifest = display_manifest
    placement = stats[:original_annotation_placements][0][:placements][0]
    placement.delete(:display)
    placement.delete(:display_replacement)
    placement[:native_geometry][:hidden] = false
    stats[:original_annotation_ink][0][:composite_count] = 0
    manifest[0][:children].pop
    capsule = manifest[0][:children][0]
    capsule[:style_evidence][:entity_visible] = true
    capsule[:annotation_native_geometry][:hidden] = false
    assert Display.verify_manifest!(stats,manifest)
    capsule[:annotation_native_geometry][:hidden] = true
    assert_raises(Error) { Display.verify_manifest!(stats,manifest) }
  end

  def suppression_fixture
    stats,_manifest = display_manifest
    proof = stats[:original_annotation_placements][0]
    composite = proof[:placements][0][:display]
    capsule,image,unrelated = DisplayEntity.new(20,'Group'),DisplayEntity.new(11,'Image'),DisplayEntity.new(99,'Group')
    capsule.source_geometry = native_snapshot.first
    capsule.set_attribute(Display::DICTIONARY,'original_annotation_capsule',true)
    capsule.set_attribute(Display::DICTIONARY,'original_annotation_source',JSON.generate(composite[:source]))
    image.set_attribute(Display::DICTIONARY,'annotation_composite_image',true)
    image.set_attribute(Display::DICTIONARY,'annotation_source_pdf_sha256',proof[:source_pdf_sha256])
    image.set_attribute(Display::DICTIONARY,'annotation_page_number',proof[:page])
    image.set_attribute(Display::DICTIONARY,'annotation_ref',composite[:source][:annotation_ref])
    [Struct.new(:entities).new([capsule,image,unrelated]),capsule,image,unrelated,composite,proof]
  end

  def test_verified_composite_suppresses_only_its_exact_owned_editable_source_group
    page,capsule,image,unrelated,composite,proof = suppression_fixture
    before = Marshal.dump(capsule.source_geometry)
    binding = Display.suppress_replaced_capsule!(page,capsule,image,composite,proof)
    assert_equal Display.replacement_binding('persistent_id:20','persistent_id:11'),binding
    assert capsule.hidden?
    refute image.hidden?
    refute unrelated.hidden?
    assert_equal before,Marshal.dump(capsule.source_geometry)
    assert_match(/Original annotation 7 0 R.*editable source/,capsule.name)
    assert_equal binding,Subject.symbols(JSON.parse(capsule.get_attribute(Display::DICTIONARY,'original_annotation_display_replacement')))
  end

  def test_ignored_hide_setter_rejects_duplicate_visible_paint
    page,capsule,image,_unrelated,composite,proof = suppression_fixture
    capsule.ignore_hidden = true
    error = assert_raises(Error) { Display.suppress_replaced_capsule!(page,capsule,image,composite,proof) }
    assert_match(/suppression setter was ignored/,error.message)
    refute capsule.hidden?
  end

  def test_unproven_missing_hidden_or_wrong_source_image_cannot_suppress_source_geometry
    mutations = [
      lambda { |page,_capsule,image,_composite| page.entities.delete(image) },
      lambda { |_page,_capsule,image,_composite| image.hidden = true },
      lambda { |_page,_capsule,image,_composite| image.set_attribute(Display::DICTIONARY,'annotation_ref','8 0 R') },
      lambda { |_page,_capsule,_image,composite| composite[:pixels][:transparent_pixel_present] = true },
      lambda { |_page,capsule,_image,_composite| capsule.set_attribute(Display::DICTIONARY,'original_annotation_source','{}') }
    ]
    mutations.each do |mutation|
      page,capsule,image,unrelated,composite,proof = suppression_fixture
      mutation.call(page,capsule,image,composite)
      assert_raises(Error) { Display.suppress_replaced_capsule!(page,capsule,image,composite,proof) }
      refute capsule.hidden?
      refute unrelated.hidden?
    end
  end
end
