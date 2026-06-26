#!/usr/bin/env ruby
# test/pre_import_prompt_test.rb
require 'minitest/autorun'

class PreImportPromptTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  MAIN_RB = File.join(REPO_ROOT, 'extracted', 'sketchup_ext',
                      'bc_pdf_vector_importer', 'main.rb')
  GUIDANCE_RB = File.join(REPO_ROOT, 'extracted', 'sketchup_ext',
                          'bc_pdf_vector_importer', 'import_guidance.rb')

  def test_standard_import_uses_once_only_guidance_module
    main_source = File.read(MAIN_RB)
    guidance_source = File.read(GUIDANCE_RB)

    assert_includes main_source, "require File.join(dir, 'import_guidance')"
    assert_includes main_source, 'ImportGuidance.maybe_show'

    method_body = main_source[/def self\.import_pdf\b.*?^\s+def self\.import_pdf_safe/m]
    refute_nil method_body
    refute_includes method_body, 'LibreCAD'
    refute_includes method_body, 'UI.messagebox(
          "Before you import'

    refute_includes guidance_source, 'LibreCAD'
    refute_includes guidance_source, '<<~'
    assert_includes guidance_source, 'import_guidance_dismissed'
    assert_includes guidance_source, 'Sketchup.read_default'
    assert_includes guidance_source, 'Sketchup.write_default'
  end
end
