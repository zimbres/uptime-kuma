# Monitor dependency: agent implementation guide

## 1. Purpose and baseline

Allow a monitor to depend on one other monitor. Before each scheduled check, evaluate that dependency. If blocked, record an UNKNOWN heartbeat instead of executing the monitor-type check. Persist the derived unknown flag and display it in the frontend.

This guide was checked against Marcio's commits and branch `2.5.X` at `0db43e4c`, fork version `2.5.6-4`. The dependency feature, clear button, and Prometheus fix already exist there. Use this guide to verify or improve this branch, or port the changes to another release. Do not duplicate existing code or migrations.

Sections 3–5 describe committed behavior. Section 6 identifies proposed corrections separately. The monitors API in section 7 exists on a separate branch and is not part of reviewed HEAD.

Read repository `AGENTS.md` and `CLAUDE.md` first. Follow existing style and JSDoc rules, add translations only to `src/lang/en.json`, and do not commit runtime data or build output.

## 2. Commit map and scope

Inspect exact patches with `git show <hash> -- <path>`. Port relevant hunks rather than blindly cherry-picking commits containing packaging changes.

| Commit | Change | Scope |
| --- | --- | --- |
| `1a179aff` | Initial feature document, root Dockerfile and Docker exclusions | Design and packaging |
| `d340af45` | Dependency migrations, backend gating, UNKNOWN, persistence, frontend | Core feature |
| `18edbd75` | Filter Prometheus labels against initialized schema | Related runtime fix and version bump |
| `b56e099b` | Clear dependency button and accessible label | Selector improvement and package version changes |
| `b393d361` | Release-triggered fork container publication | Packaging |
| `d93f3826` | Container latest tag, fork README and version | Packaging |
| `3baf5534` | Workflow action version updates | Packaging |
| `0db43e4c` | Repository instruction update and upstream policy-file removal | Housekeeping |
| `0143e388` | Authenticated GET /api/monitors | Separate `monitors-api` branch |

Version bumps, README replacements, policy-file deletions, and publication settings are not required to port dependency functionality.

## 3. Committed behavior contract

### Data model

| Field | Representation | Meaning |
| --- | --- | --- |
| `monitor.dependency` | Nullable integer; JSON `dependency` | Referenced monitor ID; null means none |
| `monitor.is_unknown` | Non-null database boolean, default false | Derived from latest processed heartbeat |
| JSON `isUnknown` | Boolean | CamelCase serialization of the derived flag |
| Heartbeat status | Integer | DOWN=0, UP=1, PENDING=2, MAINTENANCE=3, UNKNOWN=4 |

Dependency is separate from the group hierarchy (`parent`). Each monitor has at most one dependency; multiple monitors may reference the same dependency. Unknown state is runtime state, not a user setting. A paused dependent does not run its heartbeat loop and may retain its last derived flag.

### Dependency decision table

`Monitor.isDependencySatisfied(monitorID)` applies these conditions in order:

| Condition | Result |
| --- | --- |
| Monitor missing, or dependency not configured | Satisfied |
| Referenced dependency missing | Satisfied |
| Dependency `active !== 1` | Blocked |
| Active dependency absent from `server.monitorList` | Satisfied, even with an old non-UP heartbeat |
| Active running dependency has no heartbeat | Satisfied |
| Active running dependency's latest heartbeat is UP | Satisfied |
| Active running dependency's latest heartbeat is any other status | Blocked |

Latest heartbeat is queried with `monitor_id = ? ORDER BY time DESC`. The helper does not recursively traverse dependencies or directly check their maintenance schedules. Maintenance blocks after the dependency records a non-UP heartbeat. Startup without history currently permits checks.

Groups are valid dependencies and **do generate heartbeats**, through `server/monitor-types/group.js`. Their recorded status participates in the same table. An empty group records PENDING and blocks once that heartbeat exists. The earlier document's claim that groups are always satisfied unless paused was incorrect.

### Heartbeat lifecycle

