<#
.SYNOPSIS
  Shared helper functions for SCL Outages scripts. Dot-source this file.

.EXAMPLE
  . "$PSScriptRoot\SCLOutages-Helpers.ps1"
#>

function Escape-TSqlString([string]$s) {
  $s -replace "'","''"
}

function Escape-SqlIdentifier([string]$s) {
  $s -replace '[^\w]',''
}

function Invoke-SqlFile([string]$serverInstance, [string]$database, [string]$tsql) {
  $tmp = [System.IO.Path]::GetTempFileName()
  Set-Content -Path $tmp -Value $tsql -Encoding UTF8
  try {
    $serverEsc = $serverInstance -replace '"','\"'
    $dbEsc     = $database -replace '"','\"'
    $out = cmd /c "sqlcmd -S `"$serverEsc`" -d `"$dbEsc`" -b -I -i `"$tmp`" 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE): $out" }
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-SqlRows([string]$serverInstance, [string]$database, [string]$query) {
  $tmp = [System.IO.Path]::GetTempFileName()
  Set-Content -Path $tmp -Value "SET NOCOUNT ON;`n$query" -Encoding UTF8
  try {
    $serverEsc = $serverInstance -replace '"','\"'
    $dbEsc     = $database -replace '"','\"'
    $out = cmd /c "sqlcmd -S `"$serverEsc`" -d `"$dbEsc`" -h -1 -W -b -i `"$tmp`" 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE): $out" }
    return $out | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-SqlScalar([string]$serverInstance, [string]$database, [string]$query) {
  $rows = Invoke-SqlRows $serverInstance $database $query
  return ($rows | Select-Object -First 1)?.Trim()
}
