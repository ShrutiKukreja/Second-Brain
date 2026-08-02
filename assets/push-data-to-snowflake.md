
# Skill: push-data-to-snowflake

Push all Second Brain project data into Snowflake via the Composio MCP Server. Idempotent — safe to run multiple times. Maintains persistent context so each run reuses existing resources and only processes new files.

---

## Configuration

| Setting | Value |
|---------|-------|
| **Snowflake Connection** | Composio MCP Server (`snowflake_basic`) |
| **Target Database** | `SECOND_BRAIN` |
| **Schema** | `PUBLIC` |
| **Create DB if missing** | Yes — execute `CREATE DATABASE IF NOT EXISTS SECOND_BRAIN` on first run |

The database name `SECOND_BRAIN` is fixed for this project. If the database does not exist in Snowflake when the skill runs, create it automatically before doing anything else. Never prompt the user to create it manually.

---

## Step 1 — Load Skill Context

Read the context file at `skill/push-data-to-snowflake-context.json`.

If the file does not exist, initialize it with this default structure and write it:

```json
{
  "database": null,
  "schema": "PUBLIC",
  "tables": {},
  "file_mappings": {},
  "archived_files": []
}
```

Fields:
- `database` — Snowflake database name (null means not yet created)
- `schema` — Snowflake schema (default `PUBLIC`)
- `tables` — map of `table_name → { columns, description, source_types }`
- `file_mappings` — map of `relative_file_path → table_name` for every file ever processed
- `archived_files` — list of relative file paths already archived

Log: `[CONTEXT] Loaded context. Database: {database}, Tables known: {count}`

---

## Step 2 — Discover Files to Process

### 2a — Scan raw/ folder
List all files in `raw/`. For each file:
- If already in `context.archived_files` → skip. Log: `[SKIP] Already archived: {path}`
- Otherwise, detect file type by extension:
  - `.json` → **JSON data file** (processed in Step 7a)
  - `.vtt`, `.srt`, `.txt`, `.pdf`, or any non-JSON extension → **Direct file** (processed in Step 7c)

Log each new file: `[RAW] Found new file: {path} (type: json | file)`

### 2b — Scan projects/ folder
Recursively list all `.md` files under `projects/`. For each file, check if it already exists in `context.file_mappings`.
- If it exists in `file_mappings` → read its current content; it may have changed, so include it for upsert.
- If it is new → include it for insert.

Log each file status: `[PROJECTS] {path} — new | known`

---

## Step 3 — Connect to Snowflake via Composio

Use `COMPOSIO_SEARCH_TOOLS` to discover Snowflake tools:
```
queries: [
  { use_case: "execute a SQL query on Snowflake" },
  { use_case: "run DDL to create a Snowflake database or table" }
]
```

Retrieve schemas for the tools returned. You will need a tool that can execute arbitrary SQL against Snowflake. Use that tool for all subsequent database operations.

Log: `[COMPOSIO] Snowflake tools ready.`

---

## Step 4 — Database Management

Check `context.database`:

### If `context.database` is null (first run):
1. Set `target_db = "SECOND_BRAIN"`
2. Execute: `CREATE DATABASE IF NOT EXISTS SECOND_BRAIN`
3. Update `context.database = "SECOND_BRAIN"` and save context immediately.
4. Log: `[DB] Created database: SECOND_BRAIN`

### If `context.database` is already set:
1. Execute: `SHOW DATABASES LIKE '{context.database}'`
2. If it exists → use it. Log: `[DB] Reusing existing database: {context.database}`
3. If it does not exist → create it, update context, save. Log: `[DB] Recreated database: {context.database}`

All subsequent SQL must use `{context.database}.{context.schema}` as the fully qualified prefix.

---

## Step 5 — Analyze Data and Design Tables at Runtime

Do NOT use any hardcoded table names or column lists. Derive everything by inspecting the actual file content at runtime.

### Rule 1 — Raw JSON files → infer tables from structure

For each new file in `raw/`:

**5.1 — Read and parse the JSON.**

**5.2 — Derive a table name from the data itself** (in priority order):
1. Look for a top-level key that hints at the entity: `source_url`, `source`, `platform`, `type`, `channel`, `entity`.
   - e.g. `"source_url": "https://www.youtube.com/..."` → platform = `youtube`
   - e.g. `"source_url": "https://www.reddit.com/..."` → platform = `reddit`
   - e.g. `"source_url": "https://www.linkedin.com/..."` → platform = `linkedin`
2. If no such key, derive from the filename: strip date suffixes, numbers, and hyphens → use as the base name.
3. Append the entity type inferred from the structure (e.g. `_posts`, `_videos`, `_channels`, `_threads`, `_articles`).
4. Uppercase and replace hyphens/spaces with underscores.
- Examples: `youtube_channels`, `youtube_videos`, `reddit_posts`, `linkedin_posts`, `substack_articles`

