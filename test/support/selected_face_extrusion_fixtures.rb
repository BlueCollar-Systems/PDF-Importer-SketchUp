# Isolated native API fixtures. No host, dialogs, PDFs or product writes.
module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x,y,z); @x,@y,@z=x.to_f,y.to_f,z.to_f; end
    def transform(t); t.transform_point(self); end
  end
  class Transformation
    def initialize(a = nil); @a=a || [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]; end
    def to_a; @a.dup; end
    def transform_point(p)
      v=[p.x,p.y,p.z,1.0]
      values=4.times.map { |r| 4.times.inject(0.0) { |s,c| s+@a[c*4+r]*v[c] } }
      Point3d.new(*values.first(3).map { |value| value/values[3] })
    end
    def self.scale(x,y=nil,z=nil)
      y ||= x; z ||= x
      new([x,0,0,0,0,y,0,0,0,0,z,0,0,0,0,1])
    end
  end
end

module Sketchup
  Layer=Struct.new(:visible) do
    def visible?; visible; end
  end
  Vertex=Struct.new(:position)
  Loop=Struct.new(:vertices,:outer) do
    def outer?; outer; end
  end
  Material=Struct.new(:name,:alpha,:texture) do
    def color
      # Authored distinct fixture colors, independent of Material identity.
      values=name.to_s.include?('front') ? [255,0,0,255] : [0,0,255,255]
      object=Object.new;object.define_singleton_method(:to_a) { values };object
    end
  end
  class Entity
    attr_accessor :hidden, :locked, :layer, :valid
    attr_reader :entityID, :model
    def initialize(model)
      @model=model; @entityID=model.next_id; @valid=true
      @hidden=false; @locked=false; @layer=Layer.new(true); @attrs={}
      model.entity_registry << self
    end
    def valid?; @valid; end
    def hidden?; @hidden; end
    def locked?; @locked; end
    def get_attribute(d,k,default=nil); @attrs.fetch([d,k],default); end
    def set_attribute(d,k,v); @attrs[[d,k]]=v; end
    def base_state; [@valid,@hidden,@locked,@layer,@attrs.dup]; end
    def restore_base(s); @valid,@hidden,@locked,@layer,@attrs=s; end
    def copy_attributes(other)
      other.hidden=@hidden; other.locked=@locked; other.layer=@layer
      @attrs.each { |(d,k),v| other.set_attribute(d,k,v) }
      other
    end
  end
  class Edge < Entity
    attr_reader :start, :end
    attr_accessor :faces
    def initialize(model,p,q)
      super(model); @start=Vertex.new(p); @end=Vertex.new(q); @faces=[]
    end
    def state; [base_state,coordinates(@start.position),coordinates(@end.position),@faces.dup]; end
    def restore(s)
      restore_base(s[0]); assign(@start.position,s[1]); assign(@end.position,s[2]); @faces=s[3]
    end
    def coordinates(p); [p.x,p.y,p.z]; end
    def assign(p,v); p.x,p.y,p.z=v; end
  end
  class Entities
    attr_accessor :items
    attr_reader :model
    def initialize(model); @model=model; @items=[]; model.owner_registry << self; end
    def to_a; @items.dup; end
    def add_face(loops,normal=[0,0,1]); Face.new(self,loops,normal); end
    def clone_entities
      copy=Entities.new(model)
      face_edges=@items.select { |e| e.is_a?(Face) }.map(&:edges).flatten
      @items.each do |e|
        if e.is_a?(Face)
          e.clone_into(copy)
        elsif e.is_a?(Group) || e.is_a?(ComponentInstance)
          e.copy_attributes(e.class.new(model,e.definition,e.transformation,copy))
        elsif e.is_a?(Edge) && !face_edges.include?(e)
          copy.items << e.copy_attributes(Edge.new(model,
            Geom::Point3d.new(e.start.position.x,e.start.position.y,e.start.position.z),
            Geom::Point3d.new(e.end.position.x,e.end.position.y,e.end.position.z)))
        end
      end
      copy
    end
  end
  class Face < Entity
    attr_reader :owner, :loops, :edges, :calls, :normal, :copy_calls
    attr_accessor :mode, :connected_extras, :peer_to_move, :material, :back_material,
      :reverse_mode, :uv_front, :uv_back
    attr_reader :reverse_calls
    def initialize(owner,loops,normal=[0,0,1])
      super(owner.model); @owner=owner; @calls=[]; @copy_calls=[]; @mode=:normal; @connected_extras=[]
      @normal=Geom::Point3d.new(*normal)
      @reverse_calls=0;@reverse_mode=:normal
      @uv_front=lambda { |p| Geom::Point3d.new(p.x,p.y,1.0) }
      @uv_back=lambda { |p| Geom::Point3d.new(p.x+3.0,p.y+5.0,1.0) }
      @loops=loops.each_with_index.map { |points,i| Loop.new(points.map { |p| Vertex.new(Geom::Point3d.new(*p)) },i==0) }
      @edges=[]
      @loops.each do |loop|
        loop.vertices.each_with_index do |v,i|
          following=loop.vertices[(i+1)%loop.vertices.length].position
          key=[[v.position.x,v.position.y,v.position.z],[following.x,following.y,following.z]].sort
          edge=owner.items.find do |candidate|
            candidate.is_a?(Edge) && [[candidate.start.position.x,candidate.start.position.y,candidate.start.position.z],[candidate.end.position.x,candidate.end.position.y,candidate.end.position.z]].sort==key
          end
          unless edge
            edge=Edge.new(model,v.position,following);owner.items << edge
          end
          edge.faces << self;@edges << edge
        end
      end
      owner.items << self
    end
    def all_connected; [self]+@edges+@connected_extras; end
    def positions; @loops.map { |loop| loop.vertices.map { |v| [v.position.x,v.position.y,v.position.z] } }; end
    def state; [base_state,positions,[@normal.x,@normal.y,@normal.z],@connected_extras.dup,@material,@back_material,@uv_front,@uv_back,@reverse_calls]; end
    def restore(s)
      restore_base(s[0]); @loops.each_with_index do |loop,i|
        loop.vertices.each_with_index { |v,j| v.position.x,v.position.y,v.position.z=s[1][i][j] }
      end
      @normal=Geom::Point3d.new(*s[2]);@connected_extras=s[3]
      @material,@back_material,@uv_front,@uv_back,@reverse_calls=s[4,5]
    end
    def clone_into(owner)
      clone=copy_attributes(Face.new(owner,positions,[@normal.x,@normal.y,@normal.z]))
      clone.mode=@mode
      clone.material=@material;clone.back_material=@back_material
      clone.uv_front=@uv_front;clone.uv_back=@uv_back;clone.reverse_mode=@reverse_mode
      clone
    end
    def reverse!
      @reverse_calls+=1
      raise 'native reverse failed' if reverse_mode==:raise
      return false if reverse_mode==:false
      return nil if reverse_mode==:nil
      return self if reverse_mode==:no_effect
      @normal=Geom::Point3d.new(-@normal.x,-@normal.y,-@normal.z)
      unless reverse_mode==:keep_paint
        @material,@back_material=@back_material,@material
        @uv_front,@uv_back=@uv_back,@uv_front
      end
      @loops.first.vertices.first.position.x+=0.25 if reverse_mode==:move_boundary
      @loops.first.vertices.first.position.x+=1.0e-8 if reverse_mode==:move_small_boundary
      if reverse_mode==:uv_drift
        old=@uv_front;@uv_front=lambda { |point| uv=old.call(point);Geom::Point3d.new(uv.x+1.0,uv.y,uv.z) }
      end
      self
    end
    def get_UVHelper(*args)
      face=self
      helper=Object.new
      helper.define_singleton_method(:get_front_UVQ) { |point| face.uv_front.call(point) }
      helper.define_singleton_method(:get_back_UVQ) { |point| face.uv_back.call(point) }
      helper
    end
    def pushpull(depth,copy=false)
      @calls << depth
      @copy_calls << copy
      return nil if mode == :no_effect
      bottom=positions
      magnitude=Math.sqrt(@normal.x**2+@normal.y**2+@normal.z**2)
      delta=[@normal.x,@normal.y,@normal.z].map { |v| v/magnitude*depth }
      @loops.each { |loop| loop.vertices.each { |v| v.position.x+=delta[0]; v.position.y+=delta[1]; v.position.z+=delta[2] } }
      raise 'pushpull rejected the second island' if mode == :raise_after_change
      if mode != :missing_sides
        bottom.each_with_index do |loop,k|
          top=positions[k]
          origin=loop.first
          cross=lambda { |a,b| [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]] }
          area=[0.0,0.0,0.0]
          loop.each_with_index do |p,i|
            q=loop[(i+1)%loop.length]
            value=cross.call(p.zip(origin).map { |a,b| a-b },q.zip(origin).map { |a,b| a-b })
            area=area.zip(value).map { |a,b| a+b }
          end
          sign=(area.zip(delta).inject(0.0) { |sum,(a,b)| sum+a*b }>0.0 ? 1.0 : -1.0)*(k==0 ? 1.0 : -1.0)
          loop.each_with_index do |p,i|
            q=loop[(i+1)%loop.length]
            n=cross.call(q.zip(p).map { |a,b| a-b },delta).map { |value| value*sign }
            length=Math.sqrt(n.inject(0.0) { |sum,value| sum+value*value });n=n.map { |value| value/length }
            side=Face.new(owner,[[p,q,top[(i+1)%loop.length],top[i]]],n)
            side.material=@material;side.back_material=@back_material
          end
        end
        # Actual SU2017 pushpull(copy=true) leaves the starting cap's original
        # front direction. The old fixture's always-outward base masked this.
        base=Face.new(owner,bottom,[@normal.x,@normal.y,@normal.z])
        base.material=@material;base.back_material=@back_material
        base.uv_front=@uv_front;base.uv_back=@uv_back;base.reverse_mode=@reverse_mode
        base.edges.first.faces.pop if mode==:open_skin
        if mode==:inward_side
          side=owner.items.grep(Face).find { |face| face!=self && face!=base }
          side.instance_variable_set(:@normal,Geom::Point3d.new(-side.normal.x,-side.normal.y,-side.normal.z))
        end
      end
      if @peer_to_move
        @peer_to_move.loops.first.vertices.first.position.x+=1.0
      end
      nil
    end
  end
  class Definition
    attr_accessor :instances, :entities, :live
    def initialize(model,entities=nil)
      @model=model; @entities=entities || Entities.new(model); @instances=[]; @live=false
      model.definition_registry << self
    end
    def live_component?; @live; end
    def copy; Definition.new(@model,@entities.clone_entities); end
  end
  class ComponentInstance < Entity
    attr_accessor :definition, :transformation, :unique_mode
    attr_reader :unique_calls
    def initialize(model,definition,transformation=Geom::Transformation.new,owner=model.entities)
      super(model); @definition=definition; @transformation=transformation; @unique_calls=0
      definition.instances << self; owner.items << self
    end
    def make_unique
      @unique_calls+=1
      return false if @unique_mode == :false
      return self if @unique_mode == :leave_shared
      if @definition.instances.select(&:valid?).length > 1
        @definition.instances.delete(self); @definition=@definition.copy; @definition.instances << self
      end
      self
    end
    def state; [base_state,@definition,@transformation]; end
    def restore(s); restore_base(s[0]); @definition,@transformation=s[1],s[2]; end
  end
  class Group < ComponentInstance
    def entities; @definition.entities; end
  end
