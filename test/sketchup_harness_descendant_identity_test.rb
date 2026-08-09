#!/usr/bin/env ruby
# The acceptance harness may advance past the release tag, but never diverge.
#
# tools/ ships in no release package -- 0 of the RBZ's entries -- so a harness
# fix cannot be delivered by a product release. verify_repository_identity!
# previously required HEAD == tag == job commit, which froze the harness at the
# tagged commit permanently: the strict SketchUp campaign could not pick up a
# harness correction without minting a product release whose shipped bytes were
# byte-identical to the previous one.
#
# The replacement keeps product identity exact (the tag still names the released
# commit, and the RBZ SHA-256 is verified separately) while allowing the harness
# to move forward along the same history. Both directions are tested: a
# descendant is accepted, an unrelated or diverged commit is rejected.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
require File.join(REPO_ROOT, 'tools', 'sketchup_host_launcher')

class SketchupHarnessDescendantIdentityTest < Minitest::Test
  def git(dir, *args)
    system('git', '-C', dir, *args, [:out, :err] => File::NULL) or
      raise "git #{args.join(' ')} failed"
  end

  def build_repo(dir, identity = 'primary')
    git(dir, 'init', '-q')
    git(dir, 'config', 'user.email', 'test@example.invalid')
    git(dir, 'config', 'user.name', 'Test')
    File.write(File.join(dir, 'a.txt'), "#{identity}: one\n")
    git(dir, 'add', '-A')
    git(dir, 'commit', '-q', '-m', 'first')
    tagged = `git -C #{dir} rev-parse HEAD`.strip.downcase
    git(dir, 'tag', 'v1.0.0')
    File.write(File.join(dir, 'a.txt'), "#{identity}: two\n")
    git(dir, 'add', '-A')
    git(dir, 'commit', '-q', '-m', 'harness fix')
    head = `git -C #{dir} rev-parse HEAD`.strip.downcase
    [tagged, head]
  end

  def test_tag_commit_is_accepted_as_its_own_descendant
    Dir.mktmpdir do |dir|
      tagged, _head = build_repo(dir)
      assert SketchupHostLauncher.git_ancestor?(dir, tagged, tagged),
             'a commit is its own ancestor, so an untouched harness still passes'
    end
  end

  def test_harness_commit_descending_from_the_tag_is_accepted
    Dir.mktmpdir do |dir|
      tagged, head = build_repo(dir)
      assert SketchupHostLauncher.git_ancestor?(dir, tagged, head),
             'a harness commit built on top of the release tag must be accepted'
    end
  end

  def test_unrelated_commit_is_rejected
    Dir.mktmpdir do |dir|
      tagged, _head = build_repo(dir)
      Dir.mktmpdir do |other|
        _t2, other_head = build_repo(other, 'unrelated')
        refute_equal tagged, other_head,
                     'the fixture must create a genuinely unrelated commit'
        refute SketchupHostLauncher.git_ancestor?(dir, tagged, other_head),
               'a commit from unrelated history must never satisfy ancestry'
      end
    end
  end

  def test_reversed_ancestry_is_rejected
    Dir.mktmpdir do |dir|
      tagged, head = build_repo(dir)
      refute SketchupHostLauncher.git_ancestor?(dir, head, tagged),
             'the tag must be the ancestor, not the descendant'
    end
  end
end
