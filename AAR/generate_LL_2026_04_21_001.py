# Generate LL-2026-04-21-001.pdf - Lessons Learned for 2026-04-21 session.
# Follows the AAR skill: CUI header, dark navy cover, amber section headers.
import os
from reportlab.lib.pagesizes import letter
from reportlab.platypus import (SimpleDocTemplate, Paragraph, Spacer,
                                Table, TableStyle, PageBreak)
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib import colors
from reportlab.lib.units import inch
from reportlab.lib.enums import TA_LEFT, TA_CENTER

OUT = os.path.join(os.path.dirname(__file__), 'reports', 'LL-2026-04-21-001.pdf')

NAVY   = colors.HexColor('#16213E')
AMBER  = colors.HexColor('#FFAA00')
CUIRED = colors.HexColor('#B91C1C')
ROW_A  = colors.HexColor('#0F1A2E')
ROW_B  = colors.HexColor('#111827')
WHITE  = colors.white
GREY   = colors.HexColor('#9CA3AF')

PAGE_W, PAGE_H = letter
MARGIN_L = 0.6 * inch
MARGIN_R = 0.6 * inch
CONTENT_W = PAGE_W - MARGIN_L - MARGIN_R   # ~ 7.3 in

def cui_header_footer(canv, doc):
    canv.saveState()
    canv.setFillColor(CUIRED)
    canv.setFont('Helvetica-Bold', 9)
    canv.drawCentredString(PAGE_W / 2, PAGE_H - 0.35 * inch,
                           'CUI - CONTROLLED UNCLASSIFIED INFORMATION')
    canv.drawCentredString(PAGE_W / 2, 0.3 * inch,
                           'CUI - CONTROLLED UNCLASSIFIED INFORMATION')
    canv.setFillColor(GREY)
    canv.setFont('Helvetica', 8)
    canv.drawRightString(PAGE_W - MARGIN_R, 0.15 * inch, f'Page {doc.page}')
    canv.drawString(MARGIN_L, 0.15 * inch, 'LL-2026-04-21-001 | DRAFT | LIVING DOCUMENT')
    canv.restoreState()

styles = getSampleStyleSheet()
H1 = ParagraphStyle('H1', parent=styles['Heading1'],
                    textColor=AMBER, fontName='Helvetica-Bold',
                    fontSize=14, spaceAfter=8, spaceBefore=10)
H2 = ParagraphStyle('H2', parent=styles['Heading2'],
                    textColor=AMBER, fontName='Helvetica-Bold',
                    fontSize=11, spaceAfter=4, spaceBefore=8)
BODY = ParagraphStyle('Body', parent=styles['BodyText'],
                      fontName='Helvetica', fontSize=9,
                      leading=12, textColor=colors.HexColor('#E5E7EB'),
                      alignment=TA_LEFT, spaceAfter=4)
CODE = ParagraphStyle('Code', parent=styles['BodyText'],
                      fontName='Courier', fontSize=8, leading=10,
                      textColor=colors.HexColor('#A7F3D0'),
                      leftIndent=10, spaceAfter=4)
COVER_TITLE = ParagraphStyle('CoverTitle', parent=styles['Title'],
                             fontName='Helvetica-Bold', fontSize=24,
                             textColor=AMBER, alignment=TA_CENTER,
                             spaceAfter=12)
COVER_SUB = ParagraphStyle('CoverSub', parent=styles['Normal'],
                           fontName='Helvetica-Bold', fontSize=13,
                           textColor=WHITE, alignment=TA_CENTER,
                           spaceAfter=6)
COVER_LINE = ParagraphStyle('CoverLine', parent=styles['Normal'],
                            fontName='Helvetica', fontSize=10,
                            textColor=GREY, alignment=TA_CENTER,
                            spaceAfter=2)

