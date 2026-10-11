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
  Loop=Struct.new(:vertices)
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
    attr_accessor :mode, :connected_extras, :peer_to_move
    def initialize(owner,loops,normal=[0,0,1])
      super(owner.model); @owner=owner; @calls=[]; @copy_calls=[]; @mode=:normal; @connected_extras=[]
      @normal=Geom::Point3d.new(*normal)
      @loops=loops.map { |points| Loop.new(points.map { |p| Vertex.new(Geom::Point3d.new(*p)) }) }
      @edges=[]
      @loops.each do |loop|
        loop.vertices.each_with_index do |v,i|
          edge=Edge.new(model,v.position,loop.vertices[(i+1)%loop.vertices.length].position)
          edge.faces=[self]; @edges << edge; owner.items << edge
        end
      end
      owner.items << self
    end
    def all_connected; [self]+@edges+@connected_extras; end
    def positions; @loops.map { |loop| loop.vertices.map { |v| [v.position.x,v.position.y,v.position.z] } }; end
    def state; [base_state,positions,@normal,@connected_extras.dup]; end
    def restore(s)
      restore_base(s[0]); @loops.each_with_index do |loop,i|
        loop.vertices.each_with_index { |v,j| v.position.x,v.position.y,v.position.z=s[1][i][j] }
      end
      @normal,@connected_extras=s[2],s[3]
    end
    def clone_into(owner)
      clone=copy_attributes(Face.new(owner,positions,[@normal.x,@normal.y,@normal.z]))
      clone.mode=@mode
      clone
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
          loop.each_with_index { |p,i| Face.new(owner,[[p,loop[(i+1)%loop.length],top[(i+1)%loop.length],top[i]]],[1,0,0]) }
        end
        Face.new(owner,bottom,[0,0,-1])
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

