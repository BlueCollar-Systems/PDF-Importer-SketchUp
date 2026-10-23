require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/planar_region_partition'

class PlanarRegionPartitionTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::PlanarRegionPartition
  Boundary = BlueCollarSystems::PDFVectorImporter::SvgRegionBoundary

  def rect(x0, y0, x1, y1)
    [[x0, y0, 0], [x1, y0, 0], [x1, y1, 0], [x0, y1, 0]]
  end

  def face(*loops); { :loops => loops }; end

  def area(cells, region)
    cells.select { |cell| cell[:region] == region }.inject(0.to_r) { |sum, cell| sum + cell[:area] }
  end

  def assert_partition(white, ink, expected_white, expected_ink)
    before = Marshal.dump([white, ink])
    cells = Subject.partition(white, ink)
    assert_equal expected_white, area(cells, :white)
    assert_equal expected_ink, area(cells, :ink)
    assert_equal before, Marshal.dump([white, ink])
    cells.each do |cell|
      loop = cell[:loop]
      assert_includes [3, 4], loop.length
      assert_equal loop.length, loop.uniq.length
      assert loop.flatten.all? { |value| value.is_a?(Rational) }
      assert_operator cell[:area], :>, 0
      assert_equal cell[:area] * 2, Boundary.signed_area2(loop)
      # Convex cells have no reentrant corner and need no host subdivision.
      loop.each_index do |i|
        a, b, c = loop[i], loop[(i + 1) % loop.length], loop[(i + 2) % loop.length]
        cross = (b[0]-a[0])*(c[1]-b[1]) - (b[1]-a[1])*(c[0]-b[0])
        assert_operator cross, :>, 0
      end
    end
    cells
  end

  def test_vertical_boundaries_overlapping_ink_and_clipping_to_white
    white = [face(rect(0, 0, 4, 4))]
    ink = [face(rect(1, 1, 3, 3)), face(rect(2, 1, 5, 3))]
    assert_partition(white, ink, 10, 6)
  end

  def test_white_holes_and_ink_counters_remain_open
    white = [face(rect(0, 0, 6, 6), rect(2, 2, 4, 4))]
    ink = [face(rect(1, 1, 5, 5), rect(2, 2, 4, 4))]
    assert_partition(white, ink, 20, 12)
    assert_partition([face(rect(0, 0, 4, 4))],
                     [face(rect(1, 1, 3, 3), rect(Rational(3,2), Rational(3,2), Rational(5,2), Rational(5,2)))],
                     13, 3)
  end

  def test_concave_white_and_crossing_diagonals_add_nonvertex_x_cuts
    white = [face([[0,0,0], [4,0,0], [4,1,0], [1,1,0], [1,4,0], [0,4,0]])]
    assert_partition(white, [face(rect(Rational(1,2), Rational(1,2), 3, 3))],
                     Rational(19,4), Rational(9,4))
    # Two triangles cross at (2,2); 2 is not a source vertex x.
    white = [face(rect(0, 0, 4, 4))]
    ink = [face([[0,0,0], [4,0,0], [0,4,0]]),
           face([[0,0,0], [4,0,0], [4,4,0]])]
    cells = assert_partition(white, ink, 4, 12)
    assert_includes cells.flat_map { |cell| cell[:loop].map(&:first) }, 2.to_r
  end

  def test_coincident_partial_collinear_and_point_touching_edges
    white = [face(rect(0, 0, 2, 2)), face(rect(2, 2, 4, 4))]
    ink = [face(rect(0, 0, 1, 2)), face(rect(0, 0, 1, 2).reverse),
           face(rect(1, 0, 2, 1))]
    assert_partition(white, ink, 5, 3)
    assert_partition([face(rect(0, 0, 4, 4))], [face(rect(0, 0, 4, 4))], 0, 16)
  end

  def test_nonzero_near_parallel_sliver_is_never_discarded
    epsilon = Rational(1, 10**30)
    white = [face(rect(0, 0, 1, 1))]
    ink = [face([[0,0,0], [1,0,0], [1,epsilon*2,0], [0,epsilon,0]])]
    assert_partition(white, ink, 1-epsilon*Rational(3,2), epsilon*Rational(3,2))
  end

  def test_affine_shear_reflection_translation_and_loop_order_preserve_regions
    white = [face(rect(0, 0, 4, 4))]
    ink = [face(rect(1, 1, 3, 3), rect(Rational(3,2), Rational(3,2), Rational(5,2), Rational(5,2)))]
    # Determinant -7 changes winding, with neither axis aligned afterward.
    change = lambda do |records|
      records.reverse.map do |record|
        face(*record[:loops].map do |loop|
          loop.reverse.map { |p| [2*p[0]+p[1]+1000, p[0]-3*p[1]-2000, 0] }
        end)
      end
    end
    assert_partition(change.call(white), change.call(ink), 91, 21)
  end

  def test_classification_matches_analytic_l_shape_with_inset_rectangle
    white = [face([[0,0,0], [4,0,0], [4,1,0], [1,1,0], [1,4,0], [0,4,0]])]
    ink = [face(rect(Rational(1,2), Rational(1,2), 3, 3))]
    cells = Subject.partition(white, ink)
    (0...16).each do |x|
      (0...16).each do |y|
        point = [Rational(x,4)+Rational(1,31), Rational(y,4)+Rational(1,37)]
        in_white = point[0] < 1 || point[1] < 1
        in_ink = point[0] > Rational(1,2) && point[0] < 3 &&
                 point[1] > Rational(1,2) && point[1] < 3
        # An independent convex half-plane test checks both coverage and
        # interior disjointness; it does not reuse the production fill oracle.
        hits = cells.select do |cell|
          loop = cell[:loop]
          loop.each_index.all? do |i|
            a, b = loop[i], loop[(i+1)%loop.length]
            (b[0]-a[0])*(point[1]-a[1]) - (b[1]-a[1])*(point[0]-a[0]) > 0
          end
        end
        assert_equal(in_white ? 1 : 0, hits.length)
        assert_equal(in_ink ? :ink : :white, hits.first[:region]) if in_white
      end
    end
  end

  def test_every_budget_fails_explicitly_and_inputs_stay_unchanged
    white = [face(rect(0, 0, 4, 4))]
    ink = [face(rect(1, 1, 3, 3))]
    before = Marshal.dump([white, ink])
    [:input_edges, :atomic_edges, :slabs, :cells, :predicate_edges].each do |key|
      error = assert_raises(Subject::Error) { Subject.partition(white, ink, key => 1) }
      assert_match(/budget/, error.message)
    end
    assert_equal before, Marshal.dump([white, ink])
  end

  def test_invalid_nonfinite_and_nonplanar_contours_fail_closed
    [Float::NAN, Float::INFINITY, '1'].each do |bad|
      assert_raises(Subject::Error) { Subject.partition([face([[0,0,0], [bad,0,0], [0,1,0]])], []) }
    end
    assert_raises(Subject::Error) { Subject.partition([face([[0,0,1], [1,0,1], [0,1,1]])], []) }
    assert_raises(Subject::Error) { Subject.partition([face([[0,0,0], [1,0,0]])], []) }
  end

  def test_exact_bounds_keep_boundary_and_arbitrarily_close_inside_winding_tests
    epsilon = Rational(1, 10**30)
    prepared = Subject.with_exact_loop_bounds(Boundary.prepare_regions([face(rect(0, 0, 1, 1))], :native_union))
    original = Boundary.method(:winding)
    visited = []
    Boundary.stub(:winding, lambda { |point, loop| visited << point; original.call(point, loop) }) do
      [[-epsilon, Rational(1,2)], [1+epsilon, Rational(1,2)],
       [Rational(1,2), -epsilon], [Rational(1,2), 1+epsilon]].each do |point|
        refute Subject.filled_with_bounds?(prepared, point)
      end
      assert_empty visited
      [[0,0], [1,1], [0,Rational(1,2)], [1,Rational(1,2)],
       [epsilon,Rational(1,2)], [1-epsilon,Rational(1,2)]].each do |point|
        expected = original.call(point, prepared[0][:loops][0]) != 0
        assert_equal expected, Subject.filled_with_bounds?(prepared, point)
        assert_equal point, visited.last
      end
      assert_equal 6, visited.length
    end
  end

  def test_cached_classification_matches_uncached_concave_union_holes_and_touching_edges
    source = [face([[0,0,0], [5,0,0], [5,1,0], [1,1,0], [1,5,0], [0,5,0]]),
              face(rect(1, 1, 5, 5), rect(2, 2, 4, 4)), face(rect(5, 5, 6, 6))]
    baseline = Boundary.prepare_regions(source, :native_union)
    cached = Subject.with_exact_loop_bounds(Boundary.prepare_regions(source, :native_union))
    (-1..25).each do |x|
      (-1..25).each do |y|
        point = [Rational(x,4), Rational(y,4)]
        assert_equal Boundary.filled?(baseline, :native_union, point),
                     Subject.filled_with_bounds?(cached, point)
      end
    end
    refute Subject.filled_with_bounds?(cached, [3,3]), 'the source hole remains empty'
    assert Subject.filled_with_bounds?(cached, [Rational(3,2),3]), 'the surrounding source face remains filled'
  end

  def test_cache_is_exact_immutable_and_rebuilt_from_changed_source_on_each_call
    x = Rational(10**30 + 1, 10**30)
    source = [face(rect(x, 0, x+1, 1))]
    prepared = Boundary.prepare_regions(source, :native_union)
    cached = Subject.with_exact_loop_bounds(prepared)
    assert_equal [x,0,x+1,1], cached[0][:loop_bounds][0]
    assert cached.frozen?
    assert cached[0].frozen?
    assert cached[0][:loops].frozen?
    assert cached[0][:loops][0].frozen?
    assert cached[0][:loops][0][0].frozen?
    assert cached[0][:loop_bounds].frozen?
    assert cached[0][:loop_bounds][0].frozen?
    source[0][:loops][0].each { |point| point[0] += 10 }
    assert Subject.filled_with_bounds?(cached, [x+Rational(1,2),Rational(1,2)])
    fresh = Subject.with_exact_loop_bounds(Boundary.prepare_regions(source, :native_union))
    refute Subject.filled_with_bounds?(fresh, [x+Rational(1,2),Rational(1,2)])
    assert Subject.filled_with_bounds?(fresh, [x+10+Rational(1,2),Rational(1,2)])
    assert_equal 1, Subject.partition(source, []).inject(0.to_r) { |sum, cell| sum + cell[:area] }
  end
