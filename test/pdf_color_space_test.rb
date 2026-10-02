require 'minitest/autorun'
require 'tmpdir'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/xobject_parser'

# Named colour spaces must import as the colour a PDF viewer shows. A
# one-component colour in a Separation space is an ink amount, not a gray
# level: "/CsK CS 1 SCN" is full black ink and used to be imported white.
# Every fixture is synthetic (job D042, marks EX100).
class PdfColorSpaceTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  Parser = IMP::ContentStreamParser
  CS = IMP::PdfColorSpace
  BIN = Encoding::BINARY

  LINE = '0 0 m 10 0 l S'.freeze
  BOX = '0 0 10 10 re f'.freeze
  BLACK = [0.0, 0.0, 0.0].freeze
  WHITE = [1.0, 1.0, 1.0].freeze

  # Parsed-object store in the shapes PDFParser returns: numbers, names and
  # references are Strings, arrays are Arrays, dictionaries are Hashes.
  class Store
    def initialize(objects = {}, streams = {})
      @objects = objects
      @streams = streams
    end

    def resolve_object(value)
      value.is_a?(String) && value =~ /\A(\d+) \d+ R\z/ ? @objects[Regexp.last_match(1).to_i] : value
    end

    def get_stream_data(number)
      @streams[number]
    end
  end

  GRAY_RAMP = { '/FunctionType' => '2', '/Domain' => %w[0 1], '/C0' => ['1'], '/C1' => ['0'], '/N' => '1' }.freeze
  BLACK_INK = ['/Separation', '/Black', '/DeviceGray', GRAY_RAMP].freeze

  def parse(stream, spaces, store = Store.new)
    Parser.new([stream], store, {}, {}, { '/ColorSpace' => spaces }).parse
  end

  def strokes(stream, spaces, store = Store.new)
    parse(stream, spaces, store).map(&:stroke_color)
  end

  def fills(stream, spaces, store = Store.new)
    parse(stream, spaces, store).map(&:fill_color)
  end

  def assert_rgb(expected, actual, delta = 0.002)
    assert_kind_of Array, actual
    assert_equal 3, actual.length
    expected.each_index do |index|
      assert_in_delta expected[index], actual[index], delta,
                      "channel #{index} of #{actual.inspect}, expected #{expected.inspect}"
    end
  end

  def function(reference, store)
    CS::Function.build(reference, CS::Objects.new(store))
  end

  def calculator(source, inputs, range = %w[0 1])
    store = Store.new({ 9 => { '/FunctionType' => '4', '/Domain' => %w[0 1] * inputs, '/Range' => range } },
                      { 9 => source })
    function('9 0 R', store)
  end

  # -------------------------------------------------------------------
  # Separation
  # -------------------------------------------------------------------
  def test_separation_black_full_tint_is_black_and_zero_tint_is_white
    spaces = { '/CsK' => BLACK_INK }
    colors = strokes("/CsK CS 1 SCN #{LINE} 0 SCN #{LINE} 0.25 SC #{LINE}", spaces)
    assert_rgb BLACK, colors[0]
    assert_rgb WHITE, colors[1]
    assert_rgb [0.75, 0.75, 0.75], colors[2]
    colors = fills("/CsK cs 1 scn #{BOX} 0 scn #{BOX}", spaces)
    assert_rgb BLACK, colors[0]
    assert_rgb WHITE, colors[1]
  end

  def test_selecting_a_separation_space_starts_at_full_tint
    spaces = { '/CsK' => BLACK_INK }
    paths = parse("1 G 1 g /CsK CS /CsK cs #{LINE} #{BOX}", spaces)
    assert_rgb BLACK, paths[0].stroke_color
    assert_rgb BLACK, paths[1].fill_color
  end

  def test_separation_without_a_usable_function_uses_the_colorant_name
    spaces = {
      '/CsK' => ['/Separation', '/Black', '/DeviceGray', '99 0 R'],
      '/CsAll' => ['/Separation', '/All', '/DeviceCMYK', '99 0 R'],
      '/CsC' => ['/Separation', '/Cyan', '/DeviceCMYK', '99 0 R'],
      '/CsM' => ['/Separation', '/Magenta', '/DeviceCMYK', '99 0 R'],
      '/CsY' => ['/Separation', '/Yellow', '/DeviceCMYK', '99 0 R'],
      '/CsSpot' => ['/Separation', '/EX100#20Primer', '/DeviceCMYK', '99 0 R']
    }
    stream = "/CsK CS 1 SCN #{LINE} 0.25 SCN #{LINE} /CsAll CS 1 SCN #{LINE} " \
             "/CsC CS 1 SCN #{LINE} /CsM CS 1 SCN #{LINE} /CsY CS 1 SCN #{LINE} " \
             "/CsSpot CS 1 SCN #{LINE} 0.4 SCN #{LINE} 0 SCN #{LINE}"
    colors = strokes(stream, spaces)
    assert_rgb BLACK, colors[0]
    assert_rgb [0.75, 0.75, 0.75], colors[1]
    assert_rgb BLACK, colors[2]
    assert_rgb [0.0, 1.0, 1.0], colors[3]
    assert_rgb [1.0, 0.0, 1.0], colors[4]
    assert_rgb [1.0, 1.0, 0.0], colors[5]
    assert_rgb BLACK, colors[6]
    assert_rgb [0.6, 0.6, 0.6], colors[7]
    assert_rgb WHITE, colors[8]
  end

  def test_separation_none_paints_nothing
    spaces = { '/CsNone' => ['/Separation', '/None', '/DeviceGray', GRAY_RAMP], '/CsK' => BLACK_INK }
    assert_empty parse("/CsNone CS 1 SCN #{LINE} /CsNone cs 1 scn #{BOX}", spaces)

    paths = parse("0 0 1 RG /CsNone cs 1 scn 0 0 10 10 re B q /CsK cs 1 scn #{BOX} Q #{BOX} 0 g #{BOX}", spaces)
    assert_equal 3, paths.length
    assert_equal [true, false], [paths[0].stroke, paths[0].fill]
    assert_rgb [0.0, 0.0, 1.0], paths[0].stroke_color
    assert_equal [false, true], [paths[1].stroke, paths[1].fill]
    assert_rgb BLACK, paths[1].fill_color
    # Q restored the /None fill (no path); a device colour paints again.
    assert_rgb BLACK, paths[2].fill_color
  end

  def test_spot_separation_with_exponential_function_into_device_cmyk
    orange = { '/FunctionType' => '2', '/Domain' => %w[0 1], '/C0' => %w[0 0 0 0],
               '/C1' => %w[0 0.5 1 0], '/N' => '1' }
    spaces = { '/CsSpot' => ['/Separation', '/EX100#20Orange', '/DeviceCMYK', orange] }
    colors = strokes("/CsSpot CS 1 SCN #{LINE} 0.5 SCN #{LINE} 0 SCN #{LINE}", spaces)
    assert_rgb [1.0, 0.5, 0.0], colors[0]
    assert_rgb [1.0, 0.75, 0.5], colors[1]
    assert_rgb WHITE, colors[2]

    curved = orange.merge('/C1' => %w[0 0 0 1], '/N' => '2')
    colors = fills("/CsSpot cs 0.5 scn #{BOX}", '/CsSpot' => ['/Separation', '/EX100', '/DeviceCMYK', curved])
    assert_rgb [0.75, 0.75, 0.75], colors[0]
  end

  def test_separation_with_calculator_function
    store = Store.new(
      { 20 => { '/FunctionType' => '4', '/Domain' => %w[0 1], '/Range' => %w[0 1 0 1 0 1 0 1] } },
      { 20 => '{ 0 exch dup 0.5 mul exch 0 }' }
    )
    spaces = { '/CsSpot' => ['/Separation', '/EX100', '/DeviceCMYK', '20 0 R'] }
    colors = strokes("/CsSpot CS 1 SCN #{LINE} 0.5 SCN #{LINE}", spaces, store)
    assert_rgb [1.0, 0.5, 0.0], colors[0]
    assert_rgb [1.0, 0.75, 0.5], colors[1]
  end

  def test_separation_with_sampled_function_into_an_icc_rgb_alternate
    ramp = ''.dup.force_encoding(BIN)
    255.times do |step|
      t = step / 254.0
      [255 - (255 - 32) * t, 255 - (255 - 48) * t, 255 - (255 - 64) * t].each { |value| ramp << value.round }
    end
    store = Store.new(
      { 21 => { '/FunctionType' => '0', '/Domain' => %w[0 1], '/Range' => %w[0 1 0 1 0 1],
                '/Size' => ['255'], '/BitsPerSample' => '8', '/Encode' => %w[0 254],
                '/Decode' => %w[0 1 0 1 0 1] },
        22 => { '/N' => '3', '/Alternate' => '/DeviceRGB' },
        23 => ['/ICCBased', '22 0 R'] },
      { 21 => ramp }
    )
    spaces = { '/CsK' => ['/Separation', '/Black', '23 0 R', '21 0 R'] }
    colors = strokes("/CsK CS 1 SCN #{LINE} 0 SCN #{LINE} 0.5 SCN #{LINE}", spaces, store)
    assert_rgb [32 / 255.0, 48 / 255.0, 64 / 255.0], colors[0]
    assert_rgb WHITE, colors[1]
    assert_rgb [143.5 / 255.0, 151.5 / 255.0, 159.5 / 255.0], colors[2], 0.004
  end

  # -------------------------------------------------------------------
  # Functions
  # -------------------------------------------------------------------
  def test_sampled_function_bit_depths_decode_and_two_inputs
    store = Store.new(
      { 30 => { '/FunctionType' => '0', '/Domain' => %w[0 1 0 1], '/Range' => %w[0 1],
                '/Size' => %w[2 2], '/BitsPerSample' => '8' },
        31 => { '/FunctionType' => '0', '/Domain' => %w[0 1], '/Range' => %w[0 1],
                '/Size' => ['2'], '/BitsPerSample' => '16' },
        32 => { '/FunctionType' => '0', '/Domain' => %w[0 1], '/Range' => %w[0 1],
                '/Size' => ['3'], '/BitsPerSample' => '4' },
        33 => { '/FunctionType' => '0', '/Domain' => %w[0 1], '/Range' => %w[0 1],
                '/Size' => ['2'], '/BitsPerSample' => '8', '/Decode' => %w[1 0] },
        34 => { '/FunctionType' => '0', '/Domain' => %w[0 1], '/Range' => %w[0 1],
                '/Size' => ['4'], '/BitsPerSample' => '8' } },
      { 30 => [0, 51, 102, 255].pack('C*'), 31 => [0, 0, 255, 255].pack('C*'),
        32 => [0x08, 0xF0].pack('C*'), 33 => [0, 255].pack('C*'), 34 => [0, 255].pack('C*') }
    )
    assert_in_delta 0.4, function('30 0 R', store).evaluate([0.5, 0.5])[0], 1e-9
    assert_in_delta 0.2, function('30 0 R', store).evaluate([1.0, 0.0])[0], 1e-9
    assert_in_delta 0.4, function('30 0 R', store).evaluate([0.0, 1.0])[0], 1e-9
    assert_in_delta 0.5, function('31 0 R', store).evaluate([0.5])[0], 1e-9
    assert_in_delta 8 / 15.0, function('32 0 R', store).evaluate([0.5])[0], 1e-9
    assert_in_delta 1.0, function('32 0 R', store).evaluate([1.0])[0], 1e-9
    assert_in_delta 0.75, function('33 0 R', store).evaluate([0.25])[0], 1e-9
    # Fewer sample bytes than /Size needs: not a usable function.
    assert_nil function('34 0 R', store)
  end

  def test_stitching_function
    rising = { '/FunctionType' => '2', '/Domain' => %w[0 1], '/N' => '1' }
    falling = { '/FunctionType' => '2', '/Domain' => %w[0 1], '/C0' => ['1'], '/C1' => ['0'], '/N' => '1' }
    stitched = { '/FunctionType' => '3', '/Domain' => %w[0 1], '/Functions' => [rising, falling],
                 '/Bounds' => ['0.5'], '/Encode' => %w[0 1 0 1] }
    evaluator = function(stitched, Store.new)
    assert_in_delta 0.5, evaluator.evaluate([0.25])[0], 1e-9
    assert_in_delta 1.0, evaluator.evaluate([0.5])[0], 1e-9
    assert_in_delta 0.5, evaluator.evaluate([0.75])[0], 1e-9
    assert_in_delta 0.0, evaluator.evaluate([1.0])[0], 1e-9

    spaces = { '/CsK' => ['/Separation', '/Black', '/DeviceGray', stitched] }
    assert_rgb [0.5, 0.5, 0.5], strokes("/CsK CS 0.75 SCN #{LINE}", spaces)[0]
  end

  def test_calculator_function_operators
    assert_equal [1.0, 0.5],
                 calculator('{ 2 copy add 3 1 roll sub }', 2, %w[0 1 0 1]).evaluate([0.75, 0.25])
    threshold = calculator('{ dup 0.5 gt { pop 1 } { 2 mul } ifelse }', 1)
    assert_equal [1.0], threshold.evaluate([0.75])
    assert_equal [0.5], threshold.evaluate([0.25])
    assert_in_delta 1.0, calculator('{ 360 mul sin abs }', 1).evaluate([0.25])[0], 1e-9
    assert_in_delta 0.75, calculator('{ 1 exch sub dup mul sqrt neg neg }', 1).evaluate([0.25])[0], 1e-9
    assert_equal [1.0], calculator('{ 3 2 idiv 7 3 mod add 2 bitshift 8 eq { 1 } { 0 } ifelse exch pop }', 1).evaluate([0.3])
    assert_equal [0.25], calculator('{ true false or { 0.25 } if exch pop }', 1).evaluate([0.9])
    assert_equal [1.25],
                 calculator('{ pop 2.7 cvi 0.5 round add 1.5 floor add 0.2 ceiling add 4 div }', 1, %w[0 2]).evaluate([0.0])
    assert_in_delta 1.0, calculator('{ pop 1 1 atan 45 div }', 1).evaluate([0.0])[0], 1e-9
    assert_in_delta 0.5, calculator('{ pop 100 log 2 exp 8 div }', 1).evaluate([0.0])[0], 1e-9
    assert_in_delta 0.5, calculator('{ pop 1 ln 60 cos add }', 1).evaluate([0.0])[0], 1e-9
    assert_equal [0.6], calculator('{ 0.6 1 index pop exch pop }', 1).evaluate([0.1])
    assert_equal [0.75],
                 calculator('{ pop 1 2 lt 2 1 ge and true xor not { 0.75 } { 0.25 } ifelse }', 1).evaluate([0.0])
    assert_equal [0.5], calculator("{ % halve\n -7 2 idiv -3 eq 7 -2 mod 1 eq and 1.9 truncate 1 eq and 2 1 ne and " \
                                   "1 1 le and 5 cvr 5 eq and { 0.5 mul } if }", 1).evaluate([1.0])
    # Out-of-range results are clipped to /Range.
    assert_equal [1.0], calculator('{ 5 mul }', 1).evaluate([1.0])
  end

  def test_calculator_function_failures_do_not_raise
    assert_nil calculator('{ 1 frobnicate }', 1)
    assert_nil calculator('1 add', 1)
    assert_nil calculator('{ add }', 1).evaluate([0.5])
    assert_nil calculator('{ 0 div }', 1).evaluate([0.5])
    assert_nil calculator('{ pop true }', 1).evaluate([0.5])
    # A separation whose function fails still paints: colorant name decides.
    store = Store.new({ 20 => { '/FunctionType' => '4', '/Domain' => %w[0 1], '/Range' => %w[0 1] } },
                      { 20 => '{ add }' })
    spaces = { '/CsK' => ['/Separation', '/Black', '/DeviceGray', '20 0 R'] }
    assert_rgb BLACK, strokes("/CsK CS 1 SCN #{LINE}", spaces, store)[0]
  end

  # -------------------------------------------------------------------
  # Indexed, ICCBased, DeviceN, Lab, Cal*
  # -------------------------------------------------------------------
  def test_indexed_over_device_rgb_with_string_and_stream_tables
    store = Store.new({ 40 => { '/Length' => '9' } }, { 40 => [255, 0, 0, 0, 255, 0, 0, 0, 255].pack('C*') })
    spaces = {
      '/IxHex' => ['/Indexed', '/DeviceRGB', '2', '<FF0000 00FF00 0000FF>'],
      '/IxText' => ['/Indexed', '/DeviceRGB', '2', '(\\377\\000\\000\\000\\377\\000\\000\\000\\377)'],
      '/IxStream' => ['/Indexed', '/DeviceRGB', '2', '40 0 R'],
      '/IxCmyk' => ['/Indexed', '/DeviceCMYK', '1', '<00000000 000000FF>'],
      '/IxGray' => ['/Indexed', '/DeviceGray', '1', '(\\200a)']
    }
    %w[/IxHex /IxText /IxStream].each do |name|
      colors = fills("#{name} cs #{BOX} 1 sc #{BOX} 2 sc #{BOX} 9 sc #{BOX}", spaces, store)
      assert_rgb [1.0, 0.0, 0.0], colors[0], 0.002 # selecting the space starts at index 0
      assert_rgb [0.0, 1.0, 0.0], colors[1]
      assert_rgb [0.0, 0.0, 1.0], colors[2]
      assert_rgb [0.0, 0.0, 1.0], colors[3] # clamped to hival
    end
    colors = strokes("/IxCmyk CS 1 SC #{LINE} 0 SC #{LINE} /IxGray CS 0 SC #{LINE} 1 SC #{LINE}", spaces, store)
    assert_rgb BLACK, colors[0]
    assert_rgb WHITE, colors[1]
    assert_rgb [128 / 255.0] * 3, colors[2]
    assert_rgb [97 / 255.0] * 3, colors[3]
  end

  def test_icc_based_by_component_count_and_alternate
    store = Store.new(41 => { '/N' => '1' }, 43 => { '/N' => '3' }, 44 => { '/N' => '4' },
                      45 => { '/N' => '3', '/Alternate' => ['/Lab', { '/WhitePoint' => %w[0.9642 1 0.8249] }] },
                      46 => { '/N' => '4', '/Alternate' => '/DeviceRGB' })
    spaces = { '/Icc1' => ['/ICCBased', '41 0 R'], '/Icc3' => ['/ICCBased', '43 0 R'],
               '/Icc4' => ['/ICCBased', '44 0 R'], '/IccLab' => ['/ICCBased', '45 0 R'],
               '/IccOdd' => ['/ICCBased', '46 0 R'] }
    stream = "/Icc1 CS #{LINE} 0.5 SC #{LINE} 1 SCN #{LINE} " \
             "/Icc3 CS #{LINE} 0.2 0.4 0.6 SC #{LINE} " \
             "/Icc4 CS #{LINE} 1 0 0 0 SCN #{LINE} 0 0 0 0 SCN #{LINE} " \
             "/IccLab CS 100 0 0 SC #{LINE} " \
             "/IccOdd CS 0 1 0 0 SC #{LINE}"
    colors = strokes(stream, spaces, store)
    assert_rgb BLACK, colors[0]
    assert_rgb [0.5, 0.5, 0.5], colors[1]
    assert_rgb WHITE, colors[2] # one component of a GRAY space is a gray level
    assert_rgb BLACK, colors[3]
    assert_rgb [0.2, 0.4, 0.6], colors[4]
    assert_rgb BLACK, colors[5] # initial CMYK colour is 0 0 0 1
    assert_rgb [0.0, 1.0, 1.0], colors[6]
    assert_rgb WHITE, colors[7]
    assert_rgb WHITE, colors[8] # /Alternate honoured
    assert_rgb [1.0, 0.0, 1.0], colors[9] # /Alternate with the wrong component count: /N decides
  end

  def test_device_n_with_two_process_colorants
    store = Store.new(
      { 50 => { '/FunctionType' => '4', '/Domain' => %w[0 1 0 1], '/Range' => %w[0 1 0 1 0 1 0 1] } },
      { 50 => '{ 0 exch 0 }' }
    )
    spaces = { '/CsDn' => ['/DeviceN', ['/Cyan', '/Yellow'], '/DeviceCMYK', '50 0 R'],
               '/CsNames' => ['/DeviceN', ['/Cyan', '/Yellow'], '/DeviceCMYK', '99 0 R'],
               '/CsHole' => ['/DeviceN', ['/None', '/None'], '/DeviceCMYK', '50 0 R'] }
    %w[/CsDn /CsNames].each do |name|
      colors = fills("#{name} cs #{BOX} 1 0 scn #{BOX} 0 1 scn #{BOX} 0 0 scn #{BOX} 0.5 0.25 scn #{BOX}", spaces, store)
      assert_rgb [0.0, 1.0, 0.0], colors[0] # full tint of both inks
      assert_rgb [0.0, 1.0, 1.0], colors[1]
      assert_rgb [1.0, 1.0, 0.0], colors[2]
      assert_rgb WHITE, colors[3]
      assert_rgb [0.5, 1.0, 0.75], colors[4]
    end
    assert_empty parse("/CsHole cs 1 1 scn #{BOX}", spaces, store)
  end

  def test_lab_and_cal_spaces
    spaces = { '/CsLab' => ['/Lab', { '/WhitePoint' => %w[0.9642 1 0.8249], '/Range' => %w[-128 127 -128 127] }],
               '/CsCalG' => ['/CalGray', { '/WhitePoint' => %w[0.9505 1 1.089] }],
               '/CsCalRgb' => ['/CalRGB', { '/WhitePoint' => %w[0.9505 1 1.089] }] }
    stream = "/CsLab CS #{LINE} 100 0 0 SC #{LINE} 50 0 0 SC #{LINE} 54 81 70 SC #{LINE} 30 20 -70 SC #{LINE} " \
             "/CsCalG CS 0.25 SC #{LINE} /CsCalRgb CS 0.1 0.2 0.3 SC #{LINE}"
    colors = strokes(stream, spaces)
    assert_rgb BLACK, colors[0]
    assert_rgb WHITE, colors[1]
    assert_rgb [0.466, 0.466, 0.466], colors[2], 0.004
    assert_operator colors[3][0], :>, 0.9 # a saturated red
    assert_operator colors[3][1], :<, 0.25
    assert_operator colors[3][2], :<, 0.25
    assert_operator colors[4][2], :>, 0.6 # a deep blue
    assert_operator colors[4][0], :<, 0.3
    assert_rgb [0.25, 0.25, 0.25], colors[5]
    assert_rgb [0.1, 0.2, 0.3], colors[6]
  end

  # -------------------------------------------------------------------
  # Graphics state and unchanged behaviour
  # -------------------------------------------------------------------
  def test_q_and_Q_save_and_restore_the_colour_space
    spaces = { '/CsK' => BLACK_INK }
    stream = "/CsK CS 1 SCN q 1 0 0 RG #{LINE} 0.25 0.5 0.75 SC #{LINE} Q #{LINE} 0.25 SCN #{LINE} " \
             "q /CsK cs 1 scn #{BOX} Q #{BOX} 0.25 sc #{BOX}"
    paths = parse(stream, spaces)
    assert_rgb [1.0, 0.0, 0.0], paths[0].stroke_color
    assert_rgb [0.25, 0.5, 0.75], paths[1].stroke_color
    assert_rgb BLACK, paths[2].stroke_color
    # Still the Separation space after Q: 0.25 is a quarter tint, not gray 0.25.
    assert_rgb [0.75, 0.75, 0.75], paths[3].stroke_color
    assert_rgb BLACK, paths[4].fill_color
    assert_rgb BLACK, paths[5].fill_color # initial DeviceGray black restored
    assert_rgb [0.25, 0.25, 0.25], paths[6].fill_color
  end

  def test_colour_space_state_survives_a_content_stream_boundary
    spaces = { '/CsK' => BLACK_INK }
    paths = Parser.new(['/CsK CS', "0.25 SCN #{LINE}"], Store.new, {}, {}, '/ColorSpace' => spaces).parse
    assert_rgb [0.75, 0.75, 0.75], paths[0].stroke_color
  end

  def test_device_pattern_and_unknown_spaces_keep_their_behaviour
    spaces = { '/CsK' => BLACK_INK, '/CsPat' => ['/Pattern', '/DeviceRGB'], '/CsBad' => ['/Separation'],
               '/CsRgb' => '/DeviceRGB' }
    stream = "0 0 1 RG /DeviceRGB CS #{LINE} 1 0 0 SC #{LINE} /DeviceGray CS 0.5 SC #{LINE} " \
             "/DeviceCMYK CS 0 0 0 1 SCN #{LINE} 0 0 0 1 K #{LINE} 0.1 0.2 0.3 0.4 K #{LINE} " \
             "0 1 0 rg /Pattern cs /P1 scn #{BOX} /CsPat cs 0.2 0.4 0.6 /P1 scn #{BOX} " \
             "/CsMissing cs 1 scn #{BOX} 0.2 0.4 0.6 scn #{BOX} 1 0 0 0 scn #{BOX} " \
             "/CsBad cs 1 scn #{BOX} /CsRgb cs 0.2 0.4 0.6 sc #{BOX}"
    parser = Parser.new([stream], Store.new, {}, {}, '/ColorSpace' => spaces)
    paths = parser.parse
    assert_rgb [0.0, 0.0, 1.0], paths[0].stroke_color # device CS does not reset the colour
    assert_rgb [1.0, 0.0, 0.0], paths[1].stroke_color
    assert_rgb [0.5, 0.5, 0.5], paths[2].stroke_color
    assert_rgb BLACK, paths[3].stroke_color
    assert_rgb BLACK, paths[4].stroke_color
    assert_rgb [0.9 * 0.6, 0.8 * 0.6, 0.7 * 0.6], paths[5].stroke_color, 1e-9
    assert_rgb [0.0, 1.0, 0.0], paths[6].fill_color # pattern-only scn
    assert_rgb [0.2, 0.4, 0.6], paths[7].fill_color
    assert_rgb WHITE, paths[8].fill_color # unknown name: component-count fallback as before
    assert_rgb [0.2, 0.4, 0.6], paths[9].fill_color
    assert_rgb [0.0, 1.0, 1.0], paths[10].fill_color
    assert_rgb WHITE, paths[11].fill_color
    assert_rgb [0.2, 0.4, 0.6], paths[12].fill_color
    assert_equal ['/CsBad'], parser.unsupported_color_spaces

    # No resources at all (the pre-existing call shape): unchanged fallback.
    legacy = Parser.new(["/CsK CS 1 SCN #{LINE} 0 0 0 1 k #{BOX}"], nil).parse
    assert_rgb WHITE, legacy[0].stroke_color
    assert_rgb BLACK, legacy[1].fill_color
  end

  # -------------------------------------------------------------------
  # Through PDFParser: resource dictionaries, streams, Form XObjects
  # -------------------------------------------------------------------
  def stream_object(entries, bytes)
    body = "<< #{entries} /Length #{bytes.bytesize} >>\nstream\n".dup.force_encoding(BIN)
    body << bytes.dup.force_encoding(BIN) << "\nendstream"
  end

  def write_pdf(path, objects)
    data = "%PDF-1.4\n".dup.force_encoding(BIN)
    offsets = []
    objects.each_with_index do |object, index|
      offsets << data.bytesize
      data << "#{index + 1} 0 obj\n" << object.dup.force_encoding(BIN) << "\nendobj\n"
    end
    xref = data.bytesize
    data << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
    offsets.each { |offset| data << format('%010d 00000 n ', offset) << "\n" }
    data << "trailer << /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    File.binwrite(path, data)
    path
  end

  def with_parser(objects)
    Dir.mktmpdir('pdf_color_space') do |dir|
      parser = IMP::PDFParser.new(write_pdf(File.join(dir, 'd042.pdf'), objects))
      parser.parse
      yield parser
    end
  end

  # Page 3 with two content streams (4, 5); Forms 6..9; functions 10..13.
  def form_fixture
    ramp = [255, 255, 255, 32, 48, 64].pack('C*')
    page_resources = '/ColorSpace << /CsK [/Separation /Black [/ICCBased 14 0 R] 10 0 R] ' \
                     '/CsIx [/Indexed /DeviceRGB 1 15 0 R] /CsIxText 16 0 R >> ' \
                     '/XObject << /FmInherit 6 0 R /FmOwn 7 0 R /FmOuter 8 0 R >>'
    [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << #{page_resources} >> " \
        '/Contents [4 0 R 5 0 R] >>',
      stream_object('', "/CsK CS 1 SCN #{LINE} /FmInherit Do #{LINE} /FmOwn Do #{LINE}"),
      stream_object('', "/FmOuter Do /CsK cs 1 scn #{BOX} /CsIx cs 1 sc #{BOX} /CsIxText cs 1 sc #{BOX} /FmOwn Do"),
      # 6: no /Resources: the page's /CsK applies inside the Form
      stream_object('/Type /XObject /Subtype /Form /BBox [0 0 50 50]', "/CsK CS 0.5 SCN #{LINE}"),
      # 7: own /Resources shadow the page's /CsK with a cyan ink
      stream_object('/Type /XObject /Subtype /Form /BBox [0 0 50 50] /Matrix [1 0 0 1 20 20] ' \
                    '/Resources << /ColorSpace << /CsK [/Separation /Cyan /DeviceCMYK 11 0 R] >> >>',
                    "/CsK CS 1 SCN #{LINE}"),
      # 8: nests Form 9 and uses a name only the page defines
      stream_object('/Type /XObject /Subtype /Form /BBox [0 0 50 50] ' \
                    '/Resources << /ColorSpace << /CsM [/Separation /Magenta /DeviceCMYK 12 0 R] >> ' \
                    '/XObject << /FmInner 9 0 R >> >>',
                    "/CsM CS 1 SCN #{LINE} /FmInner Do #{LINE} /CsK CS 1 SCN #{LINE}"),
      # 9: innermost, its own /CsM is yellow
      stream_object('/Type /XObject /Subtype /Form /BBox [0 0 50 50] ' \
                    '/Resources << /ColorSpace << /CsM [/Separation /Yellow /DeviceCMYK 13 0 R] >> >>',
                    "/CsM CS 1 SCN #{LINE}"),
      stream_object('/FunctionType 0 /Domain [0 1] /Range [0 1 0 1 0 1] /Size [2] /BitsPerSample 8', ramp),
      '<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [1 0 0 0] /N 1 >>',
      stream_object('/FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1 0 1]', '{ 0 exch 0 0 }'),
      '<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 0 1 0] /N 1 >>',
      stream_object('/N 3 /Alternate /DeviceRGB', 'synthetic profile placeholder'),
      stream_object('', [0, 0, 0, 0, 128, 255].pack('C*')),
      '[/Indexed /DeviceRGB 1 (\\000\\000\\000\\377\\200\\000)]'
    ]
  end

  def test_form_xobjects_use_their_own_resources_and_inherit_the_invoking_scope
    with_parser(form_fixture) do |parser|
      raw = parser.page_data(1)
      paths = Parser.new(raw[:content_streams], parser).parse
      dark = [32 / 255.0, 48 / 255.0, 64 / 255.0]
      half = [143.5 / 255.0, 151.5 / 255.0, 159.5 / 255.0]
      expected = [
        dark,              # page: /CsK full tint through the sampled function
        half,              # FmInherit: no /Resources, page /CsK at half tint
        dark,              # page again: Q restored the colour
        [0.0, 1.0, 1.0],   # FmOwn: its own /CsK is cyan
        dark,              # page again
        [1.0, 0.0, 1.0],   # FmOuter: /CsM magenta
        [1.0, 1.0, 0.0],   # FmInner: its own /CsM yellow
        [1.0, 0.0, 1.0],   # FmOuter after the nested Form
        dark               # FmOuter: /CsK only exists on the page
      ]
      expected.each_with_index do |rgb, index|
        assert paths[index].stroke, "path #{index} is stroked"
        assert_rgb rgb, paths[index].stroke_color, 0.004
      end
      assert_rgb dark, paths[9].fill_color, 0.004
      assert_rgb [0.0, 128 / 255.0, 1.0], paths[10].fill_color   # Indexed, stream table
      assert_rgb [1.0, 128 / 255.0, 0.0], paths[11].fill_color   # Indexed, string table
      assert_rgb [0.0, 1.0, 1.0], paths[12].stroke_color         # FmOwn from the second stream
      assert_equal 13, paths.length
      assert_empty Parser.new(raw[:content_streams], parser).tap(&:parse).unsupported_color_spaces

      # The unexpanded page streams carry the page scope as well.
      source = Parser.new(raw[:source_content_streams], parser).parse
      assert_rgb dark, source[0].stroke_color, 0.004
    end
  end

  def test_form_parsed_on_its_own_by_the_xobject_parser_sees_its_resources
    with_parser(form_fixture) do |parser|
      xobjects = IMP::XObjectParser.new(parser)
      xobjects.scan_page(1)
      assert_rgb [0.0, 1.0, 1.0], xobjects.parse_xobject_paths('FmOwn')[0].stroke_color
      assert_rgb [143.5 / 255.0, 151.5 / 255.0, 159.5 / 255.0],
                 xobjects.parse_xobject_paths('FmInherit')[0].stroke_color, 0.004
    end
  end

  def test_resource_scope_maps_nested_byte_ranges
    page = { '/Name' => 'page' }
    outer = { '/Name' => 'outer' }
    inner = { '/Name' => 'inner' }
    late = { '/Name' => 'late' }
    scope = CS::ResourceScope.new(page, [[10, 50, [outer, page]], [20, 30, [inner, outer, page]],
                                         [60, 70, [late, page]]])
    assert_equal [page], scope.chain_at(0)
    assert_equal [page], scope.chain_at(9)
    assert_equal [outer, page], scope.chain_at(10)
    assert_equal [inner, outer, page], scope.chain_at(20)
    assert_equal [inner, outer, page], scope.chain_at(29)
    assert_equal [outer, page], scope.chain_at(30)
    assert_equal [page], scope.chain_at(50)
    assert_equal [late, page], scope.chain_at(65)
    assert_equal [page], scope.chain_at(70)
    assert_equal [page], scope.chain_at(nil)
    assert_equal [page], CS::ResourceScope.new(page).chain_at(40)
    assert_equal [], CS::ResourceScope.new(nil).chain_at(40)

    stream = 'q Q'.dup
    assert_nil CS::ResourceScope.of(stream)
    assert_same scope, CS::ResourceScope.of(CS::ResourceScope.attach(stream, scope))
    assert_nil CS::ResourceScope.of(CS::ResourceScope.attach('q Q'.freeze, scope))
  end
end
