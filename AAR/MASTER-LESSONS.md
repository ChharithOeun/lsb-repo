# Master Lessons Index

This file indexes every Lessons Learned / After Action Report filed under
`AAR/reports/`. Newest entries appear at the top. Each entry links to a PDF and
summarizes the 3-5 most portable takeaways.

See individual reports for full TRADOC-format analysis (Situation, Timeline,
Root Cause, Failed Attempts, Solutions, Capabilities, Known Bugs, Warfighter
Analysis, Token Cost, Doctrine Update, Recommendations).

---

## LL-2026-04-21-001 - Git Remote Bootstrap + Bootstrap-Script Hardening
**Date:** 2026-04-21 | **Level:** SIGNIFICANT

**Key Lessons:**

- PowerShell 5.1 source must be ASCII + CRLF when written from a Unix-style
  sandbox. Em-dashes and other UTF-8 punctuation trigger ParserError cascades
  that look unrelated to the real issue. Enforce via:
  `awk 'sub("$", "\r")' file.ps1` + `LC_ALL=C grep -Pn '[^\x00-\x7F]' file.ps1`.
- External `.env` files should contribute only credentials (PAT, username).
  Scope-specific values like `GITHUB_REPO` belong to the stack the `.env` is
  embedded in. Re-using an outside `.env` for a different repo silently
  corrupted a URL and created a malformed GitHub repo.
- Destructive GitHub operations need three independent gates
  (pattern match + empty + recently created) before any DELETE is issued.
  Transcript must have PAT scrubbed post-run.
- Smoke test diagnostics must distinguish *deploy bugs* from *runtime
  prerequisites*. "ai_bridge: down" was expected state (game offline) and was
  mis-framed as a bug until the diagnostic was rewritten to declare which
  condition applied.
- Operator's canonical `.env` lives at `C:\Users\User\Chharbot\.env`. Scripts
  that read credentials should probe that path first, then widen.

**Report:** AAR/reports/LL-2026-04-21-001.pdf

## LL-2026-04-23-001 - ai_bridge Lua addon rewrite: Ashita v4 to v3 classic API
**Date:** 2026-04-23 | **Level:** SIGNIFICANT
**Key Lessons:**
- Ashita v3 classic uses _addon.name + ashita.register_event; v4 uses addon.name + ashita.events.register. Silent stalls at load stage 2/3 when mismatched.
- When an addon has NO console/chat output, a file-based io.open() trace log at each step is the fastest diagnostic path.
- Before coding any new Ashita Lua addon, dump a known-working addon (distance.lua, tparty.lua) first to confirm which API flavor the runtime expects.
**Report:** AAR/reports/LL-2026-04-23-001.pdf
