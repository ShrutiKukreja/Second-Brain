# Skill: build-wiki

Build and maintain a structured wiki inside `wiki/` by compiling data fetched from Snowflake. Follows Karpathy's LLM Wiki pattern: raw sources are immutable, the LLM acts as a compiler that synthesizes them into structured, cross-linked markdown pages. You rarely write wiki pages manually — this skill writes them for you.

> "Obsidian is the IDE; the LLM is the programmer; the wiki is the codebase." — Andrej Karpathy

---

## Data Source

| Setting | Value |
|---------|-------|
| **Where data comes from** | Snowflake — database `SECOND_BRAIN`, schema `PUBLIC` |
| **How to connect** | Composio MCP Server (`snowflake_basic` connection) |
| **Tables to read** | All tables listed in `skill/push-data-to-snowflake-context.json` |
| **If DB does not exist** | Abort and log `[ERROR] Database SECOND_BRAIN not found. Run push-data-to-snowflake first.` |

This skill is **read-only** against Snowflake. It never writes or modifies any Snowflake table. All writes go to the local `wiki/` folder only.

---

## Core Philosophy (Read This First)

This is not summarization. This is **compilation**.

- Summarization loses detail.
- Compilation restructures raw information into a consistent, cross-linked format that preserves key details, resolves contradictions across sources, and builds a coherent ontology.

Every time this skill runs:
- New data from Snowflake gets compiled into wiki pages.
- Existing pages get updated if the underlying data changed.
- Cross-links between related pages are added or strengthened.
- The master index is regenerated.

The wiki becomes denser and more connected with every run. That is the goal.

---

## Wiki Folder Structure

```
wiki/
  index.md                  ← master index, auto-generated
  people/                   ← one page per real person
  companies/                ← one page per company or org
  products/                 ← one page per product, course, or tool
  topics/                   ← concept pages: themes, frameworks, ideas
  content/                  ← one page per content channel or corpus
```

These folders are fixed. All pages go into one of them. If a new entity type emerges (e.g. "events"), create a new subfolder.

---

## Wiki Page Format (Every Page Must Follow This)

```markdown
---
title: {Human-readable title}
type: {person | company | product | topic | content}
tags: [{tag1}, {tag2}]
sources: [{snowflake_table: row_id}, ...]
last_compiled: {YYYY-MM-DD}
---

# {Title}

{2-3 sentence synthesis: what this is, why it matters in this knowledge base}

## {Section 1}
...

## {Section N}
...

## Related
- [[{wiki-page-slug}]] — {one-line reason for the link}
- [[{wiki-page-slug}]] — {one-line reason for the link}

## Sources
- {Snowflake table}: {natural key or description}
```

Rules:
- Use `[[page-slug]]` syntax for all internal cross-links (Obsidian-compatible).
- `sources` frontmatter lists every Snowflake record that contributed to this page.
- `last_compiled` is today's date — update it every time the page is rewritten.
- Sections are determined by the data, not hardcoded. Use what makes sense for the entity.

---

## Step 1 — Load Wiki Context

Read `skill/build-wiki-context.json`.

If it does not exist, initialize and write:
```json
{
  "last_run": null,
  "table_watermarks": {},
  "pages": {},
  "entity_map": {}
}
```

Fields:
- `last_run` — ISO date of the last successful run
- `table_watermarks` — tracks what was already fetched per table:
  ```json
  {
    "YOUTUBE_VIDEOS": {
      "last_fetched_at": "2026-07-15T10:00:00Z",
      "row_count": 228
    },
    "PROJECT_DOCUMENTS": {
      "last_fetched_at": "2026-07-15T10:00:00Z",
      "row_count": 8
    }
  }
  ```
- `pages` — map of `wiki_path → { last_compiled, source_row_ids }` where `source_row_ids` is the list of Snowflake row keys that fed this page
- `entity_map` — map of entity name/id → wiki page path (for cross-linking)

Log: `[CONTEXT] Wiki context loaded. Last run: {last_run}, Tables tracked: {count}, Known pages: {count}`

---

## Step 2 — Connect to Snowflake via Composio MCP Server

Use the **Composio MCP Server** to discover and connect to Snowflake tools:

```
COMPOSIO_SEARCH_TOOLS with queries:
  [
    { use_case: "execute a SQL query on Snowflake" },
    { use_case: "run a SELECT query on a Snowflake table" }
  ]
```

From the results, call `COMPOSIO_GET_TOOL_SCHEMAS` on the returned tool slugs to load their full input schemas.

