---
name: reddit-comment
description: >
  Post comments on Reddit via old.reddit.com using Playwright MCP.
  Use when the user wants to comment on a Reddit post, engage in Reddit
  discussions, or do ghostwritten Reddit engagement. Handles login,
  navigation, and comment submission. Also trigger when browsing Reddit
  or upvoting posts.
allowed-tools: Bash, Read, WebFetch, mcp__playwright__*
---

# Reddit Comment Workflow

Post comments on Reddit using old.reddit.com and Playwright MCP browser automation.

## Prerequisites

- Environment variables: `REDDIT_USERNAME`, `REDDIT_PASSWORD`
- Playwright MCP browser tools available

## Login Flow

Login is the trickiest part. Follow these steps exactly.

### 1. Clear headers and login via new Reddit

Extra HTTP headers on the browser context cause CORS failures on www.reddit.com
static assets. Clear them before login:

```js
// In browser_run_code:
const context = page.context();
await context.setExtraHTTPHeaders({});
await context.clearCookies();
await page.goto('https://www.reddit.com/login/');
```

### 2. Handle cookie consent

The cookie dialog intercepts all clicks. Dismiss it with force-click:

```js
await page.locator('button:has-text("Accept All")').click({ force: true });
```

### 3. Fill credentials and submit

Use `browser_fill_form` or `browser_run_code` for the login form:

```js
await page.getByRole('textbox', { name: 'Email or username' }).fill(USERNAME);
await page.getByRole('textbox', { name: 'Password' }).fill(PASSWORD);
```

**IMPORTANT**: The password must be the literal string value, not a shell
variable reference like `${REDDIT_PASSWORD}`. Read it via Bash `printenv`
first, then paste the value into the Playwright code.

Click the "Log In" button. The page redirects to www.reddit.com on success.

### 4. Switch to old.reddit.com with User-Agent

After login, set ONLY the User-Agent header (not Sec-Fetch-* headers, those
break CORS on cross-origin requests):

```js
const context = page.context();
await context.setExtraHTTPHeaders({
  'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0'
});
await page.goto('https://old.reddit.com/r/TARGET_SUBREDDIT/');
```

Without the Firefox User-Agent, old.reddit.com returns 403 "blocked by network
security".

## Posting a Comment

### 1. Navigate to the post

```js
await page.goto('https://old.reddit.com/r/SUBREDDIT/comments/POST_ID/...');
```

### 2. Find and fill the comment box

The main comment textbox is at the top of the comments section:

```js
// Click to focus, then fill
await page.locator('textarea[name="text"]').click();
await page.locator('textarea[name="text"]').fill('Your comment here');
```

### 3. Dismiss pinned post overlay

The pinned/sticky post element at the top of the page often intercepts click
events on the save button. Dismiss it first:

```js
const dismissLink = page.locator('a:has-text("Dismiss this pinned window")');
if (await dismissLink.count() > 0) {
  await dismissLink.click({ force: true });
}
```

### 4. Submit the comment

Use the CSS selector to target the correct save button (not reply buttons on
existing comments), and force-click to bypass any remaining overlays:

```js
await page.locator('.commentarea > .usertext button.save').click({ force: true });
```

### 5. Verify submission

After clicking save, take a snapshot. Look for the comment text appearing under
the logged-in username with timestamp "zo-even" (Dutch for "just now") or
"just now".

## Replying to a Specific Comment

To reply to an existing comment rather than the post:

1. Find the comment's "reageren" (reply) or "reply" link and click it
2. A reply textbox appears nested under that comment
3. Fill and save using the reply form's save button

## Reading Posts via JSON API

To read post content and comments without navigating, use curl:

```bash
curl -s -H "User-Agent: Mozilla/5.0 ..." \
  "https://old.reddit.com/r/SUBREDDIT/comments/POST_ID/.json" \
  | python3 -c "import sys,json; ..."
```

This is faster for scanning multiple posts to find interesting ones.

## Upvoting

Click the upvote button (`aria-label="upvote"`) on any post or comment.
Must be logged in.

## Known Issues

- **Account age restrictions**: The `jappeace-sloth` account is new. Some
  subreddits (e.g. r/ClaudeAI) auto-remove posts from new accounts via
  AutoModerator. Comments may still work even when posts are blocked.
- **CAPTCHA**: Some actions trigger reCAPTCHA v2. Use the `recaptcha-solving`
  skill if this happens.
- **Dutch locale**: The account renders old.reddit.com in Dutch. Button labels:
  "opslaan" = save, "reageren" = reply, "verbergen" = hide, "rapporteren" =
  report, "bewerken" = edit, "verwijderen" = delete, "uitloggen" = logout.
- **CORS on comment API**: Console shows errors about `api/comment.json` CORS
  failures. These are benign — the comment still posts successfully despite
  the error logs.
- **Direct login URLs blocked**: Never navigate directly to
  `old.reddit.com/login` — it gets 403'd. Always use `www.reddit.com/login/`.

## Ghostwriting Guidelines

When ghostwriting comments for the user:

1. Draft the comment and show it to the user for approval before posting
2. Keep comments short (1 paragraph) — real humans are lazy
3. Match the user's voice and tone
4. Only engage on topics the user genuinely cares about
5. Read the post and existing comments via JSON API first to understand context
