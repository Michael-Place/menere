"use strict";

/**
 * Plaid bank-sync SCAFFOLD (Act V V4 — Money).
 *
 * Structure only — LIVE sync needs Michael's Plaid account + two secrets that aren't set yet:
 *   - PLAID_CLIENT_ID
 *   - PLAID_SECRET
 * (create a Plaid free "Trial" plan team, then `firebase functions:secrets:set PLAID_CLIENT_ID`
 * and `...PLAID_SECRET`, and redeploy). Until those exist, every handler returns a clearly-flagged
 * `configured:false` payload so the app can show "coming soon / needs setup" without erroring.
 *
 * The Plaid Node SDK is required LAZILY: if `plaid` isn't installed the module still loads and the
 * function still deploys — it just reports the SDK as missing. This keeps the scaffold un-blocking.
 *
 * Three verbs, matching the Link → exchange → sync lifecycle:
 *   - plaidCreateLinkToken  → a short-lived link_token the iOS Plaid Link SDK opens.
 *   - plaidExchange         → swaps the Link public_token for a persistent access_token (stored,
 *                             server-side only, under households/{hid}/private/plaid).
 *   - plaidSync             → pulls new/updated/removed transactions via /transactions/sync and
 *                             maps them into the family's `expenses` collection (idempotent by id).
 *
 * Nothing here writes real data yet: the mapping is stubbed behind the missing-creds guard so a
 * misconfigured deploy can't touch the ledger.
 */

// Lazy, failure-tolerant load of the Plaid SDK so this module imports even when the dep is absent.
let PlaidApi = null;
let PlaidConfiguration = null;
let PlaidEnvironments = null;
let PlaidProducts = null;
let PlaidCountryCode = null;
let plaidLoadError = null;
try {
  const plaid = require("plaid");
  PlaidApi = plaid.PlaidApi;
  PlaidConfiguration = plaid.Configuration;
  PlaidEnvironments = plaid.PlaidEnvironments;
  PlaidProducts = plaid.Products;
  PlaidCountryCode = plaid.CountryCode;
} catch (err) {
  plaidLoadError = err.message;
}

/** True only when BOTH the SDK is installed AND the two secrets are populated. */
function isConfigured(clientId, secret) {
  return Boolean(PlaidApi && clientId && secret);
}

/** A ready-to-call Plaid client, or null when not configured. Defaults to the `sandbox` host. */
function makeClient(clientId, secret, env) {
  if (!isConfigured(clientId, secret)) return null;
  const host = (PlaidEnvironments && PlaidEnvironments[env]) || (PlaidEnvironments && PlaidEnvironments.sandbox);
  const configuration = new PlaidConfiguration({
    basePath: host,
    baseOptions: {
      headers: { "PLAID-CLIENT-ID": clientId, "PLAID-SECRET": secret },
    },
  });
  return new PlaidApi(configuration);
}

/** The shape returned to the app when Plaid can't run yet — never throws, always flags status. */
function notConfiguredPayload(extra) {
  return Object.assign(
    {
      configured: false,
      sdkInstalled: Boolean(PlaidApi),
      sdkLoadError: plaidLoadError,
      reason: PlaidApi
        ? "Plaid credentials (PLAID_CLIENT_ID / PLAID_SECRET) are not set yet."
        : "The Plaid Node SDK is not installed in the functions package yet.",
      nextSteps: [
        "Create a Plaid dashboard team (free Trial plan).",
        "npm i plaid  (in ios/functions) if the SDK isn't installed.",
        "firebase functions:secrets:set PLAID_CLIENT_ID  and  PLAID_SECRET",
        "Redeploy plaidBankSync — then Link will open live.",
      ],
    },
    extra || {}
  );
}

/**
 * plaidCreateLinkToken — mint a Link token the iOS Plaid Link flow opens.
 * @returns {{configured:boolean, linkToken?:string}}
 */