end

# The original Rational winding oracle remains independent of slab events.
class PlanarRegionPartitionTest
  def rect(x0,y0,x1,y1)
    [[x0,y0,0],[x1,y0,0],[x1,y1,0],[x0,y1,0]]
  end
  def face(*loops); { :loops => loops }; end
  def partition(white, ink, options = {})
    Subject.partition(white, ink, options)
  end
  def check_area(cells, white, ink)
    assert_equal white, cells.select { |c| c[:region] == :white }.inject(0.to_r) { |sum,c| sum+c[:area] }
    assert_equal ink, cells.select { |c| c[:region] == :ink }.inject(0.to_r) { |sum,c| sum+c[:area] }
  end
  def prepared(records)
    Subject.with_exact_loop_bounds(Boundary.prepare_regions(records, :native_union))
  end
  def boundary_point?(records, point)
    records.any? do |record|
      record[:loops].any? do |loop|
        loop.each_index.any? { |i| Boundary.on_segment?(point, loop[i], loop[(i+1)%loop.length]) }
      end
    end
  end
  def compare_queries(white, ink, xs, ys)
    white, ink = prepared(white), prepared(ink)
    xs.each do |x|
      state = Subject.slab_membership_state(white, ink, x.to_r)
      assert_operator state[:events].length, :<=, Subject.region_edges(white).length + Subject.region_edges(ink).length
      assert state[:events].all? { |e| e[0].is_a?(Rational) }
      ys.sort.each do |y|
        point = [x.to_r, y.to_r]
        # Cell probes are open arrangement interiors. Boundary membership is
        # intentionally outside this private sweep helper's contract.
        next if boundary_point?(white + ink, point)
        expected = [Subject.filled_region_index(white, point), Subject.filled_with_bounds?(ink, point)]
        assert_equal expected, Subject.advance_slab_membership!(state, point[1]), point.inspect
      end
    end
  end
  def test_slab_surrounding_ink_original_monotone_vertex_at_clipped_slab_middle
    white = [face(rect(0,0,2,2))]
    # No ink edge enters the white box. The original vertex x=1 is exactly
    # the sole clipped slab midpoint; strict source x tests lose its crossing.
    ink = [face([[-2,-4,0],[1,-3,0],[4,-4,0],[4,4,0],[-2,4,0]])]
    check_area(partition(white, ink), 0, 4)
    check_area(partition(white, [face(ink[0][:loops][0].reverse)]), 0, 4)
    compare_queries(white, ink, [1], [-5,-2,1,3,5])
  end
  def test_slab_counters_native_union_and_coincident_opposite_direction_events
    white = [face(rect(0,0,8,8), rect(2,2,6,6)), face(rect(3,3,5,5))]
    ink = [face(rect(-1,-1,9,9), rect(1,1,7,7).reverse),
           face(rect(0,0,4,4)), face(rect(0,0,4,4).reverse),
           face(rect(4,0,8,4))]
    partition(white, ink)
    compare_queries(white, ink, [-1,0,1,2,3,4,5,6,7,8,9],
                    [-2,-1,0,Rational(1,2),1,2,Rational(5,2),3,4,5,6,7,8,9,10])
  end
  def test_slab_first_white_owner_retained_through_union_transitions
    white = [face(rect(1,1,5,5), rect(2,2,4,4)),
             face(rect(0,0,6,6)), face(rect(2,2,4,4))]
    ink = [face(rect(3,-1,4,7))]
    partition(white, ink)
    compare_queries(white, ink, [Rational(3,2),3,Rational(9,2)],
                    [-2,Rational(1,2),Rational(3,2),Rational(5,2),Rational(7,2),Rational(9,2),Rational(11,2),7])
  end
  def test_slab_tiny_rational_features_reflections_and_nested_regions
    epsilon = Rational(1,10**30)
    white = [face(rect(0,0,3,3))]
    ink = [face([[0,0,0],[3,0,0],[3,epsilon*2,0],[0,epsilon,0]]),
           face(rect(1,1,2,2), rect(1+epsilon,1+epsilon,2-epsilon,2-epsilon))]
    cells = partition(white, ink)
    assert cells.any? { |c| c[:area] > 0 && c[:area] < epsilon*10 }
    change = lambda do |records|
      records.reverse.map { |r| face(*r[:loops].map { |loop| loop.reverse.map { |p| [2*p[0]+p[1]+100, p[0]-3*p[1]-80, 0] } }) }
    end
    partition(change.call(white), change.call(ink))
  end
  def test_slab_self_crossing_and_overlapping_holes_match_existing_native_union
    white = [face(rect(-3,-3,3,3))]
    ink = [face([[-2,-2,0],[2,2,0],[-2,2,0],[2,-2,0]]),
           face(rect(-2,-2,2,2),rect(-1,-1,1,1),rect(0,0,3,3))]
    partition(white, ink)
    compare_queries(white, ink, [-2,Rational(-3,2),Rational(-1,2),Rational(1,2),Rational(3,2),2],
                    [-4,Rational(-5,2),Rational(-3,2),Rational(-1,2),Rational(1,2),Rational(3,2),Rational(5,2),4])
  end
  def test_slab_many_regions_owner_bitset_exceeds_legacy_machine_word
    white = 80.times.map { |i| face(rect(i*2,0,i*2+1,1)) }
    ink = [face(rect(-1,-1,161,2))]
    state = Subject.slab_membership_state(prepared(white), prepared(ink), Rational(317,2))
    assert_equal [79,true], Subject.advance_slab_membership!(state, Rational(1,2))
    partition(white, ink)
  end
  def test_slab_deterministic_tiny_fixtures_match_original_winding_oracle
    random = Random.new(178)
    completed=0
    white,ink=nil,nil
    16.times do
      white = [face(rect(-3,-3,3,3)), face(rect(0,0,4,4),rect(1,1,2,2))]
      ink = 3.times.map do
        x = Rational(random.rand(-8..6),2)
        y = Rational(random.rand(-8..6),2)
        face(rect(x,y,x+Rational(random.rand(1..6),2),y+Rational(random.rand(1..6),2)))
      end
      partition(white, ink)
      compare_queries(white, ink, [Rational(-5,2),Rational(-1,2),Rational(3,2)],
        (-13..17).map { |value| Rational(value,4) })
      completed+=1
    end
    assert_equal 16, completed
  end
  class Progress
    attr_reader :calls
    def initialize(cancel_at = nil); @calls=[]; @cancel_at=cancel_at; end
    def checkpoint!(stage, metadata)
      @calls << [stage,metadata]
      raise RuntimeError, 'one-shot cancel' if @cancel_at && @calls.length == @cancel_at
    end
  end
  def test_slab_original_budget_failures_and_one_shot_terminal_checkpoint
    white=[face(rect(0,0,4,4))];ink=[face(rect(1,1,3,3))]
    progress=Progress.new
    partition(white,ink,:run_controller=>progress,:page_number=>1)
    assert_equal [:white_mask_intersections,:white_mask_partition],progress.calls.map(&:first).uniq
    assert_equal [:white_mask_partition,{:completed=>3,:total=>3,:page=>1}],progress.calls.last
    controller=Progress.new(3)
    error=assert_raises(RuntimeError) { partition(white,ink,:run_controller=>controller,:page_number=>1) }
    assert_equal 'one-shot cancel',error.message
    assert_equal 3,controller.calls.length
    [:input_edges,:atomic_edges,:slabs,:cells,:predicate_edges].each do |budget|
      assert_raises(Subject::Error) { partition(white,ink,budget=>1) }
    end
  end
  def test_slab_membership_avoids_repeated_winding_but_matches_original_source_oracle
    white=[face(rect(0,0,12,12))]
    ink=6.times.map { |i|face(rect(i+1,i+1,i+Rational(3,2),12-i)) }
    original=Boundary.method(:winding);calls=0
    Boundary.stub(:winding,lambda { |point,loop|calls+=1;original.call(point,loop) }) do
      partition(white,ink)
      assert_equal 0,calls
      compare_queries(white,ink,[Rational(3,2),Rational(9,2),Rational(15,2)],
        (0..49).map { |value|Rational(value,4) })
      assert_operator calls,:>,0
    end
  end

  def test_slab_known_literal_source_cells_keep_order_coordinates_classes_and_areas
    white=[face(rect(0,0,4,4))];ink=[face(rect(1,1,3,3))]
    expected=[[:white,rect(0,0,1,4),4],[:white,rect(1,0,3,1),2],
      [:ink,rect(1,1,3,3),4],[:white,rect(1,3,3,4),2],[:white,rect(3,0,4,4),4]].map do |region,loop,area|
      {:region=>region,:loop=>loop.map { |point|point.map(&:to_r) },:area=>area.to_r}
    end
    assert_equal expected,partition(white,ink)
  end

  def nested_ink_fixture(count = 24)
    white = [face(rect(0,0,10,10))]
    ink = count.times.map do |index|
      inset = Rational(index, count * 4)
      face(rect(1,1+inset,9,9-inset))
    end
    [white,ink]
  end

  def test_maximal_run_avoids_discarded_polygons_but_retains_literal_cells
    white,ink = nested_ink_fixture
    expected = [[:white,rect(0,0,1,10),10],[:white,rect(1,0,9,1),8],
      [:ink,rect(1,1,9,9),64],[:white,rect(1,9,9,10),8],
      [:white,rect(9,0,10,10),10]].map do |region,loop,value|
      {:region=>region,:loop=>loop.map { |point|point.map(&:to_r) },:area=>value.to_r}
    end
    calls = 0
    original = Subject.method(:exact_cell)
    cells = Subject.stub(:exact_cell,lambda { |*args| calls += 1; original.call(*args) }) do
      partition(white,ink)
    end
    assert_equal expected,cells
    assert_equal 5,calls, 'internal same-class intervals do not allocate discarded polygons'
    assert_equal expected,partition(white,ink,:cells=>5)
    error = assert_raises(Subject::Error) { partition(white,ink,:cells=>4) }
    assert_match(/cell budget/,error.message)
  end

  def test_actual_work_cap_covers_original_source_scans_even_when_clipped_out
    white = [face(rect(0,0,1,1))]
    ink = 12.times.map { |index| face(rect(index+10,20,index+11,21)) }
    before = Marshal.dump([white,ink])
    error = assert_raises(Subject::Error) { partition(white,ink,:predicate_edges=>16) }
    assert_match(/predicate budget/,error.message)
    assert_equal before,Marshal.dump([white,ink])
    assert_equal [{:region=>:white,:loop=>rect(0,0,1,1).map { |p|p.map(&:to_r) },:area=>1.to_r}],
      partition(white,ink)
  end

  def test_work_budget_is_one_shared_counter_and_does_not_spend_past_limit
    budget = Subject::WorkBudget.new(3,{},1)
    budget.charge!
    budget.charge!(2)
    assert_equal 3,budget.used
    error = assert_raises(Subject::Error) { budget.charge! }
    assert_match(/predicate budget/,error.message)
    assert_equal 3,budget.used
  end

  def test_deferred_run_still_checks_every_elementary_exact_area_sum
    budget = Subject::WorkBudget.new(10,{},1)
    active = {:region=>:white,:owner=>0,:low_edge=>[[0.to_r,0.to_r],[2.to_r,0.to_r]],
      :high_edge=>[[0.to_r,2.to_r],[2.to_r,2.to_r]],:area=>5.to_r}
    runs = []
    error = assert_raises(Subject::Error) do
      Subject.finish_run!(active,runs,0.to_r,2.to_r,0,10,budget)
    end
    assert_match(/changed covered area/,error.message)
    assert_empty runs
  end

  def test_cells_cap_covers_live_output_and_pending_run_before_polygon_allocation
    budget = Subject::WorkBudget.new(10,{},1)
    active = {:region=>:white,:owner=>0,:low_edge=>[[0.to_r,0.to_r],[2.to_r,0.to_r]],
      :high_edge=>[[0.to_r,2.to_r],[2.to_r,2.to_r]],:area=>4.to_r}
    original = Subject.method(:exact_cell)
    calls = 0
    Subject.stub(:exact_cell,lambda { |*args| calls += 1; original.call(*args) }) do
      assert_raises(Subject::Error) do
        Subject.finish_run!(active,[],0.to_r,2.to_r,1,1,budget)
      end
    end
    assert_equal 0,calls
  end

  class WorkCancel
    attr_reader :seen, :failure
    def initialize
      @seen = []
      @partition_calls = 0
      @failure = RuntimeError.new('one-shot work checkpoint cancellation')
    end
    def checkpoint!(stage, metadata)
      @seen << [stage,metadata]
      return unless stage == :white_mask_partition
      @partition_calls += 1
      raise @failure if @partition_calls == 3
    end
  end

  def test_counted_inner_work_keeps_terminal_exception_identity_and_inputs
    white,ink = nested_ink_fixture(32)
    before = Marshal.dump([white,ink])
    controller = WorkCancel.new
    raised = assert_raises(RuntimeError) do
      partition(white,ink,:run_controller=>controller,:page_number=>7)
    end
    assert_same controller.failure,raised
    assert_equal before,Marshal.dump([white,ink])
    assert_equal 3,controller.seen.count { |row|row[0] == :white_mask_partition }
    assert_equal 7,controller.seen.last[1][:page]
  end
end