def std_table(data, col_widths):
    t = Table(data, colWidths=col_widths, repeatRows=1)
    style = TableStyle([
        ('BACKGROUND', (0, 0), (-1, 0), NAVY),
        ('TEXTCOLOR', (0, 0), (-1, 0), AMBER),
        ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
        ('FONTSIZE', (0, 0), (-1, -1), 8),
        ('LEADING', (0, 0), (-1, -1), 10),
        ('VALIGN', (0, 0), (-1, -1), 'TOP'),
        ('TEXTCOLOR', (0, 1), (-1, -1), WHITE),
        ('LINEBELOW', (0, 0), (-1, 0), 0.5, AMBER),
        ('GRID', (0, 0), (-1, -1), 0.25, colors.HexColor('#1F2937')),
        ('LEFTPADDING', (0, 0), (-1, -1), 4),
        ('RIGHTPADDING', (0, 0), (-1, -1), 4),
        ('TOPPADDING', (0, 0), (-1, -1), 3),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 3),
    ])
    for i in range(1, len(data)):
        style.add('BACKGROUND', (0, i), (-1, i), ROW_A if i % 2 else ROW_B)
    t.setStyle(style)
    return t

def para_cell(text):
    return Paragraph(text, ParagraphStyle('Cell', parent=BODY, fontSize=8,
                                          leading=10, textColor=WHITE))

def on_cover(canv, doc):
    canv.saveState()
    canv.setFillColor(NAVY)
    canv.rect(0, 0, PAGE_W, PAGE_H, stroke=0, fill=1)
    canv.setFillColor(CUIRED)
    canv.setFont('Helvetica-Bold', 10)
    canv.drawCentredString(PAGE_W / 2, PAGE_H - 0.4 * inch,
                           'CUI - CONTROLLED UNCLASSIFIED INFORMATION')
    canv.drawCentredString(PAGE_W / 2, 0.35 * inch,
                           'CUI - CONTROLLED UNCLASSIFIED INFORMATION')
    canv.restoreState()

doc = SimpleDocTemplate(OUT, pagesize=letter,
                        leftMargin=MARGIN_L, rightMargin=MARGIN_R,
                        topMargin=0.7 * inch, bottomMargin=0.55 * inch,
                        title='LL-2026-04-21-001',
                        author='Chharbot / Chharith Oeun')

story = []

# ---------- COVER ----------
story.append(Spacer(1, 1.2 * inch))
story.append(Paragraph('LESSONS LEARNED', COVER_TITLE))
story.append(Paragraph('LL-2026-04-21-001', COVER_SUB))
story.append(Spacer(1, 0.25 * inch))
story.append(Paragraph(
    'LSB Chharbot Control Stack: Git Remote Bootstrap, PowerShell Parser Fixes, '
    'GitHub Cleanup, Smoke Test Diagnostic Sharpening',
    ParagraphStyle('CoverDesc', parent=COVER_SUB, fontSize=12, leading=16)))
story.append(Spacer(1, 0.35 * inch))
story.append(Paragraph('Classification: <b>SIGNIFICANT</b>', COVER_LINE))
story.append(Paragraph('Date: 21 April 2026', COVER_LINE))
story.append(Paragraph('Status: DRAFT -> LIVING DOCUMENT', COVER_LINE))
story.append(Spacer(1, 0.4 * inch))
story.append(Paragraph('Owner: Chharith Oeun (BBoy-PopTart)', COVER_LINE))
story.append(Paragraph('Reporter: Chharbot (Claude, via Cowork)', COVER_LINE))
story.append(Paragraph('Authority: TRADOC 525-3-1 | ADP 3-0 | FM 6-01.1', COVER_LINE))
story.append(PageBreak())

# ---------- SECTION 1: SITUATION ----------
story.append(Paragraph('SECTION 1 - SITUATION', H1))
story.append(Paragraph(
    'Following the successful stand-up of the Chharbot AI control stack for the '
    'LandSandBoat (LSB) FFXI private server (sessions 2026-04-18 through 2026-04-20), '
    'this session focused on initializing the F:\\ffxi\\lsb-repo working tree as a git '
    'repository and pushing it to a new private GitHub repo under the '
    'ChharithOeun account. Secondary objectives emerged as side-effects of the first '
    'attempt: a malformed GitHub repo to clean up, and an ambiguous smoke-test '
    'diagnostic ("ai_bridge: down") that read like a bug but was actually expected '
    'state.', BODY))
story.append(Paragraph(
    '<b>Systems affected:</b> F:\\ffxi\\lsb-repo (git init + remote push), '
    'ChharithOeun GitHub account (repo created, stray repo deleted), '
    'chharbot/bin/smoke-test.ps1 (diagnostic clarified). No downtime to the live '
    'LSB server, sidecar, or Ashita addons.', BODY))
