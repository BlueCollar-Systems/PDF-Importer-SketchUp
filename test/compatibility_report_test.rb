#!/usr/bin/env ruby

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SOURCE_DIR = File.join(
  REPO_ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer'
)

class CompatibilityReportEntities
  def add_image(*_args); end

  def add_3d_text(*_args); end
end

class CompatibilityReportModel
  def active_entities
    @active_entities ||= CompatibilityReportEntities.new
  end

  def line_styles
    @line_styles ||= Object.new
  end
end

module Sketchup
  class Importer; end

  class << self
    def active_model
      @active_model ||= CompatibilityReportModel.new
    end

    def version
      '17.3.116'
    end

    def version_number
      17_03_01_16
    end

    def platform
      :platform_win
    end

    def is_pro?
      false
    end
  end
end

module UI
  class HtmlDialog; end

  class << self
    def reset_test_state
      @messages = []
      @clipboard_payload = nil
    end

    def messages
      Array(@messages).dup
    end

    def clipboard_payload
      @clipboard_payload
    end

    def select_directory(*_args); end

    def set_clipboard_data(payload)
      @clipboard_payload = payload
    end

    def messagebox(message)
      @messages ||= []
      @messages << message
    end
  end
end

module BlueCollarSystems
  module PDFVectorImporter
    PLUGIN_VERSION = 'test'.freeze unless defined?(PLUGIN_VERSION)

    module Logger
      class << self
        def reset_test_state
          @errors = []
        end

        def errors
          Array(@errors).dup
        end

        def error(context, message, exception = nil)
          @errors ||= []
          @errors << [context, message, exception]
        end

        def warn(_context, _message); end
      end
    end

    module DependencyResolver
      class << self
        attr_accessor :test_status, :test_bundled_bin_dir

        def scan
          test_status
        end

        def bundled_bin_dir
          test_bundled_bin_dir
        end

        def missing_recommended(_status)
          []
        end

        def download_lines(_missing)
          []
        end
      end
    end
  end
end

require File.join(SOURCE_DIR, 'compatibility_report')

