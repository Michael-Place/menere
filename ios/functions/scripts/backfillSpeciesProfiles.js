"use strict";

/**
 * P19-C4 backfill — enrich every existing `.plant` careItem with a rich SPECIES PROFILE
 * (light/humidity/fertilizer/ideal temp/common problems + pet-toxicity).
 *
 * This is REAL, permanent, desirable data (a feature, not test data): the Place family has 32 plants
 * and 3 pets, and "is this plant safe if a dog chews it?" is genuinely useful.
 *
 * **ADDITIVE ONLY.** For each plant it calls the same `speciesProfile()` Claude helper the
 * `plantSpeciesProfile` callable uses (by the plant's species / common name — no photo), then writes
 * ONLY the `speciesProfile` field via `set({ speciesProfile }, { merge: true })`. It never touches
 * name/photo/tasks/location/careContext/water interval or any other field.
 *
 * Usage (from ios/functions):
 *   ANTHROPIC_API_KEY=$(firebase functions:secrets:access ANTHROPIC_API_KEY --project menere) \
 *     node scripts/backfillSpeciesProfiles.js            # dry-run report + write
 *   ... node scripts/backfillSpeciesProfiles.js --dry    # report only, no writes
 */

const path = require("path");
const admin = require("firebase-admin");
const { speciesProfile } = require("../plantSpeciesProfile");

const DRY = process.argv.includes("--dry");
const API_KEY = process.env.ANTHROPIC_API_KEY;
if (!API_KEY) {
  console.error("Set ANTHROPIC_API_KEY (e.g. via `firebase functions:secrets:access`).");
  process.exit(1);
}

const serviceAccount = require(path.join(
  __dirname,
  "..",
  "..",
  "menere-firebase-adminsdk-fbsvc-2f282cf452.json"
));

admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
const db = admin.firestore();

async function main() {
  const households = await db.collection("households").get();
  let totalPlants = 0;
  let profiled = 0;
  const toxicSummary = [];

  for (const hh of households.docs) {
    const careItems = await hh.ref.collection("careItems").where("kind", "==", "plant").get();
    console.log(`\nHousehold ${hh.id}: ${careItems.size} plant careItems`);
    totalPlants += careItems.size;

    for (const doc of careItems.docs) {
      const data = doc.data() || {};
      const commonName = (data.species || data.name || "").trim();
      const botanical = (data.speciesLatin || "").trim();
      const label = data.name || commonName || doc.id;

      if (!commonName && !botanical) {
        console.log(`  • ${label}: no species/name to look up — skipped`);
        continue;
      }

      try {
        const profile = await speciesProfile({
          species: botanical || undefined,
          commonName: commonName || undefined,
          apiKey: API_KEY,
        });
        const t = profile.petToxicity || {};
        const tox = t.isToxicToPets
          ? `TOXIC (${[t.toxicToDogs ? "dogs" : null, t.toxicToCats ? "cats" : null]
              .filter(Boolean)
              .join("+")}${t.severity ? `, ${t.severity}` : ""})`
          : "pet-safe";
        toxicSummary.push(`${label} [${commonName || botanical}] → ${tox}: ${t.note || ""}`);

        if (!DRY) {
          await doc.ref.set({ speciesProfile: profile }, { merge: true });
        }
        profiled += 1;
        console.log(`  ✓ ${label} — ${tox}`);
      } catch (err) {
        console.log(`  ✗ ${label}: ${err.message}`);
      }
    }
  }

  console.log(`\n===== ${DRY ? "DRY-RUN " : ""}DONE =====`);
  console.log(`Plants seen: ${totalPlants}   profiled: ${profiled}`);
  console.log(`\nToxicity results:`);
  for (const line of toxicSummary) console.log("  " + line);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
