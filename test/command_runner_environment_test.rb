require 'minitest/autorun'
require 'rbconfig'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/command_runner'

class CommandRunnerEnvironmentTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::CommandRunner

  def test_overrides_apply_only_to_child_and_unrelated_commands_still_inherit
    name = 'BC_COMMAND_ENV_FIXTURE'
    previous = ENV[name]
    ENV[name] = 'parent'
    args = [RbConfig.ruby, '-e', "require 'json'; print JSON.generate(ENV[#{name.inspect}])"]
    changed = Subject.run(args, :env => { name => 'child' })
    assert changed[:ok]
    assert_equal 'child', JSON.parse(changed[:stdout])
    assert_equal 'parent', ENV[name]
    removed = Subject.run(args, :env => { name => nil })
    assert removed[:ok]
    assert_nil JSON.parse(removed[:stdout])
    unchanged = Subject.run(args)
    assert unchanged[:ok]
    assert_equal 'parent', JSON.parse(unchanged[:stdout])
  ensure
    ENV[name] = previous
  end

  def test_invalid_environment_is_rejected_before_launch
    assert_raises(ArgumentError) { Subject.run(['unused'], :env => 'GS_OPTIONS=x') }
    assert_raises(ArgumentError) { Subject.run(['unused'], :env => { :GS_OPTIONS => '' }) }
    assert_raises(ArgumentError) { Subject.run(['unused'], :env => { 'GS_OPTIONS' => 1 }) }
  end
end