story.append(Paragraph(
    '<b>Impact:</b> Version control now established for the entire control stack '
    '(22 repos total under account, 1 operational). PowerShell bootstrap scripts '
    'hardened against three distinct classes of failure. Smoke test no longer '
    'misreports "down" as a bug when the game client is simply offline.', BODY))

# ---------- SECTION 2: TIMELINE ----------
story.append(Paragraph('SECTION 2 - TIMELINE', H1))
timeline = [
    ['Time (local)', 'Event'],
    ['~18:43', 'GIT_INIT.ps1 first run - FATAL: no .env found. Candidate list too narrow.'],
    ['~18:44', 'User direction: ".env is at C:\\Users\\User\\Chharbot\\.env"'],
    ['~18:45', 'Added exact path as first candidate; re-ran. Parser error on em-dash (U+2014).'],
    ['~18:48', 'sed -i stripped em-dash -> ASCII; GIT_INIT pushed as URL-as-repo-name.'],
    ['~18:50', 'Added external-.env guard + URL regex to derive bare repo name; re-ran.'],
    ['18:51', 'Push OK: commit a1fb0fc to ChharithOeun/lsb-repo on branch main.'],
    ['18:53', 'Task #27 marked complete; follow-up tasks queued.'],
    ['~18:57', 'GH_CLEANUP.ps1 written + executed -> 1 malformed repo deleted, lsb-repo verified.'],
    ['~19:10', 'Investigated ai_bridge "down"; confirmed it is not a bug but game-offline state.'],
    ['~19:15', 'Smoke-test.ps1 enhanced with 3-state ai_bridge diagnostic; re-ran -> new text confirmed.'],
    ['~19:20', 'LL PDF generation begun.'],
]
story.append(std_table(timeline, [1.1 * inch, CONTENT_W - 1.1 * inch]))
story.append(Spacer(1, 6))
story.append(Paragraph(
    '<b>Time to detect:</b> immediate (scripts fail loud). '
    '<b>Time to diagnose:</b> 1-3 min per issue. '
    '<b>Time to resolve:</b> ~40 min total across 3 script-bootstrap classes of bugs.',
    BODY))

# ---------- SECTION 3: ROOT CAUSE ----------
story.append(Paragraph('SECTION 3 - ROOT CAUSE ANALYSIS', H1))
story.append(Paragraph(
    'Three distinct root causes surfaced, each in a different category:', BODY))

story.append(Paragraph('A. .env discovery too narrow (config drift)', H2))
story.append(Paragraph(
    'The original GIT_INIT.ps1 probed only the deploy/repo-adjacent locations for .env. '
    'The operator had pre-existing secrets stored at a non-standard location '
    '(C:\\Users\\User\\Chharbot\\.env). The script treated the absence as fatal '
    'rather than expanding the search. Root assumption: ".env lives near the stack it '
    'serves" - valid for greenfield, invalid for a pre-existing operator profile.', BODY))

story.append(Paragraph('B. Non-ASCII characters in PowerShell 5.1 source (encoding)', H2))
story.append(Paragraph(
    'An em-dash (U+2014, 0xE2 0x80 0x94 in UTF-8) was copied into a comment when the '
    'file was authored. The sandbox wrote LF-terminated UTF-8; Windows PowerShell 5.1 '
    'then interpreted the bytes as CP-1252 and produced a cascade of ParserErrors. '
    'The LF vs CRLF issue and the em-dash issue compounded - neither alone would have '
    'been fatal, but together they defeated the parser.', BODY))

story.append(Paragraph('C. Configuration value used for the wrong purpose (scope)', H2))
story.append(Paragraph(
    'The existing .env contained GITHUB_REPO=https://github.com/ChharithOeun/Chharbot.git '
    '(a full clone URL for a different project), and the script naively concatenated '
    '"$ghUser/$ghRepoName" into the remote URL. Result: '
    'https://github.com/ChharithOeun/https://github.com/ChharithOeun/Chharbot.git.git/. '
    'GitHub API tolerated it (sanitized to "https-github.com-ChharithOeun-Chharbot"), '
    'creating the malformed repo that GH_CLEANUP later deleted. Root assumption: '
    '"if the .env is in-repo, its values are scoped to this repo" - invalid when an '
    'external .env is reused.', BODY))