Identify the tool that executes arbitrary SQL against Snowflake (typically a tool with a `query` or `sql` parameter). This is the **only tool** used for all Snowflake reads in this skill.

Log: `[COMPOSIO] Snowflake SQL tool ready: {tool_slug}`

If no Snowflake tool is found → abort and log:
`[ERROR] No Snowflake tool available via Composio MCP. Ensure the snowflake_basic connection is active.`

---

## Step 3 — Fetch Only New Data from Snowflake

Read `skill/push-data-to-snowflake-context.json` to get `database`, `schema`, and the list of known tables.

For each table, check `context.table_watermarks[table_name]`:

### If the table has NO watermark (first time seeing this table):
Fetch everything:
```sql
SELECT * FROM {database}.{schema}.{table_name}
ORDER BY ingested_at ASC
```
Log: `[SNOWFLAKE] First fetch for {table_name}: {n} rows`

### If the table HAS a watermark (`last_fetched_at` exists):
Fetch only rows ingested after the last run. Use `ingested_at` for most tables, `last_updated_at` for `PROJECT_DOCUMENTS`:

```sql
-- Standard tables
SELECT * FROM {database}.{schema}.{table_name}
WHERE ingested_at > '{last_fetched_at}'
ORDER BY ingested_at ASC

-- For PROJECT_DOCUMENTS specifically
SELECT * FROM {database}.{schema}.PROJECT_DOCUMENTS
WHERE last_updated_at > '{last_fetched_at}'
ORDER BY last_updated_at ASC
```

Log: `[SNOWFLAKE] {table_name}: {n} new rows since {last_fetched_at}`
Log: `[SKIP] {table_name}: 0 new rows — skipping`

### Special case — `RAW_FILES` table

The `RAW_FILES` table stores full verbatim file content (Zoom transcripts, meeting notes, etc.). Fetch it with the same watermark pattern as other tables, but note:

- The `content` column is the primary payload — it is the full text of the original file, not a metadata field.
- Each row is one file, not one data point.
- To fetch **all new files** since last run:
  ```sql
  SELECT file_id, file_name, file_type, content, char_count, ingested_at
  FROM SECOND_BRAIN.PUBLIC.RAW_FILES
  WHERE ingested_at > '{last_fetched_at}'
  ORDER BY ingested_at ASC
  ```
- To fetch **a specific file** by its source path at any time:
  ```sql
  SELECT content
  FROM SECOND_BRAIN.PUBLIC.RAW_FILES
  WHERE file_id = 'raw/zoom-2026-07-15.vtt'
  ```
- To fetch **all files of a given type** (e.g. all Zoom transcripts):
  ```sql
  SELECT file_id, file_name, content
  FROM SECOND_BRAIN.PUBLIC.RAW_FILES
  WHERE file_type = 'zoom_transcript'
  ORDER BY ingested_at DESC
  ```

Store `RAW_FILES` rows in `new_rows['RAW_FILES']` like any other table. The `content` field is available in memory for Step 4 entity discovery and Step 6 compilation — do NOT re-query Snowflake for it.

### After fetching:
- Store the new rows in memory keyed by table name: `new_rows[table_name] = [...]`
- Record the highest `ingested_at` (or `last_updated_at`) value seen as the pending new watermark for this table — do NOT write it to context yet (save only after successful wiki writes in Step 8)
- If a table has 0 new rows → exclude it from further processing entirely

Log total: `[SNOWFLAKE] Fetch complete. Tables with new data: {n}, Total new rows: {n}`

---

## Step 4 — Discover Entities from the Data

Scan all fetched rows and identify distinct real-world entities. Use these rules:

### 3.1 — People
Any row that represents a person (profile, author, instructor, founder):
- Source signal: table name contains `profile`, `person`, `author`; or fields like `name`, `profile_id`, `profile_url`, `followers`
- One wiki page per unique person
- Canonical ID: `profile_id` or derived from `profile_url`
- Target file: `wiki/people/{slug}.md`

### 3.2 — Companies / Organisations
Any row or set of rows that describes a company, startup, institute, or brand:
- Source signal: fields like `company`, `current_company`, or data from `PROJECT_DOCUMENTS` where `document_type = 'company_overview'`
- One wiki page per unique company
- Target file: `wiki/companies/{slug}.md`

### 3.3 — Products / Courses
Any row describing a product, platform, tool, or course:
- Source signal: `PROJECT_DOCUMENTS` where `document_type IN ('product', 'course')`, or any table with `product_name`, `course_id`
- One wiki page per product or course
- Target file: `wiki/products/{slug}.md`

