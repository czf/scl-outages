<#
.SYNOPSIS
  XLSX (multi-sheet) → per-sheet CSV → (transform EPSG:2285→4326) → BULK INSERT
  - One destination table per workbook (all sheets append to the same table)
  - Minimal logging via BULK INSERT into an empty heap with TABLOCK
  - CHECKPOINT after each BULK INSERT to keep the log small

.PARAMETER InputFolder
  Folder containing .xlsx files.

.PARAMETER OutputFolder
  Folder where intermediate and final CSVs will be written.

.PARAMETER ServerInstance
  SQL Server instance name, e.g., ".\SQLEXPRESS" or "localhost".

.PARAMETER Database
  Target database name.

.PARAMETER Schema
  SQL schema (default "dbo").

.PARAMETER TablePrefix
  Prefix for destination table names (default "SCL_2024"). Final name per workbook is: {Prefix}_{WorkbookName}

.PARAMETER CodePage
  CSV encoding for BULK INSERT (default "65001" = UTF-8).

.PARAMETER KeepStageCsvs
  Keep the intermediate per-sheet CSV and final CSV (by default, both are kept; you can delete later).

.EXAMPLE
  .\Import-Outages-OneTablePerWorkbook.ps1 `
    -InputFolder "C:\in" `
    -OutputFolder "C:\out" `
    -ServerInstance "localhost" `
    -Database "SclOutage" `
    -Schema "dbo" `
    -TablePrefix "SCL_2024"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string]$InputFolder,
  [Parameter(Mandatory=$true)] [string]$OutputFolder,
  [Parameter(Mandatory=$true)] [string]$ServerInstance,
  [Parameter(Mandatory=$true)] [string]$Database,
  [string]$Schema = "dbo",
  [string]$TablePrefix = "SCL_2024",
  [string]$CodePage = "65001",
  [switch]$KeepStageCsvs
)

# -------- Helpers --------

function Throw-IfMissingExe([string]$exe) {
  $found = Get-Command $exe -ErrorAction SilentlyContinue
  if (-not $found) { throw "Required executable '$exe' not found in PATH." }
}

function Invoke-External([string]$exe, [string]$argString) {
  Write-Host ">> $exe $argString" -ForegroundColor Cyan
  $output = cmd /c "$exe $argString 2>&1"
  if ($LASTEXITCODE -ne 0) { 
    throw "'$exe' failed with exit code $LASTEXITCODE. Output: $output"
  }
  return $output
}

function Get-SheetNames([string]$xlsxPath) {
  # Parse ogrinfo sheet enumeration:
  #  - "1: SheetName"
  #  - "Layer name: SheetName"
  try {
    $output = & ogrinfo -ro "$xlsxPath" 2>&1
  } catch {
    throw "ogrinfo failed to scan '$xlsxPath'. $_"
  }
  $sheetNames = @()
  foreach ($line in $output) {
    if ($line -match '^\s*\d+:\s*(.+?)(\s+\(None\))?\s*$') {
      $sheetNames += $matches[1].Trim()
    } elseif ($line -match 'Layer name:\s*(.+?)(\s+\(None\))?\s*$') {
      $sheetNames += $matches[1].Trim()
    }
  }
  if ($sheetNames.Count -eq 0) { throw "No sheets detected in '$xlsxPath'." }
  return $sheetNames
}

function Escape-TSqlString([string]$s) { $s -replace "'","''" }

function Escape-SqlIdentifier([string]$s) {
  # Remove potentially dangerous characters for SQL identifiers
  return $s -replace '[^\w]',''
}

function Exec-Sql([string]$server, [string]$db, [string]$tsql) {
  $sqlTemp = [System.IO.Path]::GetTempFileName()
  Set-Content -Path $sqlTemp -Value $tsql -Encoding UTF8
  try {
    # Escape server and db to prevent command injection
    $serverEsc = $server -replace '"','\"'
    $dbEsc = $db -replace '"','\"'
    Invoke-External "sqlcmd" "-S `"$serverEsc`" -d `"$dbEsc`" -b -I -i `"$sqlTemp`""
  } finally {
    Remove-Item $sqlTemp -Force -ErrorAction SilentlyContinue
  }
}

