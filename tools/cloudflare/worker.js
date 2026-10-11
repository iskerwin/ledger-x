// Cloudflare Worker: a faster mirror of the Ledger X SideStore / AltStore sources and the IPAs they point to.
//
//   /release.json   /dev.json     the sources, with every download link pointing back at this Worker
//   /dl/<tag>/Ledger.ipa          the IPA of a release (v0.0.2…) or of the dev build, cached at the edge
//
// Only these paths are served, so it can't be used as a general proxy.
// Deploy: Cloudflare dashboard → Workers & Pages → Create → Worker → paste this file → Deploy,
// then Settings → Domains & Routes → add a custom domain (workers.dev is often unreachable in mainland China).

const REPO = "iskerwin/ledger-x";
const RAW = `https://raw.githubusercontent.com/${REPO}/sidestore`;
const DL = `https://github.com/${REPO}/releases/download/`;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method !== "GET" && request.method !== "HEAD") return new Response("Method not allowed", { status: 405 });

    const src = url.pathname.match(/^\/(release|dev)\.json$/);
    if (src) return source(src[1], url.origin);

    const dl = url.pathname.match(/^\/dl\/(v\d+(?:\.\d+)*|dev)\/Ledger\.ipa$/);
    if (dl) return ipa(dl[1], request, ctx);

    if (url.pathname === "/") {
      return new Response(`Ledger X sources\n${url.origin}/release.json\n${url.origin}/dev.json\n`, { headers: { "content-type": "text/plain; charset=utf-8" } });
    }
    return new Response("Not found", { status: 404 });
  },
};

// the source from GitHub, rewritten so the app downloads through this Worker too
async function source(kind, origin) {
  const r = await fetch(`${RAW}/${kind}.json`, { cf: { cacheTtl: 60, cacheEverything: true } });
  if (!r.ok) return new Response(`GitHub returned ${r.status}`, { status: 502 });
  const s = await r.json();
  s.sourceURL = `${origin}/${kind}.json`;
  for (const app of s.apps ?? []) {
    for (const v of app.versions ?? []) v.downloadURL = rewrite(v.downloadURL, origin, v.version);
    if (app.downloadURL) app.downloadURL = rewrite(app.downloadURL, origin, app.version);
  }
  return new Response(JSON.stringify(s, null, 2), {
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=60", "access-control-allow-origin": "*" },
  });
}

// github.com/<repo>/releases/download/<tag>/Ledger.ipa → <worker>/dl/<tag>/Ledger.ipa?v=<version>
// (the version in the query keeps the dev build's edge cache from serving an older build)
function rewrite(link, origin, version) {
  if (!link || !link.startsWith(DL)) return link;
  return `${origin}/dl/${link.slice(DL.length)}?v=${encodeURIComponent(version ?? "")}`;
}

async function ipa(tag, request, ctx) {
  const cache = caches.default;
  const key = new Request(request.url, { method: "GET" });
  const hit = await cache.match(key);
  if (hit) return request.method === "HEAD" ? new Response(null, hit) : hit;

  const r = await fetch(`${DL}${tag}/Ledger.ipa`, { redirect: "follow" });
  if (!r.ok) return new Response(`GitHub returned ${r.status}`, { status: r.status === 404 ? 404 : 502 });
  // a release never changes; the dev build is keyed by its version (?v=), so a day is plenty either way
  const res = new Response(r.body, {
    headers: {
      "content-type": "application/octet-stream",
      "content-disposition": 'attachment; filename="Ledger.ipa"',
      "cache-control": tag === "dev" ? "public, max-age=86400" : "public, max-age=31536000, immutable",
      ...(r.headers.get("content-length") ? { "content-length": r.headers.get("content-length") } : {}),
    },
  });
  ctx.waitUntil(cache.put(key, res.clone()));
  return request.method === "HEAD" ? new Response(null, res) : res;
}
