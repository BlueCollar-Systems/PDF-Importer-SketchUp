require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/xobject_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/vector_stroke_footprint'

module Geom
  class Point3d
    attr_reader :x,:y,:z
    def initialize(x,y,z); @x,@y,@z=x.to_f,y.to_f,z.to_f; end
    def transform(t); Point3d.new(x*t.scale,y*t.scale,z*t.scale); end
  end
  class Transformation
    attr_reader :scale
    def initialize; @scale=1.0; end
    def self.scaling(x,y,z)
      raise 'not uniform' unless x == y && y == z
      result=new; result.instance_variable_set(:@scale,x); result
    end
  end
end

class VectorStrokeFootprintTest < Minitest::Test
  IMP=BlueCollarSystems::PDFVectorImporter
  Parser=IMP::ContentStreamParser
  Subject=IMP::VectorStrokeFootprint
  BOX=[-1000,-1000,1000,1000].freeze

  def parse(stream)
    Parser.new([stream],nil).parse
  end
  def plan(stream,box=BOX)
    path=parse(stream).first
    sampled=Subject.flatten_subpath(path,path.subpaths.first)
    Subject.plan(path,sampled[:points],path.subpaths.first.closed,box).merge(sampled)
  end
  def paint_area(specification)
    specification[:polygons].inject(0.0) { |sum,loop| sum+Subject.area2(loop).to_f/2 }
  end
  def bounds(specification)
    points=specification[:polygons].flatten(1)
    [points.map(&:first).min,points.map(&:last).min,points.map(&:first).max,points.map(&:last).max].map(&:to_f)
  end
  def test_butt_square_and_round_open_caps_retain_width_and_source_endpoints
    butt=plan('2 w 10 20 m 30 20 l S')
    assert_equal [10,19,30,21],bounds(butt)
    assert_equal [[10,20],[30,20]],butt[:centerline]
    assert_in_delta 40,paint_area(butt),1e-10
    square=plan('2 J 2 w 10 20 m 30 20 l S')
    assert_equal [9,19,31,21],bounds(square)
    assert_in_delta 44,paint_area(square),1e-10
    round=plan('1 J 2 w 10 20 m 30 20 l S')
    assert_equal [9,19,31,21],bounds(round)
    assert_in_delta 40+Math::PI,paint_area(round),0.003
  end
  def test_closed_rectangle_has_centered_miter_bands_and_keeps_counter_empty
    stroke=plan('2 w 10 20 30 40 re S')
    assert_equal [9,19,41,61],bounds(stroke)
    assert_equal 4,stroke[:polygons].length
    assert_in_delta 32*42-28*38,paint_area(stroke),1e-10
    stroke[:polygons].each do |loop|
      assert_equal 0,IMP::SvgRegionBoundary.winding([25.to_r,40.to_r],loop)
    end
  end
  def test_round_and_bevel_joins_and_miter_limit_are_geometric_not_native_profiles
    bevel=plan('2 j 2 w 10 20 30 40 re S')
    rounded=plan('1 j 2 w 10 20 30 40 re S')
    clipped_miter=plan('1 M 2 w 10 20 30 40 re S')
    assert_in_delta 278,paint_area(bevel),1e-10
    assert_in_delta 276+Math::PI,paint_area(rounded),0.003
    assert_equal bevel[:polygons],clipped_miter[:polygons]
    assert_equal [9,19,41,61],bounds(rounded)
  end
  def test_closed_seam_has_joins_not_open_round_caps
    assert_equal plan('2 w 10 20 30 40 re S')[:polygons],
      plan('1 J 2 w 10 20 30 40 re S')[:polygons]
  end
  def test_nonuniform_sheared_and_reflected_ctm_transform_actual_footprints
    nonuniform=plan('2 0 0 3 5 7 cm 2 w 10 20 m 30 20 l S')
    assert_equal [25,64,65,70],bounds(nonuniform)
    assert_in_delta 240,paint_area(nonuniform),1e-10
    sheared=plan('1 0 2 1 0 0 cm 2 w 10 20 m 30 20 l S')
    assert_equal [[48,19],[68,19],[72,21],[52,21]],sheared[:polygons].first
    reflected=plan('-2 0 0 3 5 7 cm 2 w 10 20 m 30 20 l S')
    assert_equal [-55,64,-15,70],bounds(reflected)
    assert_in_delta 240,paint_area(reflected),1e-10
    assert Subject.area2(reflected[:polygons].first)>0
  end
  def test_complete_painted_width_is_clipped_even_when_centerline_is_outside
    stroke=plan('4 w -1 1 m -1 9 l S',[0,0,10,10])
    assert_equal [0,1,1,9],bounds(stroke)
    assert_in_delta 8,paint_area(stroke),1e-10
  end
  def test_width_collapsing_counter_nonconvex_and_open_multisegment_are_explicit
    ['40 w 10 20 30 40 re S',
     '2 w 0 0 m 10 0 l 4 4 l 10 10 l 0 10 l h S',
     '2 w 0 0 m 10 0 l 10 10 l S',
     '1 w 0 10 m 6 -8 l -10 3 l 10 3 l -6 -8 l h S'].each do |stream|
      assert_raises(Subject::Unsupported) { plan(stream) }
    end
  end
  def test_hairlines_dashes_fill_stroke_transparency_and_unproven_ctm_do_not_certify
    ['0 w 10 20 m 30 20 l S','[3 2] 1 d 2 w 10 20 m 30 20 l S',
     '2 w 10 20 30 40 re B','10 20 m 2 0 0 2 0 0 cm 30 20 l S'].each do |stream|
      assert_raises(Subject::Unsupported) { plan(stream) }
    end
    path=parse('2 w 10 20 m 30 20 l S').first
    path.source_stroke_opacity=0.5
    assert_raises(Subject::Unsupported) { Subject.plan(path,[[10,20],[30,20]],false,BOX) }
  end
  def test_midpath_cm_and_restored_ctm_only_change_provenance_not_existing_coordinates
    path=parse('10 20 m 2 0 0 3 5 7 cm 30 20 l S').first
    assert_equal [[25.0,67.0],[65.0,67.0]],path.subpaths.first.segments.last.points
    assert_equal false,path.source_stroke_ctm_proven
    restored=parse('q 2 0 0 3 5 7 cm 10 20 m Q 30 20 l S').first
    assert_equal [[10.0,20.0],[30.0,20.0]],restored.subpaths.first.segments.last.points
    assert_equal false,restored.source_stroke_ctm_proven
    paths=parse('10 20 m 2 0 0 3 5 7 cm 30 20 l S 10 20 m 30 20 l S')
    assert_equal [false,true],paths.map(&:source_stroke_ctm_proven)
    transformed=IMP::XObjectParser.new(nil).send(:transform_paths,[paths.last],[1,0,0,1,4,8]).first
    assert_equal true,transformed.source_stroke_ctm_proven
  end
  def test_curve_sampling_is_width_relative_bounded_and_does_not_fit_an_analytic_circle
    stream='1.5 w 280 50 m 280 38.9543 288.9543 30 300 30 c 311.0457 30 320 38.9543 320 50 c 320 61.0457 311.0457 70 300 70 c 288.9543 70 280 61.0457 280 50 c h S'
    stroke=plan(stream)
    assert_equal true,stroke[:curve_sampled]
    assert_in_delta 1.5/64,stroke[:source_curve_tolerance_pdf_points],1e-12
    assert stroke[:centerline].length <= Subject::MAX_POINTS
    assert_in_delta 2*Math::PI*20*1.5,paint_area(stroke),0.15
    assert_raises(Subject::Unsupported) { plan(stream.sub('1.5 w','0.000000001 w')) }
  end
  def test_pattern_or_unresolved_color_cannot_certify_stale_rgb_and_q_restore_recovers_solid_proof
    paths=parse('1 0 0 RG q /Pattern CS /P0 SCN 2 w 10 20 m 30 20 l S Q 2 w 10 30 m 30 30 l S')
    assert_equal [1.0,0.0,0.0],paths.first.stroke_color
    assert_equal [false,true],paths.map(&:source_stroke_solid_color_proven)
    assert_raises(Subject::Unsupported) { Subject.flatten_subpath(paths.first,paths.first.subpaths.first) }
    transformed=IMP::XObjectParser.new(nil).send(:transform_paths,[paths.first],[1,0,0,1,4,8]).first
    assert_equal false,transformed.source_stroke_solid_color_proven
    ['/Unknown CS 0.5 SCN','/Pattern CS 0.5 /P0 SCN','/DeviceRGB CS 0.2 SC',
     '/DeviceRGB CS 0.2 0.4 0.6 /P0 SCN'].each do |prefix|
      assert_raises(Subject::Unsupported) { plan(prefix+' 2 w 10 20 m 30 20 l S') }
    end
    assert_equal [51,102,153],plan('/DeviceRGB CS 0.2 0.4 0.6 SCN 2 w 10 20 m 30 20 l S')[:source_rgb]
  end

  Vertex=Struct.new(:position)
  Color=Struct.new(:red,:green,:blue)
  Material=Struct.new(:color,:alpha,:texture)
  Loop=Struct.new(:vertices)
  class Edge
    attr_accessor :layer,:material,:hidden
    attr_reader :start,:end
    def initialize(p,q); @start,@end=Vertex.new(p),Vertex.new(q); end
    def valid?; true; end
    def hidden?; @hidden == true; end
  end
  class Face
    attr_accessor :layer,:material,:back_material
    attr_reader :outer_loop,:edges
    def initialize(points,alter)
      points=points.dup
      points[0]=Geom::Point3d.new(points[0].x+1,points[0].y,0) if alter
      @outer_loop=Loop.new(points.map { |p| Vertex.new(p) })
      @edges=points.each_with_index.map { |p,i| Edge.new(p,points[(i+1)%points.length]) }
    end
    def loops; [outer_loop]; end
    def typename; 'Face'; end
    def valid?; true; end
    def normal; Struct.new(:z).new(1); end
  end
  class Entities
    attr_reader :items
    def initialize(alter=false,ignore_hidden=false); @items=[]; @alter,@ignore_hidden=alter,ignore_hidden; end
    def add_group; g=Group.new(@alter,@ignore_hidden); @items << g; g; end
    def add_face(points); f=Face.new(points,@alter); @items << f; f; end
    def add_line(p,q); e=Edge.new(p,q); @items << e; e; end
  end
  class Group
    attr_accessor :name,:transformation,:layer
    attr_reader :entities
    def initialize(alter=false,ignore_hidden=false); @entities=Entities.new(alter,ignore_hidden); @attrs={}; @ignore_hidden=ignore_hidden; end
    def valid?; !@erased; end
    def erase!; @erased=true; end
    def hidden=(value); @hidden=value unless @ignore_hidden; end
    def hidden?; @hidden == true; end
    def set_attribute(dictionary,key,value); @attrs[[dictionary,key]]=value; end
    def get_attribute(dictionary,key,default); @attrs.fetch([dictionary,key],default); end
  end
  def test_native_builder_retains_real_boundary_and_editable_hidden_centerline
    owner=Entities.new
    material=Material.new(Color.new(0,0,0),1.0,nil)
    result=Subject.build!(owner,plan('2 w 10 20 m 30 20 l S'),
      lambda { |x,y| Geom::Point3d.new(x/72,y/72,0) },material,:layer)
    assert_equal 1,result[:face_count]
    assert_equal 5,result[:edge_count]
    group=result[:group]
    assert group.entities.items.last.hidden?
    face=group.entities.items.first.entities.items.first
    assert face.edges.all?(&:hidden?)
    assert_same material,face.material
    actual=face.outer_loop.vertices.map { |v| v.position.transform(group.transformation) }
    assert_equal [10.0/72,19.0/72,30.0/72,21.0/72],
      [actual.map(&:x).min,actual.map(&:y).min,actual.map(&:x).max,actual.map(&:y).max]
  end
  def test_host_coordinate_change_or_ignored_hidden_container_is_terminal_and_cleans_owned_group
    [Entities.new(true),Entities.new(false,true)].each do |owner|
      assert_raises(IMP::RepresentationFidelity::ContractError) do
        Subject.build!(owner,plan('2 w 10 20 m 30 20 l S'),lambda { |x,y| Geom::Point3d.new(x/72,y/72,0) },Material.new(Color.new(0,0,0),1.0,nil),nil)
      end
      refute owner.items.first.valid?
    end
  end
  def test_wrong_native_rgb_is_terminal_and_erases_owned_footprint
    owner=Entities.new
    assert_raises(IMP::RepresentationFidelity::ContractError) do
      Subject.build!(owner,plan('2 w 10 20 m 30 20 l S'),lambda { |x,y| Geom::Point3d.new(x/72,y/72,0) },Material.new(Color.new(255,0,0),1.0,nil),nil)
    end
    refute owner.items.first.valid?
  end
  class RetainedGroup < Group
    def erase!; end
  end
  class RetainedOwner < Entities
    def add_group
      group=RetainedGroup.new(true)
      @items << group
      group
    end
  end
  def test_failed_owned_cleanup_retains_original_boundary_failure_and_reports_uncertainty
    owner=RetainedOwner.new
    error=assert_raises(IMP::RepresentationFidelity::ContractError) do
      Subject.build!(owner,plan('2 w 10 20 m 30 20 l S'),lambda { |x,y| Geom::Point3d.new(x/72,y/72,0) },Material.new(Color.new(0,0,0),1.0,nil),nil)
    end
    assert_match(/changed source boundary vertices/,error.message)
    assert_match(/cleanup failed.*remains valid/,error.message)
    assert owner.items.first.valid?
  end
end
