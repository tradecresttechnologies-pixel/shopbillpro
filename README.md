# ShopBill Pro — Planning & Reference Documents (v1.1)

**Version:** v1.1 (post Batch 012)
**Generated:** 6 May 2026
**Purpose:** Single source of truth for product strategy, current build state, and next sprint plan.

This is a "living" reference. Keep it in `docs/` at repo root. Update at end of every batch.

**v1.1 changelog:**
- Locked decisions from 6 May founder session baked into Vertical Playbook §11
- 12 bugs moved from "open" to "closed" in Current State Audit §2 after Batch 012 deploy
- BUG_FIX_PLAN renamed to historical record; new active deploy guide is `BATCH_012_DEPLOY.md` shipped with the batch zip

---

## What's in this folder

### 📘 `VERTICAL_PLAYBOOK.md` (strategic — rarely changes)

Per-vertical reference for "how does ShopBill Pro work for a salon vs a kirana vs a clinic."

**Read this when:**
- A new vertical sub-type needs to be added
- Designing a new feature (figure out which verticals it applies to)
- AI website prompt engineering
- Sample data seeding decisions
- Decision points around module visibility per vertical

**Sections:**
- §1 Architecture in one page
- §2 The 12 macro categories
- §3 The 19 module profiles
- §4 Per-vertical sidebar maps (salon, healthcare, education, services, kirana, restaurant, pharmacy, etc.)
- §5 All 85 sub-types → profile map
- §6 Module catalog (universal core, add-ons, vertical-specific)
- §7 Vertical coverage scoring
- §8 Sample data per vertical (signup seed)
- §9 AI website prompt skeleton per vertical
- §10 Drift tracker (when doc and code disagree)
- §11 Decision points needing founder input
- §12 Versioning & maintenance

### 📋 `CURRENT_STATE_AUDIT.md` (snapshot — update after every batch)

What exists in code right now. Files, RPCs, deploys, bugs, tech debt.

**Read this when:**
- Returning after a break and need to know "where are we"
- Auditing for compliance with API-first rule
- Figuring out which migrations are deployed
- Triaging a bug — first check if it's already in the register

**Sections:**
- §1 File inventory (HTML, JS, SQL — root + admin + lib + site)
- §2 Bug register (open) — 19 bugs catalogued with severity
- §3 API-first compliance audit
- §4 Deploy state
- §5 Recently shipped timeline
- §6 Open questions / pending decisions
- §7 Maintenance note

### 🔧 `BUG_FIX_PLAN.md` (next sprint — execute when given "go")

Concrete batch plan with exact diffs for the bugs found in the latest audit.

**Read this when:**
- About to start a bug-fix sprint
- Need to estimate how long a fix will take
- Verifying scope before deploy

**Sections:**
- §1 Sprint goals
- §2 Fix order (priority + dependencies)
- §3 Detailed fixes (with exact diffs)
- §4 Deploy plan
- §5 Smoke test checklist
- §6 Rollback plan
- §7 Files in final zip
- §8 Time estimate
- §9 Decision points needing founder input

---

## How to use these docs

### When a new batch starts

1. Read **CURRENT_STATE_AUDIT.md §1 (File Inventory)** to know the file landscape
2. Read **CURRENT_STATE_AUDIT.md §2 (Bug Register)** to know what's open
3. Read **VERTICAL_PLAYBOOK.md** sections relevant to the vertical(s) being touched
4. Plan the batch
5. Execute
6. **Update CURRENT_STATE_AUDIT.md** with new files, fixed bugs, new RPCs
7. **Update VERTICAL_PLAYBOOK.md** if module/profile/vertical changes

### When founder asks "what's the state of the app"

Read aloud from **CURRENT_STATE_AUDIT.md §5 (Recently Shipped Timeline)** + §2 (Bug Register critical/high).

### When founder asks "how does X vertical work"

Read **VERTICAL_PLAYBOOK.md §4** for the specific vertical (salon, kirana, etc.).

### When a new bug is filed

Add to **CURRENT_STATE_AUDIT.md §2** with severity, affected pages, and likely cause file.

### When a bug is fixed

Move to a "Closed" subsection in §2, with date + batch reference.

---

## Versioning

All three docs are at **v1.0** (6 May 2026). Bump version when:
- Major structural change to the doc
- A locked decision changes
- New macro/profile added

Date-stamp every edit at the top of the relevant section.

---

## Future enhancement

Once these docs are referenced enough, consider:
- Auto-generating §1 (File Inventory) and §2 (Bug Register) from a script that scans the repo
- Auto-generating §6 (Module Catalog) from `lib/sidebar-engine.js` and `sbp_module_profiles` table
- Sub-folder per macro vertical with extended notes (`docs/verticals/salon.md`, `docs/verticals/kirana.md`)

For now, hand-maintained markdown is the right level of effort for a solo-founder build.

---

*ShopBill Pro · TradeCrest Technologies Pvt. Ltd.*
