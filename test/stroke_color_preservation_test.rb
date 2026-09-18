require_relative 'stroke_clipping_test'

# Native-edge API doubles only; PDF parsing and every builder route are real.
module Geom
  class Vector3d
    attr_accessor :x, :y, :z
    def initialize(x, y, z)
      @x, @y, @z = x.to_f, y.to_f, z.to_f
    end
    def length
      Math.sqrt(x*x + y*y + z*z)
    end
    def length=(value)
      scale = value.to_f / length
      @x *= scale
      @y *= scale
      @z *= scale
    end
  end
end

class StrokeColorPreservationTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  Builder = IMP::GeometryBuilder
  Base = GeometryBuilderStagingTest

  class Edge < Base::Edge
    def initialize(a, b, failure=nil)
      super(a,b)
      @failure = failure
    end
    def material=(value)
      raise 'native setter failed' if @failure == :raise
      @material = value unless @failure == :ignore
    end
  end

  class Entities < Base::Entities
    attr_accessor :failure, :batch_failure
    def add_group
      group = Base::Group.new(self)
      child = Entities.new
      child.failure = failure
      group.instance_variable_set(:@entities, child)
      @items << group
      @groups_created += 1
      group
    end
    def add_line(a,b)
      edge = Edge.new(a,b,failure)
      @items << edge
      edge
    end
    def add_edges(points)
      raise 'batch unavailable' if batch_failure
      points.each_cons(2).map { |a,b| add_line(a,b) }
    end
    def add_arc(center, xaxis, normal, radius, start, sweep, count)
      [add_line(Geom::Point3d.new(center.x+radius,center.y,0),
                Geom::Point3d.new(center.x,center.y+radius,0))]
    end
  end

  class Model < Base::Model
    def initialize
      super
      @active_entities = Entities.new
    end
  end

  def build(stream, options={}, failure=nil)
    model = Model.new
    model.active_entities.failure = failure
    paths = IMP::ContentStreamParser.new([stream],nil).parse
    builder = Builder.new(model,paths,[],[0,0,100,80],
      {:group_per_page=>false,:detect_arcs=>false,:merge_tolerance=>0}.merge(options))
    result = builder.build
    [model,builder,result]
  end

  def all_edges(entities)
    entities.to_a.flat_map do |node|
      node.respond_to?(:entities) ? all_edges(node.entities) :
        (node.is_a?(Base::Edge) ? [node] : [])
    end
  end

  def rgb(edge)
    color=edge.material.color
    [color.red,color.green,color.blue]
  end

  def test_source_rgb_is_on_edges_with_grouping_on_or_off
    [false,true].each do |grouped|
      model,=build('1 0 0 RG 10 10 m 20 10 l S 0 0 1 RG 10 20 m 20 20 l S 0 G 10 30 m 20 30 l S', :group_by_color=>grouped)
      assert_equal [[255,0,0],[0,0,255],[0,0,0]],all_edges(model.active_entities).map{|e|rgb(e)}
    end
  end

  def test_clipped_strokes_keep_exact_material_and_endpoints
    model,=build('1 0 0 RG 10 20 m 110 20 l S',:group_by_color=>true)
    edge=all_edges(model.active_entities).fetch(0)
    assert_equal [255,0,0],rgb(edge)
    assert_in_delta 100.0/72,edge.end_point.x,1e-12
  end

  def test_heavy_staging_retains_each_path_color_without_mutable_style_leaks
    stream=500.times.map{|i| "#{i.even? ? '1 0 0' : '0 0 1'} RG 10 #{i*0.1} m 20 #{i*0.1} l S"}.join(' ')
    model,_,result=build(stream)
    assert result[:geometry_staging][:enabled]
    edges=all_edges(model.active_entities)
    assert_equal 500,edges.length
    edges.each_with_index{|edge,i|assert_equal(i.even? ? [255,0,0] : [0,0,255],rgb(edge))}
  end

  def test_independent_fill_color_and_hidden_fill_only_support_edges
    model,=build('1 0 0 RG 0 0 1 rg 10 10 10 10 re B 0 1 0 rg 40 40 10 10 re f')
    face=model.active_entities.to_a.grep(Base::Face).first
    assert_equal [0,0,255],[face.material.color.red,face.material.color.green,face.material.color.blue]
    assert all_edges(model.active_entities).all?{|e|rgb(e)==[255,0,0]}
    fills=model.active_entities.to_a.grep(Base::Group).flat_map{|g|g.entities.to_a.grep(Base::Face)}
    assert_equal 1,fills.length
    assert fills.first.edges.all?(&:hidden)
    assert fills.first.edges.all?{|e|e.material.nil?},'fill supports must not acquire stroke ink'
    assert_equal [0,255,0],[fills.first.material.color.red,fills.first.material.color.green,fills.first.material.color.blue]
  end

  def test_batch_fallback_and_physical_dash_segments_retain_material
    model=Model.new
    builder=Builder.new(model,[],[],[0,0,100,80],:merge_tolerance=>0)
    style=builder.send(:source_stroke_style,[0,0,1])
    points=[Geom::Point3d.new(0,0,0),Geom::Point3d.new(2,0,0)]
    model.active_entities.batch_failure=true
    builder.send(:draw_edges,model.active_entities,points,nil,nil,nil,false,style)
    assert_equal [[0,0,255]],all_edges(model.active_entities).map{|e|rgb(e)}
    model.active_entities.batch_failure=false
    builder.send(:draw_edges,model.active_entities,points,nil,nil,{:pattern=>[0.25,0.25],:phase=>0},false,style)
    assert_equal 5,all_edges(model.active_entities).length
    assert all_edges(model.active_entities).all?{|e|rgb(e)==[0,0,255]}
  end

  def arc_stub
    [{:type=>:arc,:start_pt=>[1,0],:mid_pt=>[0.70710678,0.70710678],
      :end_pt=>[0,1],:center=>[0,0],:radius=>1,:points=>[[1,0],[0.70710678,0.70710678],[0,1]]}]
  end

  def test_native_arc_edges_retain_material
    model=Model.new
    builder=Builder.new(model,[],[],[0,0,100,80])
    style=builder.send(:source_stroke_style,[1,0,0])
    points=[Geom::Point3d.new(1,0,0),Geom::Point3d.new(0,1,0)]
    IMP::ArcFitter.stub(:detect_arcs_in_polyline,arc_stub) do
      builder.send(:draw_with_arc_detection,model.active_entities,points,nil,nil,nil,false,false,nil,style)
    end
    assert_equal [[255,0,0]],all_edges(model.active_entities).map{|e|rgb(e)}
  end

  def test_failed_and_ignored_setters_abort_all_edge_routes
    [:raise,:ignore].each do |failure|
      [:batch,:line,:dash,:arc,:clipped].each do |route|
        model=Model.new
        model.active_entities.failure=failure
        builder=Builder.new(model,[],[],[0,0,100,80],:merge_tolerance=>0)
        style=builder.send(:source_stroke_style,[1,0,0])
        points=[Geom::Point3d.new(1,0,0),Geom::Point3d.new(0,1,0)]
        assert_raises(Builder::StrokeStyleFailure,"#{failure} #{route}") do
          case route
          when :batch
            builder.send(:draw_edges,model.active_entities,points,nil,nil,nil,false,style)
          when :line
            builder.send(:safe_add_line,model.active_entities,*points,nil,nil,nil,style)
          when :dash
            builder.send(:add_dashed_line,model.active_entities,*points,{:pattern=>[0.2,0.2],:phase=>0},nil,style)
          when :arc
            IMP::ArcFitter.stub(:detect_arcs_in_polyline,arc_stub) do
              builder.send(:draw_with_arc_detection,model.active_entities,points,nil,nil,nil,false,false,nil,style)
            end
          when :clipped
            build('1 0 0 RG 10 20 m 110 20 l S',{},failure)
          end
        end
      end
    end
  end

  def test_material_creation_failure_or_ignored_color_setter_is_not_success
    [:raise,:ignore].each do |failure|
      model=Model.new
      material=Object.new
      material.define_singleton_method(:color=){|v|raise 'color setter failed' if failure==:raise}
      material.define_singleton_method(:color){Sketchup::Color.new(0,0,0)}
      model.materials.define_singleton_method(:add){|name|material}
      builder=Builder.new(model,[],[],[0,0,100,80])
      assert_raises(Builder::StrokeStyleFailure){builder.send(:source_stroke_style,[1,0,0])}
    end
  end

  def test_matching_user_material_name_cannot_add_transparency_or_texture
    model=Model.new
    user=model.materials.add('PDF_Stroke_255_0_0')
    user.color=Sketchup::Color.new(255,0,0)
    user.alpha=0.2
    user.texture=:user_texture
    builder=Builder.new(model,[],[],[0,0,100,80])
    style=builder.send(:source_stroke_style,[1,0,0])
    refute_same user,style[:material]
    assert_equal 1.0,style[:material].alpha
    assert_nil style[:material].texture
    assert_equal 0.2,user.alpha
    assert_equal :user_texture,user.texture
    assert_equal user,model.materials['PDF_Stroke_255_0_0']
  end

  def test_ignored_setter_cannot_pass_with_a_different_same_rgb_material
    model=Model.new
    builder=Builder.new(model,[],[],[0,0,100,80])
    style=builder.send(:source_stroke_style,[1,0,0])
    old=Base::Material.new
    old.color=Sketchup::Color.new(255,0,0)
    old.alpha=0.2
    edge=Edge.new(Geom::Point3d.new(0,0,0),Geom::Point3d.new(1,0,0),:ignore)
    edge.instance_variable_set(:@material,old)
    assert_raises(Builder::StrokeStyleFailure){builder.send(:style_stroke_edge,edge,style)}
    assert_same old,edge.material
  end

  def test_source_stroke_style_is_frozen_and_cache_does_not_recolor_peers
    model=Model.new
    builder=Builder.new(model,[],[],[0,0,100,80])
    red=builder.send(:source_stroke_style,[1,0,0])
    blue=builder.send(:source_stroke_style,[0,0,1])
    assert red.frozen?
    assert red[:rgb].frozen?
    assert_equal red[:material],builder.send(:source_stroke_style,[1,0,0])[:material]
    refute_equal red[:material],blue[:material]
    assert_equal [255,0,0],builder.send(:stroke_material_rgb,red[:material])
  end
end