1. Evaluate dependency before the dependent's own maintenance handling and monitor-type dispatch in `Monitor.start()`.
2. When blocked, set `bean.status = UNKNOWN` and `bean.msg = "Dependency is down or paused"`. Skip the monitor-type check. UNKNOWN takes precedence when own maintenance also applies.
3. Continue shared processing: importance evaluation, uptime calculation, socket emission, persistence, metrics, and scheduling.
4. After `R.store(bean)`, derive `this.is_unknown` from `bean.status === UNKNOWN`. When the current comparison detects a change, update the column with `UPDATE monitor SET is_unknown = ? WHERE id = ?`.
5. Fetch JSON through `server.getMonitorJSONList(this.user_id, this.id)` and emit `updateMonitorIntoList` through `server.io.to(this.user_id).emit(...)`.
6. Reevaluate on the dependent's next scheduled heartbeat. Dependency changes do not immediately trigger all dependents.

Skipping the monitor-type check does not skip every shared operation. For example, domain expiry handling excludes MAINTENANCE but currently does not exclude UNKNOWN.

### Status consumers and notifications

| Consumer | UNKNOWN behavior |
| --- | --- |
| `UptimeCalculator.flatStatus()` | Map to DOWN; unknown time reduces uptime |
| Socket mixin `statusList()` | Translated Unknown with secondary color |
| Socket mixin `stats()` | Increment unknown count for active UNKNOWN monitors |
| `Uptime.vue` | Gray/secondary badge |
| `HeartbeatBar.vue` | `colors.empty`; aria label `Unknown at <formatted time>` |
| Prometheus monitor status | Raw status value 4 |

UNKNOWN is a stored heartbeat even though the bar uses the empty color. It differs from missing heartbeat data.

The feature commit did **not** add UNKNOWN transitions to `Monitor.isImportantBeat()` or `Monitor.isImportantForNotification()`. First beats qualify through existing rules, but subsequent transitions into or out of UNKNOWN are not explicitly recognized. Do not promise notifications on every UNKNOWN transition. Delivery and provider formatting still follow the existing notification path.

## 4. Ordered implementation plan

### Step 1: Audit the target release

Locate monitor write handlers, heartbeat processing, serialization, groups, status consumers, migrations, and tests. Paths may move between releases. Check whether UNKNOWN already exists or has other semantics; preserve existing status numbers. Inspect section 2's patches and record intentional departures from section 3.

### Step 2: Schema and shared status

| Migration under `db/knex_migrations/` | Up | Down |
| --- | --- | --- |
| `2026-10-04-0000-add-monitor-dependency.js` | Add unsigned nullable integer dependency, default null, referencing monitor.id; ON DELETE SET NULL and ON UPDATE CASCADE | Drop dependency |
| `2026-10-04-0001-add-monitor-is-unknown.js` | Add non-null boolean is_unknown, default false | Drop is_unknown |

Preserve deployed migration filenames and contents; introduce new migrations for further schema changes. Verify SQLite and MariaDB/MySQL behavior. Dependency deletion clears the database reference; subsequent heartbeats should resume. Verify client refresh and live configuration too.

Add `export const UNKNOWN = 4;` in `src/util.ts`. Backend imports resolve compiled `src/util.js`, while frontend imports use util.ts. Regenerate util.js through `npm run tsc`, inspect emitted diffs, and confirm the backend export is 4. The repository documents existing TypeScript diagnostics: report them separately and verify emission. Do not hand-edit generated util.js or assume frontend build regenerates it.

### Step 3: Backend gating and persistence

In `server/model/monitor.js`:

- Import UNKNOWN and add `isDependencySatisfied()` using section 3's table for an exact port.
- Gate before own maintenance and monitor-type checks.
- Serialize dependency and `isUnknown: Boolean(this.is_unknown)` in `toJSON()`.
- Persist the derived flag after heartbeat storage and emit updated JSON to the owning user's room.
- Preserve heartbeat scheduling, uptime updates, and metrics while blocked.

In `server/server.js`:

- Creation currently imports dependency through `bean.import(monitor)` in the add handler.
- Editing explicitly assigns `bean.dependency = monitor.dependency` before persistence.
- Committed edit validation rejects self and IDs returned by `Monitor.getAllChildrenIDs(monitor.id)`, with messages `A monitor cannot depend on itself` and `A monitor cannot depend on its descendant`.
- Those children are group descendants. This does not validate arbitrary dependency cycles; see section 6.

In `server/uptime-calculator.js`, import UNKNOWN and map it to DOWN in `flatStatus()`. Preserve maintenance's existing mapping to UP.

### Step 4: Selector, clear button, translations

In `src/pages/EditMonitor.vue`:

