# Monitor Dependency Feature Implementation Documentation

## Overview
This feature allows users to set a "Dependency Monitor" for each monitor. When the dependency monitor is paused, down, or under maintenance, the dependent monitor will show as "Unknown" status instead of running its check.

## Database Changes

### Migration: `2026-10-04-0000-add-monitor-dependency.js`
```javascript
exports.up = function (knex) {
    return knex.schema.alterTable("monitor", function (table) {
        table.integer("dependency").unsigned().nullable().defaultTo(null)
            .references("id").inTable("monitor")
            .onDelete("SET NULL").onUpdate("CASCADE");
    });
};

exports.down = function (knex) {
    return knex.schema.alterTable("monitor", function (table) {
        table.dropColumn("dependency");
    });
};
```

**Foreign Key Behavior:**
- `ON DELETE SET NULL`: If the dependency monitor is deleted, the `dependency` field is automatically set to `NULL`
- `ON UPDATE CASCADE`: If the dependency monitor's ID changes (unlikely), the reference is updated automatically

## Backend Changes

### 1. `src/util.ts` - Added UNKNOWN status constant
```typescript
export const DOWN = 0;
export const UP = 1;
export const PENDING = 2;
export const MAINTENANCE = 3;
export const UNKNOWN = 4;  // Added
```

### 2. `server/model/monitor.js` - Core logic

#### Import UNKNOWN constant
```javascript
const {
    // ... existing imports
    UNKNOWN,  // Added
} = require("../../src/util");
```

#### Added `isDependencySatisfied()` static method
```javascript
/**
 * Checks if the monitor's dependency is satisfied
 * @param {number} monitorID ID of the monitor to check
 * @returns {Promise<boolean>} Is the dependency satisfied (UP)?
 */
static async isDependencySatisfied(monitorID) {
    const monitor = await R.findOne("monitor", "id = ?", [monitorID]);

    if (!monitor || !monitor.dependency) {
        return true;
    }

    const dependency = await R.findOne("monitor", "id = ?", [monitor.dependency]);

    if (!dependency) {
        return true;
    }

    // Dependency must be active (not paused)
    if (dependency.active !== 1) {
        return false;
    }

    // Check if dependency monitor is running and UP
    const server = require("../uptime-kuma-server").UptimeKumaServer.getInstance();
    if (server.monitorList[dependency.id]) {
        const lastHeartbeat = await R.findOne("heartbeat", "monitor_id = ? ORDER BY time DESC", [dependency.id]);
        if (lastHeartbeat && lastHeartbeat.status !== 1) { // Not UP (includes DOWN, PENDING, MAINTENANCE, UNKNOWN)
            return false;
        }
    }

    return true;
}
```

#### Modified `start()` method to check dependency first
```javascript
try {
    // Check if dependency is satisfied
    if (!(await Monitor.isDependencySatisfied(this.id))) {
        bean.msg = "Dependency is down or paused";
        bean.status = UNKNOWN;
    } else if (await Monitor.isUnderMaintenance(this.id)) {
        bean.msg = "Monitor under maintenance";
        bean.status = MAINTENANCE;
    } else if (this.type === "http" || this.type === "keyword" || this.type === "json-query") {
        // ... rest of the logic
    }
}
```

#### Added `dependency` to JSON output in `toJSON()` method
```javascript
let data = {
    // ... existing fields
    dependency: this.dependency,  // Added
    // ... rest of fields
};
```

### 3. `server/uptime-calculator.js` - Handle UNKNOWN in uptime calculation
```javascript
const { UP, MAINTENANCE, DOWN, PENDING, UNKNOWN } = require("../src/util");  // Added UNKNOWN

flatStatus(status) {
    switch (status) {
        case UP:
        case MAINTENANCE:
            return UP;
        case DOWN:
        case PENDING:
        case UNKNOWN:  // Added - treat UNKNOWN as DOWN for uptime calculation
            return DOWN;
    }
    throw new Error("Invalid status");
}
```

## Frontend Changes

### 1. `src/mixins/socket.js` - Status handling
```javascript
import { DOWN, MAINTENANCE, PENDING, UP, UNKNOWN } from "../util.ts";  // Added UNKNOWN

statusList() {
    // ... existing code
    } else if (lastHeartBeat.status === UNKNOWN) {  // Added
        result[monitorID] = {
            text: this.$t("Unknown"),
            color: "secondary",
        };
    } else {
        result[monitorID] = unknown;
    }
}
```

