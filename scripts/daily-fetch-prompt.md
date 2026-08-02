# Daily YouTube + LinkedIn Fetch

Today's date is {{TODAY}} (format YYYY-MM-DD). Use this exact string for filenames below — do not compute it yourself.

Use the Composio MCP server (`mcp__composio__*` tools) for ALL data fetching in this task. If a needed Composio tool isn't loaded yet, call `mcp__composio__COMPOSIO_SEARCH_TOOLS` first to discover it.

## Step 1 — YouTube Daily Fetch

1. Call `YOUTUBE_SEARCH_YOU_TUBE` with `q: "MaheshAIPMCommunity"`, `type: "channel"`. From the result collect:
   - Channel title
   - Channel ID
   - Then call `YOUTUBE_GET_CHANNEL_STATISTICS` with that channel ID (part `snippet,statistics`) to get subscriber count, total video count, total view count.
2. Call `YOUTUBE_SEARCH_YOU_TUBE` with `q: "MaheshAIPMCommunity"`, `type: "video"`, `order: "date"`, `maxResults: 15` to find the 15 most recent videos. If this returns 0 items (it sometimes does), instead call `YOUTUBE_LIST_CHANNEL_VIDEOS` with the channel ID and `maxResults: 15`.
3. For each of the 15 videos, use `YOUTUBE_GET_VIDEO_DETAILS_BATCH` (part `snippet,statistics`) to collect:
   - Video title
   - Video ID
   - Published date
   - View count
   - Like count

Assemble into this JSON shape:
```json
{
  "channel": {
    "channel_title": "...",
    "channel_id": "...",
    "subscriber_count": 0,
    "total_video_count": 0,
    "total_view_count": 0
  },
  "videos": [
    {"video_title": "...", "video_id": "...", "published_date": "...", "view_count": 0, "like_count": 0}
  ]
}
```

Save this JSON to: `raw/youtube/daily/{{TODAY}}.json` (relative to the current working directory, which is the Second-Brain project root — create the folder if it doesn't exist).

## Step 2 — LinkedIn Daily Fetch

Use Composio's Apify tools (do NOT make a raw curl call with an embedded token — go through Composio):

1. Run the actor `bebity/linkedin-company-posts-scraper` via `APIFY_RUN_ACTOR_SYNC_GET_DATASET_ITEMS` (or the appropriate Composio Apify tool) with input:
   ```json
   {"startUrls": ["https://www.linkedin.com/company/mahesh-ai-pm-community/"], "maxPosts": 10}
   ```
   Use a `waitForFinish`/`timeout` of at least 180 seconds so the run completes before returning.
2. If the actor rejects the input fields, fetch its real input schema (e.g. via `mcp__composio__COMPOSIO_REMOTE_BASH_TOOL` hitting `https://api.apify.com/v2/acts/bebity~linkedin-company-posts-scraper/builds/latest` and reading `inputSchema`) and retry with the correct field names — don't guess blindly.
3. From the dataset results collect:
   - Follower count
   - For each of up to 10 posts: post text, published date, reaction count, comment count, repost count

Assemble into this JSON shape:
```json
{
  "company": {
    "company_name": "...",
    "follower_count": 0
  },
  "posts": [
    {"post_text": "...", "published_date": "...", "reaction_count": 0, "comment_count": 0, "repost_count": 0}
  ]
}
```

Save this JSON to: `raw/linkedin/daily/{{TODAY}}.json` (relative to the current working directory, which is the Second-Brain project root — create the folder if it doesn't exist).

## Step 3 — Done

Print a one-line summary of what was saved (subscriber count, follower count, file paths). Do not ask any clarifying questions — run to completion autonomously.
