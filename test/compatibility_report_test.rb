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
    def select_directory(*_args); end

    def set_clipboard_data(*_args); end
  end
end

module BlueCollarSystems
  module PDFVectorImporter
    PLUGIN_VERSION = 'test'.freeze unless defined?(PLUGIN_VERSION)

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

  def setup
    RESOLVER.test_bundled_bin_dir =
      'C:\\Users\\Private Operator\\AppData\\Roaming\\SketchUp\\Library\\bin'
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