end

class FixtureModel
  attr_reader :entities, :entity_registry, :owner_registry, :definition_registry, :calls
  attr_accessor :selection, :active_path, :edit_transform, :commit_result, :abort_result, :start_result, :open_operation
  def initialize
    @next_id=0; @entity_registry=[]; @owner_registry=[]; @definition_registry=[]
    @entities=Sketchup::Entities.new(self); @selection=[]; @active_path=[]
    @edit_transform=Geom::Transformation.new; @calls=[]
    @commit_result=@abort_result=@start_result=true; @open_operation=false
  end
  def next_id; @next_id+=1; end
  def active_entities; active_path.empty? ? entities : active_path.last.definition.entities; end
  def start_operation(*args)
    @calls << :start
    @snapshot=[@entity_registry.map { |e| [e,e.state] },@owner_registry.map { |e| [e,e.items.dup] },
      @definition_registry.map { |d| [d,d.instances.dup] }]
    @open_operation=true
    @start_result
  end
  def commit_operation
    @calls << :commit
    raise 'commit raised' if @commit_result == :raise
    @open_operation=false if @commit_result == true
    @commit_result
  end
  def abort_operation
    @calls << :abort
    raise 'abort raised' if @abort_result == :raise
    if @abort_result == true && @snapshot
      old=@snapshot[0].map(&:first)
      (@entity_registry-old).each { |e| e.valid=false }
      @snapshot[0].each { |entity,state| entity.restore(state) }
      @snapshot[1].each { |owner,items| owner.items=items }
      @snapshot[2].each { |definition,instances| definition.instances=instances }
      @open_operation=false
    end
    @abort_result
  end
end

