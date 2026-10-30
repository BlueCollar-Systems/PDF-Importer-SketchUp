"""Execute the actual source-bound release guards with controlled Git/Ruby results."""
from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/auto-release.yml'
TEST_PATH = 'test/command_runner_legacy_capture_test.rb'
OLD = 'e0bafb474acd8c0a831cc99ab162687b5b74b99a'
CURRENT = 'c0e340172daef13a312cfbb5797999e779188750'


def block(shell: str) -> str:
    text = WORKFLOW.read_text(encoding='utf-8')
    match = re.search(rf'(?ms)^          # BEGIN source-bound legacy capture regression \({shell}\)\n(.*?)^          # END source-bound legacy capture regression \({shell}\)$', text)
    if not match:
        raise AssertionError(f'Missing actual {shell} guard')
    return textwrap.dedent(match.group(1))


POWERSHELL_FIXTURE = r'''
$ErrorActionPreference = 'Stop'
function global:git {
  switch ($args[0]) {
    'rev-parse' { $global:LASTEXITCODE = [int]$env:CASE_REF_EXIT; if ($LASTEXITCODE -eq 0) { Write-Output $env:CASE_HEAD }; return }
    'ls-tree' { $global:LASTEXITCODE = [int]$env:CASE_TREE_EXIT; if ($LASTEXITCODE -eq 0 -and $env:CASE_TRACKED -eq 'yes') { Write-Output 'test/command_runner_legacy_capture_test.rb' }; return }
    'show' { $global:LASTEXITCODE = [int]$env:CASE_SHOW_EXIT; if ($LASTEXITCODE -eq 0) { Write-Output $env:CASE_RUNNER }; return }
    default { throw 'Unexpected Git command' }
  }
}
function global:ruby {
  Write-Output ('RUBY_CALLED:' + ($args -join '|'))
  $global:LASTEXITCODE = [int]$env:CASE_RUBY_EXIT
}
'''
BASH_FIXTURE = r'''
set -euo pipefail
git() {
  case "$1" in
    rev-parse) if [ "$CASE_REF_EXIT" -eq 0 ]; then printf '%s\n' "$CASE_HEAD"; fi; return "$CASE_REF_EXIT" ;;
    ls-tree) if [ "$CASE_TREE_EXIT" -eq 0 ] && [ "$CASE_TRACKED" = yes ]; then printf '%s\n' 'test/command_runner_legacy_capture_test.rb'; fi; return "$CASE_TREE_EXIT" ;;
    show) if [ "$CASE_SHOW_EXIT" -eq 0 ]; then printf '%s\n' "$CASE_RUNNER"; fi; return "$CASE_SHOW_EXIT" ;;
    *) return 99 ;;
  esac
}
ruby() { printf 'RUBY_CALLED:%s\n' "$*"; return "$CASE_RUBY_EXIT"; }
'''


class ReleaseSourceSmokeContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.powershell = shutil.which('pwsh') or shutil.which('powershell')
        cls.bash = shutil.which('bash')
        if os.name == 'nt':
            git_bash = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'Git/bin/bash.exe'
            if git_bash.is_file():
                cls.bash = str(git_bash)
        if not cls.powershell or not cls.bash:
            raise AssertionError('Release guard controls require PowerShell and Bash (Git Bash on Windows).')

    def run_case(self, *, present=False, selected=OLD, trigger=CURRENT, head=OLD,
                 state='published', tracked=False, implementation=False, ruby_exit=0,
                 ref_exit=0, tree_exit=0, show_exit=0):
        env = os.environ.copy()
        env.update(GITHUB_SHA=trigger, CASE_HEAD=head, CASE_TRACKED='yes' if tracked else 'no',
                   CASE_RUNNER='def self.run_legacy_bundled_capture; end' if implementation else 'def self.run(args); end',
                   CASE_RUBY_EXIT=str(ruby_exit), CASE_REF_EXIT=str(ref_exit),
                   CASE_TREE_EXIT=str(tree_exit), CASE_SHOW_EXIT=str(show_exit))
        results = {}
        with tempfile.TemporaryDirectory(prefix='source-roster-control-') as temporary:
            directory = Path(temporary)
            if present:
                test_file = directory / TEST_PATH
                test_file.parent.mkdir()
                test_file.write_text('# fictional test command target\n', encoding='utf-8')
            for shell, prefix, executable, suffix in (
                ('PowerShell', POWERSHELL_FIXTURE, self.powershell, '.ps1'),
                ('Bash', BASH_FIXTURE, self.bash, '.sh'),
            ):
                actual = block(shell).replace('${{ needs.release-plan.outputs.build_ref }}', selected).replace('${{ needs.release-plan.outputs.release_state }}', state)
                tail = "\nWrite-Output 'GUARD_FINISHED'\n" if shell == 'PowerShell' else "\nprintf '%s\\n' GUARD_FINISHED\n"
                script = directory / ('guard' + suffix)
                script.write_text(prefix + '\n' + actual + tail, encoding='utf-8')
                command = [executable, '-NoProfile', '-NonInteractive', '-File', str(script)] if shell == 'PowerShell' else [executable, str(script)]
                results[shell] = subprocess.run(command, cwd=directory, env=env, capture_output=True, text=True, timeout=20)
        return results

    def assert_refused(self, **options):
        for shell, result in self.run_case(**options).items():
            with self.subTest(shell=shell, options=options):
                self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertNotIn('GUARD_FINISHED', result.stdout)

    def test_present_test_always_executes_and_passes(self):
        for shell, result in self.run_case(present=True, selected=CURRENT, head=CURRENT).items():
            with self.subTest(shell=shell):
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertIn('RUBY_CALLED:' + TEST_PATH, result.stdout)
                self.assertIn('GUARD_FINISHED', result.stdout)
                self.assertNotIn('::notice::', result.stdout)

    def test_present_test_failure_cannot_be_hidden(self):
        self.assert_refused(present=True, ruby_exit=7)

    def test_only_a_pinned_older_published_source_without_feature_or_test_may_omit_it(self):
        for shell, result in self.run_case().items():
            with self.subTest(shell=shell):
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertIn('::notice::Published historical source ' + OLD, result.stdout)
                self.assertNotIn('RUBY_CALLED:', result.stdout)
                self.assertIn('GUARD_FINISHED', result.stdout)

    def test_missing_current_head_test_is_an_error_even_without_implementation(self):
        self.assert_refused(selected=CURRENT, head=CURRENT)

    def test_feature_implementation_without_its_test_is_an_error(self):
        self.assert_refused(implementation=True)

    def test_deleting_a_test_tracked_by_the_selected_commit_is_an_error(self):
        self.assert_refused(tracked=True)

    def test_wrong_selected_ref_or_unpinned_ref_is_an_error(self):
        self.assert_refused(head=CURRENT)
        self.assert_refused(selected='v3.7.185', head='v3.7.185')

    def test_unknown_trigger_identity_is_an_error(self):
        self.assert_refused(trigger='')

    def test_draft_or_missing_release_does_not_get_a_historical_exception(self):
        for state in ('draft', 'missing', ''):
            self.assert_refused(state=state)

    def test_git_inspection_errors_fail_closed(self):
        for field in ('ref_exit', 'tree_exit', 'show_exit'):
            self.assert_refused(**{field: 128})

    def test_current_source_ci_and_exact_ruby_roster_still_require_the_test(self):
        ci = (ROOT / '.github/workflows/su-pdfimporter-ci.yml').read_text(encoding='utf-8')
        exact = (ROOT / 'tools/run_ruby22_exact_source.sh').read_text(encoding='utf-8')
        self.assertEqual(2, ci.count('ruby ' + TEST_PATH))
        self.assertIn('  ' + TEST_PATH + '\n', exact)
        self.assertIn('tools.test_release_source_smoke_contract', ci)


if __name__ == '__main__':
    unittest.main()