function Sanitize-Name([string]$name) {
  $clean = ($name -replace '[^A-Za-z0-9]+','_').Trim('_')
  if ([string]::IsNullOrWhiteSpace($clean)) { $clean = "Sheet" }
  return $clean
}

function Ensure-WorkbookTable([string]$schema, [string]$table) {
  # IMPORTANT: Column order must match CSV order.
  # CSV order produced below:
  # EVENT_IDX, SERV_LOC_ID, MAX_NUM_CUST_OUT, MIN_EVENT_BEGIN, MAX_RESTORE_TIME, MAX_EVENT_ETOR,
  # MIN_CAUSE, MIN_TROUBLE_CODE, MIN_EVENT_TYPE, MIN_PRIMARY_CAUSE_OM, MIN_SUBSTATION,
  # MIN_FIRST_CREW_TIME, MAX_POINT_X, MAX_POINT_Y, COUNT_CUSTOMERS_AT_LOCATION,
  # [transformed lon], [transformed lat]
  $schemaEsc = Escape-TSqlString $schema
  $tableEsc = Escape-TSqlString $table
  $schemaSafe = Escape-SqlIdentifier $schema
  $tableSafe = Escape-SqlIdentifier $table
  $tsql = @"
IF NOT EXISTS (
  SELECT 1
  FROM sys.tables t
  JOIN sys.schemas s ON s.schema_id = t.schema_id
  WHERE s.name = N'$schemaEsc' AND t.name = N'$tableEsc'
)
BEGIN
  EXEC(N'
    CREATE TABLE [$schemaSafe].[$tableSafe] (
      EVENT_IDX                       BIGINT          NOT NULL,
      SERV_LOC_ID                     BIGINT          NOT NULL,
      MAX_NUM_CUST_OUT                INT             NULL,
      MIN_EVENT_BEGIN                 DATETIME2(0)    NULL,
      MAX_RESTORE_TIME                DATETIME2(0)    NULL,
      MAX_EVENT_ETOR                  DATETIME2(0)    NULL,
      MIN_CAUSE                       VARCHAR(255)    NULL,
      MIN_TROUBLE_CODE                VARCHAR(255)     NULL,
      MIN_EVENT_TYPE                  VARCHAR(255)     NULL,
      MIN_PRIMARY_CAUSE_OM            VARCHAR(255)    NULL,
      MIN_SUBSTATION                  VARCHAR(255)     NULL,
      MIN_FIRST_CREW_TIME             DATETIME2(0)    NULL,
      MAX_POINT_X                     DECIMAL(13,6)   NULL,
      MAX_POINT_Y                     DECIMAL(13,6)   NULL,
      COUNT_CUSTOMERS_AT_LOCATION     INT             NULL,
      -- WGS84 lon/lat appended by ogr2ogr (X/Y after reprojection)
      MAX_POINT_X_AS_WGS84_LONGITUDE  DECIMAL(10,6)   NULL,
      MAX_POINT_Y_AS_WGS84_LATITUDE   DECIMAL(10,6)   NULL
    );
  ');
END
"@
  Exec-Sql -server $ServerInstance -db $Database -tsql $tsql
}

# -------- Main --------

Throw-IfMissingExe "ogr2ogr"
Throw-IfMissingExe "ogrinfo"
Throw-IfMissingExe "sqlcmd"
Throw-IfMissingExe "python"

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

Get-ChildItem -Path $InputFolder -Filter *.xlsx | ForEach-Object {
  $xlsx = $_.FullName
  $fileBase = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
  $tableName = "${TablePrefix}_${fileBase}"

  Write-Host "Processing workbook: $($_.Name) → table [$Schema].[$tableName]" -ForegroundColor Yellow

  # Create destination table once per workbook (heap, no indexes yet)
  Ensure-WorkbookTable -schema $Schema -table $tableName

  $sheets = Get-SheetNames $xlsx
  foreach ($sheet in $sheets) {
    $sheetSafe = Sanitize-Name $sheet

    $stageCsv = Join-Path $OutputFolder "${fileBase}_${sheetSafe}.stage.csv"
    $finalCsv = Join-Path $OutputFolder "${fileBase}_${sheetSafe}.final.csv"

    # 1) Extract sheet to CSV using Python/openpyxl (preserves datetime time components;
    #    GDAL's XLSX driver truncates datetime to date-only due to Excel cell format detection)
    $pyScript = @"
import openpyxl, csv, sys
from datetime import datetime, date

wb = openpyxl.load_workbook(sys.argv[1], data_only=True, read_only=True)
ws = wb[sys.argv[2]]
out = sys.argv[3]

with open(out, 'w', newline='', encoding='utf-8') as f:
    writer = csv.writer(f, quoting=csv.QUOTE_MINIMAL)
    for row in ws.iter_rows(values_only=True):
        formatted = []
        for v in row:
            if isinstance(v, datetime):
                formatted.append(v.strftime('%Y/%m/%d %H:%M:%S'))
            elif isinstance(v, date):
                formatted.append(v.strftime('%Y/%m/%d'))
            elif v is None:
                formatted.append('')
            else:
                formatted.append(str(v))
        writer.writerow(formatted)

wb.close()
"@
    $pyFile = Join-Path $OutputFolder "${fileBase}_${sheetSafe}_extract.py"
    Set-Content -Path $pyFile -Value $pyScript -Encoding UTF8
    Invoke-External "python" "`"$pyFile`" `"$xlsx`" `"$sheet`" `"$stageCsv`""
    Remove-Item $pyFile -Force -ErrorAction SilentlyContinue

    # ---- Validate sheet contains outage data ----
    # Check if second non-blank row starts with a numeric EVENT_IDX
    # Skips metadata sheets (e.g. a "SQL" sheet containing the source query)
    $firstDataLine = $null
    $sr0 = [System.IO.StreamReader]::new($stageCsv)
    try {
      $skippedFirst = $false
      while (-not $sr0.EndOfStream) {
        $l = $sr0.ReadLine()
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        if (-not $skippedFirst) { $skippedFirst = $true; continue } # skip header/first row
        $firstDataLine = $l
        break
      }
    } finally { $sr0.Close() }

    $firstField = ($firstDataLine -split ',')[0].Trim('"')
    if (-not ($firstField -match '^\d+$')) {
      Write-Host "  Skipping sheet '$sheet' - does not appear to contain outage data (first value: '$firstField')" -ForegroundColor DarkYellow
      Remove-Item $stageCsv -Force -ErrorAction SilentlyContinue
      continue
    }
    # ---- End Validation ----

    # ---- Header Fix: ensure first non-blank row is the expected header ----
    $expectedHeader = "EVENT_IDX,SERV_LOC_ID,MAX_NUM_CUST_OUT,MIN_EVENT_BEGIN,MAX_RESTORE_TIME,MAX_EVENT_ETOR,MIN_CAUSE,MIN_TROUBLE_CODE,MIN_EVENT_TYPE,MIN_PRIMARY_CAUSE_OM,MIN_SUBSTATION,MIN_FIRST_CREW_TIME,MAX_POINT_X,MAX_POINT_Y,COUNT_CUSTOMERS_AT_LOCATION"

    # Detect whether the first non-blank row equals the expected header (stream-safe)
    $needsHeader = $false
    $hasAutoGeneratedHeader = $false
    $sr = [System.IO.StreamReader]::new($stageCsv)
    try {
      while(-not $sr.EndOfStream) {
        $line = $sr.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -ne $expectedHeader) { 
          $needsHeader = $true 
          # Check if ogr2ogr auto-generated Field1,Field2,... header
          if ($line -match '^Field1,Field2,') {
            $hasAutoGeneratedHeader = $true
          }
        }
        break
      }
    } finally { $sr.Close() }

    if ($needsHeader) {
      Write-Host "  Fixing missing header row on sheet '$sheet'..." -ForegroundColor Yellow
      $tmpFixed = "$stageCsv.fixed"
      $sw = [System.IO.StreamWriter]::new($tmpFixed, $false, [System.Text.Encoding]::UTF8)
      try {
        # Write header
        $sw.WriteLine($expectedHeader)
        # Copy original content, skipping leading blank lines and auto-generated header
        $sr2 = [System.IO.StreamReader]::new($stageCsv)
        try {
          $leading = $true
          $firstNonBlank = $true
          while(-not $sr2.EndOfStream) {
            $l = $sr2.ReadLine()
            if ($leading -and [string]::IsNullOrWhiteSpace($l)) { continue }
            $leading = $false
            # Skip the auto-generated Field1,Field2,... header if present
            if ($firstNonBlank -and $hasAutoGeneratedHeader -and $l -match '^Field1,Field2,') {
              $firstNonBlank = $false
              continue
            }
            $firstNonBlank = $false
            $sw.WriteLine($l)
          }
        } finally { $sr2.Close() }
      } finally { $sw.Close() }
      Move-Item -Force $tmpFixed $stageCsv
    }
    # ---- End Header Fix ----

    # 2) Transform EPSG:2285 (MAX_POINT_X/Y) → EPSG:4326 lon/lat using CSV driver geometry detection
    #    - Detect geometry from MAX_POINT_X/MAX_POINT_Y
    #    - Assign srs 2285, transform to 4326
    #    - Write geometry as XY columns
    #    Note: GEOMETRY=AS_XY puts X,Y at the start, so we use VRT to reorder without loading into RAM
    $stageLayer = [System.IO.Path]::GetFileNameWithoutExtension($stageCsv)
    $tempCsv = Join-Path $OutputFolder "${fileBase}_${sheetSafe}.temp.csv"

    Invoke-External "ogr2ogr" (
      "-f CSV `"$tempCsv`" " +
      "`"$stageCsv`" " +
      "-oo X_POSSIBLE_NAMES=MAX_POINT_X " +
      "-oo Y_POSSIBLE_NAMES=MAX_POINT_Y " +
      #"-s_srs EPSG:2285 -t_srs EPSG:4326 " +  # NAD83 Washington South (original assumption - incorrect per SCL)
      "-s_srs EPSG:2926 -t_srs EPSG:4326 " +  # NAD83 HARN Washington North (confirmed by SCL)
      "-lco STRING_QUOTING=IF_NEEDED " +
      "-lco GEOMETRY=AS_XY"
    )

    # Create VRT to reorder columns: move X,Y from start to end, and filter blank rows
    $vrtFile = Join-Path $OutputFolder "${fileBase}_${sheetSafe}.vrt"
    $tempCsvAbs = [System.IO.Path]::GetFullPath($tempCsv)
    $vrtContent = @"
<OGRVRTDataSource>
  <OGRVRTLayer name="reordered">
    <SrcDataSource>$tempCsvAbs</SrcDataSource>
    <SrcLayer>$([System.IO.Path]::GetFileNameWithoutExtension($tempCsv))</SrcLayer>
    <SrcSQL>SELECT * FROM "$([System.IO.Path]::GetFileNameWithoutExtension($tempCsv))" WHERE EVENT_IDX IS NOT NULL AND EVENT_IDX != ''</SrcSQL>
    <Field name="EVENT_IDX" src="EVENT_IDX" type="String"/>
    <Field name="SERV_LOC_ID" src="SERV_LOC_ID" type="String"/>
    <Field name="MAX_NUM_CUST_OUT" src="MAX_NUM_CUST_OUT" type="String"/>
    <Field name="MIN_EVENT_BEGIN" src="MIN_EVENT_BEGIN" type="String"/>
    <Field name="MAX_RESTORE_TIME" src="MAX_RESTORE_TIME" type="String"/>
    <Field name="MAX_EVENT_ETOR" src="MAX_EVENT_ETOR" type="String"/>
    <Field name="MIN_CAUSE" src="MIN_CAUSE" type="String"/>
    <Field name="MIN_TROUBLE_CODE" src="MIN_TROUBLE_CODE" type="String"/>
    <Field name="MIN_EVENT_TYPE" src="MIN_EVENT_TYPE" type="String"/>
    <Field name="MIN_PRIMARY_CAUSE_OM" src="MIN_PRIMARY_CAUSE_OM" type="String"/>
    <Field name="MIN_SUBSTATION" src="MIN_SUBSTATION" type="String"/>
    <Field name="MIN_FIRST_CREW_TIME" src="MIN_FIRST_CREW_TIME" type="String"/>
    <Field name="MAX_POINT_X" src="MAX_POINT_X" type="String"/>
    <Field name="MAX_POINT_Y" src="MAX_POINT_Y" type="String"/>
    <Field name="COUNT_CUSTOMERS_AT_LOCATION" src="COUNT_CUSTOMERS_AT_LOCATION" type="String"/>
    <Field name="X" src="X" type="String"/>
    <Field name="Y" src="Y" type="String"/>
  </OGRVRTLayer>
</OGRVRTDataSource>
"@
    Set-Content -Path $vrtFile -Value $vrtContent -Encoding UTF8

    # Use VRT to write final CSV with correct column order (streaming, no memory load)
    Invoke-External "ogr2ogr" (
      "-f CSV `"$finalCsv`" " +
      "`"$vrtFile`" " +
      "reordered " +
      "-lco STRING_QUOTING=IF_NEEDED"
    )
    
    Remove-Item $tempCsv -Force -ErrorAction SilentlyContinue
    Remove-Item $vrtFile -Force -ErrorAction SilentlyContinue

    if (-not $KeepStageCsvs) {
      Remove-Item $stageCsv -Force -ErrorAction SilentlyContinue
    }

    # 3) BULK INSERT into the per-workbook table (append per sheet)
    #    The final CSV column order is original 15 columns + X,Y (WGS84).
    #    By position, X → MAX_POINT_X_AS_WGS84_LONGITUDE and Y → MAX_POINT_Y_AS_WGS84_LATITUDE.
    $finalCsvEsc = Escape-TSqlString $finalCsv
    $errorFile   = Join-Path $OutputFolder "${fileBase}_${sheetSafe}.bulk_errors.log"
    $errorFileEsc = Escape-TSqlString $errorFile
    $schemaSafe  = Escape-SqlIdentifier $Schema
    $tableSafe   = Escape-SqlIdentifier $tableName

    # Remove old error log files if they exist
    Remove-Item "$errorFile*" -Force -ErrorAction SilentlyContinue

    $bulkTsql = @"
SET NOCOUNT ON;
-- In case the datetime strings are US-style (e.g., 11/19/2024 3:52 PM)
SET DATEFORMAT mdy;

BULK INSERT [$schemaSafe].[$tableSafe]
FROM N'$finalCsvEsc'
WITH (
  FORMAT = 'CSV',                   -- Use CSV format parser (SQL Server 2017+) to handle quoted fields
  FIRSTROW = 2,
  FIELDTERMINATOR = ',',
  ROWTERMINATOR   = '\n',
  TABLOCK,
  CODEPAGE = '$CodePage',
  DATAFILETYPE = 'char',
  ERRORFILE = N'$errorFileEsc'
);

-- Force checkpoint to keep log small (SIMPLE recovery)
CHECKPOINT;
"@

    Exec-Sql -server $ServerInstance -db $Database -tsql $bulkTsql

    Write-Host "  Loaded sheet: $sheet → [$Schema].[$tableName]" -ForegroundColor Green
  }

  Write-Host "Completed workbook: $($_.Name)" -ForegroundColor Yellow
}

Write-Host "All done." -ForegroundColor Green