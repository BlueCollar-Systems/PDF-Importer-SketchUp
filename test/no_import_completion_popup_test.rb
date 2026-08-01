#!/usr/bin/env ruby
# test/no_import_completion_popup_test.rb
#
# Owner rule (field report 2026-07-06): no gratuitous blocking modal on
# every import. The standard import path must announce completion on the
# status bar, NOT pop a UI.messagebox wall of internal detection telemetry.
# This guards against reintroducing ReportDialog.show_report (or any
# UI.messagebox) on the import_pdf success path.

require 'minitest/autorun'

class NoImportCompletionPopupTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  SRC = File.join(REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer')
  MAIN_RB = File.join(SRC, 'main.rb')

  def import_pdf_body
    src = File.read(MAIN_RB)
    body = src[/def self\.import_pdf\b.*?^\s+def self\.import_pdf_safe/m]
    refute_nil body, 'could not isolate import_pdf method body'
    body
  end

  def success_branch
    # From the run_pipeline call to the failing else (the success handling).
    b = import_pdf_body[/stats = run_(?:resumable_)?pipeline.*?else/m]
    refute_nil b, 'could not isolate the import success branch'
    b
  end

  def test_success_path_does_not_show_blocking_report_modal
    branch = success_branch
    refute_includes branch, 'show_report',
                     'import success must not auto-open the blocking report modal'
    refute_includes branch, 'UI.messagebox',
                     'import success must not pop a blocking messagebox'
    assert_includes branch, 'announce',
                    'import success should announce completion non-blockingly'
  end

  def test_announce_is_non_blocking
    src = File.read(File.join(SRC, 'report_dialog.rb'))
    announce = src[/def self\.announce\b.*?^\s+end/m]
    refute_nil announce, 'ReportDialog.announce must exist'
    refute_includes announce, 'UI.messagebox',
                     'announce must not use a blocking messagebox'
    assert_includes announce, 'status_text',
                    'announce should write to the SketchUp status bar'
  end
end
