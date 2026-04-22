# IDEAS — POL-one project (future)

Rolling capture of ideas that belong to the POL-one project, not the current auth-fix session. When POL-one kicks off, start here.

---

## 2026-04-20 — Expanding past POL's 4-character UI limit

POL's character-select window is limited to 4 visible content_ids (sometimes 16 depending on the client revision and account type). The UI is baked into the retail client binary — we can't resize it. But we can make the limit irrelevant.

### Option 1 — Linked-account rotation (lowest effort)
- Create `GUESTCL2`, `GUESTCL3`, … each with its own 4 content_ids
- Chharbot control panel exposes an account picker before Launch
- Picker sets `--user` for xiloader; POL renders that account's 4 slots

**Pros:** no LSB changes, no client changes, no schema changes
**Cons:** characters are hard-partitioned across accounts; no single unified list

### Option 2 — Content_id swap utility (clever path)
LSB's `chars` table can hold arbitrarily many characters. Each character is attached to a content_id slot, and content_ids are what POL's UI enumerates. A pre-launch swap tool rebinds which char_ids are bound to the active account's visible slots.

Rough shape:
```sql
-- Given account 1000 with 10 characters but only 4 visible slots:
--   slots 1..4 → whichever 4 we want to expose this session
UPDATE chars SET content_id = :slot WHERE charid = :charid;
```
The swap has to respect: (1) the client's cached content_id list at login, (2) the unique constraint on (accid, content_id), (3) anything referencing content_id in `char_vars`, party state, etc. Needs a dry-run / integrity check before commit.

**Pros:** single account, unified character list, POL unchanged
**Cons:** touching `chars` live is risky; needs a lock on the account during swap; undo-log discipline

### Option 3 — Chharbot character picker UI (the "proper" answer)
Full character roster UI outside POL, in the Chharbot control panel. Displays every character across every linked account with rich metadata (last login, job/levels, gear, location). When the user clicks a character, the picker calls option 1 or option 2 under the hood to get POL to show it in its 4 slots.

**Pros:** the UX actually scales; looks modern; enables features POL can't (search, filter, sort by job, alt-dashboards)
**Cons:** most work; needs to pull char data out of `chars` and `char_jobs` and `char_inventory` and render it

### Recommendation for POL-one
Build option 3's UI. Back it with option 1 initially (one-account-per-group-of-4), graduate to option 2 if/when the content_id swap is proven safe. This order minimizes risk to the DB and lets the UI land before the hairy DB-rebinding work.

### Dependencies to stage before this work
- BCrypt migration for the `accounts` table (so multi-account doesn't multiply the legacy-hash landmine)
- `SupportedXiloaderVersion` becoming a config value (so rolling multiple xiloader clients across accounts doesn't trip version gates)
- A transactional wrapper around content_id swaps in `chars` (for option 2)

---