### 3.4 — Topics / Concepts
Extract recurring themes, frameworks, and ideas from:
- `topic_theme` column in YouTube/video tables
- `text_snippet` and `post` fields in LinkedIn/social tables
- Titles and content of `PROJECT_DOCUMENTS` pages
- Deduplicate and normalize: "Agentic AI Systems & Architecture" and "Agentic AI" → same topic
- One wiki page per distinct concept
- Target file: `wiki/topics/{slug}.md`

### 3.5 — Content Channels
Any row representing a content source corpus (YouTube channel, LinkedIn profile feed, newsletter):
- Source signal: table name contains `channel`, `feed`, `newsletter`; or top-level `channel` object in a row
- One wiki page per channel/corpus
- Target file: `wiki/content/{slug}.md`

### 3.6 — RAW_FILES rows (transcripts, text documents)

For each row in `new_rows['RAW_FILES']`:

**If `file_type = 'zoom_transcript'`:**
- Read the `content` field (the full VTT/transcript text).
- Extract:
  - **Speakers** — lines with `<v Speaker Name>` tags in VTT, or `Speaker:` prefixes in plain text → each unique speaker is a candidate for a `people/` wiki page.
  - **Topics discussed** — recurring keywords and phrases → candidates for `topics/` pages.
  - **Decisions and action items** — sentences containing "we decided", "action item", "follow up", "next step" → record under a `decisions` section on the relevant wiki page.
  - **Meeting title / date** — infer from `file_name` (e.g. `zoom-2026-07-15-product-sync.vtt` → title: "Product Sync", date: 2026-07-15).
- Create or update a wiki page at `wiki/content/{file_name-slug}.md` that synthesizes the full transcript into structured sections (Overview, Speakers, Key Topics, Decisions & Action Items, Raw Excerpts).

**If `file_type = 'text'` or `'markdown'`:**
- Extract entities (people, companies, topics) mentioned in the `content` field.
- Create or update the relevant wiki pages with the new information.

Log: `[ENTITY] raw_file: {file_name} ({file_type}) → {wiki_path}`

Log every entity discovered: `[ENTITY] {type}: {name} → {wiki_path}`

Register all discovered entities in `context.entity_map` keyed by name and any known aliases.

---

## Step 5 — Decide What to Write or Update

For each entity discovered in Step 4, determine if its wiki page needs recompiling:

### Case A — New entity (page does not exist in `context.pages`):
→ Compile. Log: `[NEW] {wiki_path} — first time seen`

### Case B — Existing entity, new rows touch it:
Check whether any row in `new_rows` (fetched in Step 3) belongs to this entity:
- A row belongs to this entity if its natural key (profile_id, channel_id, document_id, etc.) matches the entity's ID, OR the entity name appears in the row's text fields.
- If yes → recompile, merging new rows with the existing wiki page content.
- Log: `[UPDATE] {wiki_path} — {n} new rows from {table_name}`

### Case C — Existing entity, no new rows touch it:
→ Skip entirely. Do not reread from Snowflake, do not rewrite the file.
→ Log: `[SKIP] {wiki_path} — no new data since {last_compiled}`

### Summary before compiling:
Print a pre-flight list:
```
[PLAN] Pages to write : {n}
[PLAN] Pages to update: {n}
[PLAN] Pages to skip  : {n}
```

---

## Step 6 — Compile Wiki Pages

For each page that needs writing:

### 5.1 — Gather all source rows for this entity
Pull every row across all tables that relates to this entity (by ID, name, or slug match).

### 5.2 — Synthesize, do not summarize
Write the page content by:
- Reading across all source rows as a whole
- Identifying what is factual, what is context, what is a theme
- Writing prose that a reader would find more useful than the raw data
- Preserving specific numbers, dates, URLs, and proper nouns — do not paraphrase away concrete facts

### 5.3 — Determine sections dynamically
Do not use a fixed template per entity type. Look at the data and decide what sections are warranted. Examples:
- A person page might have: Overview, Career, Current Work, Content & Teaching, Key Ideas, Metrics
- A company page might have: Overview, Problem They Solve, Product, Target Market, Positioning
- A topic page might have: Definition, Why It Matters, Key Frameworks, Related Content, Open Questions
- A content channel page might have: Overview, Statistics, Recurring Themes, Top Content, Related People