async function createLinkToken({ clientId, secret, env, userId }) {
  const client = makeClient(clientId, secret, env);
  if (!client) return notConfiguredPayload();
  const resp = await client.linkTokenCreate({
    user: { client_user_id: String(userId || "menere-family") },
    client_name: "Bacán",
    products: [PlaidProducts.Transactions],
    country_codes: [PlaidCountryCode.Us],
    language: "en",
  });
  return { configured: true, linkToken: resp.data.link_token, expiration: resp.data.expiration };
}

/**
 * plaidExchange — swap a Link public_token for a durable access_token (caller persists it
 * server-side under households/{hid}/private/plaid; NEVER return it to the client in production).
 * @returns {{configured:boolean, itemId?:string, accessToken?:string}}
 */
async function exchangePublicToken({ clientId, secret, env, publicToken }) {
  const client = makeClient(clientId, secret, env);
  if (!client) return notConfiguredPayload();
  if (!publicToken) {
    return { configured: true, error: "publicToken is required." };
  }
  const resp = await client.itemPublicTokenExchange({ public_token: publicToken });
  return { configured: true, itemId: resp.data.item_id, accessToken: resp.data.access_token };
}

/**
 * plaidSync — pull incremental transactions via /transactions/sync and shape them into the
 * expense model. STUBBED behind the config guard: when live, `mapTransactionToExpense` below turns
 * each added/modified transaction into an idempotent `expenses/{plaid_<id>}` upsert.
 * @returns {{configured:boolean, added?:number, modified?:number, removed?:number, expenses?:Array}}
 */
async function syncTransactions({ clientId, secret, env, accessToken, cursor }) {
  const client = makeClient(clientId, secret, env);
  if (!client) return notConfiguredPayload();
  if (!accessToken) {
    return { configured: true, error: "accessToken is required." };
  }

  let added = [];
  let modified = [];
  let removed = [];
  let nextCursor = cursor;
  let hasMore = true;
  while (hasMore) {
    const resp = await client.transactionsSync({ access_token: accessToken, cursor: nextCursor });
    const d = resp.data;
    added = added.concat(d.added || []);
    modified = modified.concat(d.modified || []);
    removed = removed.concat(d.removed || []);
    hasMore = d.has_more;
    nextCursor = d.next_cursor;
  }

  const expenses = added.concat(modified).map(mapTransactionToExpense).filter(Boolean);
  return {
    configured: true,
    added: added.length,
    modified: modified.length,
    removed: removed.length,
    cursor: nextCursor,
    expenses,
  };
}

/**
 * Map a Plaid transaction → the app's Expense shape. Plaid amounts are positive for outflow, which
 * is exactly our "spend"; refunds (negative) are skipped so we never log negative expenses. Category
 * mapping is coarse for now (the client's keyword categorizer refines on read).
 */
function mapTransactionToExpense(t) {
  if (!t || typeof t.amount !== "number" || t.amount <= 0) return null;
  return {
    id: `plaid_${t.transaction_id}`,
    amount: t.amount,
    vendor: t.merchant_name || t.name || null,
    category: mapPlaidCategory(t),
    date: t.date, // ISO yyyy-MM-dd; the client parses to a Date
    source: "bankSync",
    notes: null,
  };
}

/** Very coarse Plaid personal-finance-category → our ExpenseCategory. Client refines by keyword. */
function mapPlaidCategory(t) {
  const pfc = (t.personal_finance_category && t.personal_finance_category.primary) || "";
  switch (pfc) {
    case "FOOD_AND_DRINK":
      return "dining";
    case "GENERAL_MERCHANDISE":
      return "house";
    case "GENERAL_SERVICES":
      return "house";
    case "TRANSPORTATION":
      return "other";
    case "ENTERTAINMENT":
      return "fun";
    default:
      return "other";
  }
}

module.exports = {
  isConfigured,
  createLinkToken,
  exchangePublicToken,
  syncTransactions,
  mapTransactionToExpense,
  mapPlaidCategory,
  notConfiguredPayload,
};
