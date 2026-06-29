"use strict";

/**
 * Standalone, deploy-free TTB COLA (Certificate of Label Approval) class/type lookup.
 *
 * The public TTB COLA registry exposes a search form that POSTs to
 * `publicSearchColasBasicProcess.do?action=search` and returns an HTML results table.
 * Each row already carries the approved Class/Type description (e.g. "TABLE RED WINE",
 * "SPARKLING GRAPE WINE", "DESSERT /PORT/SHERRY/(COOKING) WINE") in its last column, so
 * we never need to fetch a per-row detail page for the class/type.
 *
 * This module is intentionally framework-free (plain `fetch` + regex) so it can be run
 * with `node` WITHOUT deploying the Cloud Function:
 *
 *     node -e "require('./ttbLookup').lookupColaClassType({productName:'Caymus'}).then(r=>console.log(JSON.stringify(r,null,2)))"
 *
 * It is defensive by contract: TTB may return zero rows, throttle, time out, or change
 * its markup — none of those throw. On anything other than a clean hit it returns
 * `{ found: false, classType: null }`.
 */

const https = require("https");
const tls = require("tls");
const { TTB_INTERMEDIATE_PEM } = require("./ttbCert");

const SEARCH_URL =
  "https://ttbonline.gov/colasonline/publicSearchColasBasicProcess.do?action=search";

const DEFAULT_TIMEOUT_MS = 12000;

// ttbonline.gov omits its intermediate cert; trust Node's default roots PLUS the bundled
// Entrust intermediate so the chain validates without disabling verification.
const TTB_CA_BUNDLE = [...tls.rootCertificates, TTB_INTERMEDIATE_PEM];

/** Decode the small set of numeric/named HTML entities TTB emits (e.g. &#x2f; → "/"). */
function decodeEntities(s) {
  if (!s) return "";
  return s
    .replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCharCode(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(parseInt(d, 10)))
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">");
}

/** Strip tags, decode entities, collapse whitespace. */
function cellText(html) {
  return decodeEntities(html.replace(/<[^>]+>/g, " "))
    .replace(/\s+/g, " ")
    .trim();
}

/** mm/dd/yyyy string for a Date `yearsAgo` years before now (lower-bounds the search window). */
function dateString(d) {
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${mm}/${dd}/${d.getFullYear()}`;
}

/**
 * Parse the COLA results table into row objects. The header order is stable:
 * [TTB ID, Permit No., Serial Number, Completed Date, Fanciful Name, Brand Name,
 *  Origin, Origin Desc, Class/Type, Class/Type Desc].
 * We key off rows that link to a `publicDisplaySearchBasic` detail page.
 */
function parseRows(html) {
  const rows = [];
  const trRe = /<tr[^>]*>([\s\S]*?)<\/tr>/gi;
  let m;
  while ((m = trRe.exec(html)) !== null) {
    const tr = m[1];
    if (!/publicDisplaySearchBasic/i.test(tr)) continue;
    const cells = [];
    const tdRe = /<td[^>]*>([\s\S]*?)<\/td>/gi;
    let c;
    while ((c = tdRe.exec(tr)) !== null) cells.push(cellText(c[1]));
    if (cells.length < 10) continue;
    rows.push({
      colaId: cells[0],
      completedDate: cells[3],
      fancifulName: cells[4],
      brandName: cells[5],
      classTypeCode: cells[8],
      classType: cells[9],
    });
  }
  return rows;
}

/**
 * Rank a parsed class/type description as a coarse wine "kind" purely to bias row
 * selection toward a representative bottling (e.g. prefer a varietal "TABLE RED WINE"
 * over a "(COOKING) WINE"). The authoritative WineType mapping lives on the iOS side.
 */
function isCooking(classType) {
  return /cooking/i.test(classType || "");
}
function hasSpecificColor(classType) {
  return /\b(red|white|ros[eé]|blush|sparkling|champagne)\b/i.test(classType || "");
}

/**
 * Choose the most representative row. Prefer (a) brand matches when a brand is supplied,
 * (b) rows whose class/type names a specific color/style, (c) non-cooking wines, then
 * the most recently completed label.
 */
function pickBestRow(rows, brand) {
  const brandLc = (brand || "").trim().toLowerCase();
  function score(r) {
    let s = 0;
    if (brandLc && r.brandName && r.brandName.toLowerCase().includes(brandLc)) s += 10;
    if (hasSpecificColor(r.classType)) s += 5;
    if (isCooking(r.classType)) s -= 5;
    if (/wine/i.test(r.classType)) s += 1;
    return s;
  }
  return rows
    .map((r) => ({ r, s: score(r) }))
    .sort((a, b) => b.s - a.s)[0].r;
}

/** POST the COLA search form. Returns the raw HTML, or null on any network/timeout error. */
function fetchResultsHtml(productName, timeoutMs) {
  const now = new Date();
  const from = new Date(now);
  // TTB rejects any date range over 15 years; stay safely under that boundary.
  from.setFullYear(from.getFullYear() - 14);

  const body = new URLSearchParams({
    "searchCriteria.productOrFancifulName": productName,
    // "E" = search Either brand OR fanciful name (matches the live form's default).
    "searchCriteria.productNameSearchType": "E",
    "searchCriteria.classTypeFrom": "",
    "searchCriteria.classTypeTo": "",
    "searchCriteria.originCode": "",
    "searchCriteria.dateCompletedFrom": dateString(from),
    "searchCriteria.dateCompletedTo": dateString(now),
  }).toString();

  const url = new URL(SEARCH_URL);
  const options = {
    method: "POST",
    hostname: url.hostname,
    path: url.pathname + url.search,
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Content-Length": Buffer.byteLength(body),
      "User-Agent": "Menere/1.0 (iOS wine app; contact: support@menere.app)",
      Accept: "text/html",
    },
    ca: TTB_CA_BUNDLE,
    timeout: timeoutMs,
  };

  return new Promise((resolve) => {
    const req = https.request(options, (res) => {
      if (res.statusCode !== 200) {
        res.resume();
        resolve(null);
        return;
      }
      let data = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve(data));
    });
    req.on("timeout", () => req.destroy());
    req.on("error", () => resolve(null));
    req.write(body);
    req.end();
  });
}

/**
 * Look up the TTB COLA class/type for a wine.
 *
 * @param {{productName?: string, brand?: string, timeoutMs?: number}} params
 * @returns {Promise<{found: boolean, classType: string|null, permitName?: string, colaId?: string}>}
 *   Never throws. `{ found: false, classType: null }` on no rows / error.
 */
async function lookupColaClassType({ productName, brand, timeoutMs } = {}) {
  const term = (productName || brand || "").trim();
  if (!term) return { found: false, classType: null };

  const html = await fetchResultsHtml(term, timeoutMs || DEFAULT_TIMEOUT_MS);
  if (!html) return { found: false, classType: null };

  let rows;
  try {
    rows = parseRows(html);
  } catch {
    return { found: false, classType: null };
  }
  if (!rows.length) return { found: false, classType: null };

  const best = pickBestRow(rows, brand || productName);
  if (!best || !best.classType) return { found: false, classType: null };

  return {
    found: true,
    classType: best.classType,
    permitName: best.brandName || undefined,
    colaId: best.colaId || undefined,
  };
}

module.exports = { lookupColaClassType, parseRows, pickBestRow, decodeEntities };