# ---------- SECTION 4: FAILED ATTEMPTS ----------
story.append(Paragraph('SECTION 4 - ATTEMPTS THAT FAILED', H1))
fails = [
    ['#', 'Attempt', 'Why it failed', 'Lesson'],
    ['1', 'Recursive scan of C:\\Users\\User for .env',
     'Traversed AppData/Dropbox/OneDrive; stuck >4 min.',
     'Depth-capped scans; always probe known locations first.'],
    ['2', 'Trust .env GITHUB_REPO value even when .env is outside repo',
     'External secrets leaked scope into this repo -> malformed URL.',
     'Scope config by proximity: external .env contributes only user+PAT.'],
    ['3', 'Assume UTF-8 source is PS-safe',
     'Em-dash re-read as CP-1252 produced ParserError cascade.',
     'Enforce ASCII-only in PS source + CRLF line endings at write time.'],
    ['4', 'Treat "ai_bridge: down" as a bug to fix',
     'Misread expected game-offline state as broken deploy.',
     'Differentiate staging-failure vs runtime-prereq in diagnostic text.'],
]
story.append(std_table([[para_cell(c) for c in row] for row in fails],
                       [0.35 * inch, 1.9 * inch, 2.3 * inch, CONTENT_W - 4.55 * inch]))

# ---------- SECTION 5: SOLUTIONS ----------
story.append(PageBreak())
story.append(Paragraph('SECTION 5 - SOLUTIONS THAT WORKED', H1))

story.append(Paragraph('A. Stage-A/B .env discovery', H2))
story.append(Paragraph(
    'Added a hard-coded list of 16 known candidate paths (Stage A), searched in order, '
    'first to contain a recognized PAT key wins. Stage B recursive fallback retained '
    'but depth-capped. Operator told us the exact path once; script now finds it '
    'every time thereafter.', BODY))

story.append(Paragraph('B. ASCII + CRLF enforcement pipeline', H2))
story.append(Paragraph(
    'After every PowerShell edit in the sandbox, two post-processing steps:', BODY))
story.append(Paragraph(
    "awk 'sub(\"$\", \"\\r\")' file.ps1 &gt; file.crlf    # CRLF-terminate every line<br/>"
    "LC_ALL=C grep -Pn '[^\\x00-\\x7F]' file.ps1   # assert no non-ASCII bytes",
    CODE))

story.append(Paragraph('C. External-.env scope guard + URL-to-name regex', H2))
story.append(Paragraph(
    'If the resolved .env is not inside the repo root, the script uses only its '
    'PAT + user values and forces LSB_REPO_NAME to "lsb-repo". If the .env is in-repo, '
    'GITHUB_REPO is accepted but a URL pattern is stripped to just the bare name:', BODY))
story.append(Paragraph(
    "if (`$ghRepoName -match '(?:https?://github\\.com/|git@github\\.com:)([^/]+)/([^/]+?)(?:\\.git)?/?`$') {<br/>"
    "    `$ghRepoName = `$Matches[2]<br/>"
    "}",
    CODE))

story.append(Paragraph('D. Safety-gated GitHub cleanup', H2))
story.append(Paragraph(
    'GH_CLEANUP.ps1 scans all repos, flags any with URL-like names or disallowed '
    'characters, and deletes ONLY if both size==0 and created within 1 day. Three '
    'deletion gates (pattern match, empty, recently-created) prevent any legitimate '
    'repo from being touched. Transcript is PAT-redacted as defense-in-depth.', BODY))

story.append(Paragraph('E. Smoke-test tri-state diagnostic', H2))
story.append(Paragraph(
    'Instead of a binary "up/down", ai_bridge now reports one of three states: '
    '"up"; "down (game offline -- start FFXI + /addon load ai_bridge to exercise)"; or '
    '"down (addon not staged at [path] -- run deploy-full-stack.ps1)". The third is '
    'the only one that indicates a real bug.', BODY))

