Run an incremental push-data-to-snowflake job for this repo (Second-Brain), using Composio MCP tools. Snowflake connection: snowflake_basic; database SECOND_BRAIN, schema PUBLIC (both already exist from prior runs).

Step 1 — Load state and scan for new files:
- Read skill/push-data-to-snowflake-context.json. It tracks tables{}, file_mappings{}, and archived_files[] from prior runs. If missing, treat as empty (database=SECOND_BRAIN, schema=PUBLIC, tables={}, file_mappings={}, archived_files=[]).
- Scan for files NOT already present in context.archived_files (the merge key for "already pushed"):
  - raw/youtube/**/*.json
  - raw/linkedin/**/*.json
  - wiki/**/*.md in this repo's own wiki/ folder — skip .DS_Store and any non-markdown file. Wiki files use file_mappings (not archived_files, since wiki files aren't archived) to detect "already pushed": if a wiki file's relative path is already a key in context.file_mappings AND its content is unchanged, skip it; if new or changed, push it (upsert by re-inserting/overwriting).
- If there is truly nothing new anywhere, skip straight to the summary and log exactly: "No new files — nothing to push."

Step 2 — Push new JSON files (YouTube + LinkedIn):
For each new raw JSON file: parse it, detect source (youtube vs linkedin) from path/content. Reuse the existing tables from context.tables if compatible (YOUTUBE_CHANNELS, YOUTUBE_VIDEOS, LINKEDIN_COMPANIES, LINKEDIN_POSTS were already created in a prior run with these columns — read the context file for exact column lists before writing SQL). Only CREATE TABLE IF NOT EXISTS if no compatible table exists yet. INSERT each row (channel/company as one row, each video/post as one row), including source_file and a pushed_at TIMESTAMP = CURRENT_TIMESTAMP(). Log: file name, table(s), row count.

Step 3 — Push new/changed wiki markdown files:
Reuse or create a WIKI_DOCUMENTS table (columns: document_id VARCHAR, folder VARCHAR, file_name VARCHAR, title VARCHAR, content TEXT, source_path VARCHAR, pushed_at TIMESTAMP — this table already exists from a prior run, reuse it). document_id = relative path under wiki/ (e.g. campaigns/README.md). Insert new rows for new/changed files. Log filename and confirm insert.

Step 4 — Archive pushed raw files:
For every raw/ file successfully pushed this run (JSON — NOT wiki files, wiki files are never archived), move it from raw/... to Archive/raw/... preserving the subfolder structure (e.g. raw/youtube/daily/2026-08-03.json -> Archive/raw/youtube/daily/2026-08-03.json). Create destination directories as needed.

Step 5 — Update context file:
Add every newly pushed raw file's relative path to context.archived_files. Add/update file_mappings for every file processed (raw and wiki) to its target table name(s). Update context.tables if any new table was created. Save the context file back to skill/push-data-to-snowflake-context.json.

Step 6 — Commit and push:
Commit all changes (archived file moves, context file update) to the main branch with a commit message like "Daily Snowflake push YYYY-MM-DD". If nothing changed (no new files), skip the commit.

Step 7 — Print a summary log with: current date/time this job ran, how many new files were found, how many pushed successfully, which Snowflake tables were created or updated, any files that failed with the reason (do not archive a file that failed to push — leave it in raw/ for the next run to retry), and the "No new files — nothing to push." line if nothing was found.

Do this fully autonomously without asking questions. If the Snowflake Composio connection is not active/expired, log the error clearly in the summary and stop.