**5.3 — Detect whether the JSON is a single object or a collection:**
- If the top level is an array → each element is one row.
- If the top level is an object with one key whose value is an array → that array is the row set; the top-level scalar fields are metadata (store separately or as extra columns on each row).
- If the top level is a flat object → single row.

**5.4 — Inspect a sample of rows (up to 10) and infer column names and types:**

For each key in a row:
- Value is a string that looks like a date/timestamp → `TIMESTAMP`
- Value is a string that looks like a URL → `VARCHAR`
- Value is a long string (>200 chars) → `TEXT`
- Value is a short string → `VARCHAR`
- Value is an integer → `INTEGER`
- Value is a float → `FLOAT`
- Value is a boolean → `BOOLEAN`
- Value is a nested object → serialize to JSON string → `VARIANT` (Snowflake semi-structured)
- Value is an array → `VARIANT`
- Value is null → `VARCHAR` (default; update if a non-null value appears in another row)

Always add two system columns to every inferred table:
- `source_file VARCHAR` — the original filename this row came from
- `ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`

**5.5 — Identify a natural primary key for upsert:**
Look for a key whose name contains `id`, `key`, `slug`, or `url` and whose values are unique across the sample rows.
- If found → use it as the merge key.
- If multiple candidates → prefer the shortest, most stable one.
- If none found → use a combination of 2–3 fields that together uniquely identify a row.
- Record the chosen merge key(s) alongside the table definition.

**5.6 — Check if an existing table can absorb this data:**
Before deciding to create a new table, check `context.tables` for any table whose `source_types` overlap with this file's platform/entity.
- If a compatible table exists and has the same merge key → reuse it; only add any missing columns via `ALTER TABLE`.
- Only create a new table if no existing table is a reasonable fit.

### Rule 2 — Project markdown files → `PROJECT_DOCUMENTS` table

All `.md` files under `projects/` always map to a single generic table. The schema is fixed because markdown structure is uniform regardless of content:

`PROJECT_DOCUMENTS`:
- `document_id VARCHAR` — natural key: `{project_name}/{file_name}`
- `project_name VARCHAR` — folder name under `projects/`
- `file_name VARCHAR`
- `document_type VARCHAR` — inferred at runtime from the file name stem (e.g. `company-overview` → `company_overview`; anything unrecognized → `other`)
- `title VARCHAR` — first `# Heading` in the file
- `content TEXT` — full file content
- `source_path VARCHAR`
- `ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`
- `last_updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`

### Rule 3 — Direct files (transcripts, text files) → `RAW_FILES` table

All non-JSON files from `raw/` map to a single `RAW_FILES` table. This stores the full raw file content verbatim in Snowflake — e.g. Zoom transcripts (`.vtt`), meeting notes (`.txt`), subtitles (`.srt`), or any text document you want to preserve and later retrieve when building the wiki.

`RAW_FILES` schema (fixed — do not infer at runtime):
- `file_id VARCHAR` — natural key: the relative source path (e.g. `raw/zoom-2026-07-15.vtt`)
- `file_name VARCHAR` — filename only (e.g. `zoom-2026-07-15.vtt`)
- `file_type VARCHAR` — inferred from extension and content (see below)
- `source_path VARCHAR` — original relative path
- `content TEXT` — full raw text content of the file
- `char_count INTEGER` — length of content in characters
- `ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`
- `last_updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP`

**Merge key:** `file_id`

**`file_type` detection rules (check in order):**
1. `.vtt` → read first 50 characters; if starts with `WEBVTT` → `zoom_transcript`; otherwise `subtitle`
2. `.srt` → `subtitle`
3. `.txt` → `text`
4. `.md` → `markdown`
5. Anything else → `other`

---

### Rule 4 — Check existing tables before creating
For each table needed:
1. Check `context.tables` — if known, compare required columns against stored schema.
   - Columns match → reuse, no DDL.
   - New columns needed → `ALTER TABLE ... ADD COLUMN ...`, update context.
   - Never drop columns or recreate the table.
2. If not in `context.tables` → check Snowflake: `SHOW TABLES LIKE '{table_name}' IN {db}.{schema}`
   - Exists → `DESCRIBE TABLE`, store in context, apply any missing columns.
   - Does not exist → create it.

Log every decision:
- `[TABLE] Reusing existing table: {table_name}`
- `[TABLE] Creating new table: {table_name} (inferred from {file})`
- `[TABLE] Evolving schema for {table_name}: adding columns {cols}`
- `[TABLE] Merge key for {table_name}: {key_columns}`

---

## Step 6 — Create or Evolve Tables

Execute the DDL for any tables that need to be created or altered (from Step 5 decisions).

After each DDL:
1. Update `context.tables[table_name]` with:
   ```json
   {
     "columns": ["col1 TYPE", "col2 TYPE", ...],
     "description": "what this table holds",
     "source_types": ["raw_json", "project_markdown"]
   }
   ```
2. Save context immediately after every change.

---

## Step 7 — Ingest Data

Process each file using the table definitions and merge keys derived in Step 5. There are no hardcoded file names or field names here — everything is driven by what Step 5 discovered.

