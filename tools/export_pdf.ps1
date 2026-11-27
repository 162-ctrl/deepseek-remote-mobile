param(
  [Parameter(Mandatory = $true)][string]$Docx,
  [Parameter(Mandatory = $true)][string]$Pdf
)
# Export a DOCX to PDF using the locally installed Microsoft Word (COM).
$ErrorActionPreference = "Stop"
$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0
try {
  $doc = $word.Documents.Open($Docx, $false, $true)  # confirmConversions=false, readOnly=true
  $doc.Fields.Update() | Out-Null
  $doc.ExportAsFixedFormat($Pdf, 17)  # 17 = wdExportFormatPDF
  $pages = $doc.ComputeStatistics(2)  # wdStatisticPages
  $doc.Close($false)
  Write-Host "pages=$pages pdf=$Pdf"
}
finally {
  $word.Quit()
  [System.Runtime.InteropServices.Marshal]::ReleaseComObject($word) | Out-Null
}