- Add `dependency: null` to monitor defaults.
- Reuse ActionSelect with ID monitorDependencySelector, binding monitor.dependency and dependencyMonitorOptionsList.
- Include all monitors, including groups, excluding self and group descendants. Sort active first, weight descending, then pathName alphabetically using localeCompare.
- Offer translated None with null value, followed by monitor pathName labels and numeric IDs. If no candidates exist, show noMonitorMsg and disable selection.
- Include the clear action from `b56e099b`: times icon, action setting monitor.dependency to null, and translated Clear dependency aria label. Clearing modifies the form; saving persists it.

`src/components/ActionSelect.vue` already supplies the required action props; the commit did not change that shared component.

Add these English keys if missing:

| Key | Value |
| --- | --- |
| noMonitorMsg | Not Available. Create a Monitor First. |
| Dependency Monitor | Dependency Monitor |
| If this monitor is down or paused, the current monitor will show as Unknown | Same text as key |
| A monitor cannot depend on itself | Same text as key |
| A monitor cannot depend on its descendant | Same text as key |
| Clear dependency | Clear dependency |

Reuse existing None and Unknown keys. The committed helper text does not enumerate PENDING, MAINTENANCE, or UNKNOWN dependency states; revise copy if implementing that clarification.

### Step 5: Frontend status and synchronization

In `src/mixins/socket.js`, import UNKNOWN, handle it in statusList and stats, and update reactive monitor.isUnknown on heartbeat receipt. Reuse the existing updateMonitorIntoList handler to replace entries with server JSON.

**Known serialization mismatch:** backend toJSON returns camelCase isUnknown, but assignMonitorUrlParser overwrites it using `Boolean(monitor.is_unknown)`. That snake_case flag is absent from the serialized contract, so list loads and monitor updates can reset the flag to false; heartbeat events can temporarily correct it. For a corrected implementation, consume camelCase isUnknown and compare heartbeat status with the imported UNKNOWN constant instead of literal 4.

Update `src/components/Uptime.vue` and `src/components/HeartbeatBar.vue` as described in section 3. Inspect additional status consumers in the target release, including public status pages and badges, rather than assuming these files cover all views.

### Step 6: Related Prometheus fix

In `server/prometheus.js`, metric definitions capture tag labels at initialization. Adding tags later previously passed undeclared labels to prom-client, causing `Added label ... is not included in initial labelset`.

The fix in `18edbd75` keeps commonLabels at module scope and assigns initialized tag/monitor labels to it. `filterLabels(labels)` keeps only registered keys. All metric update and removal calls use filtered labels. Window metrics add their separately declared window label after filtering.

This does not dynamically register new tags. Tags added after initialization are omitted until the schema is recreated, normally on restart. Verify both update and removal, registered tags, and all window metrics.

## 5. Acceptance checks for committed behavior

Use distinct names Dependency and Dependent to avoid confusing dependency with group parentage. Wait for the relevant heartbeat intervals.

| Scenario | Expected result |
| --- | --- |
| Create, save, reload and edit dependency | Selected ID persists and appears in JSON |
| Clear button, save and reload | Null dependency; normal checks resume |
| No dependency or dependency UP | Normal monitor processing |
| Dependency paused | UNKNOWN without monitor-type check |
| Running dependency DOWN, PENDING, MAINTENANCE or UNKNOWN | UNKNOWN without monitor-type check |
| No dependency heartbeat or missing running instance | Check proceeds under current fallback |
| Dependency recovers | Resume on dependent's next heartbeat |
| Dependency blocked and dependent under maintenance | UNKNOWN takes precedence |
| Delete dependency | Foreign key becomes null; subsequent checks resume |
| Edit dependency to self or group descendant, including direct socket request | Backend rejects edit |
| Group dependency UP/non-UP; empty group | Heartbeat decision table applies; empty group's PENDING blocks |
| UNKNOWN uptime interval | Counted as DOWN |
| Dashboard and bar | Gray Unknown, unknown statistics, empty-color bar and correct aria label |
| Prometheus UNKNOWN heartbeat | Status metric exposes 4 |
| Add tag after metric initialization, update/delete monitor | No undeclared-label errors; existing labels/windows still work |

Characterize first-beat notifications separately from subsequent UNKNOWN transitions. The old claim that every transition triggers a notification does not match source.

## 6. Known gaps and proposed follow-up changes

These are review findings and proposed improvements, not already implemented requirements. Select them deliberately, then update the contract and tests.

