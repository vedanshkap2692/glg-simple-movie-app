# GLG Movie App: Local Setup Report

**Task:** Get the React + Node + TypeScript movie app running in a local dev environment, and be able to explain what was broken, how it was found, and how it was fixed.

**Outcome:** The app runs. The listing view and the detail view both load, the All / Movies / TV Shows tabs work, and clicking a poster opens its detail page. The checks below were done in a real browser (headless Chrome driven by puppeteer).

| Service  | URL                   | Stack                                  |
| -------- | --------------------- | -------------------------------------- |
| Frontend | http://localhost:3031 | React 18, MobX, MUI, Vite 5            |
| API      | http://localhost:9091 | Express, TypeScript (ts-node/nodemon)  |

## 1. Architecture in brief

- **Browser** loads the React app from Vite. It calls `VITE_SERVER/api/media/...` with axios.
- **Express server** exposes `/api/media/trending`, `/trending/movies`, `/trending/tv` and `/:mediaType/:id`. It calls the TMDB API through a `MovieDB` service and filters out adult content, a couple of banned name terms, and non-English titles.
- **Mocking (MSW):** when `VITE_MOCK_RESULTS=true`, MSW intercepts TMDB calls on the server (`server/mocks`) and poster-image requests in the browser (`src/mocks`). Fixture JSON lives in `server/mocks/data`, posters in `public/images`.
- **Docker:** `docker-compose.yml` runs the same image twice (frontend and backend), both reading `.env.development`.

## 2. Approach

1. **Read before running.** I went through the README, `package.json`, Docker files, the env template, and all server and client source. That alone surfaced several likely bugs.
2. **Check the environment.** TMDB's API was unreachable from this network, but its image CDN was. The README describes this ISP-blocking case and prescribes mock mode, so I used it.
3. **Run natively instead of Docker.** The Docker daemon wasn't confirmed running, and a native run gives faster feedback. `npm install`, then `dev:server` and `dev:client` with the env vars loaded.
4. **Verify at each layer.** I typechecked client and server separately, curled every API endpoint (including every mock detail file), then drove a real browser.
5. **Fix, then re-verify.** Each fix was re-tested and the typechecks re-run.

## 3. Issues found and fixes

| # | Issue | Evidence | Fix |
| - | ----- | -------- | --- |
| 1 | TMDB API unreachable on this network | `curl` to `api.themoviedb.org` returned no response; the image CDN responded | Enabled `VITE_MOCK_RESULTS=true` (MSW mocks) |
| 2 | No `.env.development`, and `etc/dev.env` used stale variable names (`REACT_APP_SERVER`, `MOVIE_API_V4`) that the code never reads | Code reads `VITE_SERVER`, `MOVIE_DB_API_BASE_URL`, `MOVIE_DB_API_KEY`, `API_PORT` | Created `.env.development`, updated `etc/dev.env` |
| 3 | `bin/prepare-docker.sh` never created the env file, and its backticks in an `echo` ran as a command substitution | Read the script | Quoted correctly; the script seeds `.env.development` if missing |
| 4 | `MediaDetailController.getMedia` didn't `await` the axios call, then read `response.data` on a Promise | Code review | Added `await` |
| 5 | `server/mocks/data/movie/157336.json` (Interstellar) was a 0-byte file | Looping over every mock detail endpoint: only this one returned 500 (`Unexpected end of JSON input`) | Rebuilt the fixture from the trending entry plus a few detail fields. The genres, tagline and runtime are my additions, not TMDB data |
| 6 | CORS origin hardcoded to `localhost:3000`, but the client runs on 3031 and calls the API directly | Code review | Origin now derives from `PORT`, defaulting to 3031 |
| 7 | `index.html` included `mockServiceWorker.js` as a normal `<script type="module">` | Code review. MSW registers its own service worker from `index.tsx` | Removed the tag |
| 8 | Client typecheck failed with 9 errors: no Vite env types, and TypeScript 4.9 can't compile the TC39 `accessor` decorators the MobX stores use | `tsc -p tsconfig.json` output | Added `src/vite-env.d.ts`, upgraded to TypeScript 5.x, client target `es2020`, removed `experimentalDecorators` from the client tsconfig only (the server still needs it for `bind-decorator`) |

## 4. Verification

| Check | Result |
| ----- | ------ |
| `tsc` client / server | Both clean |
| `GET /api/media/trending` | 16 items |
| Every mock detail endpoint (movie + tv) | All return 200 after fix #5 |
| UI: All / Movies / TV Shows | 16 / 18 / 13 items |
| UI: click poster | Navigates to `/movie/1202479`, shows "Opus" |
| UI: `/movie/157336`, `/tv/1399` | "Interstellar", "Game of Thrones" |

One testing note: Chrome's `--virtual-time-budget` flag produced a blank page because of async service-worker startup. That was a testing artifact, not an app bug. Real-time puppeteer runs showed the correct output.

## 5. Risks and follow-ups

- **Detail page is minimal.** It shows poster, title, date and overview only. The fixtures contain much more (genres, runtime, tagline) that isn't displayed.
- **Browser-side mock only covers poster images.** The browser always talks to the real Express server. Only the server's TMDB calls and the image requests are mocked.
- **`react-scripts` is unused** (the app builds with Vite) and accounts for most of the 76 `npm audit` findings. It could be removed.
- **Dependency drift.** `.nvmrc` pins Node 18.12, but everything ran on Node 26 without problems.
- **A TMDB bearer token is committed** in `etc/dev.env`. It was already public in the original repo, but it should be treated as exposed.
- **Docker path not run.** The compose setup was fixed on paper (items 2 and 3) but I did not run `npm run start:development`.
- **Minor code smells.** A new controller instance is created on every render in both views, and the `MediaComponent` link uses a relative path (`movie/123`), which only works from `/`.

## 6. How to run

```bash
npm install
cp etc/dev.env .env.development        # mock mode on by default
set -a; . ./.env.development; set +a   # server reads process env
npm run dev:server                     # terminal 1, port 9091
npm run dev:client                     # terminal 2, port 3031
# or: npm run start:development        # Docker
```

To use the real TMDB API, set `VITE_MOCK_RESULTS=false` in `.env.development`. This needs network access to `api.themoviedb.org`.
