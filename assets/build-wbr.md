# Skill: build-wbr

Generate a Weekly Business Review (WBR) by fetching the latest data from Snowflake and compiling it into a structured markdown report saved under `wbr/`. Follows the Amazon-style WBR format: metrics first, narrative second, actions last.

---

## Data Source

| Setting | Value |
|---------|-------|
| **Where data comes from** | Snowflake — database `SECOND_BRAIN`, schema `PUBLIC` |
| **How to connect** | Composio MCP Server (`snowflake_basic` connection) |
| **Tables to read** | All tables in `skill/push-data-to-snowflake-context.json` |
| **If DB does not exist** | Abort: `[ERROR] Database SECOND_BRAIN not found. Run push-data-to-snowflake first.` |

This skill is **read-only** against Snowflake. All output goes to `wbr/`.

---

## Output

Each run produces one file: `wbr/YYYY-MM-DD.md` (dated to the Monday of the current week).

If a file for this week already exists → overwrite it (re-running mid-week refreshes the numbers).

---

## Step 1 — Load WBR Context

Read `skill/build-wbr-context.json`.

If it does not exist, initialize and write:
```json
{
  "last_run": null,
  "last_wbr_file": null,
  "weeks_generated": []
}
```

- `last_run` — ISO date of the last run
- `last_wbr_file` — path to the most recently generated WBR
- `weeks_generated` — list of week start dates already generated (for history)

Log: `[CONTEXT] WBR context loaded. Last run: {last_run}`

---

## Step 2 — Connect to Snowflake via Composio MCP Server

Use the **Composio MCP Server** to discover the Snowflake SQL execution tool:

```
COMPOSIO_SEARCH_TOOLS with queries:
  [{ use_case: "execute a SQL query on Snowflake" }]
```

Call `COMPOSIO_GET_TOOL_SCHEMAS` on the returned slug to load the full input schema.

Log: `[COMPOSIO] Snowflake SQL tool ready: {tool_slug}`

If no tool found → abort:
`[ERROR] No Snowflake tool available via Composio MCP. Ensure snowflake_basic connection is active.`

---

## Step 3 — Establish Time Windows

Calculate the two comparison windows used throughout all queries:

```
THIS_WEEK_START  = Monday of the current ISO week  (e.g. 2026-07-13)
THIS_WEEK_END    = today
LAST_WEEK_START  = Monday of the previous ISO week (e.g. 2026-07-06)
LAST_WEEK_END    = Sunday of the previous ISO week (e.g. 2026-07-12)
```

All metric queries use these windows for week-over-week (WoW) comparison.

Log: `[WBR] This week: {THIS_WEEK_START} → {THIS_WEEK_END}`
Log: `[WBR] Last week: {LAST_WEEK_START} → {LAST_WEEK_END}`

---

## Step 4 — Fetch Metrics from Snowflake

Read `skill/push-data-to-snowflake-context.json` to get the list of available tables. Then run the queries below for each relevant table found. Skip any query whose table does not exist.

### 4a — YouTube Channel Metrics

```sql
-- Latest channel snapshot
SELECT subscriber_count, video_count, view_count, ingested_at
FROM SECOND_BRAIN.PUBLIC.YOUTUBE_CHANNELS
ORDER BY ingested_at DESC
LIMIT 2
```

```sql
-- Videos published this week
SELECT video_id, title, published_at, topic_theme
FROM SECOND_BRAIN.PUBLIC.YOUTUBE_VIDEOS
WHERE published_at >= '{THIS_WEEK_START}'
ORDER BY published_at DESC
```

```sql
-- Videos published last week
SELECT video_id, title, published_at, topic_theme
FROM SECOND_BRAIN.PUBLIC.YOUTUBE_VIDEOS
WHERE published_at >= '{LAST_WEEK_START}' AND published_at < '{THIS_WEEK_START}'
ORDER BY published_at DESC
```

