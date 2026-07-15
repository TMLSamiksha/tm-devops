# OrderFlow-Lite — Test Suite

This directory contains the Jest test suite for OrderFlow-Lite. All tests are
unit/integration-style tests against the Express app — none of them touch a
real MySQL database; `src/db` is mocked in every file via `jest.mock("../src/db")`.

## Test files and cases

### `health.test.js` — health & readiness endpoints

| Suite | Case | What it verifies |
|---|---|---|
| `GET /health` | always returns 200, regardless of DB state | `/health` is a pure liveness check — returns `{ status: "ok" }` with no DB dependency |
| `GET /ready` | returns 200 when the DB check succeeds | `/ready` runs `SELECT 1` against the pool; on success responds `{ status: "ready" }` |
| `GET /ready` | returns 503 when the DB check throws | if the DB query rejects, `/ready` responds `503 { status: "not ready" }` |

### `orders.test.js` — `/orders` API

| Suite | Case | What it verifies |
|---|---|---|
| auth middleware on `/orders` routes | rejects requests with no `x-api-key` header | `401` when the header is missing |
| auth middleware on `/orders` routes | rejects requests with an incorrect `x-api-key` header | `401` when the key doesn't match `API_KEY` |
| `POST /orders` | creates an order and returns 201 | happy path: opens a transaction, inserts the order + an `order_events` row, commits, releases the connection, and returns the created order |
| `POST /orders` | rejects a request missing a required field with 400 | validation runs before any DB connection is acquired (`pool.getConnection` is never called) |
| `GET /orders` | returns the list of orders | lists all orders from `pool.query` |
| `GET /orders/:id` | returns 404 when the order does not exist | empty result set from the DB maps to `404` |
| `GET /orders/:id` | returns the order along with its event history | joins the order row with its `order_events` rows into a single `events` array |

### `worker.test.js` — background order processor (`src/worker/processOrders.js`)

| Suite | Case | What it verifies |
|---|---|---|
| `processOrder` | marks the order completed and writes matching `order_events` on success | when the simulated outcome succeeds (`Math.random()` mocked below the success-rate threshold), the worker writes a `processing_started` event, updates the order status to `completed`, then writes a final `completed` event, in that order |
| `processOrder` | marks the order failed and writes matching `order_events` on failure | when the simulated outcome fails (`Math.random()` mocked above the threshold), the order status is updated to `failed` and a matching `failed` event is written |

The worker's random outcome and its 1–2s simulated processing delay are both
injected/mocked (`jest.spyOn(Math, "random")`, `delayFn: instantDelay`) so the
tests run deterministically and instantly.

**12 tests total across 3 suites.**

---

## How to run the tests

### 1. Prerequisites

- Node.js >= 20 (see `engines` in `package.json`)
- Dependencies installed:

  ```bash
  cd orderflow-lite
  npm install
  ```

No database, `.env` file, or running services are required — the test suite
mocks `src/db` in every file, so `DB_HOST`/`DB_USER`/etc. are never read.
`orders.test.js` sets its own `API_KEY=test-api-key` at the top of the file.

### 2. Run the full suite

```bash
npm test
```

This runs `jest` with the config embedded in `package.json` (`testEnvironment: node`,
console + `jest-junit` reporters). Expected output:

```
PASS tests/worker.test.js
PASS tests/health.test.js
PASS tests/orders.test.js

Test Suites: 3 passed, 3 total
Tests:       12 passed, 12 total
Snapshots:   0 total
Time:        0.635 s
```

You will also see `console.log`/`console.error` lines from the worker and the
`/ready` failure-path test — these are expected (the tests intentionally
exercise the failure branch) and don't indicate a failing test.

### 3. Run a single file or test

```bash
# One file
npx jest tests/orders.test.js

# One test by name (regex match)
npx jest -t "returns 404 when the order does not exist"
```

### 4. CI mode (used by Jenkins)

```bash
npm run test:ci
```

This runs `jest --ci --reporters=default --reporters=jest-junit`, which
additionally writes a `junit.xml` report to the project root — this is the
command the Jenkinsfile's `Install & Unit Test` stage invokes for reporting.

> **Note:** `jest-junit` is pinned to `16.0.0` in `package.json` as a
> deliberately seeded vulnerable devDependency for the GitLeaks/Trivy modules
> of this course (see `TRAINING_SEEDS.md`). It is not present in the
> production Docker image and does not affect these test commands.

### 5. Watch mode (optional, local dev)

```bash
npx jest --watch
```

Re-runs affected tests on file save. Not used in CI.

## Troubleshooting

- **`Cannot find module 'supertest'` or similar** — dependencies aren't
  installed; run `npm install` from `orderflow-lite/`.
- **Tests hang or don't exit** — check you didn't accidentally remove a
  `jest.mock("../src/db", ...)` call from a test file; without it, code paths
  that call `pool.query`/`pool.getConnection` will try to reach a real,
  unavailable MySQL instance.
- **`junit.xml` not generated** — make sure you ran `npm run test:ci`, not
  `npm test`; the plain `test` script still uses the reporters configured in
  `package.json`'s `jest.reporters`, but CI invokes the dedicated script for
  a clean exit code and consistent flags.
