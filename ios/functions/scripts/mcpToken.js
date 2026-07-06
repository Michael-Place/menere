"use strict";

/**
 * mcpToken — mint (or print) the MCP bearer token for a household via the Admin SDK.
 *
 * Usage (from ios/functions):
 *   node scripts/mcpToken.js <hid>            # generate + store a new token, print it
 *   node scripts/mcpToken.js <hid> --show     # print the existing token (no change)
 *
 * Requires the gitignored Admin SDK key at ios/menere-firebase-adminsdk-fbsvc-*.json.
 * The token embeds the hid (`bcn~<hid>~<secret>`); the server validates it with a single doc read.
 */

const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");
const { mintToken } = require("../mcpServer");

const ENDPOINT = "https://us-central1-menere.cloudfunctions.net/bacanMcp";

function findKey() {
  // Explicit override wins (useful from a git worktree, where the gitignored key isn't checked out).
  if (process.env.MENERE_ADMIN_KEY) return process.env.MENERE_ADMIN_KEY;
  const dir = path.join(__dirname, "..", "..");
  const hit = fs.existsSync(dir) &&
    fs.readdirSync(dir).find((f) => /^menere-firebase-adminsdk-fbsvc-.*\.json$/.test(f));
  if (!hit) throw new Error("Admin SDK key not found under ios/ (set MENERE_ADMIN_KEY to its path).");
  return path.join(dir, hit);
}

(async () => {
  const hid = process.argv[2];
  const show = process.argv.includes("--show");
  if (!hid) {
    console.error("Usage: node scripts/mcpToken.js <hid> [--show]");
    process.exit(1);
  }
  admin.initializeApp({ credential: admin.credential.cert(require(findKey())) });
  const db = admin.firestore();
  const ref = db.collection("households").doc(hid).collection("config").doc("mcpToken");

  if (show) {
    const snap = await ref.get();
    if (!snap.exists) { console.error("No token set for", hid); process.exit(2); }
    console.log(snap.data().token);
    process.exit(0);
  }

  const token = mintToken(hid);
  await ref.set({ token, createdAt: admin.firestore.Timestamp.now() });
  console.log("Household:", hid);
  console.log("Endpoint :", ENDPOINT);
  console.log("Token    :", token);
  console.log("\nAuthenticate with:  Authorization: Bearer " + token);
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