```sql
-- Top themes this week by video count
SELECT topic_theme, COUNT(*) as video_count
FROM SECOND_BRAIN.PUBLIC.YOUTUBE_VIDEOS
WHERE published_at >= '{THIS_WEEK_START}'
GROUP BY topic_theme
ORDER BY video_count DESC
```

### 4b — LinkedIn Activity Metrics

```sql
-- Profile snapshot (followers)
SELECT name, followers, connections, ingested_at
FROM SECOND_BRAIN.PUBLIC.LINKEDIN_PROFILES
ORDER BY ingested_at DESC
LIMIT 1
```

```sql
-- Posts this week
SELECT post_id, text_snippet, topic_theme, likes, comments, reposts, published_at
FROM SECOND_BRAIN.PUBLIC.LINKEDIN_POSTS
WHERE published_at >= '{THIS_WEEK_START}'
ORDER BY published_at DESC
```

```sql
-- Posts last week
SELECT post_id, text_snippet, topic_theme, likes, comments, reposts, published_at
FROM SECOND_BRAIN.PUBLIC.LINKEDIN_POSTS
WHERE published_at >= '{LAST_WEEK_START}' AND published_at < '{THIS_WEEK_START}'
ORDER BY published_at DESC
```

```sql
-- Top post this week by total engagement
SELECT post_id, text_snippet, (likes + comments + reposts) AS total_engagement
FROM SECOND_BRAIN.PUBLIC.LINKEDIN_POSTS
WHERE published_at >= '{THIS_WEEK_START}'
ORDER BY total_engagement DESC
LIMIT 1
```

### 4c — Project Documents Activity

```sql
-- Documents updated this week
SELECT project_name, file_name, document_type, last_updated_at
FROM SECOND_BRAIN.PUBLIC.PROJECT_DOCUMENTS
WHERE last_updated_at >= '{THIS_WEEK_START}'
ORDER BY last_updated_at DESC
```

### 4d — Competitor Pulse (if table exists)

```sql
-- Any competitor data ingested this week
SELECT *
FROM SECOND_BRAIN.PUBLIC.MAVEN_COMPETITORS
WHERE ingested_at >= '{THIS_WEEK_START}'
```

Log each query result: `[FETCH] {metric_name}: {n} rows`

---

## Step 5 — Compute WoW Deltas

For each metric pair (this week vs. last week), compute:
- **Absolute delta**: `this_week_value - last_week_value`
- **% change**: `((this - last) / last) * 100` rounded to 1 decimal
- **Direction indicator**: `▲` (positive), `▼` (negative), `—` (no change)

Metrics to delta:
| Metric | This Week | Last Week | Delta |
|--------|-----------|-----------|-------|
| YouTube videos published | count | count | ▲/▼/— |
| LinkedIn posts published | count | count | ▲/▼/— |
| LinkedIn total engagement | sum(likes+comments+reposts) | same | ▲/▼/— |
| Avg engagement per post | total_engagement / post_count | same | ▲/▼/— |
| Subscriber count | latest snapshot | prev snapshot | ▲/▼/— |
| Project docs updated | count | count | ▲/▼/— |

If last week data is missing for a metric → show `N/A` for delta.

---

## Step 6 — Generate the WBR Document

Write `wbr/{THIS_WEEK_START}.md` using this structure:

---

