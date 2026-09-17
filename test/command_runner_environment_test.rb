require 'minitest/autorun'
require 'rbconfig'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/command_runner'

class CommandRunnerEnvironmentTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::CommandRunner

  def test_overrides_apply_only_to_child_and_unrelated_commands_still_inherit
    name = 'BC_COMMAND_ENV_FIXTURE'
    previous = ENV[name]
    ENV[name] = 'parent'
    # Match the source-built Ruby 2.2 gate's --disable-gems invocation. This
    # subprocess tests ENV only, so it needs no RubyGems startup or JSON gem.
    args = [RbConfig.ruby, '--disable-gems', '-e', "STDOUT.write(ENV[#{name.inspect}].inspect)"]
    changed = Subject.run(args, :env => { name => 'child' })
    assert changed[:ok], changed.inspect
    assert_equal 'child'.inspect, changed[:stdout]
    assert_equal 'parent', ENV[name]
    removed = Subject.run(args, :env => { name => nil })
    assert removed[:ok], removed.inspect
    assert_equal 'nil', removed[:stdout]
    unchanged = Subject.run(args)
    assert unchanged[:ok], unchanged.inspect
    assert_equal 'parent'.inspect, unchanged[:stdout]
  ensure
    ENV[name] = previous
  end

  def test_invalid_environment_is_rejected_before_launch
    assert_raises(ArgumentError) { Subject.run(['unused'], :env => 'GS_OPTIONS=x') }
    assert_raises(ArgumentError) { Subject.run(['unused'], :env => { :GS_OPTIONS => '' }) }
    assert_raises(ArgumentError) { Subject.run(['unused'], :env => { 'GS_OPTIONS' => 1 }) }
  end
end
