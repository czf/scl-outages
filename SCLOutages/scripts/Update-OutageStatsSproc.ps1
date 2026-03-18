<#
.SYNOPSIS
  Discovers all Device outage tables in the database, compares against the stored
  procedure's source table signature, and regenerates the sproc only when the table
  list has changed (preserving the SQL Server plan cache otherwise).

.PARAMETER ServerInstance
  SQL Server instance name.

.PARAMETER Database
  Target database name.

.PARAMETER Schema
  SQL schema (default "dbo").

.PARAMETER DeviceTablePattern
  LIKE pattern for Device outage tables (default "SCL_%_OMS_Device_%").

.EXAMPLE
  .\Update-OutageStatsSproc.ps1 -ServerInstance "localhost" -Database "SclOutage"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string]$ServerInstance,
  [Parameter(Mandatory=$true)] [string]$Database,
  [string]$Schema             = "dbo",
  [string]$DeviceTablePattern = "SCL_%_OMS_Device_%"
)

. "$PSScriptRoot\SCLOutages-Helpers.ps1"

$ProcName = "usp_GetOutageStatsByLocation"
$PropName = "SourceTables"

# -------- Discover tables --------

Write-Host "Discovering Device outage tables..." -ForegroundColor Cyan

$schemaEsc  = Escape-TSqlString $Schema
$patternEsc = Escape-TSqlString $DeviceTablePattern

$tableNames = Invoke-SqlRows $ServerInstance $Database @"
SELECT t.name
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = N'$schemaEsc'
  AND t.name LIKE N'$patternEsc'
ORDER BY t.name
"@

if (-not $tableNames -or $tableNames.Count -eq 0) {
  throw "No tables found matching pattern '$DeviceTablePattern' in schema '$Schema'."
}

Write-Host "  Found: $($tableNames -join ', ')" -ForegroundColor Cyan

# -------- Compare signature --------

$schemaSafe  = Escape-SqlIdentifier $Schema
$propNameEsc = Escape-TSqlString $PropName
$signature   = ($tableNames | Sort-Object) -join '|'

$storedSig = Invoke-SqlScalar $ServerInstance $Database @"
SELECT CAST(ep.value AS NVARCHAR(MAX))
FROM sys.extended_properties ep
WHERE ep.major_id = OBJECT_ID(N'[$schemaSafe].[$ProcName]')
  AND ep.name     = N'$propNameEsc'
  AND ep.minor_id = 0
"@

if ($storedSig -eq $signature) {
  Write-Host "Stored procedure is current - no changes needed." -ForegroundColor Green
  return
}

Write-Host "Table list changed - regenerating stored procedure..." -ForegroundColor Yellow

# -------- Build static UNION ALL --------

$unionParts = $tableNames | ForEach-Object {
  $tbl = Escape-SqlIdentifier $_
  "    SELECT EVENT_IDX, SERV_LOC_ID, MIN_EVENT_BEGIN, MAX_RESTORE_TIME," +
  " MIN_PRIMARY_CAUSE_OM AS MIN_CAUSE, MAX_POINT_X_AS_WGS84_LONGITUDE, MAX_POINT_Y_AS_WGS84_LATITUDE" +
  " FROM [$schemaSafe].[$tbl]"
}
$unionSql = $unionParts -join "`n    UNION ALL`n"

# -------- Create/replace stored procedure --------

