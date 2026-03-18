// ─── Config ───────────────────────────────────────────────────────────────────
// Resolved relative to the page URL — works in local dev and on GitHub Pages.
const PMTILES_URL = new URL('outages.pmtiles', location.href).href;
const LAYER       = 'outages';
const CENTER      = [-122.335, 47.610];
const ZOOM        = 11;

// Viridis-based color scale: colorblind-safe, perceptually uniform.
// Steps match 1 / 2–4 / 5–9 / 10+ outages.
const OUTAGE_COLOR = [
  'step', ['get', 'outages'],
  '#440154',        // 1     dark purple
  2,  '#2c728e',    // 2–4   blue
  5,  '#20a387',    // 5–9   teal
  10, '#fde725',    // 10+   yellow
];

// ─── PMTiles protocol ─────────────────────────────────────────────────────────
const protocol = new pmtiles.Protocol();
maplibregl.addProtocol('pmtiles', protocol.tile.bind(protocol));

// ─── Map ──────────────────────────────────────────────────────────────────────
const map = new maplibregl.Map({
  container: 'map',
  style: 'https://tiles.openfreemap.org/styles/liberty',
  center: CENTER,
  zoom: ZOOM,
  attributionControl: false,
});

map.addControl(new maplibregl.AttributionControl({ compact: true }), 'bottom-right');
map.addControl(new maplibregl.NavigationControl(), 'top-right');

map.on('load', () => {
  map.addSource('outages', {
    type: 'vector',
    url: `pmtiles://${PMTILES_URL}`,
  });

  map.addLayer({
    id: 'outage-dots',
    type: 'circle',
    source: 'outages',
    'source-layer': LAYER,
    paint: {
      // Composite expression: zoom drives interpolation, data drives each stop's output.
      // zoom must be the direct input to the top-level interpolate.
      'circle-radius': [
        'interpolate', ['linear'], ['zoom'],
        8,  ['step', ['get', 'outages'], 1.5, 5, 2.0, 10, 2.5],
        12, ['step', ['get', 'outages'], 3.5, 5, 4.5, 10, 6.0],
        16, ['step', ['get', 'outages'], 7.0, 5, 9.0, 10, 12.0],
      ],
      'circle-color': OUTAGE_COLOR,
      'circle-opacity': 0.85,
      'circle-stroke-width': ['interpolate', ['linear'], ['zoom'], 8, 0.3, 14, 0.8],
      'circle-stroke-color': 'rgba(0,0,0,0.30)',
    },
  });

  map.on('mouseenter', 'outage-dots', () => { map.getCanvas().style.cursor = 'pointer'; });
  map.on('mouseleave', 'outage-dots', () => { map.getCanvas().style.cursor = ''; });
  map.on('click', 'outage-dots', onDotClick);
});

// ─── Click handler ────────────────────────────────────────────────────────────
function onDotClick(e) {
  const p  = e.features[0].properties;
  const id = e.features[0].id;

  document.getElementById('no-selection').hidden   = true;
  document.getElementById('stats-content').hidden  = false;

  document.getElementById('s-id').textContent    = id ?? '—';
  document.getElementById('s-years').textContent =
    p.yr_from === p.yr_to ? String(p.yr_from) : `${p.yr_from}–${p.yr_to}`;
  document.getElementById('s-count').textContent = p.outages;
  document.getElementById('s-avg').textContent   = fmtHrs(p.avg_hrs);
  document.getElementById('s-med').textContent   = fmtHrs(p.med_hrs);
  document.getElementById('s-p90').textContent   = fmtHrs(p.p90_hrs);
  document.getElementById('s-max').textContent   = fmtHrs(p.max_hrs);
  document.getElementById('s-cause').textContent = toTitleCase(p.cause) || '—';

  switchTab('stats');

  // Auto-fill calculator from location history.
  const years = Math.max(1, p.yr_to - p.yr_from + 1);
  document.getElementById('c-freq').value  = (p.outages / years).toFixed(2);
  document.getElementById('c-dur').value   = parseFloat(p.avg_hrs || 4).toFixed(1);
  document.getElementById('c-source').textContent =
    `From location data: ${p.outages} outage(s) over ${years} yr(s)`;

  updateCalc();
}

