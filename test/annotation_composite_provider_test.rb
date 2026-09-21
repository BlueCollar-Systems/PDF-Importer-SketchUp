require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/annotation_composite_provider'

class AnnotationCompositeProviderTest < Minitest::Test
  Importer = BlueCollarSystems::PDFVectorImporter
  Subject = Importer::AnnotationCompositeProvider
  Error = Importer::RepresentationFidelity::ContractError
  Runner = Struct.new(:action) do
    def run(command,_opts); action.call(command); end
  end

  def setup
    @dir = Importer::SafeTemp.mktmpdir('annotation-provider-test-')
    @source = File.join(@dir,'original.pdf')
    @helper = File.join(@dir,'helper.exe')
    @output = File.join(@dir,'output.svg')
    File.binwrite(@source,'%PDF-fictional-original')
    File.binwrite(@helper,'fictional nonexecuted helper identity')
    @sha = Digest::SHA256.file(@source).hexdigest
    @parser = Object.new
    @parser.instance_variable_set(:@data,File.binread(@source))
    @parser.instance_variable_set(:@filepath,@source)
    @good = { :ok=>true,:exitstatus=>0,:timed_out=>false,:error=>nil,:stdout=>'',:stderr=>'' }
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def run_with(&block)
    page = Subject::Page.new(@parser,1,@sha,@helper,Runner.new(block))
    page.run_verified!([@helper,@source,@output],@output,@source,@sha)
  end

  def test_clean_source_bound_output_succeeds_without_modifying_input
    result = run_with { |_command| File.binwrite(@output,'<svg/>'); @good }
    assert result[:ok]
    assert_equal @sha,Digest::SHA256.file(@source).hexdigest
  end

  def test_renderer_warning_timeout_and_empty_success_fail_instead_of_dropping_geometry
    [{:stderr=>'warning: font substitution'}, {:timed_out=>true}, {:exitstatus=>1}].each do |mutation|
      assert_raises(Error) do
        run_with { |_command| File.binwrite(@output,'<svg/>'); @good.merge(mutation) }
      end
      File.delete(@output)
    end
    assert_raises(Error) { run_with { |_command| @good } }
  end

  def test_original_file_mutation_is_runtime_failure_not_source_impossibility
    assert_raises(Error) do
      run_with { |_command| File.binwrite(@output,'<svg/>'); File.binwrite(@source,'changed'); @good }
    end
  end

  def test_helper_mutation_and_preexisting_output_are_rejected
    assert_raises(Error) do
      run_with { |_command| File.binwrite(@output,'<svg/>'); File.binwrite(@helper,'changed'); @good }
    end
    called = false
    assert_raises(Error) { run_with { |_command| called = true; @good } }
    refute called
  end

  def test_failure_retains_actionable_runner_and_identity_evidence
    page = Subject::Page.new(@parser,1,@sha,@helper,Runner.new(proc do |_command|
      { :ok=>false,:exitstatus=>99,:timed_out=>false,:error=>nil,
        :stdout=>'',:stderr=>"Unsupported crop option\nsecond diagnostic\n" }
    end))
    error = assert_raises(Error) do
      page.run_verified!([@helper,@source,@output],@output,@source,@sha)
    end
    assert_match(/exit=99/,error.message)
    assert_match(/stderr: Unsupported crop option/,error.message)
    assert_match(/missing or empty output/,error.message)
    assert_equal 'RENDERER_FAILED',page.report[:composite_status]
    attempt = page.report[:renderer_attempts].fetch(0)
    assert_equal 99,attempt[:exitstatus]
    assert_equal true,attempt[:input_unchanged]
    assert_equal true,attempt[:renderer_unchanged]
    assert_equal false,attempt[:output_exists]
    assert_equal 0,attempt[:output_bytes]
    assert_equal 'output_verification',attempt[:phase]
  end

  def test_timeout_and_raised_runner_preserve_the_failure_phase
    page = Subject::Page.new(@parser,1,@sha,@helper,Runner.new(proc do |_command|
      @good.merge(:timed_out=>true)
    end))
    error = assert_raises(Error) { page.run_verified!([@helper],@output,@source,@sha) }
    assert_match(/timed out/,error.message)
    assert_equal true,page.report[:renderer_attempts].last[:timed_out]
    page = Subject::Page.new(@parser,1,@sha,@helper,Runner.new(proc { |_command| raise IOError,'launch failed' }))
    error = assert_raises(IOError) { page.run_verified!([@helper],@output,@source,@sha) }
    assert_equal 'launch failed',error.message
    assert_equal 'renderer',page.report[:renderer_attempts].last[:phase]
    assert_equal 'RENDERER_FAILED',page.report[:composite_status]
  end

  def font_inventory(rows = 'FictionalFont TrueType WinAnsi yes no yes 8 0')
    "name type encoding emb sub uni object ID\n---- ---- ---- --- --- --- ----\n" + rows + "\n"
  end

  def page_with_symbol_warning(inventory, renderer_warning = "Syntax Error: No display font for 'Symbol'\n", &mutation)
    helper = File.join(@dir,'pdffonts.exe')
    File.binwrite(helper,'fictional inventory helper')
    calls = []
    runner = Runner.new(proc do |command|
      calls << command
      if command.first == helper
        mutation.call(helper) if mutation
        @good.merge(:stdout=>inventory,:stderr=>"Syntax Error: No display font for 'Symbol'\n")
      else
        File.binwrite(@output,'<svg/>')
        @good.merge(:stderr=>renderer_warning)
      end
    end)
    [Subject::Page.new(@parser,1,@sha,@helper,runner),calls]
  end

  def test_exact_unused_symbol_startup_warning_requires_bound_complete_inventory
    page,calls = page_with_symbol_warning(font_inventory)
    result = page.run_verified!([@helper],@output,@source,@sha)
    assert_equal true,result[:ok]
    assert_equal 2,calls.length
    proof = page.report[:renderer_attempts].last[:nonaffecting_warning_proof]
    assert_equal true,proof[:symbol_font_absent]
    assert_equal @sha,proof[:source_pdf_sha256]
    assert_equal 1,proof[:font_row_count]
    File.delete(@output)
    page.run_verified!([@helper],@output,@source,@sha)
    assert_equal 3,calls.length # one immutable source inventory per provider
  end

  def test_actual_symbol_incomplete_inventory_and_other_warnings_remain_fatal
    [font_inventory('Symbol Type1 Custom no no no 9 0'), '', "name type encoding emb sub uni object ID\n"].each do |inventory|
      page,_calls = page_with_symbol_warning(inventory)
      assert_raises(Error) { page.run_verified!([@helper],@output,@source,@sha) }
      File.delete(@output)
    end
    page,calls = page_with_symbol_warning(font_inventory,"Syntax Error: No display font for 'Symbol'\nother warning\n")
    assert_raises(Error) { page.run_verified!([@helper],@output,@source,@sha) }
    assert_equal 1,calls.length
  end

  def test_inventory_helper_mutation_cannot_qualify_the_warning
    page,_calls = page_with_symbol_warning(font_inventory) { |helper| File.binwrite(helper,'changed') }
    assert_raises(Error) { page.run_verified!([@helper],@output,@source,@sha) }
    assert_equal false,page.report[:font_inventory_attempt][:helper_unchanged]
  end
end