class CompatibilityReportTest < Minitest::Test
  REPORT = BlueCollarSystems::PDFVectorImporter::CompatibilityReport
  RESOLVER = BlueCollarSystems::PDFVectorImporter::DependencyResolver
  LOGGER = BlueCollarSystems::PDFVectorImporter::Logger

  def setup
    UI.reset_test_state
    LOGGER.reset_test_state
    RESOLVER.test_bundled_bin_dir =
      'C:\\Users\\Private Operator\\AppData\\Roaming\\SketchUp\\Library\\bin'
    RESOLVER.test_status = {
      :bundled_bin => false,
      :pdftocairo => nil,
      :mutool => nil,
      :pdftotext => nil,
      :pdffonts => nil,
      :ghostscript => nil
    }
  end

  def test_show_never_discloses_saved_path_across_path_styles
    private_paths = [
      'C:\\Users\\Private Operator\\AppData\\Local\\Temp\\bc_pdf_importer\\compatibility_report.txt',
      '\\\\private-server\\SecretShare\\compatibility_report.txt',
      '/home/private-client/.cache/bc_pdf_importer/compatibility_report.txt'
    ]
    rendered = private_paths.map do |private_path|
      UI.reset_test_state
      REPORT.stub(:save_report, private_path) do
        REPORT.stub(:print_to_console, nil) { REPORT.show }
      end
      [private_path, UI.messages.last.to_s]
    end

    leaked = rendered.select do |private_path, message|
      message.include?(private_path)
    end.map { |pair| pair[0] }
    assert_empty leaked,
                 "saved paths leaked into Compatibility Report UI: #{leaked.inspect}"
  end

  def test_show_keeps_path_free_report_access_guidance
    private_path =
      'C:\\Users\\Private Operator\\Temp\\compatibility_report.txt'

    REPORT.stub(:save_report, private_path) do
      REPORT.stub(:print_to_console, nil) { REPORT.show }
    end

    message = UI.messages.last.to_s
    assert_includes message, 'Clipboard: Copied'
    assert_includes message,
                    'Report file: Saved locally (path hidden for privacy)'
    assert_includes message,
                    'Use the clipboard or Ruby Console to access the full report.'
    assert_includes UI.clipboard_payload,
                    '=== PDF Vector Importer Compatibility Report ==='
    refute_includes message, private_path
  end

  def test_show_error_dialog_hides_hostile_exception_but_logs_it_locally
    hostile = 'C:\\Users\\Private Operator\\secret.txt | ' \
              '\\\\private-server\\SecretShare | /home/private-client/secret'
    failure = RuntimeError.new(hostile)

    REPORT.stub(:build_report, lambda { raise failure }) { REPORT.show }

    logged = LOGGER.errors.last
    assert_equal 'CompatibilityReport', logged[0]
    assert_equal 'show failed', logged[1]
    assert_same failure, logged[2]
    message = UI.messages.last.to_s
    refute_includes message, hostile
    refute_match(/Private Operator|private-server|SecretShare|private-client/,
                 message)
    assert_equal "Compatibility report failed.\n" \
                 'See the local importer log for diagnostic details, then retry.',
                 message
  end

  def test_shareable_report_redacts_extension_and_all_helper_paths
    private_paths = [
      'C:\\Users\\Private Operator\\Client-Zephyr\\bin\\pdftocairo.exe',
      '\\\\private-server\\SecretShare\\mutool.exe',
      '/home/private-client/tools/pdftotext',
      'D:\\Customer Archives\\Restricted Set\\pdffonts.exe',
      'C:\\Program Files\\gs\\private-build\\gswin64c.exe'
    ]
    RESOLVER.test_status = {
      :bundled_bin => true,
      :pdftocairo => private_paths[0],
      :mutool => private_paths[1],
      :pdftotext => private_paths[2],
      :pdffonts => private_paths[3],
      :ghostscript => private_paths[4]
    }

    report = REPORT.build_report

    assert_includes report, 'Extension Directory: [path redacted]'
    assert_includes report,
                    'Bundled bin folder ready: OK ([path redacted])'
    assert_includes report, 'pdftocairo found: OK ([path redacted])'
    assert_includes report, 'mutool found: OK ([path redacted])'
    assert_includes report, 'pdftotext found: OK ([path redacted])'
    assert_includes report, 'pdffonts found: OK ([path redacted])'
    assert_includes report, 'Ghostscript found: OK ([path redacted])'
    assert_includes report,
                    '- Local executable and extension paths are redacted.'

    private_paths.each { |path| refute_includes report, path }
    refute_includes report, RESOLVER.test_bundled_bin_dir
    refute_includes report, SOURCE_DIR
    refute_match(/Private Operator|Client-Zephyr|private-server|SecretShare|private-client/,
                 report)
  end

  def test_path_redaction_preserves_exact_helper_compatibility_decisions
    RESOLVER.test_status = {
      :bundled_bin => false,
      :pdftocairo => nil,
      :mutool => 'C:\\Users\\Private Operator\\Tools\\mutool.exe',
      :pdftotext => nil,
      :pdffonts => 'D:\\Private\\pdffonts.exe',
      :ghostscript => nil
    }

    report = REPORT.build_report

    assert_includes report,
                    'Bundled bin folder ready: MISSING ([path redacted])'
    assert_includes report, 'pdftocairo found: MISSING'
    assert_includes report, 'mutool found: OK ([path redacted])'
    assert_includes report, 'pdftotext found: MISSING'
    assert_includes report, 'pdffonts found: OK ([path redacted])'
    assert_includes report, 'Ghostscript found: MISSING'
    assert_includes report,
                    '- SVG/geometry text render: Enabled via mutool.'
    assert_includes report,
                    '- External text extraction: Disabled (internal parser fallback).'
    assert_includes report,
                    '- Non-embedded font repair: Detection enabled, repair disabled (Ghostscript not found).'
  end
end