// ─── Tabs ─────────────────────────────────────────────────────────────────────
function switchTab(name) {
  document.querySelectorAll('.tab').forEach(b =>
    b.classList.toggle('active', b.dataset.tab === name));
  document.querySelectorAll('.panel').forEach(p =>
    p.classList.toggle('active', p.id === `tab-${name}`));
}

document.querySelectorAll('.tab').forEach(b =>
  b.addEventListener('click', () => switchTab(b.dataset.tab)));

document.getElementById('goto-calc').addEventListener('click', () => switchTab('calc'));

// ─── Calculator ───────────────────────────────────────────────────────────────
const BATTERIES = [
  { name: 'Tesla Powerwall 2',      kwh: 13.5,  cost: 10000 },
  { name: 'Tesla Powerwall 3',      kwh: 13.5,  cost: 13000 },
  { name: 'Enphase IQ Battery 10T', kwh: 10.08, cost: 12000 },
  { name: 'Franklin aPower 15H',    kwh: 15.0,  cost: 10500 },
  { name: 'Standby generator',      kwh: null,  cost:  8000, fuelPerHr: 1.00 },
  { name: 'Portable generator',     kwh: null,  cost:  1200, fuelPerHr: 1.50 },
];

function updateCalc() {
  const power  = +document.getElementById('c-power').value || 1.5;
  const food   = +document.getElementById('c-food').value  || 0;
  const wfh    = +document.getElementById('c-wfh').value   || 0;
  const rate   = +document.getElementById('c-rate').value  || 0;
  const freq   = +document.getElementById('c-freq').value  || 1;
  const dur    = +document.getElementById('c-dur').value   || 4;

  const annualHrs  = freq * dur;
  const wfhFrac    = wfh / 5;
  // Food loss scales linearly up to 4 hrs, then caps (threshold for fridge safety).
  const foodLoss   = freq * food * Math.min(1, dur / 4);
  const workLoss   = annualHrs * rate * wfhFrac;
  const annualCost = foodLoss + workLoss;
  const neededKwh  = power * Math.min(dur, 24);

  let html = `
    <div class="calc-summary">
      <div class="c-row"><span>Expected hours off/year</span><b>${annualHrs.toFixed(1)} hrs</b></div>
      <div class="c-row"><span>Annual outage cost</span>    <b>$${annualCost.toFixed(0)}/yr</b></div>
      <div class="c-row"><span>Capacity needed</span>       <b>${neededKwh.toFixed(1)} kWh</b></div>
    </div>
    <table class="opt-table" aria-label="Backup power options comparison">
      <thead><tr><th>Option</th><th>Installed</th><th>Payback</th></tr></thead>
      <tbody>`;

  for (const b of BATTERIES) {
    const annualFuel   = b.fuelPerHr != null ? annualHrs * b.fuelPerHr : 0;
    const annualSaving = annualCost - annualFuel;
    const payback      = annualSaving > 0 ? `${(b.cost / annualSaving).toFixed(1)} yrs` : '—';
    const sizeWarn     = b.kwh != null && b.kwh < neededKwh
      ? `<br><small class="warn">⚠ ${b.kwh} kWh &lt; ${neededKwh.toFixed(1)} needed</small>` : '';
    const fuelNote     = b.fuelPerHr != null
      ? `<br><small>+$${annualFuel.toFixed(0)}/yr fuel</small>` : '';

    html += `<tr>
      <td>${b.name}${sizeWarn}${fuelNote}</td>
      <td>~$${b.cost.toLocaleString()}</td>
      <td>${payback}</td>
    </tr>`;
  }

  html += `</tbody></table>
    <p class="disclaimer">Costs are rough estimates. Payback assumes all outage costs are avoided.
    Consult a licensed installer for accurate pricing.</p>`;

  document.getElementById('calc-out').innerHTML = html;
}

document.querySelectorAll('#tab-calc input').forEach(el =>
  el.addEventListener('input', updateCalc));

// Initial render so calculator shows results on first tab visit.
updateCalc();

// ─── Helpers ──────────────────────────────────────────────────────────────────
function fmtHrs(hrs) {
  const h = parseFloat(hrs);
  if (isNaN(h) || hrs == null || hrs === '') return '—';
  if (h < 1) return `${Math.round(h * 60)} min`;
  return `${h.toFixed(1)} hrs`;
}

function toTitleCase(s) {
  if (!s) return '';
  return s.toLowerCase().replace(/\b\w/g, c => c.toUpperCase());
}
