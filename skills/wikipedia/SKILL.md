---
name: wikipedia
description: Fetch and read Wikipedia articles. Use when you need to access Wikipedia content, since the WebFetch tool gets 403 errors from Wikipedia. Accepts an article title or search query as argument.
argument-hint: <article-title-or-search-query>
allowed-tools: Bash
---

# Wikipedia Access

Fetch Wikipedia articles using the MediaWiki API, which bypasses Wikipedia's bot blocking that prevents the WebFetch tool from working.

## Usage

The argument `$ARGUMENTS` is either an article title (e.g. "Strait of Hormuz") or a search query.

## Step 1: Fetch the article

Use the MediaWiki API with a browser User-Agent header. The article title should have spaces replaced with underscores.

```bash
curl -s -H "User-Agent: Mozilla/5.0" \
  "https://en.wikipedia.org/w/api.php?action=query&prop=extracts&titles=ARTICLE_TITLE&format=json&explaintext=true"
```

Parse the JSON to extract the article text:

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

## Step 3: Present the content

Summarize the relevant parts of the article for the user's question. If the article is very long, fetch it in chunks and focus on the sections most relevant to what was asked.

## Other useful API endpoints

- **Specific sections**: `action=parse&page=TITLE&prop=wikitext&section=N` to get a specific section
- **Categories**: `action=query&prop=categories&titles=TITLE`
- **Links**: `action=query&prop=links&titles=TITLE`
- **Other languages**: Replace `en.wikipedia.org` with `de.wikipedia.org`, `fr.wikipedia.org`, etc.
