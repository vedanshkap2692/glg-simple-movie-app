# GLG Movie App: Technical Review

**Task:** Get the React + Node + TypeScript movie app running in a local dev environment, and be able to explain what was broken, how it was found, and how it was fixed.

**Outcome:** The app runs. The listing view and the detail view both load, the All / Movies / TV Shows tabs work, and clicking a poster opens its detail page. The checks below were done in a real browser (headless Chrome driven by puppeteer).

Beyond the brief, the app was also reviewed for security, UI quality and production readiness. In total there are **26 findings**, each backed by evidence:

| Area | Findings | Status |
| ---- | -------- | ------ |
| Setup defects | 8 | Fixed and committed |
| Security | 6 | Documented, with fixes (some tested in isolation) |
| UI | 6 | Documented, with fixes |
| Production readiness | 6 | Documented; 4 reproduced in a real production build |

The presentation of this review is in [`docs/presentation.pdf`](docs/presentation.pdf).

| Service  | URL                   | Stack                                  |
| -------- | --------------------- | -------------------------------------- |
| Frontend | http://localhost:3031 | React 18, MobX, MUI, Vite 5            |
| API      | http://localhost:9091 | Express, TypeScript (ts-node/nodemon)  |

## Contents

1. [Architecture](#1-architecture)
2. [Approach](#2-approach)
3. [Setup defects (fixed)](#3-setup-defects-fixed)
4. [Security findings](#4-security-findings)
5. [UI issues](#5-ui-issues)
6. [Production readiness](#6-production-readiness)
7. [Roadmap](#7-roadmap)
8. [Verification](#8-verification)
9. [Limits](#9-limits)
10. [How to run](#10-how-to-run)

## 1. Architecture

- **Browser** loads the React app from Vite. It calls `VITE_SERVER/api/media/...` with axios.
- **Express server** exposes `/api/media/trending`, `/trending/movies`, `/trending/tv` and `/:mediaType/:id`. It calls the TMDB API through a `MovieDB` service with a server-side bearer token, and filters out adult content, a couple of banned title terms, and non-English titles.
- **Mocking (MSW):** when `VITE_MOCK_RESULTS=true`, MSW intercepts TMDB calls on the server (`server/mocks`) and poster-image requests in the browser (`src/mocks`). Fixture JSON lives in `server/mocks/data`, posters in `public/images`.
- **Docker:** `docker-compose.yml` runs the same dev image twice (frontend and backend), both reading `.env.development`.
- **Production (intended):** no Vite. Express should serve the built SPA and the API from one origin. Section 6 shows that it does not yet.

## 2. Approach

1. **Read before running.** README, `package.json`, Docker files, env template, and all server and client source. This alone surfaced several bugs.
2. **Probe the environment.** TMDB's API was unreachable from this network, but its image CDN was. The README describes this ISP-blocking case and prescribes mock mode, so we used it.
3. **Run natively instead of Docker,** for faster feedback: `npm install`, then `dev:server` and `dev:client` with the env vars loaded.
4. **Test each layer on its own,** so a failure points at one place: typecheck client and server separately, request every API endpoint (including every mock detail file), then drive a real browser.
5. **Attack and operate.** Send hostile input to the API, read the server logs, run `npm audit`, then build and run the production bundle.
6. **Fix, then re-verify** after each change.

| Method | What it caught |
| ------ | -------------- |
| Read every file before running | Missing `await`, wrong CORS port, stray script tag |
| Probe the network with curl | TMDB API blocked, image CDN open |
| Typecheck client and server separately | 9 client type errors |
| Sweep every API endpoint | Empty Interstellar fixture returning 500 |
| Drive Chrome with puppeteer | Tabs, navigation and screenshots verified |
| Hostile requests and a production build | Path traversal, token in logs, 4 production gaps |

## 3. Setup defects (fixed)

These eight are fixed and committed.

| # | Issue | Evidence | Fix |
| - | ----- | -------- | --- |
| 1 | TMDB API unreachable on this network | `curl` to `api.themoviedb.org` returned no response; the image CDN responded | Enabled `VITE_MOCK_RESULTS=true` (MSW mocks) |
| 2 | No `.env.development`, and `etc/dev.env` used stale variable names (`REACT_APP_SERVER`, `MOVIE_API_V4`) that the code never reads | Code reads `VITE_SERVER`, `MOVIE_DB_API_BASE_URL`, `MOVIE_DB_API_KEY`, `API_PORT` | Created `.env.development`, updated `etc/dev.env` |
| 3 | `bin/prepare-docker.sh` never created the env file, and its backticks in an `echo` ran as a command substitution | Read the script | Quoted correctly; the script seeds `.env.development` if missing |
| 4 | `MediaDetailController.getMedia` didn't `await` the axios call, then read `response.data` on a Promise | Code review | Added `await` |
| 5 | `server/mocks/data/movie/157336.json` (Interstellar) was a 0-byte file | Requesting every mock detail endpoint: only this one returned 500 (`Unexpected end of JSON input`) | Rebuilt the fixture from the trending entry plus a few detail fields. The genres, tagline and runtime are illustrative, not TMDB data |
| 6 | CORS origin hardcoded to `localhost:3000`, but the client runs on 3031 and calls the API directly | Code review | Origin now derives from `PORT`, defaulting to 3031 |
| 7 | `index.html` included `mockServiceWorker.js` as a normal `<script type="module">` | Code review. MSW registers its own service worker from `index.tsx` | Removed the tag |
| 8 | Client typecheck failed with 9 errors: no Vite env types, and TypeScript 4.9 can't compile the TC39 `accessor` decorators the MobX stores use | `tsc -p tsconfig.json` output | Added `src/vite-env.d.ts`, upgraded to TypeScript 5.x, client target `es2020`, removed `experimentalDecorators` from the client tsconfig only (the server still needs it for `bind-decorator`) |

The missing `await` (#4) is the most important: without it the detail view never shows anything. The `any` type on the response hid it from the compiler.

```ts
// Before
const response: any = this.apiInstance.get(`${media_type}/${id}`);
this.mediaDetailStore.setDocument(response.data.media); // TypeError

// After
const response = await this.apiInstance.get(`${media_type}/${id}`);
this.mediaDetailStore.setDocument(response.data.media);
```

## 4. Security findings

Severity is our judgement for this app. The committed token has the `api_read` scope (read-only), which caps the damage of S1–S3, but they are still the top priority because they are cheap to exploit and cheap to fix.

| # | Finding | Severity | Evidence |
| - | ------- | -------- | -------- |
| S1 | Path traversal into other TMDB endpoints, using our token | High | `GET /api/media/..%2Faccount/1` made the server call `https://api.themoviedb.org/account/1` |
| S2 | Bearer token printed in server logs | High | One dev session's log held 8 copies of the token |
| S3 | API token committed to a public repo | High | `etc/dev.env` and `.env.development` |
| S4 | Vulnerable production dependencies | High | `npm audit --omit=dev`: 12 advisories, 2 critical |
| S5 | Content filter bypassed on the detail route, and over-broad on lists | Medium | Filter only runs on list routes; substring match blocks "Essex" |
| S6 | No upstream timeouts, rate limits or security headers | Medium | Code review of `server/index.ts` and `MovieDB.ts` |

### S1. Path traversal (server-side request forgery pattern)

`req.params.mediaType` goes straight into the outbound URL. Express decodes `%2F` in route params, and axios resolves `../`, so a caller can reach any TMDB endpoint with our credentials. `Number(id)` does not help, because the attack is in `mediaType`. The fix is an allow-list, not escaping:

```ts
const TYPES = new Set(["movie", "tv"]);

const { mediaType, id } = req.params;
if (!TYPES.has(mediaType) || !/^\d{1,10}$/.test(id)) {
  res.status(400).json({ error: "INVALID_MEDIA" });
  return;
}
await movieService.getMedia(mediaType as MediaType, Number(id));
```

*Tested in isolation:* accepts `movie`/`tv` with numeric ids; rejects `../account`, non-numeric ids and unknown types.

### S2. Token in logs

`console.error(e)` on an axios error prints the whole request config, including the `Authorization` header. Logs usually reach far more people than secrets do. Log a safe summary instead, and return 502 so clients know the fault is upstream:

```ts
} catch (e: any) {
  console.error("TMDB request failed", {
    message: e?.message,
    status: e?.response?.status,
    path: e?.config?.url,
  });
  res.status(502).json({ error: "UPSTREAM_ERROR" });
}
```

*Tested in isolation:* the summary keeps the status and never contains the token. In production, a logger with built-in redaction (for example pino) is the durable fix.

### S3. Committed token

A TMDB bearer token sits in `etc/dev.env` and `.env.development`. It was already public in the upstream repo, and is now in this public repo too. Once a secret is in git history, deleting the file is not enough:

- Rotate the token.
- Inject it at runtime from a secret manager or CI secret.
- Commit only an `.env.example` with empty values, and add `.env.development` to `.gitignore`.

### S4. Vulnerable production dependencies

`npm audit` reports 76 findings, but most come from `react-scripts`, which this Vite app never uses. Production dependencies alone have 12, and all have fixes available:

| Severity | Packages |
| -------- | -------- |
| Critical | `form-data`, `proxy-addr` |
| High | `express`, `axios`, `react-router`, `react-router-dom`, `@remix-run/router`, `body-parser`, `path-to-regexp` |
| Moderate | `follow-redirects`, `qs`, `yaml` |

Fix: `npm audit fix`, remove `react-scripts`, then Renovate or Dependabot and an audit gate in CI.

### S5. Content filter

- The detail route never runs `filterMedia`, so adult titles are reachable at `/api/media/movie/:id`.
- The title filter matches substrings, so "Essex", "Middlesex" and "Sexton" are blocked.

```ts
const BLOCKED = [/\bsex\b/i, /\bmagic mike\b/i];
const isBlocked = (t = "") => BLOCKED.some((re) => re.test(t));

// getMedia: same policy as the list routes
if (media.adult || isBlocked(media.title ?? media.name)) {
  res.status(404).json({ error: "NOT_FOUND" });
  return;
}
```

*Tested in isolation:* Essex, Middlesex and Sexton pass; Sex Education and Magic Mike XXL are blocked.

### S6. Missing hardening (proposed, not run)

Without an upstream timeout, a slow TMDB holds every request open, so a handful of clients can exhaust the server.

```ts
import helmet from "helmet";
import rateLimit from "express-rate-limit";

app.use(helmet());
app.use("/api", rateLimit({ windowMs: 60_000, limit: 100 }));

// MovieDB
axios.create({ baseURL, headers, timeout: 5_000 });
```

Also fix the `Content-Type` header value in `MovieDB.ts`, which has a leading space (`" application/json;charset=utf-8"`).

## 5. UI issues

"Latent" means the current fixtures don't trigger it, but real TMDB data will.

| # | Issue | User impact | Where |
| - | ----- | ----------- | ----- |
| U1 | Missing date renders today's date (`dayjs(undefined)` is "now") | Wrong date shown (latent) | `MediaComponent`, `MediaDetailView` |
| U2 | No loading or error state | Blank page and an unhandled promise rejection when the API fails | Both views |
| U3 | Links are plain `<a href>` / MUI `Link href` | Full page reload on every click; relative `movie/123` breaks off `/` | `MediaComponent`, Back link |
| U4 | Missing poster builds `.../null` | Broken image (latent) | Both views |
| U5 | Fast tab switches can race | Responses arrive out of order and show the wrong list | `MediaView` |
| U6 | Weak accessibility | `alt="poster"` on every image; tabs have no selected state for screen readers | Cards, tabs |

### Rendering fixes

Helpers (*tested in isolation*):

```ts
const fmtDate = (d?: string) =>
  d && dayjs(d).isValid() ? dayjs(d).format("MMM DD, YYYY") : "Release date unknown";

const posterUrl = (p?: string | null) =>
  p ? `${IMG_BASE}${p}` : "/images/placeholder.svg"; // placeholder asset still to add
```

Component (*proposed*):

```tsx
import { Link } from "react-router-dom";

const title = movie.title ?? movie.name;
<Link to={`/${movie.media_type}/${movie.id}`}>
  <img src={posterUrl(movie.poster_path)} alt={`${title} poster`} />
</Link>
<div>{fmtDate(movie.release_date ?? movie.first_air_date)}</div>
```

### State fixes (proposed)

Track status explicitly and abort the previous request when the tab changes, so the last click always wins:

```tsx
const [status, setStatus] = useState<"loading" | "ok" | "error">("loading");

useEffect(() => {
  const ctrl = new AbortController();
  setStatus("loading");
  controller.load(contentType, ctrl.signal)
    .then(() => setStatus("ok"))
    .catch(() => { if (!ctrl.signal.aborted) setStatus("error"); });
  return () => ctrl.abort();
}, [contentType]);

if (status === "error") return <ErrorBanner />;
```

Also: `aria-pressed` on the tab buttons, `key={m.id}` instead of the array index, and one controller per view (`useMemo`) instead of one per render. The detail view needs the same status pattern, plus a not-found state.

## 6. Production readiness

We built both bundles (`npm run build:client`, `npm run build:server`) and ran the compiled server on a spare port. The first four rows were observed directly.

| # | Gap | Evidence |
| - | --- | -------- |
| P1 | No production start script | `NODE_ENV=production npm start` fails: `per-env` looks for `start:production`, which doesn't exist |
| P2 | Built server shows "Hello" instead of the app | `express.static(path.join(__dirname, "../build"))` resolves to `build-server/build`, which doesn't exist |
| P3 | Deep links return 404 | `GET /movie/157336` on the built server: 404 (no SPA fallback) |
| P4 | Client bundle calls `undefined/api/media` | `VITE_SERVER` is only set in `.env.development`, so it is undefined in production builds |
| P5 | Server crashes without devDependencies | `server/index.ts` imports `./mocks/node` (MSW, a devDependency) unconditionally |
| P6 | Dev-only Docker on end-of-life Node 18.12; no tests or CI | Only `Dockerfile.dev`; the `husky.hooks` block in `package.json` is husky v4 format, which husky 8 ignores |

Also: `app.listen()` runs before the routes are registered, and an unset `API_PORT` makes Express pick a random port.

### Server (proposed)

```ts
if (process.env.VITE_MOCK_RESULTS === "true") {
  require("./mocks/node").server.listen();
}
// compiled to build-server/server/index.js
const BUILD = path.join(__dirname, "../../build");

app.use(helmet());
app.use("/api/media", new MediaRouter().getRouter());
app.get("/healthz", (_req, res) => res.send("ok"));
app.use(express.static(BUILD));
app.get("*", (_req, res) => res.sendFile(path.join(BUILD, "index.html")));
app.listen(Number(process.env.API_PORT ?? 9091));
```

Client: `baseURL: \`${import.meta.env.VITE_SERVER ?? ""}/api/media\``, so production calls its own origin and dev keeps using the Vite proxy.

### Container (proposed)

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build:client && npm run build:server

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev
COPY --from=build /app/build ./build
COPY --from=build /app/build-server ./build-server
USER node
EXPOSE 9091
CMD ["node", "build-server/server/index.js"]
```

Multi-stage, Node 22 LTS, reproducible `npm ci`, non-root user, secrets passed at runtime. It depends on the server changes above. Add `"start:production": "node build-server/server/index.js"` so `npm start` works.

### Delivery and operations

- **CI:** lint and format → typecheck (client and server) → API tests (reuse the MSW fixtures) and UI tests → audit gate on high/critical → build an image tagged by commit → deploy behind `/healthz`.
- **Logging:** structured JSON with secret redaction.
- **Monitoring:** latency and error rate per route, and upstream TMDB failures.
- **Caching:** trending lists change at most daily; cache them for a few minutes to cut TMDB calls and rate-limit risk.

## 7. Roadmap

| When | Items |
| ---- | ----- |
| **Now** (this week) | Rotate the TMDB token · allow-list `mediaType` and `id` · redact upstream errors in logs · `npm audit fix` |
| **Next** (this sprint) | Production server, Dockerfile and start script · loading, error and empty states · router links and date/poster fallbacks · filter the detail route |
| **Later** | CI pipeline with an audit gate · helmet, rate limits, upstream timeouts · cache trending responses · API and UI test suites |

## 8. Verification

| Check | Result |
| ----- | ------ |
| `tsc` client / server | Both clean |
| `GET /api/media/trending` | 16 items |
| Every mock detail endpoint (movie + tv) | All return 200 after fix #5 |
| UI: All / Movies / TV Shows | 16 / 18 / 13 items |
| UI: click poster | Navigates to `/movie/1202479`, shows "Opus" |
| UI: `/movie/157336`, `/tv/1399` | "Interstellar", "Game of Thrones" |
| Fix snippets marked "tested" | 19 assertions pass (Node `assert`, as standalone functions) |
| Hostile requests and production build | Traversal, log leak and P1–P4 reproduced |

Testing note: Chrome's `--virtual-time-budget` flag produced a blank page because of async service-worker startup. That was a testing artifact, not an app bug. Real-time puppeteer runs showed the correct output.

## 9. Limits

- **Fixes not yet merged.** Only the 8 setup fixes are in the repo. Security, UI and production fixes are either tested in isolation or proposed, and are labelled that way above.
- **Mock data only.** TMDB was unreachable, so everything shown comes from fixtures. Live API behaviour is untested.
- **Docker not run.** The dev compose setup was fixed on paper (items 2 and 3), and the proposed production image has not been built.
- **Node version.** `.nvmrc` pins Node 18.12, but everything ran on Node 26 without problems.

## 10. How to run

```bash
npm install
cp etc/dev.env .env.development        # mock mode on by default
set -a; . ./.env.development; set +a   # server reads process env
npm run dev:server                     # terminal 1, port 9091
npm run dev:client                     # terminal 2, port 3031
# or: npm run start:development        # Docker
```

To use the real TMDB API, set `VITE_MOCK_RESULTS=false` in `.env.development`. This needs network access to `api.themoviedb.org`.
