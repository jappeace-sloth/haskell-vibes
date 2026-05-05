---
name: wikipedia
description: Fetch and read Wikipedia articles. Use when you need to access Wikipedia content, since the WebFetch tool gets 403 errors from Wikipedia. Accepts an article title or search query as argument.
argument-hint: <article-title-or-search-query>
allowed-tools: Bash, WebFetch, WebSearch
---

# Wikipedia Access

Fetch Wikipedia articles using the MediaWiki API, which bypasses Wikipedia's bot blocking that prevents the WebFetch tool from working.

## Critical: Source Verification is Mandatory

Wikipedia is only as good as its sources. News reports can and do contain narratives that serve particular interests rather than reflect ground truth. For example, US intelligence claims about Iranian mine-laying in the Strait of Hormuz were widely reported as fact by major outlets and cited on Wikipedia, but cross-referencing revealed zero confirmed mine strikes on ships — every actual attack used targeted drones/missiles. The mine narrative served US military interests (justifying naval presence) rather than reflecting what was actually happening.

**Always verify Wikipedia claims against primary sources before presenting them as fact.** Look for:
- Claims sourced only to anonymous intelligence officials or single outlets
- Narratives that conveniently serve one side's interests
- Assertions where the evidence is "detected" or "reported" but never independently confirmed
- Discrepancies between what sources claim happened and what the physical evidence shows

## Usage

The argument `$ARGUMENTS` is either an article title (e.g. "Strait of Hormuz") or a search query.

## Step 1: Fetch the article

Use the MediaWiki API with a browser User-Agent header. The article title should have spaces replaced with underscores.

If the extract API returns empty content, the page may be a redirect. Use the parse API to check:

```bash
curl -s -H "User-Agent: Mozilla/5.0" \
  "https://en.wikipedia.org/w/api.php?action=parse&page=ARTICLE_TITLE&prop=wikitext&format=json" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['parse']['wikitext']['*'][:200])"
```

If it starts with `#REDIRECT`, follow the redirect target.

For the actual article text:

```bash
curl -s -H "User-Agent: Mozilla/5.0" \
  "https://en.wikipedia.org/w/api.php?action=query&prop=extracts&titles=ARTICLE_TITLE&format=json&explaintext=true" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); pages=d['query']['pages']; p=list(pages.values())[0]; print(p.get('extract','Article not found')[:8000])"
```

If the article is long and you need more, fetch subsequent chunks by adjusting the slice (e.g. `[8000:16000]`).

## Step 2: If no exact match, search first

If the article title doesn't return content (the page ID is -1 or extract is missing), search for it:

```bash
curl -s -H "User-Agent: Mozilla/5.0" \
  "https://en.wikipedia.org/w/api.php?action=opensearch&search=SEARCH_QUERY&limit=5&format=json"
```

This returns a JSON array with titles. Pick the best match and fetch that article.

## Step 3: Extract and verify sources

After reading the article, get the external links cited as references:

```bash
curl -s -H "User-Agent: Mozilla/5.0" \
  "https://en.wikipedia.org/w/api.php?action=parse&page=ARTICLE_TITLE&prop=externallinks&format=json" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(l) for l in d['parse']['externallinks'][:60]]"
```

Then **spot-check key claims** by fetching the actual cited sources.

### Fetching strategy

- Use **WebFetch** on non-paywalled sources (think tanks, Al Jazeera, Euronews, etc.)
- Use **WebSearch with specific quotes** from Wikipedia claims — search snippets often contain key passages even from paywalled articles
- Look for **secondary outlets** that quote paywalled originals (e.g. Times of Israel quoting NYT, EADaily summarizing Reuters)
- **Never batch source fetches in parallel** — if one WebFetch fails, parallel sibling calls get cancelled too. Fetch sources **sequentially**.
- Major outlets (NYT, Reuters, WSJ, Foreign Affairs) are paywalled and can't be fetched directly — don't waste time trying curl tricks or archive.org, they require JS rendering which doesn't work in this environment

### What to verify

1. Identify the most important/contentious claims in the article
2. Find which sources support those claims from the external links list
3. Fetch those sources and verify:
   - Does the source actually say what Wikipedia claims it says?
   - What is the source's own sourcing? (anonymous officials? named sources? physical evidence?)
   - Is the source a major outlet (NYT, Reuters, BBC) or a less established one?
   - Are multiple independent sources confirming the same claim, or does everything trace back to one original report?
4. Flag any claims that are:
   - Only sourced to anonymous intelligence/military officials
   - Only confirmed by a single outlet and repeated by others
   - Contradicted by physical evidence or logical analysis
   - Serving an obvious narrative interest of one party

## Step 4: Present the content with verification assessment

When presenting the article content to the user:

1. Summarize the relevant parts of the article
2. Include a **source verification section** that rates the reliability of key claims:
   - **Well-sourced**: Multiple independent outlets, named sources, physical evidence
   - **Plausible but thinly sourced**: Relies on anonymous sources or single-outlet reporting
   - **Questionable**: Contradicted by evidence, serves obvious narrative interests, or lacks independent confirmation
3. Note the source ecosystem — e.g. if most citations trace back to exile media, government statements, or intelligence leaks, say so

## Other useful API endpoints

- **Specific sections**: `action=parse&page=TITLE&prop=wikitext&section=N` to get a specific section
- **Categories**: `action=query&prop=categories&titles=TITLE`
- **Links**: `action=query&prop=links&titles=TITLE`
- **Other languages**: Replace `en.wikipedia.org` with `de.wikipedia.org`, `fr.wikipedia.org`, etc.
