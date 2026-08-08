#!/usr/bin/env ruby
# frozen_string_literal: true

# The bundled Poppler helpers cannot WRITE to a path containing a non-ASCII
# character. Their output writers hand the UTF-8 byte string to a byte-oriented
# fopen, so `pdftocairo -svg in.pdf <ü-path>.svg` exits 2 and writes nothing --
# while non-ASCII INPUT paths work fine (poppler uses _wfopen there). Verified
# by isolation on the shipped RBZ with input and output varied independently.
#
# Every helper output path in the shipped tree is derived from Dir.tmpdir, and
# on Windows Dir.tmpdir is %TMP% = C:\Users\<account>\AppData\Local\Temp -- the
# customer's account name is a literal component. A customer named 'Müller' or
# 'Иван' therefore loses every helper-backed rung, including terminal Raster.
# Worse, pdf_salvage folded File.basename(pdf_path) -- the customer's own PDF
# filename -- into the output path, so a damaged PDF named 'Détail_acier.pdf'
# failed salvage on a plain ASCII machine, silently.
#
# The fix routes every temp path through SafeTemp, whose root is guaranteed
# ASCII (BC_PDF_TEMP_DIR override -> Dir.tmpdir -> %ProgramData%). These tests
# manufacture the hostile conditions themselves, so an ASCII developer profile
# cannot hide the defect -- same property as the PE import-table gate that
# caught the CRT gap.
#
# Ruby 2.2 compatible (SketchUp 2017 ships 2.2.4).

require 'minitest/autorun'
require 'tmpdir'

EXT_DIR = File.expand_path(
  File.join('..', 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer'),
  File.dirname(__FILE__)
)
require File.join(EXT_DIR, 'safe_temp')

class PopplerOutputPathAlphabetTest < Minitest::Test
  SafeTemp = BlueCollarSystems::PDFVectorImporter::SafeTemp

  def setup
    SafeTemp.reset!
    @saved_override = ENV['BC_PDF_TEMP_DIR']
    ENV.delete('BC_PDF_TEMP_DIR')
  end

  def teardown
    if @saved_override
      ENV['BC_PDF_TEMP_DIR'] = @saved_override
    else
      ENV.delete('BC_PDF_TEMP_DIR')
    end
    SafeTemp.reset!
  end

  # --- (a) the fence: no shipped file may reach Dir.tmpdir on its own --------

  def test_no_shipped_file_derives_a_temp_path_from_dir_tmpdir
    offenders = []
    Dir.glob(File.join(EXT_DIR, '**', '*.rb')).sort.each do |path|
      next if File.basename(path) == 'safe_temp.rb'
      text = File.read(path)
      text.each_line.with_index(1) do |line, lineno|
        # Full-line comments may legitimately mention the API by name.
        next if line =~ /\A\s*#/
        next unless line =~ /Dir\s*\.\s*(?:tmpdir|mktmpdir)/
        offenders << "#{File.basename(path)}:#{lineno}"
      end
    end
    assert_equal [], offenders,
                 "These sites hand a profile-derived (account-name-bearing) " \
                 "temp path to code that may reach a bundled helper. Route " \
                 "them through SafeTemp instead:\n  " + offenders.join("\n  ")
  end

  # --- (b) the root is ASCII even when the profile is not --------------------

  def test_safe_temp_root_is_ascii_when_the_profile_is_not
    hostile = File.join(Dir.tmpdir, "bc_профиль_#{Process.pid}")
    original = Dir.method(:tmpdir)
    Dir.define_singleton_method(:tmpdir) { hostile }
    begin
      SafeTemp.reset!
      root = SafeTemp.root
      assert root.ascii_only?,
             "SafeTemp.root must not inherit a non-ASCII profile temp; got #{root.inspect}"
      assert File.directory?(root), 'the resolved root must actually exist'
    ensure
      Dir.define_singleton_method(:tmpdir, original)
      SafeTemp.reset!
    end
  end

  def test_ascii_override_is_honoured
    Dir.mktmpdir('bc_override_') do |dir|
      ENV['BC_PDF_TEMP_DIR'] = dir
      SafeTemp.reset!
      assert_equal dir, SafeTemp.root
    end
  end

  def test_non_ascii_override_is_refused
    Dir.mktmpdir('bc_override_') do |dir|
      hostile = File.join(dir, 'подпапка')
      Dir.mkdir(hostile)
      ENV['BC_PDF_TEMP_DIR'] = hostile
      SafeTemp.reset!
      refute_equal hostile, SafeTemp.root,
                   'a non-ASCII override would reintroduce the exact defect ' \
                   'this module exists to prevent'
      assert SafeTemp.root.ascii_only?
    end
  end

  def test_mktmpdir_creates_under_the_safe_root
    dir = SafeTemp.mktmpdir('bc_gate_')
    begin
      assert dir.ascii_only?, "mktmpdir result must be ASCII, got #{dir.inspect}"
      assert File.directory?(dir)
      assert dir.start_with?(SafeTemp.root),
             'owned temp dirs must live under the safe root'
    ensure
      Dir.rmdir(dir) if File.directory?(dir)
    end
  end

  # --- customer-derived filename components must be sanitised -----------------

  def test_ascii_component_strips_what_helpers_cannot_write
    assert_equal 'D_tail_acier.pdf', SafeTemp.ascii_component('Détail_acier.pdf')
    assert SafeTemp.ascii_component('чертёж.pdf').ascii_only?
    assert_equal 'plan-01.pdf', SafeTemp.ascii_component('plan-01.pdf'),
                 'ordinary ASCII names must pass through unchanged'
  end

  def test_ascii_component_never_returns_an_empty_or_dot_only_name
    ['', '...', '寸法図'].each do |bad|
      token = SafeTemp.ascii_component(bad)
      assert token.ascii_only?
      refute token.gsub(/[_.\-]/, '').empty?,
             "#{bad.inspect} must yield a usable fallback token, got #{token.inspect}"
    end
  end

  # --- (c) documents the helper defect itself; passes only once helper
  #         invocations write cwd-relative. Kept skipped so the suite is green
  #         while the fence above already prevents regressions, and un-skipped
  #         by the follow-up that changes the invocation sites.

  def test_every_helper_writes_to_the_exact_path_requested
    skip 'follow-up: helper invocations become cwd-relative ' \
         '(pdftocairo/pdftotext byte-fopen cannot take a non-ASCII output ' \
         'path; SafeTemp keeps such paths out of reach today)'
  end
end