```markdown
---
week: {THIS_WEEK_START}
generated: {today}
tables_used: [{list of tables queried}]
---

# Weekly Business Review — Week of {THIS_WEEK_START}

> Auto-generated by the build-wbr skill from Snowflake (SECOND_BRAIN). Do not edit manually.

---

## Executive Summary

{3–5 bullet points synthesizing the most important things that happened this week across all channels. Be specific — include numbers. Example: "Published 3 YouTube videos, 2 more than last week, with Spec-Based Development as the top theme." Flag anything that moved significantly (>20% WoW change).}

---

## Metrics Scorecard

| Metric | This Week | Last Week | WoW Change |
|--------|-----------|-----------|------------|
| YouTube videos published | {n} | {n} | {▲/▼ n%} |
| YouTube subscriber count | {n} | {n} | {▲/▼ n} |
| LinkedIn posts published | {n} | {n} | {▲/▼ n%} |
| LinkedIn total engagement | {n} | {n} | {▲/▼ n%} |
| Avg engagement per post | {n} | {n} | {▲/▼ n%} |
| Project docs updated | {n} | {n} | {▲/▼ n} |

---

## YouTube

### Videos Published This Week ({n} total)
{For each video: bullet with title, publish date, theme}

### Top Theme This Week
{Most common topic_theme among videos published this week, with count}

### Videos Published Last Week ({n} total)
{Same format — for comparison context}

---

## LinkedIn

### Posts This Week ({n} total)
{For each post: bullet with text_snippet (first 100 chars), engagement breakdown: 👍 likes / 💬 comments / 🔁 reposts}

### Top Post This Week
> "{text_snippet}"
> 👍 {likes} · 💬 {comments} · 🔁 {reposts} · Total: {n}

### Engagement Summary
- Total engagement this week: {n}
- Avg per post: {n}
- WoW change: {▲/▼ n%}

---

## Projects

### Documents Updated This Week
{For each doc: bullet with project_name / file_name / document_type — or "No documents updated this week."}

---

## Competitor Pulse

{If competitor data was ingested this week → summarize any new entrants or changes observed.}
{If no new competitor data → "No new competitor data ingested this week."}

---

## Highlights

{2–4 bullets: what went well this week? Derive from the data — e.g. high engagement post, strong video output, new project docs created.}

---

## Lowlights

{2–4 bullets: what underperformed or is worth watching? Derive from data — e.g. low engagement week, no videos published, subscriber count flat.}

---

## Open Questions

{1–3 questions the data raises but cannot answer alone. Examples: "Engagement was high on the spec-based dev post — is this a topic to double down on?", "No YouTube videos this week — planned or unplanned?"}

---

## Actions for Next Week

{3–5 concrete action items derived from the highlights/lowlights. Be specific. Example: "Publish at least 2 YouTube videos on Agentic AI theme given strong engagement last week." Leave blank if data is insufficient to suggest actions.}

---

*Sources: Snowflake / SECOND_BRAIN.PUBLIC — {list tables used} | Generated: {today}*
```

---

Log: `[WBR] Written: wbr/{THIS_WEEK_START}.md`

---

## Step 7 — Save Context

Update `skill/build-wbr-context.json`:
- Set `last_run` to today's date.
- Set `last_wbr_file` to `wbr/{THIS_WEEK_START}.md`.
- Append `THIS_WEEK_START` to `weeks_generated` (if not already present).

Save the file.

---

## Step 8 — Print Summary

```
===== build-wbr: Run Complete =====
WBR file     : wbr/{THIS_WEEK_START}.md
Week         : {THIS_WEEK_START} → {THIS_WEEK_END}
Tables used  : {list}
Metrics      : {n} computed
====================================
```

---

## Incremental / Re-run Behavior

- Running the skill again within the same week **overwrites** the existing WBR for that week with fresh data — this is intentional (mid-week refresh).
- Running on a new week creates a new file — previous weeks are never modified.
- If a table has no data for the current window → its section shows "No data available for this period" rather than erroring.
- Missing tables (not yet ingested) → skip that section silently, note in the Sources line which tables were absent.

---

## Rules

1. **Numbers must come from Snowflake.** Never fabricate or estimate metrics.
2. **WoW deltas are mandatory** for every metric row — use `N/A` only if last week truly has no data.
3. **Highlights and Lowlights are derived from data**, not invented.
4. **Executive Summary is written last** — after all sections are filled in.
5. **One file per week.** Never combine multiple weeks into one file.
