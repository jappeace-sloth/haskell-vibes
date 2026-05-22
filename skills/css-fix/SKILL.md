---
name: css-fix
description: >
  Fix CSS styling issues by visually comparing before/after screenshots.
  Use when the user reports visual alignment, spacing, margin, or padding
  problems on a web page. Also trigger when asked to fix layout issues,
  element spacing, or visual inconsistencies in CSS.
allowed-tools: Read, Edit, Write, Grep, Glob, Bash, mcp__playwright__browser_navigate, mcp__playwright__browser_take_screenshot, mcp__playwright__browser_snapshot, mcp__playwright__browser_resize
---

# CSS Fix Workflow

Fix visual CSS issues using a screenshot-driven feedback loop.

## Process

### 1. Capture the problem

- Navigate to the page with the issue using Playwright
- Take a **full-page screenshot** to see the current state
- If the user points to a specific element, take an element-level screenshot too
- Save screenshots with descriptive names (e.g. `section-before.png`)

### 2. Find the source files

- Identify which CSS file(s) control the styling
- Check if the page is generated (build output) vs static source
- If generated, find the source CSS — don't edit build output directories like `_site/`, `_build/`, `_penguin-site/`, `dist/`
- Read the relevant CSS rules and the HTML structure to understand what's happening

### 3. Diagnose the issue

Common problems and fixes:
- **Missing selector**: CSS targets `ul` but HTML uses `ol` (or vice versa) — add the missing selector
- **No list styling**: Lists inside a section have no rules — add margin/padding rules matching sibling sections
- **Button/element too tight against text**: Add `margin-top` or `margin-bottom` to create breathing room
- **Excessive padding**: Reduce padding values, especially horizontal padding on inline-block/button elements
- **Alignment mismatch**: Elements at different indent levels — ensure consistent `margin-left` or `padding-left`

### 4. Apply the fix

- Edit the **source** CSS file (not build output)
- Keep changes minimal — only fix what's reported
- Match existing conventions in the stylesheet (same units, similar values)

### 5. Rebuild and verify

- Rebuild the site if it uses a build system
- Navigate to the local version of the page
- Take an **after screenshot** with the same framing as the before screenshot
- Compare visually — the fix should be apparent

### 6. Test responsiveness

- Resize to mobile width (375px) to check the fix doesn't break on small screens
- Resize back to desktop (1280px) to confirm
- Take screenshots at both sizes if the fix involves layout-sensitive properties

### 7. Present results

- Show the user the before/after screenshots
- Describe what CSS was changed and why
- Ask the user if it looks right before committing

## Tips

- When a site uses a build system, find and remove stale lock files if the build fails (e.g. `_build/.shake.lock`)
- For Shake-based sites: `rm -f _build/.shake.lock` before rebuilding
- Start a local HTTP server to preview: `python3 -m http.server PORT --directory OUTPUT_DIR`
- If the server port is in use, it's likely already running from a previous attempt — just use it
- Prefer `margin` over `padding` for spacing between sibling elements
- Prefer adjusting the more specific selector (e.g. `.card .cta-button` over `.cta-button`) to avoid unintended side effects elsewhere
