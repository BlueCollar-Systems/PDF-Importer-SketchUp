#!/usr/bin/env ruby
# test/pre_import_prompt_test.rb
require 'minitest/autorun'

class PreImportPromptTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  MAIN_RB = File.join(REPO_ROOT, 'extracted', 'sketchup_ext',
                      'bc_pdf_vector_importer', 'main.rb')

  def test_standard_import_has_no_pre_import_guidance_modal
    main_source = File.read(MAIN_RB)

    refute_includes main_source, "require File.join(dir, 'import_guidance')"
    refute_includes main_source, 'ImportGuidance'
    refute_includes main_source, 'Before you import'
    refute_includes main_source, 'LibreCAD'
    refute File.exist?(File.join(REPO_ROOT, 'extracted', 'sketchup_ext',
                                 'bc_pdf_vector_importer', 'import_guidance.rb')),
           'pre-import guidance module should not ship in SketchUp RBZ'

    method_body = main_source[/def self\.import_pdf\b.*?^\s+def self\.import_pdf_safe/m]
    refute_nil method_body
    refute_includes method_body, 'LibreCAD'
    pre_picker = method_body[/return UI\.messagebox\("No active model\."\) unless model.*?path = UI\.openpanel/m]
    refute_nil pre_picker
    refute_includes pre_picker, 'Before you import'
    refute_includes pre_picker, 'ImportGuidance'
  end
end