| Gap | Proposed change | Acceptance coverage |
| --- | --- | --- |
| Socket parser overwrites serialized unknown flag | Consume isUnknown; use UNKNOWN constant | Initial load, reconnect, monitor updates, recovery and two clients stay synchronized |
| Group-descendant guard misses dependency cycles | Validate dependency edges with a visited set on add and edit; retain group constraints | Reject self, two-node and longer cycles; allow acyclic chains |
| No explicit dependency ownership/existence validation on both write paths | Normalize null/ID, reject malformed IDs, require authenticated user's referenced monitor | Direct requests cannot reference missing or other users' monitors; define omitted-field semantics |
| UNKNOWN importance/notification policy absent | Decide importance and notification behavior, update both helpers and provider expectations | First beat, repeated UNKNOWN and all transitions to/from UNKNOWN |
| No-history and missing-running-instance fallbacks permit checks | Decide whether startup/unavailable runtime should block | Startup, restart and no-history behavior matches chosen policy |
| Dependency maintenance depends on recorded heartbeat | Query maintenance directly if immediate blocking is desired | Scheduled/inherited maintenance timing |
| Group aggregation ignores child UNKNOWN | Define and implement aggregation if required | Mixed UP/UNKNOWN, all UNKNOWN, paused children and empty groups |
| Numeric database boolean compared strictly to boolean | Normalize current is_unknown with Boolean before comparison | Unchanged status does not repeatedly write/emit after load |
| Shared work still runs while UNKNOWN | Define permitted domain expiry and other side effects | Blocked monitor performs only intended shared operations |

Include group aggregation interactions when evaluating cycle safety. The current dependency helper does not recurse; a dependency cycle is a logical gating problem, and the existing endless-loop comment does not establish complete validation.

## 7. Related fork changes outside core functionality

### Container and release workflow

Root Dockerfile uses node:24-bookworm-slim, installs runtime utilities, runs npm ci with legacy peer dependencies, builds frontend, prunes dev dependencies, exposes 3001, starts through dumb-init, and configures extra/healthcheck.js. Docker exclusions omit local/private data and development files.

`.github/workflows/fork.yml` runs on published releases, building/pushing amd64 and arm64 images to ghcr.io/zimbres/uptime-kuma with release-tag and latest tags. Action upgrades are recorded in `3baf5534`. These are repository settings, not dependency-port requirements. Adapt registry/version metadata only when packaging is in scope; do not publish as implementation verification.

### Separate monitors API branch

`0143e388` on monitors-api adds GET /api/monitors in `server/routers/api-router.js`; it is absent from reviewed 2.5.X HEAD. Inspect its patch before porting.

The patch applies apiAuth, parses a Basic authorization username, resolves a user, selects monitors ordered by weight descending and name, prepares preload data, and calls `monitor.toJSON(preloadData, true)`. It returns `{ Success: true, Data: monitors }`; errors return HTTP 500 and `{ Success: false, Data: [], Error: error.message }`. Serialization can include dependency and isUnknown.

The patch defaults to user ID 1 if identity resolution fails or authorization is absent. Existing apiAuth supports account credentials, API keys, and disabled authentication; parsing a username does not establish ownership for all modes. Before adopting the endpoint, derive ownership from validated authentication identity and define disabled-auth behavior. Review sensitive configuration exposure through includeSensitiveData=true. Verify account/API-key authentication, invalid credentials, user isolation and response shape. The endpoint is not needed for Socket.IO dependency functionality.

## 8. Validation and implementation handoff

For implementation, use npm ci if dependencies are needed, regenerate utility output if util.ts changes, then run:

```sh
node ./extra/check-knex-filenames.mjs
npm run lint
npm run lint:prod
npm run build
npm run test-backend
npm test
```

Build before tests. Playwright browsers require `npx playwright install` at first setup. Distinguish known TypeScript diagnostics from new failures and inspect generated output. Do not fix unrelated dependency vulnerabilities in this feature.

Add focused backend tests for gating, serialization, persistence and selected validation/transition fixes. Use E2E or manual checks for selection, clearing, display and reconnect/two-client synchronization. Test fresh/existing database migrations and rollback on disposable SQLite and MariaDB/MySQL data.

The implementing agent's handoff should report:

- Core and related commits ported or already present.
- Section 6 proposals implemented and explicit behavior decisions.
- Changed files, migration compatibility and generated utility changes.
- Test/manual verification results and remaining limitations.

For documentation-only edits, inspect source references and run git diff --check; application builds and tests do not validate prose.
