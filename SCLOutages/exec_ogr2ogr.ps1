
ogr2ogr --version
# -------------------------
# CONFIG
# -------------------------
$Server   = "localhost"
$Database = "SclOutage"              # <-- change to your DB
$Schema   = "dbo"
$SrcTable = "OMS_Device_Outages_2024"
$TmpTable = $SrcTable+"_WGS84_TMP"

# Connection strings for OGR (SQL Server source & dest)
# Trusted connection (Windows auth):
$ConnStr = "MSSQL:server=$Server;database=$Database;trusted_connection=yes"

# -------------------------
# 1) Create temp table in WGS84 using ogr2ogr
# -------------------------
# The SQL here constructs a geometry from your EPSG:2285 X/Y (feet).
# We pass -s_srs 2285 and -t_srs 4326 so GDAL/PROJ reprojects to WGS84.
$OgrSql = "SELECT EVENT_IDX, SERV_LOC_ID, geometry::Point(MAX_POINT_X, MAX_POINT_Y, 2285) AS geom FROM [$Schema].[$SrcTable] where MAX_POINT_X is not null or MAX_POINT_Y is not null"

# Build args as an ARRAY (do NOT -join into one string)
# Then call with splatting: & ogr2ogr @args
$ogrArgs = @(
  "-f", "MSSQLSpatial", $ConnStr,
  $ConnStr,
  "-sql", $OgrSql,
  "-nln", "$Schema.$TmpTable",
  "-overwrite",
  "-lco", "GEOM_TYPE=geometry",
  "-s_srs", "EPSG:2285",
  "-t_srs", "EPSG:4326"
)

# (Optional) echo the command for debugging
Write-Host "ogr2ogr " ($ogrArgs -join ' ') -ForegroundColor Yellow

Write-Host "Running ogr2ogr to create $Schema.$TmpTable ..." -ForegroundColor Cyan
# Call operator & with ARG LIST (splatting). This is the key change.
& ogr2ogr @ogrArgs

if ($LASTEXITCODE -ne 0) {
  Write-Host "ogr2ogr failed. Check GDAL installation and connection details." -ForegroundColor Red
  exit 1
}

# -------------------------
# 2) Update existing table using the temp table (EVENT_IDX + SERV_LOC_ID)
# -------------------------
$tsql = @"
;WITH W AS (
  SELECT
    EVENT_IDX,
    SERV_LOC_ID,
    [geom].STX AS WGS84_Longitude,  -- X in EPSG:4326 is longitude
    [geom].STY AS WGS84_Latitude    -- Y in EPSG:4326 is latitude
  FROM [$Schema].[$TmpTable]
)
UPDATE tgt
   SET tgt.MAX_POINT_X_AS_WGS84_LONGITUDE = W.WGS84_Longitude,
       tgt.MAX_POINT_Y_AS_WGS84_LATITUDE  = W.WGS84_Latitude
FROM [$Schema].[$SrcTable] AS tgt
JOIN W
  ON W.EVENT_IDX   = tgt.EVENT_IDX
 AND W.SERV_LOC_ID = tgt.SERV_LOC_ID
WHERE  
    tgt.MAX_POINT_X_AS_WGS84_LONGITUDE IS NULL
 OR tgt.MAX_POINT_Y_AS_WGS84_LATITUDE  IS NULL;

-- Optional cleanup
DROP TABLE [$Schema].[$TmpTable];
"@

Write-Host "Updating $Schema.$SrcTable with WGS84 longitude/latitude ..." -ForegroundColor Cyan

# Run T-SQL with sqlcmd (Windows). If you use Azure Data Studio or SSMS, you can paste it there.
# For SQL auth: add -U YOUR_USER -P YOUR_PASS and remove -E
$sqlcmdArgs = @(
  "-S", $Server,
  "-d", $Database,
  "-E",
  "-b",
  "-Q", $tsql
)
$null = & sqlcmd @sqlcmdArgs

if ($LASTEXITCODE -eq 0) {
  Write-Host "Update complete." -ForegroundColor Green
} else {
  Write-Host "T-SQL update failed. Please review the error above." -ForegroundColor Red
  exit 1
}
