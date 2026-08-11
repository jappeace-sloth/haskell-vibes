---
name: shopify-app-search
description: Reliably determine whether a Shopify app exists for a given need (accounting koppeling, review platform, carrier integration) and verify what it actually promises. Use whenever checking the Shopify app store for an app, verifying a "there is no app for X" claim, or researching app-based alternatives to custom work. The store's own search is untrustworthy for niche apps.
argument-hint: [zoekterm of app-naam]
---

# Shopify app store: zoeken dat wel werkt

Distilled from the Acumulus Sync miss (jappiesoft, 7-11 aug 2026): a
three-times-"verified" claim that no Shopify-Acumulus app existed was
false; the app had been live for two months and its existence
surfaced only because the vendor's own support desk mentioned it to
the client. Full post-mortem in jappiesoft
`research/acumulus-shopify-koppeling.org`.

## Why the obvious route fails

- The app-store search UI is weak on niche queries and favors major
  apps (Jappie's field observation, 11 aug 2026); a zero-review app
  may simply not surface, even when a human searches.
- Scripted search is worse: `search.json` returns an HTML loading
  skeleton (results render client-side), `Accept: application/json`
  gets a 422, and the sitemap route answered 503. There is NO public
  search API; Shopify's Partner API covers only your own apps.
- The server HTML of `apps.shopify.com/search?q=<term>` DOES contain
  result text (grepping for the term works), but naive link
  extraction finds only navigation chrome, not the app cards.
- Vendor ecosystems lag reality: the integrated platform's own
  koppelingen page and even its support desk may not know a new app
  exists. Absence there is weak evidence.

## Method, in order

1. Direct handle guesses (strongest signal, seconds):
   `curl -s -o /dev/null -w "%{http_code}" https://apps.shopify.com/<guess>`
   Try the product name, vendor name, and hyphenated combos
   (`acumulus`, `acumulus-sync`, `<vendor>-<product>`). 200 means
   the app exists; the handle need not match the display name
   (handle `acumulus`, name "Acumulus Sync").
2. External search engine: query `site:apps.shopify.com <term>` via
   WebSearch or w3m on a search engine. External indexes surface
   listings the store's own search buries.
3. Grep the search page for term presence, not links:
   `curl -s "https://apps.shopify.com/search?q=<term>" -H "User-Agent: Mozilla/5.0" | grep -ci "<term>"`
   A nonzero count means something is there; then extract candidate
   handles with a broad `apps.shopify.com/([a-z0-9-]+)` pattern and
   probe each per step 1.
4. Vendor side (the app maker's site, the integrated platform's
   integration pages): corroboration only, never the sole basis for
   a negative conclusion.

## Verifying what an app promises

- The listing is the primary source for promises, pricing, review
  count, and launch date ("Launched: ..."). Read it with
  `w3m -dump https://apps.shopify.com/<handle>`.
- The maker's blog or uitlegpagina may claim more than the listing
  (Acumulus Sync: btw-verlegd and OSS support appear only on the
  maker's page, not in the listing). Attribute each claim to where
  it actually appears; the gap between blog and listing is exactly
  what a client trial must test before anyone relies on it.
- Zero reviews plus a recent launch date means unproven: recommend
  free-trial verification against the client's real requirements,
  never rely on the claims.

## Negative results are perishable

A "there is no app for X" conclusion must carry its verification
date and method, and must be re-checked before it justifies building
custom work. The 7-aug "de app store heeft niets" was already false
when it was written down.
