# Ruby 2.2-compatible keyboard backend contracts. DLL/API fixtures only;
# no keyboard injection, SketchUp process or UI interaction.
require 'minitest/autorun'
require 'weakref'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control'

class EscapeCancelProbeBackendTest < Minitest::Test
  Probe = BlueCollarSystems::PDFVectorImporter::ImportRunControl::EscapeCancelProbe

  class Harness < Probe
    def initialize(fixture)
      @fixture = fixture
      super()
    end
    private
    def windows_platform?; @fixture[:windows] != false; end
    def load_key_library(name)
      @fixture[:requires] << name
      raise LoadError, "#{name} unavailable" if @fixture[:missing].include?(name)
      true
    end
    def win32api_class; @fixture[:legacy]; end
    def fiddle_module; @fixture[:fiddle]; end
  end

  class FakeHandle
    def [](name)
      raise 'Unexpected native function' unless name == 'GetAsyncKeyState'
      701
    end
  end

  def fixture(options = {})
    data = {:requires => [], :missing => ['Win32API'], :values => [0],
      :keys => [], :dll_paths => [], :constructors => [], :windows => true}.merge(options)
    legacy = Class.new
    legacy.define_singleton_method(:new) do |*args|
      data[:legacy_signature] = args
      raise RuntimeError, 'legacy API initialization failed' if data[:legacy_failure]
      api = Object.new
      api.define_singleton_method(:call) do |key|
        data[:keys] << key
        data[:values].shift
      end
      api
    end
    function = Class.new
    function.const_set(:DEFAULT, 11)
    function.const_set(:STDCALL, 19) if options[:stdcall]
    function.define_singleton_method(:new) do |*args|
      data[:constructors] << args
      api = Object.new
      api.define_singleton_method(:call) do |key|
        raise 'DLL handle was collected before use' unless data[:dll_reference].weakref_alive?
        data[:keys] << key
        data[:values].shift
      end
      api
    end
    fiddle = Module.new
    fiddle.const_set(:TYPE_INT, 4)
    fiddle.const_set(:TYPE_SHORT, 3) unless options[:missing_short]
    fiddle.const_set(:SIZEOF_VOIDP, options[:pointer_size] || 8)
    fiddle.const_set(:Function, function)
    fiddle.define_singleton_method(:dlopen) do |path|
      data[:dll_paths] << path
      raise RuntimeError, 'system DLL unavailable' if data[:dll_failure]
      library = FakeHandle.new
      data[:dll_reference] = WeakRef.new(library)
      library
    end
    data[:legacy] = legacy
    data[:fiddle] = fiddle
    data
  end

  def test_legacy_win32api_is_preserved_and_fiddle_is_not_loaded
    data = fixture(:missing => [], :values => [0, 0x8000])
    probe = Harness.new(data)
    assert_equal :win32api, probe.backend
    assert_equal ['Win32API'], data[:requires]
    assert_equal ['user32', 'GetAsyncKeyState', ['I'], 'I'], data[:legacy_signature]
    assert probe.available?
    refute probe.call
    assert probe.call
    assert_equal [0x1B, 0x1B], data[:keys]
    assert_empty data[:dll_paths]
  end

  def test_missing_win32api_selects_stdlib_fiddle_with_int_and_signed_short
    data = fixture(:values => [-32768])
    probe = Harness.new(data)
    assert_equal :fiddle, probe.backend
    assert_equal ['Win32API', 'fiddle'], data[:requires]
    assert_equal [[701, [4], 3, 11]], data[:constructors]
    assert_match(/System32[\\\/]user32\.dll\z/i, data[:dll_paths].first)
    assert probe.call
    assert_equal [0x1B], data[:keys]
    assert_nil probe.unavailable_reason
  end

  def test_legacy_api_failure_also_advances_to_fiddle
    data = fixture(:missing => [], :legacy_failure => true)
    probe = Harness.new(data)
    assert_equal :fiddle, probe.backend
    assert probe.available?
    assert_equal ['Win32API', 'fiddle'], data[:requires]
  end

  def test_32bit_windows_uses_stdcall_when_exposed
    data = fixture(:pointer_size => 4, :stdcall => true)
    probe = Harness.new(data)
    assert_equal :fiddle, probe.backend
    assert_equal [[701, [4], 3, 19]], data[:constructors]
    refute probe.call
  end

  def test_32bit_missing_stdcall_is_truthfully_unavailable_before_dll_call
    data = fixture(:pointer_size => 4)
    probe = Harness.new(data)
    refute probe.available?
    assert_equal :unavailable, probe.backend
    assert_match(/stdcall ABI is unavailable/, probe.unavailable_reason)
    assert_empty data[:dll_paths]
  end

  def test_missing_signed_short_type_is_not_replaced_with_wrong_int_return
    data = fixture(:missing_short => true)
    probe = Harness.new(data)
    refute probe.available?
    assert_match(/signed SHORT return type is unavailable/, probe.unavailable_reason)
    assert_empty data[:constructors]
  end

  def test_dll_handle_stays_alive_across_gc_and_repeated_reads
    data = fixture(:values => [0, 0x8000])
    probe = Harness.new(data)
    GC.start
    assert data[:dll_reference].weakref_alive?
    refute probe.call
    GC.start
    assert probe.call
    assert probe.available?
  end

  def test_only_current_key_down_high_bit_cancels
    data = fixture(:values => [0, 1, 0x7fff, 0x8000, 0x8001, -32768, -32767])
    probe = Harness.new(data)
    assert_equal [false, false, false, true, true, true, true], 7.times.map { probe.call }
    assert_equal [0x1B] * 7, data[:keys]
  end

  def test_missing_both_libraries_is_safe_and_reports_once
    data = fixture(:missing => ['Win32API', 'fiddle'])
    probe = Harness.new(data)
    refute probe.available?
    assert_match(/Win32API.*unavailable.*Fiddle.*unavailable/, probe.unavailable_reason)
    _stdout, stderr = capture_io { 3.times { refute probe.call } }
    assert_equal 1, stderr.scan(/Escape-key cancellation is unavailable/).length
    assert_empty data[:keys]
  end

  def test_dll_load_failure_is_visible_and_never_requests_cancellation
    data = fixture(:dll_failure => true)
    probe = Harness.new(data)
    refute probe.available?
    assert_match(/system DLL unavailable/, probe.unavailable_reason)
    capture_io { refute probe.call }
  end

  def test_non_windows_portable_fallback_never_loads_windows_libraries
    data = fixture(:windows => false)
    probe = Harness.new(data)
    assert_equal :unavailable, probe.backend
    assert_empty data[:requires]
    assert_match(/no Windows keyboard reader/, probe.unavailable_reason)
    capture_io { refute probe.call }
  end

  def test_runtime_reader_failure_is_not_reported_as_an_available_backend
    probe = Probe.new(lambda { |_| raise RuntimeError, 'reader broke' })
    capture_io { refute probe.call }
    assert_equal :unavailable, probe.backend
    refute probe.available?
    assert_match(/keyboard read failed.*reader broke/, probe.unavailable_reason)
    _stdout, stderr = capture_io { refute probe.call }
    assert_empty stderr
  end
end