### 2. `src/components/Uptime.vue` - Badge color
```javascript
import { DOWN, MAINTENANCE, PENDING, UP, UNKNOWN } from "../util.ts";  // Added UNKNOWN

color() {
    // ... existing cases
    if (this.lastHeartBeat.status === UNKNOWN) {  // Added
        return "secondary";
    }
    return "secondary";
}
```

### 3. `src/components/HeartbeatBar.vue` - Visual representation
```javascript
import { DOWN, UP, PENDING, MAINTENANCE, UNKNOWN } from "../util.ts";  // Added UNKNOWN

getBeatColor(beat, colors) {
    // ... existing cases
    } else if (status === UNKNOWN) {  // Added
        return colors.empty;  // Shows as empty/no data
    } else {
        return colors.up;
    }
}

getBeatAriaLabel(beat) {
    switch (beat?.status) {
        // ... existing cases
        case UNKNOWN:  // Added
            return `Unknown at ${this.$root.datetime(beat.time)}`;
        default:
            return "No data";
    }
}
```

### 5. `server/server.js` - Edit monitor handler fix
The `editMonitor` socket handler was missing the `dependency` field. Added:

```javascript
// In editMonitor handler, around line 507:
bean.parent = monitor.parent;
bean.dependency = monitor.dependency;  // Added
bean.type = monitor.type;
```

Also added validation to prevent circular dependencies:
```javascript
// Check if Dependency is Descendant or self (would cause endless loop)
if (monitor.dependency !== null) {
    if (monitor.dependency === monitor.id) {
        throw new Error("A monitor cannot depend on itself");
    }
    const childIDs = await Monitor.getAllChildrenIDs(monitor.id);
    if (childIDs.includes(monitor.dependency)) {
        throw new Error("A monitor cannot depend on its descendant");
    }
}
```

### 6. `src/pages/EditMonitor.vue` - UI for selecting dependency

**Note on Group Monitors as Dependencies:**
The dependency selector includes all monitors (including group monitors) except the monitor itself and its descendants. However, group monitors don't have heartbeats, so using a group monitor as a dependency will always return `true` from `isDependencySatisfied()` (unless the group is paused). This is because the dependency check looks for a heartbeat with status UP, and group monitors don't generate heartbeats.

#### Added to monitor defaults
```javascript
const monitorDefaults = {
    type: "http",
    name: "",
    parent: null,
    dependency: null,  // Added
    url: defaultValueList.http.url,
    // ... rest
};
```

#### Added Dependency Monitor selector in template
```html
<!-- Dependency Monitor -->
<div class="my-3">
    <label for="monitorDependencySelector" class="form-label">{{ $t("Dependency Monitor") }}</label>
    <ActionSelect
        id="monitorDependencySelector"
        v-model="monitor.dependency"
        :options="dependencyMonitorOptionsList"
        :disabled="sortedMonitorList.length === 0"
    />
    <div class="form-text">{{ $t("If this monitor is down or paused, the current monitor will show as Unknown") }}</div>
</div>
```

#### Added computed properties
```javascript
sortedMonitorList() {
    let result = Object.values(this.$root.monitorList);
    result = result.filter(
        (monitor) =>
            monitor.id !== this.monitor.id &&
            !this.monitor.childrenIDs?.includes(monitor.id)
    );
    result.sort((m1, m2) => {
        if (m1.active !== m2.active) {
            if (m1.active === 0) return 1;
            if (m2.active === 0) return -1;
        }
        if (m1.weight !== m2.weight) {
            if (m1.weight > m2.weight) return -1;
            if (m1.weight < m2.weight) return 1;
        }
        return m1.pathName.localeCompare(m2.pathName);
    });
    return result;
},

dependencyMonitorOptionsList() {
    let list = [];
    if (this.sortedMonitorList.length === 0) {
        list = [{ label: this.$t("noMonitorMsg"), value: null }];
    } else {
        list = [
            { label: this.$t("None"), value: null },
            ...this.sortedMonitorList.map((monitor) => ({
                label: monitor.pathName,
                value: monitor.id,
            })),
        ];
    }
    return list;
}
```

### 6. `src/lang/en.json` - Translations
```json
"noGroupMonitorMsg": "Not Available. Create a Group Monitor First.",
"noMonitorMsg": "Not Available. Create a Monitor First.",
"Dependency Monitor": "Dependency Monitor",
"If this monitor is down or paused, the current monitor will show as Unknown": "If this monitor is down or paused, the current monitor will show as Unknown",
"A monitor cannot depend on itself": "A monitor cannot depend on itself",
"A monitor cannot depend on its descendant": "A monitor cannot depend on its descendant",
```

