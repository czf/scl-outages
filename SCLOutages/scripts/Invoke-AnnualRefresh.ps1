<#
.SYNOPSIS
  Orchestrates the full annual SCL outage data refresh:
    1. Import new workbook(s) into SQL Server
    2. Regenerate the aggregation stored procedure if table list changed
    3. Export aggregated GeoJSON for map rendering

.PARAMETER InputFolder
  Folder containing new .xlsx files to import.

.PARAMETER OutputFolder
  Folder for intermediate CSVs during import.

.PARAMETER GeoJsonPath
  Output path for the final GeoJSON file.

.PARAMETER ServerInstance
  SQL Server instance name.

.PARAMETER Database
  Target database name.

.PARAMETER Schema
  SQL schema (default "dbo").

.PARAMETER TablePrefix
  Prefix for destination table names (default "SCL_2024").

.PARAMETER SkipImport
  Skip the workbook import step (useful if tables are already loaded).

.PARAMETER SkipExport
  Skip the GeoJSON export step.

.EXAMPLE
  .\Invoke-AnnualRefresh.ps1 `
    -InputFolder    "G:\data\SCL outages\2026-02-12\2026-02-12" `
    -OutputFolder   "G:\temp_output" `
    -GeoJsonPath    "G:\temp_output\outages.geojson" `
    -ServerInstance "localhost" `
    -Database       "SclOutage" `
    -TablePrefix    "SCL_2024"
#>

[CmdletBinding()]
param(
  [string]$InputFolder,
  [string]$OutputFolder,
  [Parameter(Mandatory=$true)] [string]$GeoJsonPath,
  [Parameter(Mandatory=$true)] [string]$ServerInstance,
  [Parameter(Mandatory=$true)] [string]$Database,
  [string]$Schema      = "dbo",
  [string]$TablePrefix = "SCL_2024",
  [switch]$SkipImport,
  [switch]$SkipExport
)

$ErrorActionPreference = "Stop"
$scriptsDir  = $PSScriptRoot
$importScript = Join-Path (Split-Path $scriptsDir -Parent) "..\..\workbookToTableScript.ps1"

# -------- Step 1: Import workbooks --------

if (-not $SkipImport) {
  if (-not $InputFolder) { throw "-InputFolder is required when not using -SkipImport." }
  if (-not $OutputFolder) { throw "-OutputFolder is required when not using -SkipImport." }

  Write-Host "=== Step 1: Importing workbooks ===" -ForegroundColor Magenta
  & $importScript `
    -InputFolder    $InputFolder `
    -OutputFolder   $OutputFolder `
    -ServerInstance $ServerInstance `
    -Database       $Database `
    -Schema         $Schema `
    -TablePrefix    $TablePrefix

  if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Workbook import failed." }
} else {
  Write-Host "=== Step 1: Skipped (SkipImport) ===" -ForegroundColor DarkGray
}

# -------- Step 2: Update stored procedure --------

Write-Host "=== Step 2: Updating aggregation stored procedure ===" -ForegroundColor Magenta
& "$scriptsDir\Update-OutageStatsSproc.ps1" `
  -ServerInstance $ServerInstance `
  -Database       $Database `
  -Schema         $Schema

if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Sproc update failed." }

# -------- Step 3: Export GeoJSON --------

if (-not $SkipExport) {
  Write-Host "=== Step 3: Exporting GeoJSON ===" -ForegroundColor Magenta
  & "$scriptsDir\Export-OutageGeoJSON.ps1" `
    -ServerInstance $ServerInstance `
    -Database       $Database `
    -OutputPath     $GeoJsonPath `
    -Schema         $Schema

  if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "GeoJSON export failed." }
} else {
  Write-Host "=== Step 3: Skipped (SkipExport) ===" -ForegroundColor DarkGray
}

Write-Host "=== Annual refresh complete ===" -ForegroundColor Green