Invoke-SqlFile $ServerInstance $Database @"
CREATE OR ALTER PROCEDURE [$schemaSafe].[$ProcName]
AS
BEGIN
  SET NOCOUNT ON;

  WITH AllOutages AS (
$unionSql
  ),
  WithDuration AS (
    SELECT
      SERV_LOC_ID,
      EVENT_IDX,
      MAX_POINT_X_AS_WGS84_LONGITUDE  AS lon,
      MAX_POINT_Y_AS_WGS84_LATITUDE   AS lat,
      MIN_CAUSE,
      MIN_EVENT_BEGIN,
      DATEDIFF(minute, MIN_EVENT_BEGIN, MAX_RESTORE_TIME) AS duration_mins
    FROM AllOutages
    WHERE MAX_POINT_X_AS_WGS84_LONGITUDE IS NOT NULL
      AND MAX_RESTORE_TIME IS NOT NULL
      AND MIN_EVENT_BEGIN  IS NOT NULL
  ),
  Percentiles AS (
    SELECT DISTINCT
      SERV_LOC_ID,
      CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY duration_mins)
             OVER (PARTITION BY SERV_LOC_ID) / 60.0 AS DECIMAL(10,2)) AS med_dur_hrs,
      CAST(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY duration_mins)
             OVER (PARTITION BY SERV_LOC_ID) / 60.0 AS DECIMAL(10,2)) AS p90_dur_hrs
    FROM WithDuration
  ),
  TopCause AS (
    SELECT SERV_LOC_ID, MIN_CAUSE,
      ROW_NUMBER() OVER (PARTITION BY SERV_LOC_ID ORDER BY COUNT(*) DESC) AS rn
    FROM WithDuration
    WHERE MIN_CAUSE IS NOT NULL AND MIN_CAUSE != ''
    GROUP BY SERV_LOC_ID, MIN_CAUSE
  ),
  Stats AS (
    SELECT
      SERV_LOC_ID,
      AVG(lon)                                                        AS longitude,
      AVG(lat)                                                        AS latitude,
      COUNT(DISTINCT EVENT_IDX)                                       AS outage_count,
      CAST(SUM(duration_mins * 1.0 / 60) AS DECIMAL(10,2))           AS total_hrs,
      CAST(AVG(duration_mins * 1.0 / 60) AS DECIMAL(10,2))           AS avg_dur_hrs,
      CAST(MAX(duration_mins) / 60.0     AS DECIMAL(10,2))           AS max_dur_hrs,
      MIN(YEAR(MIN_EVENT_BEGIN))                                      AS first_year,
      MAX(YEAR(MIN_EVENT_BEGIN))                                      AS last_year
    FROM WithDuration
    GROUP BY SERV_LOC_ID
  )
  SELECT
    s.SERV_LOC_ID,
    s.longitude,
    s.latitude,
    s.outage_count,
    s.total_hrs,
    s.avg_dur_hrs,
    p.med_dur_hrs,
    p.p90_dur_hrs,
    s.max_dur_hrs,
    s.first_year,
    s.last_year,
    ISNULL(tc.MIN_CAUSE, '') AS top_cause
  FROM Stats s
  JOIN  Percentiles p  ON p.SERV_LOC_ID  = s.SERV_LOC_ID
  LEFT JOIN TopCause tc ON tc.SERV_LOC_ID = s.SERV_LOC_ID AND tc.rn = 1
  ORDER BY s.SERV_LOC_ID;
END
"@

Write-Host "  Stored procedure created/updated." -ForegroundColor Green

# -------- Update extended property --------

$sigEsc = Escape-TSqlString $signature

Invoke-SqlFile $ServerInstance $Database @"
IF EXISTS (
  SELECT 1 FROM sys.extended_properties
  WHERE major_id = OBJECT_ID(N'[$schemaSafe].[$ProcName]')
    AND name = N'$propNameEsc' AND minor_id = 0
)
  EXEC sys.sp_updateextendedproperty
    @name       = N'$propNameEsc', @value      = N'$sigEsc',
    @level0type = N'SCHEMA',       @level0name = N'$schemaSafe',
    @level1type = N'PROCEDURE',    @level1name = N'$ProcName';
ELSE
  EXEC sys.sp_addextendedproperty
    @name       = N'$propNameEsc', @value      = N'$sigEsc',
    @level0type = N'SCHEMA',       @level0name = N'$schemaSafe',
    @level1type = N'PROCEDURE',    @level1name = N'$ProcName';
"@

Write-Host "  Signature stored. Done." -ForegroundColor Green