# ---------- SECTION 6: NEW CAPABILITIES ----------
story.append(Paragraph('SECTION 6 - NEW CAPABILITIES UNLOCKED', H1))
caps = [
    ['Capability', 'Description', 'File/Location', 'Status'],
    ['Git init + remote push, one-shot',
     'Idempotent bootstrap: creates GH repo if missing, configures origin with '
     'ephemeral PAT-in-URL, scrubs PAT after push.',
     'GIT_INIT.ps1 / .bat', 'LIVE'],
    ['External .env fallback',
     '16-candidate probe + recursive fallback; scope guard for cross-repo .env.',
     'GIT_INIT.ps1 (load-env section)', 'LIVE'],
    ['Safety-gated GH cleanup',
     'Pattern-match + empty + recent triple gate; PAT-redacted transcript.',
     'GH_CLEANUP.ps1 / .bat', 'LIVE'],
    ['Tri-state ai_bridge probe',
     'Distinguishes deploy bug from runtime prereq (game offline).',
     'chharbot/bin/smoke-test.ps1', 'LIVE'],
    ['CRLF + ASCII enforcement pattern',
     'Two-line post-edit pipeline for every PowerShell file touched in sandbox.',
     'internal practice (not a script)', 'DOCTRINE'],
]
story.append(std_table([[para_cell(c) for c in row] for row in caps],
                       [1.6 * inch, 2.6 * inch, 1.6 * inch, CONTENT_W - 5.8 * inch]))

# ---------- SECTION 7: KNOWN BUGS ----------
story.append(Paragraph('SECTION 7 - KNOWN BUGS & WORKAROUNDS', H1))
bugs = [
    ['Bug ID', 'Description', 'Workaround', 'Priority', 'Status'],
    ['KB-2026-04-21-A',
     'Live FFXI login test for FFXI-3331 fix not yet executed (requires user at keyboard).',
     'Run Launch-FFXI.bat shortcut on desktop; confirm character select loads post-fix.',
     'P2', 'OPEN'],
    ['KB-2026-04-21-B',
     'ai_bridge runtime handshake not exercised (depends on live game).',
     'After FFXI is up and /addon load ai_bridge runs, rerun SMOKE.bat; should flip to "up".',
     'P2', 'OPEN'],
    ['KB-2026-04-21-C',
     'GIT_INIT.log may retain PAT in git-config console output on certain PS hosts.',
     'Script already redacts .log file post-run; verify before publishing logs externally.',
     'P3', 'MITIGATED'],
]
story.append(std_table([[para_cell(c) for c in row] for row in bugs],
                       [1.2 * inch, 2.4 * inch, 2.1 * inch, 0.5 * inch,
                        CONTENT_W - 6.2 * inch]))

# ---------- SECTION 8: WARFIGHTER ANALYSIS ----------
story.append(PageBreak())
story.append(Paragraph('SECTION 8 - WARFIGHTER ANALYSIS', H1))
story.append(Paragraph(
    '<b>Foreseeable?</b> Partially. The em-dash issue is a well-known PS 5.1 hazard; '
    'we should have an ASCII-gate in the editor workflow. The URL-as-name issue was '
    'not foreseeable without prior knowledge of the operator\'s .env contents. The '
    '.env location drift was predictable: scripts should always accept an override '
    'path or probe widely.', BODY))
story.append(Paragraph('<b>Red Team - wrong assumptions</b>', H2))
story.append(Paragraph(
    '1) ".env lives next to the stack it serves"; 2) "sandbox UTF-8 is PS-safe"; '
    '3) "all .env values belong to this repo"; 4) "ai_bridge down = broken".',
    BODY))
story.append(Paragraph('<b>Blue Team - what worked</b>', H2))
story.append(Paragraph(
    '1) Transcripts + Start-Transcript / Stop-Transcript captured enough diagnostic '
    'detail to localize each fault quickly; 2) PAT redaction pattern applied '
    'uniformly; 3) Safety-gated destructive operations (3 gates before DELETE); '
    '4) Re-use of CRLF+ASCII pipeline prevented regressions on subsequent edits.',
    BODY))
story.append(Paragraph('<b>White Team - overall</b>', H2))
story.append(Paragraph(
    '<b>Vulnerability score: ACCEPTABLE.</b> No data loss, no downtime, no secrets '
    'leaked, no irreversible actions. The one malformed GitHub repo created was '
    'cleaned up the same session. The diagnostic clarification upgrade will prevent '
    'recurrence of the "is ai_bridge a bug?" question.', BODY))