## Component Updates Summary

| Component | Changes |
|-----------|---------|
| `src/util.ts` | Added UNKNOWN = 4 constant |
| `server/model/monitor.js` | Added isDependencySatisfied(), modified start(), added dependency to JSON, added isUnknown to toJSON(), update is_unknown on heartbeat |
| `server/uptime-calculator.js` | Added UNKNOWN import, updated flatStatus() |
| `src/mixins/socket.js` | Added UNKNOWN handling in statusList and stats, added isUnknown initialization and updateMonitorUnknownStatus() |
| `src/components/Uptime.vue` | Added UNKNOWN color handling |
| `src/components/HeartbeatBar.vue` | Added UNKNOWN color and aria-label |
| `src/pages/EditMonitor.vue` | Added dependency field, selector UI, computed properties |
| `server/server.js` | Added dependency to editMonitor handler, added circular dependency validation |
| `src/lang/en.json` | Added translations |

---

## is_unknown Field Feature

### Database Changes

#### Migration: `2026-10-04-0001-add-monitor-is-unknown.js`
```javascript
exports.up = function (knex) {
    return knex.schema.alterTable("monitor", function (table) {
        table.boolean("is_unknown").notNullable().defaultTo(false);
    });
};

exports.down = function (knex) {
    return knex.schema.alterTable("monitor", function (table) {
        table.dropColumn("is_unknown");
    });
};
```

### Backend Changes

#### `server/model/monitor.js`

**Added `isUnknown` to `toJSON()` output:**
```javascript
let data = {
    // ... existing fields
    maintenance: preloadData.maintenanceStatus.get(this.id),
    isUnknown: Boolean(this.is_unknown),  // Added
    // ... rest
};
```

**Update `is_unknown` after each heartbeat:**
```javascript
// Update monitor's is_unknown field based on heartbeat status
if (this.is_unknown !== (bean.status === UNKNOWN)) {
    this.is_unknown = bean.status === UNKNOWN;
    await R.exec("UPDATE monitor SET is_unknown = ? WHERE id = ?", [this.is_unknown ? 1 : 0, this.id]);
    // Notify frontend of monitor update
    const server = require("../uptime-kuma-server").UptimeKumaServer.getInstance();
    await server.sendUpdateMonitorIntoList(this.user_id, this.id);
}
```

### Frontend Changes

#### `src/mixins/socket.js`

**Initialize `isUnknown` from server data:**
The `assignMonitorUrlParser()` method initializes `monitor.isUnknown = Boolean(monitor.is_unknown)` from server data when the monitor list is received.

**Frontend notification via `updateMonitorIntoList`:**
When the backend updates `is_unknown` in the database, it calls `server.sendUpdateMonitorIntoList(user_id, monitor_id)` which emits the `updateMonitorIntoList` socket event. The frontend handler updates the monitor in the reactive `monitorList`:

```javascript
socket.on("updateMonitorIntoList", (data) => {
    this.assignMonitorUrlParser(data);
    Object.entries(data).forEach(([monitorID, updatedMonitor]) => {
        this.monitorList[monitorID] = updatedMonitor;
    });
});
```

This ensures the `isUnknown` property stays in sync across all connected clients.

**Update `isUnknown` on heartbeat events:**
```javascript
assignMonitorUrlParser(data) {
    Object.entries(data).forEach(([monitorID, monitor]) => {
        monitor.getUrl = () => {
            try {
                return new URL(monitor.url);
            } catch (_) {
                return null;
            }
        };

        // Initialize isUnknown from server data
        monitor.isUnknown = Boolean(monitor.is_unknown);
    });
    return data;
},
```

**Update `isUnknown` on heartbeat events:**
```javascript
/**
 * Update monitor's isUnknown status based on latest heartbeat
 * @param {number} monitorID Monitor ID
 * @param {number} status Heartbeat status
 */
updateMonitorUnknownStatus(monitorID, status) {
    if (this.monitorList[monitorID]) {
        this.monitorList[monitorID].isUnknown = status === 4; // UNKNOWN = 4
    }
},
```

**Called in heartbeat handler:**
```javascript
socket.on("heartbeat", (data) => {
    // ... existing code
    
    // Update monitor's isUnknown status
    this.updateMonitorUnknownStatus(data.monitorID, data.status);

    // Add to important list if it is important
    // Also toast
    if (data.important) {
        // ...
    }
});
```