### 7a — Raw JSON files

For each raw JSON file:
1. Re-read the file (already parsed in Step 5).
2. Extract the row set using the structure detected in Step 5.3.
3. For each row, map its fields to the inferred column names from Step 5.4.
   - Nested objects / arrays → serialize to JSON string for `VARIANT` columns.
   - Set `source_file = {filename}`.
4. Build a `MERGE INTO {table} USING (...) ON {merge_key_condition}` statement using the merge key identified in Step 5.5.
   - WHEN MATCHED → update all non-key columns.
   - WHEN NOT MATCHED → insert all columns.
5. Execute the MERGE. Capture the rows inserted / rows updated count.

If the JSON has multiple logical entity types (e.g. top-level metadata + a nested array of items), each maps to its own table (as determined in Step 5). Run a separate MERGE for each.

Log: `[INGEST] {file} → {table_name}: {n} inserted, {m} updated`

### 7b — Project markdown files

For each `.md` file:
1. Read the full file content.
2. Extract the first `# Heading` as `title`.
3. Infer `document_type` from the file name stem at runtime (no hardcoded list — use the stem as-is, replacing hyphens with underscores; e.g. `company-overview` → `company_overview`, `course-genaipm` → `course`).
4. Set `document_id = {project_name}/{file_name}`.
5. Execute `MERGE INTO PROJECT_DOCUMENTS USING ... ON document_id = ...`:
   - WHEN MATCHED → update `content`, `last_updated_at`.
   - WHEN NOT MATCHED → insert all fields.

Log: `[INGEST] {path} → PROJECT_DOCUMENTS: upserted`

### 7c — Direct files (transcripts, text)

For each non-JSON file discovered in Step 2a:
1. Read the full file content as a UTF-8 string.
2. Build the row:
   - `file_id` = relative path (e.g. `raw/zoom-2026-07-15.vtt`)
   - `file_name` = filename only
   - `file_type` = inferred in Rule 3 (Step 5)
   - `source_path` = relative path
   - `content` = full file text
   - `char_count` = character length of content
3. Ensure `RAW_FILES` table exists. If not in `context.tables` and not found via `SHOW TABLES LIKE 'RAW_FILES'`, create it using the fixed schema from Rule 3.
4. Execute `MERGE INTO RAW_FILES USING (...) ON file_id = '{file_id}'`:
   - WHEN MATCHED → update `content`, `char_count`, `last_updated_at`
   - WHEN NOT MATCHED → insert all fields
5. Archive the file the same way as JSON files (Step 8).

Log: `[INGEST] {path} → RAW_FILES: upserted ({char_count} chars, type: {file_type})`

---

## Step 8 — Archive Processed Raw Files

For each file in `raw/` that was successfully ingested:

1. Determine archive path: replace `raw/` prefix with `Archive/raw/` and preserve the filename.
   - e.g. `raw/MaheshAIPMCommunity.json` → `Archive/raw/MaheshAIPMCommunity.json`
2. Create the `Archive/raw/` directory if it does not exist.
3. Move the file: copy content to archive path, then delete the original.
4. Add the original relative path to `context.archived_files`.
5. Save context.

Log: `[ARCHIVE] Moved {source} → {destination}`

Note: Project markdown files are NOT archived — they are source-of-truth documents that stay in `projects/`. Only `raw/` files are archived after ingestion.

---

## Step 9 — Update File Mappings in Context

For every file processed (raw or project):
1. Add or update `context.file_mappings[relative_path] = table_name`.
2. For files that map to multiple tables (e.g. a JSON that feeds both `YOUTUBE_CHANNELS` and `YOUTUBE_VIDEOS`), store as an array: `[table1, table2]`.

Save context.

---

## Step 10 — Final Context Save and Summary

Save the final `context` object to `skill/push-data-to-snowflake-context.json`.

Print a summary:
```
===== push-data-to-snowflake: Run Complete =====
Database  : {context.database}
Tables    : {list of table names}
Raw JSON ingested   : {n}
Raw files ingested  : {n}  ← direct files pushed to RAW_FILES
Raw files archived  : {n}
Raw files skipped   : {n}
Project docs upserted: {n}
Schema changes      : {list any ALTER TABLE statements run, or "none"}
===============================================
```

---

## Error Handling

- If a Composio Snowflake tool call fails → log the error with full detail, do NOT archive the file that failed, continue with remaining files.
- If context file is malformed → log a warning, reinitialize with defaults, and continue.
- If a file cannot be read → log `[ERROR] Cannot read {path}: {reason}`, skip it.
- Never exit silently. Every skip, error, and decision must be logged.

---

## Incremental Run Behavior

On subsequent runs:
- `raw/` files already in `context.archived_files` → skipped entirely.
- Project `.md` files already in `context.file_mappings` → still read and upserted (content may have changed).
- Tables already in `context.tables` with matching schema → reused with no DDL.
- Database already in `context.database` → verified and reused.

This makes the skill safe to run daily or after any new data lands in `raw/`.