# ---------- SECTION 9: TOKEN COST ----------
story.append(Paragraph('SECTION 9 - TOKEN COST ESTIMATE', H1))
cost = [
    ['Activity', 'Est tokens', 'Notes'],
    ['GIT_INIT.ps1 edits + re-runs (3 iterations)', '~25k',
     'Each iteration re-read full script + surrounding files.'],
    ['Recursive .env scan dead-end', '~8k',
     'Waste - preventable with depth cap up-front.'],
    ['GH_CLEANUP.ps1 authoring + run', '~12k', 'Clean one-shot.'],
    ['Smoke-test enhancement + re-run', '~6k', 'Small surgical edit.'],
    ['AAR generation (this document)', '~10k', 'reportlab pipeline.'],
    ['Total session estimate', '~61k', 'within Sonnet + Opus budget.'],
]
story.append(std_table(cost, [3.0 * inch, 0.9 * inch, CONTENT_W - 3.9 * inch]))
story.append(Spacer(1, 6))
story.append(Paragraph(
    '<b>Savings identified:</b> (a) Put the .env probe list in a machine-readable '
    'config so we never re-scan by hand; (b) run ASCII+CRLF pipeline as a git '
    'pre-commit hook so the em-dash class of bug never reaches execution.', BODY))

# ---------- SECTION 10: DOCTRINE ----------
story.append(Paragraph('SECTION 10 - DOCTRINE UPDATE', H1))
doctrine = [
    ['Doctrine file', 'Update required'],
    ['BOOTSTRAP.md',
     'Add "ASCII + CRLF pipeline" as a mandatory post-edit step for any .ps1 / .bat '
     'file written from a Unix-style sandbox.'],
    ['WARFIGHTER-DOCTRINE.md',
     'Codify the 3-gate rule for destructive GitHub operations (pattern + empty + recent).'],
    ['MEMORY.md',
     'Record operator\'s canonical .env location: C:\\Users\\User\\Chharbot\\.env. '
     'Record that GITHUB_REPO in that file refers to a different project and must not '
     'be used to derive lsb-repo names.'],
    ['SOUL.md',
     'No change - existing "verify before delete" principle covered this.'],
    ['SPIRIT.md',
     'Add line item: "diagnostic text must distinguish deploy bug from runtime prereq".'],
]
story.append(std_table([[para_cell(c) for c in row] for row in doctrine],
                       [1.8 * inch, CONTENT_W - 1.8 * inch]))

# ---------- SECTION 11: RECOMMENDATIONS ----------
story.append(Paragraph('SECTION 11 - RECOMMENDATIONS & NEXT ACTIONS', H1))
recs = [
    ['Priority', 'Action', 'Owner'],
    ['P1', 'User runs live FFXI login test to close out FFXI-3331 verification.',
     'Chharith'],
    ['P1', 'User runs /addon load ai_bridge once in-game; re-run SMOKE.bat to observe '
     '"ai_bridge: up".', 'Chharith'],
    ['P2', 'Add pre-commit hook to lsb-repo that enforces ASCII + CRLF on .ps1/.bat/.cmd.',
     'Chharbot'],
    ['P2', 'Move .env discovery candidates into a YAML/JSON config file.',
     'Chharbot'],
    ['P3', 'Extend GH_CLEANUP.ps1 to also flag repos created within last 48h with 0 commits '
     '(not just pattern-matched names).', 'Chharbot'],
    ['P3', 'Publish GIT_INIT.ps1 + GH_CLEANUP.ps1 patterns to an internal "PS bootstrap '
     'cookbook" doc.', 'Chharbot'],
    ['P4', 'Evaluate switching scripts to PowerShell 7 to sidestep 5.1 parser quirks.',
     'Chharbot'],
]
story.append(std_table([[para_cell(c) for c in row] for row in recs],
                       [0.6 * inch, CONTENT_W - 1.8 * inch, 1.2 * inch]))

story.append(Spacer(1, 10))
story.append(Paragraph(
    '<b>End of Report LL-2026-04-21-001.</b> Filed under '
    'F:\\ffxi\\lsb-repo\\AAR\\reports\\. MASTER-LESSONS.md updated.', BODY))

# ---------- BUILD ----------
def first_page(canv, doc):
    on_cover(canv, doc)

def later_pages(canv, doc):
    cui_header_footer(canv, doc)

doc.build(story, onFirstPage=first_page, onLaterPages=later_pages)
print(f'Wrote {OUT}')
