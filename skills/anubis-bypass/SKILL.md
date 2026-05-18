---
name: anubis-bypass
description: "Bypass Anubis PoW bot-check pages using Playwright MCP. Trigger when navigating to a site blocked by Anubis ('Making sure you are not a bot!', 'Oh noes!', Anubis challenge page). Also invocable as /anubis-bypass <url>."
user-invocable: true
argument-hint: "[url]"
---

# Anubis Bypass

Access sites protected by Anubis PoW challenges via Playwright MCP.

## Procedure

### 1. Patch the User-Agent header

Use `browser_run_code` to intercept all requests and replace the UA string:

```js
await page.route('**/*', async (route) => {
  const headers = await route.request().allHeaders();
  headers['user-agent'] = headers['user-agent'].replace(/HeadlessChrome/g, 'Chrome');
  await route.continue({ headers });
});
```

### 2. Navigate to the target URL

Use `browser_navigate` with the URL (from the argument or from the page that triggered Anubis).

### 3. Wait for the PoW challenge to complete

Use `browser_wait_for` with `textGone: "Checking your browser..."` and a 60-second timeout.
If the page shows "Loading..." instead, wait for that to disappear too.

### 4. Verify the real page loaded

Use `browser_snapshot` to confirm the actual page content is visible and no Anubis challenge text remains.
