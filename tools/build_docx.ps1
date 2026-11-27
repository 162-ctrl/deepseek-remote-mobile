param(
  [string]$Root = "<项目根>",
  [string]$Markdown = "docs\concept\项目构思方案_v0.2.md",
  [string]$Output = "DeepSeek Remote AI 项目构思方案 v0.2.docx",
  [string]$Python = "C:\Users\user\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe",
  [int]$MaxIterations = 5
)
# Build the concept DOCX from Markdown, auto-filling TOC page numbers.
# Pipeline: build (placeholder TOC) -> Word PDF export -> map headings to pages
#           -> rebuild with real numbers -> compare -> repeat until stable.
$ErrorActionPreference = "Stop"
$md = Join-Path $Root $Markdown
$outPath = Join-Path $Root $Output
$tmp = Join-Path $Root ".tmp-py"
$baseDir = Join-Path $Root "docs\concept"
$env:PYTHONPATH = Join-Path $tmp "pdf"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$entries = Join-Path $tmp "toc_entries.json"
$pagesFile = Join-Path $tmp "toc_pages.json"
Remove-Item $pagesFile -ErrorAction SilentlyContinue

# pass 0: dump the heading list
& $Python "$Root\tools\md_to_docx.py" $md (Join-Path $tmp "toc_probe.docx") --base-dir $baseDir --toc --toc-dump $entries | Out-Null

$ok = $false
for ($it = 1; $it -le $MaxIterations; $it++) {
  $docx = Join-Path $tmp "build_$it.docx"
  $pdf = Join-Path $tmp "build_$it.pdf"
  $newPages = Join-Path $tmp "pages_$it.json"

  $buildArgs = @("$Root\tools\md_to_docx.py", $md, $docx, "--base-dir", $baseDir, "--toc")
  if (Test-Path $pagesFile) { $buildArgs += @("--toc-pages", $pagesFile) }
  & $Python @buildArgs | Out-Null
  if (-not (Test-Path $docx)) { throw "docx build failed: $docx" }

  & (Join-Path $Root "tools\export_pdf.ps1") -Docx $docx -Pdf $pdf | Out-Null

  & $Python -X utf8 "$Root\tools\docx_toc_pages.py" $pdf $entries --out $newPages | Out-Null
  if (-not (Test-Path $newPages)) { throw "page mapping failed: $newPages" }

  if (-not (Test-Path $pagesFile)) {
    Copy-Item $newPages $pagesFile -Force
    Write-Host "[iter $it] seeded page map"
    continue
  }

  $cmp = & $Python "$Root\tools\compare_pages.py" $pagesFile $newPages
  Write-Host "[iter $it] $($cmp[0])"
  if ($LASTEXITCODE -eq 0) {
    Copy-Item $docx $outPath -Force
    Write-Host "[OK] $outPath"
    $ok = $true
    break
  }
  Copy-Item $newPages $pagesFile -Force
}
if (-not $ok) { throw "TOC page numbers did not converge after $MaxIterations iterations" }
