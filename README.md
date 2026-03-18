# SCL Outage Map

Interactive map of Seattle City Light historical power outage data, aggregated per service location.

**Live map:** https://czf.github.io/scl-outages/

## What it shows

- One dot per SCL service location with at least one recorded outage
- **Color + size** encode all-time outage count (Viridis scale, colorblind-safe)
- Click any dot to see: outage count, avg/median/90th pct/max duration, top cause, data years
- **Backup power calculator** — estimates payback period for battery storage / generator options

## Data

- Source: Seattle City Light OMS (Outage Management System) device outage records
- Exported from SQL Server, aggregated per `SERV_LOC_ID`, converted to PMTiles via tippecanoe
- PMTiles file hosted as a GitHub Release asset (HTTP range requests, no server needed)
- ~386,000 unique service locations, ~1,210 outage events

## Repo structure

```
docs/               ← GitHub Pages (map app)
  index.html
  app.js
  style.css
SCLOutages/
  scripts/          ← PowerShell data pipeline
    workbookToTableScript.ps1   (Excel → SQL Server)
    SCLOutages-Helpers.ps1
    Update-OutageStatsSproc.ps1
    Export-OutageGeoJSON.ps1
    Invoke-AnnualRefresh.ps1
```

## Updating the data

1. Run `Invoke-AnnualRefresh.ps1` to re-import Excel workbooks and regenerate GeoJSON
2. Run tippecanoe in WSL to regenerate PMTiles (see script)
3. Create a new GitHub Release and upload the updated `outages.pmtiles`
4. Update `PMTILES_URL` in `docs/app.js` to point to the new release tag

## Tech stack

- [MapLibre GL JS](https://maplibre.org/) — map rendering
- [PMTiles](https://protomaps.com/docs/pmtiles) — vector tile format (HTTP range requests)
- [OpenFreeMap](https://openfreemap.org/) — basemap tiles (free, no API key)
- SQL Server + PowerShell — data pipeline
- tippecanoe — GeoJSON → PMTiles
