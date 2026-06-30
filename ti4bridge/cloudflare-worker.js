// ===========================================================================
// AsyncTI4 -> TTS proxy  (Cloudflare Worker)
// ---------------------------------------------------------------------------
// TTS's WebRequest can't negotiate TLS 1.3, but bot.asyncti4.com is TLS-1.3
// only. This Worker is the bridge: it talks TLS 1.3 to async (fine on a modern
// server) and serves the result back to TTS over TLS 1.2 with a mainstream
// cert (which we verified TTS trusts). It just passes the path straight
// through, so the loader only needs its host (API_BASE) swapped.
//
// Deploy (no CLI needed):
//   1. cloudflare.com -> sign up / log in (free tier: 100k req/day).
//   2. Workers & Pages -> Create -> Create Worker. Name it e.g. ti4bridge-proxy.
//   3. Deploy the starter, then "Edit code", paste THIS file, Deploy.
//   4. Copy the URL: https://ti4bridge-proxy.<your-subdomain>.workers.dev
//   5. Set the loader's API_BASE to:
//        https://ti4bridge-proxy.<your-subdomain>.workers.dev/api/public/game/
//      (the loader appends "<gameName>/web-data" as before)
// ===========================================================================

const ORIGIN = "https://bot.asyncti4.com";

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // Only proxy the public game API; everything else 404s.
    if (!url.pathname.startsWith("/api/public/")) {
      return new Response("not found", { status: 404 });
    }

    const upstream = ORIGIN + url.pathname + url.search;
    try {
      const resp = await fetch(upstream, {
        headers: { accept: "application/json" },
        // Be a good API citizen: cache briefly so we don't hammer async.
        cf: { cacheTtl: 30, cacheEverything: true },
      });
      return new Response(resp.body, {
        status: resp.status,
        headers: {
          "content-type": "application/json",
          "access-control-allow-origin": "*",
          "cache-control": "public, max-age=30",
        },
      });
    } catch (err) {
      return new Response(JSON.stringify({ error: String(err) }), {
        status: 502,
        headers: { "content-type": "application/json" },
      });
    }
  },
};
