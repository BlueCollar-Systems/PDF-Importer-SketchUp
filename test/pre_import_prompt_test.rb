#!/usr/bin/env ruby
# test/pre_import_prompt_test.rb
require 'minitest/autorun'

class PreImportPromptTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  MAIN_RB = File.join(REPO_ROOT, 'extracted', 'sketchup_ext',
                      'bc_pdf_vector_importer', 'main.rb')

  def test_standard_and_safe_import_do_not_show_pre_import_guidance
    source = File.read(MAIN_RB)
    import_body = source[/def self\.import_pdf\b.*?^\s+def self\.import_pdf_safe/m]
    safe_body = source[/def self\.import_pdf_safe\b.*?^\s+def self\.batch_import/m]

    refute_nil import_body
    refute_nil safe_body
    [source, import_body, safe_body].each do |body|
      refute_includes body, "require File.join(dir, 'import_guidance')"
      refute_includes body, 'ImportGuidance'
      refute_includes body, 'Before you import'
      refute_includes body, 'Choose your PDF next'
      refute_includes body, 'LibreCAD users'
    end
  end
end
