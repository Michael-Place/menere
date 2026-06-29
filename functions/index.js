"use strict";

/**
 * Menere Cloud Functions.
 *
 * `ttbColaLookup` is a v2 HTTPS callable (us-central1) that wraps the deploy-free
 * `lookupColaClassType` TTB COLA lookup. It returns the approved class/type for a wine
 * so the iOS `TTBColaSource` can map it to an authoritative `WineType`.
 */

const { onCall } = require("firebase-functions/v2/https");
const { setGlobalOptions } = require("firebase-functions/v2");
const { lookupColaClassType } = require("./ttbLookup");

setGlobalOptions({ region: "us-central1", maxInstances: 10 });

exports.ttbColaLookup = onCall(
  { timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    // TODO: enforce App Check / auth before public launch (request.app / request.auth).
    const data = request.data || {};
    const productName = typeof data.productName === "string" ? data.productName : "";
    const brand = typeof data.brand === "string" ? data.brand : "";
    return await lookupColaClassType({ productName, brand });
  }
);
