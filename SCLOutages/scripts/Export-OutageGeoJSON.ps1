<#
.SYNOPSIS
  Executes the outage stats stored procedure and streams results to a GeoJSON file.
  Automatically ensures the stored procedure is current before executing.

.PARAMETER ServerInstance
  SQL Server instance name.

.PARAMETER Database
  Target database name.

.PARAMETER OutputPath
  Path for the output GeoJSON file.

.PARAMETER Schema
  SQL schema (default "dbo").

.PARAMETER DeviceTablePattern
  LIKE pattern for Device outage tables (default "SCL_%_OMS_Device_%").

.EXAMPLE
  .\Export-OutageGeoJSON.ps1 `
    -ServerInstance "localhost" `
    -Database "SclOutage" `
    -OutputPath "G:\temp_output\outages.geojson"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string]$ServerInstance,
  [Parameter(Mandatory=$true)] [string]$Database,
  [Parameter(Mandatory=$true)] [string]$OutputPath,
  [string]$Schema             = "dbo",
  [string]$DeviceTablePattern = "SCL_%_OMS_Device_%"
)

. "$PSScriptRoot\SCLOutages-Helpers.ps1"

$ProcName   = "usp_GetOutageStatsByLocation"
$schemaSafe = Escape-SqlIdentifier $Schema

# -------- Ensure sproc is current --------

& "$PSScriptRoot\Update-OutageStatsSproc.ps1" `
  -ServerInstance     $ServerInstance `
  -Database           $Database `
  -Schema             $Schema `
  -DeviceTablePattern $DeviceTablePattern

if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
  throw "Update-OutageStatsSproc failed."
}

# -------- Stream results to GeoJSON --------

Write-Host "Streaming aggregation results to GeoJSON..." -ForegroundColor Cyan

$connStr = "Server=$ServerInstance;Database=$Database;Integrated Security=true"
$conn    = [System.Data.SqlClient.SqlConnection]::new($connStr)
$conn.Open()

$cmd                = $conn.CreateCommand()
$cmd.CommandText    = "EXEC [$schemaSafe].[$ProcName]"
$cmd.CommandTimeout = 600

$reader   = $cmd.ExecuteReader()
$sw       = [System.IO.StreamWriter]::new($OutputPath, $false, [System.Text.Encoding]::UTF8)
$first    = $true
$rowCount = 0

$sw.WriteLine('{"type":"FeatureCollection","features":[')

while ($reader.Read()) {
  $lon   = $reader["longitude"]
  $lat   = $reader["latitude"]
  $id    = $reader["SERV_LOC_ID"]
  $cause = ([string]$reader["top_cause"]) -replace '\\','\\' -replace '"','\"'

  $feature =
    '{"type":"Feature","id":' + $id +
    ',"geometry":{"type":"Point","coordinates":[' + $lon + ',' + $lat + ']}' +
    ',"properties":{' +
      '"outages":'  + $reader["outage_count"] + ',' +
      '"avg_hrs":'  + $reader["avg_dur_hrs"]  + ',' +
      '"med_hrs":'  + $reader["med_dur_hrs"]  + ',' +
      '"p90_hrs":'  + $reader["p90_dur_hrs"]  + ',' +
      '"max_hrs":'  + $reader["max_dur_hrs"]  + ',' +
      '"yr_from":'  + $reader["first_year"]   + ',' +
      '"yr_to":'    + $reader["last_year"]    + ',' +
      '"cause":"'   + $cause + '"' +
    '}}'

  if (-not $first) { $sw.Write(',') }
  $sw.WriteLine($feature)
  $first = $false
  $rowCount++

  if ($rowCount % 10000 -eq 0) {
    Write-Host "  $rowCount features written..." -ForegroundColor DarkGray
  }
}

$sw.WriteLine(']}')
$sw.Close()
$reader.Close()
$conn.Close()

Write-Host "Done. $rowCount features written to: $OutputPath" -ForegroundColor Green