### Usage

In Vue components, access the reactive `isUnknown` property:
```javascript
// In component:
monitor.isUnknown  // true/false - reactive, updates automatically on heartbeat

// In template:
<div v-if="monitor.isUnknown">Monitor is in Unknown state</div>
```

## How It Works

1. **User Configuration**: In Edit Monitor page, user selects a "Dependency Monitor" from the dropdown
2. **Dependency Check**: Before each check, `isDependencySatisfied()` is called:
   - Returns `true` if no dependency is set
   - Returns `false` if dependency monitor is inactive (paused)
   - Returns `false` if dependency monitor's last heartbeat is not UP (includes DOWN, PENDING, MAINTENANCE, UNKNOWN)
3. **Status Setting**: If dependency not satisfied:
   - Heartbeat status = UNKNOWN (4)
   - Message = "Dependency is down or paused"
   - No actual check is performed
   - Heartbeat is marked as **important** (triggers notifications for status change)
4. **Frontend Display**: UNKNOWN status shows as:
   - Badge: Gray "Unknown" pill
   - Heartbeat bar: Empty/no color
   - Status list: Gray "Unknown"
   - Uptime calculation: Treated as DOWN
5. **Database Sync**: After each heartbeat, `is_unknown` field is updated in the database and frontend is notified via `sendUpdateMonitorIntoList` socket event

## Testing Checklist

- [ ] Create two monitors: Parent and Child
- [ ] Set Child's dependency to Parent
- [ ] Verify Child shows "Unknown" when Parent is paused
- [ ] Verify Child shows "Unknown" when Parent is down
- [ ] Verify Child shows "Unknown" when Parent is under maintenance
- [ ] Verify Child runs normally when Parent is UP
- [ ] Verify Child runs normally when no dependency is set
- [ ] Verify uptime calculation treats UNKNOWN as DOWN
- [ ] Verify heartbeat bar shows empty for UNKNOWN
- [ ] Verify status badge shows gray "Unknown" for UNKNOWN
- [ ] Verify notifications are sent when Child status changes to/from UNKNOWN
- [ ] Verify `is_unknown` field in database updates correctly
- [ ] Verify frontend `monitor.isUnknown` reactive property updates correctly
- [ ] Verify circular dependency validation prevents self-dependency
- [ ] Verify circular dependency validation prevents descendant dependency
- [ ] Verify deleting dependency monitor sets dependency to NULL
- [ ] Verify group monitor as dependency behaves correctly (always satisfied unless paused)

## Reproduction Steps for Future Releases

### Monitor Dependency Feature
1. Create migration file for `dependency` column in monitor table
2. Add UNKNOWN constant to `src/util.ts`
3. Update `server/model/monitor.js`:
   - Import UNKNOWN
   - Add `isDependencySatisfied()` method
   - Modify `start()` to check dependency first
   - Add `dependency` to `toJSON()` output
4. Update `server/uptime-calculator.js`:
   - Import UNKNOWN
   - Handle UNKNOWN in `flatStatus()`
5. Update frontend components:
   - `src/mixins/socket.js` - statusList and stats
   - `src/components/Uptime.vue` - color computed
   - `src/components/HeartbeatBar.vue` - getBeatColor and getBeatAriaLabel
   - `src/pages/EditMonitor.vue` - dependency field, selector, computed properties
6. Update `server/server.js` - editMonitor handler and circular dependency validation
7. Add translations to `src/lang/en.json`
8. Run `npm run build` and `npm run lint` to verify

### is_unknown Field Feature
1. Create migration file for `is_unknown` column in monitor table
2. Update `server/model/monitor.js`:
   - Add `isUnknown: Boolean(this.is_unknown)` to `toJSON()` output
   - After each heartbeat, update `monitor.is_unknown` in DB based on heartbeat status
   - Send `updateMonitorIntoList` socket event to notify frontend
3. Update `src/mixins/socket.js`:
   - `assignMonitorUrlParser()`: Initialize `monitor.isUnknown = Boolean(monitor.is_unknown)` from server data
   - Add `updateMonitorUnknownStatus(monitorID, status)` method
   - Call on each `heartbeat` event to keep `monitor.isUnknown` in sync
   - Handle `updateMonitorIntoList` socket event to update monitor list
4. Run `npm run build` and `npm run lint` to verify