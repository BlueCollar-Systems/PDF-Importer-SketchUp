$ErrorActionPreference = 'Continue'
$qaSrc = 'C:\Users\Rowdy Payton\Desktop\PDFTest Files\Q&A'
$repos = @(
  'C:\1PDF-Importer-SketchUp',
  'C:\1PDF-Importer-FreeCAD',
  'C:\1PDF-Importer-LibreCAD',
  'C:\1PDF-Importer-Blender',
  'C:\1BlueCollar-Website',
  'C:\1 Structural_Steel_Shapes_App'
)
$qaFiles = @(
  'Q&A_INDEX.md',
  'QA-2026-06-24_round4-resolution.md',
  'QA-2026-06-24_round4-status-reopen.md',
  'QA-2026-06-24_round5-kickoff.md',
  'QA-2026-06-24_round5-reviewer-synthesis.md',
  'QA-2026-06-24_round5-resolution.md',
  'QA-2026-06-24_round4-innovation-backlog.md'
)
$msg = @'
Round 5: scale cross-check, golden oracles, preflight copy (Round 4 Phase 2 P0 slice)

'@
$log = 'C:\1PDF-Importer-SketchUp\round5_git_report.txt'
'' | Set-Content $log
"=== TESTS ===" | Add-Content $log
ruby 'C:\1PDF-Importer-SketchUp\test\qa_report_test.rb' 2>&1 | Add-Content $log
"RUBY_EXIT=$LASTEXITCODE" | Add-Content $log
Push-Location 'C:\1PDF-Importer-FreeCAD'
python -m pytest tests/test_import_report_human_summary.py -q 2>&1 | Add-Content $log
"FC_PYTEST_EXIT=$LASTEXITCODE" | Add-Content $log
Pop-Location
Push-Location 'C:\1PDF-Importer-LibreCAD'
python -m pytest tests/test_pdf_open_gate.py -q 2>&1 | Add-Content $log
"LC_PYTEST_EXIT=$LASTEXITCODE" | Add-Content $log
Pop-Location
Push-Location 'C:\1PDF-Importer-Blender'
python -m pytest tests/test_dependency_manager.py -q 2>&1 | Add-Content $log
"BL_PYTEST_EXIT=$LASTEXITCODE" | Add-Content $log
Pop-Location
foreach ($repo in $repos) {
  "=== REPO $repo ===" | Add-Content $log
  $dest = Join-Path $repo '_LLM_CONTROL_PACK\QA'
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  foreach ($f in $qaFiles) {
    $src = Join-Path $qaSrc $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $dest $f) -Force }
  }
  Push-Location $repo
  git add -A 2>&1 | Add-Content $log
  git diff --cached --quiet
  if ($LASTEXITCODE -ne 0) {
    git commit -m $msg 2>&1 | Add-Content $log
    git rev-parse HEAD 2>&1 | ForEach-Object { "COMMIT=$_"; "COMMIT=$_" | Add-Content $log }
    git push 2>&1 | Add-Content $log
    "PUSH_EXIT=$LASTEXITCODE" | Add-Content $log
  } else {
    'NO_CHANGES' | Add-Content $log
  }
  Pop-Location
}
"DONE" | Add-Content $log