### 5.4 — Add cross-links
For every other entity in `context.entity_map` that is referenced by name in this page's content:
- Add a `[[slug]]` backlink inline where it appears.
- Add it to the `## Related` section with a one-line reason.

### 5.5 — Transcript pages: section structure

When the source is a `RAW_FILES` row (especially `zoom_transcript`), use this section structure:

```markdown
## Overview
{1-2 sentences: who met, when, what was discussed}

## Speakers
- **{Name}** — {role if known, or inferred from context}

## Key Topics
- {topic} — {one-line summary of what was said}

## Decisions & Action Items
- [ ] {action item} — owner: {name if mentioned}

## Raw Excerpts
> "{notable quote or passage}" — {speaker}
```

Do not paste the full transcript verbatim — synthesize it. Preserve exact quotes only when they are notable decisions, commitments, or highly specific facts.

### 5.6 — Write the file
Write the compiled page to its target path. Create subdirectories as needed.

Log: `[WRITE] {wiki_path} ({n} words, {n} cross-links)`

---

## Step 7 — Generate the Master Index

Write `wiki/index.md`:

```markdown
---
title: Second Brain — Wiki Index
last_compiled: {date}
total_pages: {n}
---

# Second Brain Wiki

> Compiled by the build-wiki skill. Do not edit manually.

## People
- [[{slug}]] — {one-line description}

## Companies
- [[{slug}]] — {one-line description}

## Products
- [[{slug}]] — {one-line description}

## Topics
- [[{slug}]] — {one-line description}

## Content
- [[{slug}]] — {one-line description}
```

Log: `[INDEX] wiki/index.md written. Total pages: {n}`

---

## Step 8 — Save Context

Only update context after all wiki writes have succeeded. This ensures the watermark is never advanced past data that wasn't actually compiled.

Update `skill/build-wiki-context.json` with:

1. **`last_run`** — set to today's ISO date.

2. **`table_watermarks`** — for every table that had new rows fetched in Step 3, advance the watermark:
   ```json
   "YOUTUBE_VIDEOS": {
     "last_fetched_at": "{highest ingested_at seen this run}",
     "row_count": "{previous count + new rows fetched}"
   }
   ```
   Tables that had 0 new rows → leave their watermark unchanged.

3. **`pages`** — for every page written or updated:
   ```json
   "wiki/people/mahesh-yadav.md": {
     "last_compiled": "2026-07-15",
     "source_row_ids": ["initmahesh", "post_001", "post_002", ...]
   }
   ```
   Pages that were skipped → leave their entry unchanged.

4. **`entity_map`** — add any new entity name/alias → wiki path mappings discovered this run.

Save the file. Log: `[CONTEXT] Context saved. Watermarks advanced for {n} tables.`

---

## Step 9 — Print Run Summary

```
===== build-wiki: Run Complete =====
Pages written   : {n}
Pages updated   : {n}
Pages skipped   : {n} (no changes)
Cross-links added: {n}
Total wiki pages : {n}
Wiki root        : wiki/
====================================
```

---

## Incremental Behavior

The skill tracks three things to avoid reprocessing data:

| What is tracked | Where stored | How used |
|----------------|-------------|----------|
| Per-table `last_fetched_at` timestamp | `table_watermarks` in context | Step 3 uses `WHERE ingested_at > last_fetched_at` — never fetches old rows again |
| Per-page `source_row_ids` list | `pages` in context | Step 5 checks if any newly fetched row belongs to this entity — skips if none do |
| Per-table `row_count` | `table_watermarks` in context | Sanity check — if count dropped, something was deleted upstream, log a warning |

**On first run:** all rows fetched, all entities compiled, all watermarks set.

**On every subsequent run:**
- Only rows newer than `last_fetched_at` are fetched — could be 0 rows on a quiet day.
- Only wiki pages touched by those new rows are recompiled — the rest are skipped entirely.
- Watermarks advance only after successful writes — a crash mid-run is safe to retry.
- New entities (e.g. a new person or company appearing in data) always get compiled regardless.

---

## Rules the Compiler Must Follow

1. **Never edit `raw/` files.** They are immutable source material.
2. **Never hardcode entity names.** Discover everything from the data.
3. **Prefer depth over breadth.** A short page on a real entity is better than a long page stuffed with padding.
4. **Concrete facts stay.** Numbers, dates, URLs, quotes — preserve them exactly.
5. **Every claim traces to a source.** The `sources` frontmatter is not optional.
6. **Cross-link liberally.** The value of the wiki compounds with every link added.
7. **Sections follow the data.** Never add a section heading with no content.
