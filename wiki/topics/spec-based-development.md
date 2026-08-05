---
title: Spec-Based Development
type: topic
tags: [claude-code, methodology, ai-pm]
sources: [LINKEDIN_POSTS: "Vibe coding was the move in early 2025...", LINKEDIN_POSTS: "Here's what I see with data engineers using Claude Code..."]
last_compiled: 2026-08-05
---

# Spec-Based Development

A methodology [[mahesh-yadav]] teaches as the successor to "vibe coding": write a spec before generating code, so AI coding tools like [[claude-code]] build reliably instead of drifting.

## Definition

Per Mahesh's LinkedIn post (2026-07-09): "Vibe coding was the move in early 2025. Now it's table stakes, but it only gets you 80% of the way to production. Spec-based development is the answer." The pipeline is:

**PRD → Engineering Design → Spec → Code → Deploy**

## Why It Matters

A related post (2026-07-06) frames the failure mode directly: "data engineers using Claude Code... build pipelines without specs, and one change upstream breaks everything downstream. The fix: spec your entire pipeline upfront (ingestion, cleaning, transformation, analytics, dashboard) so Claude Code builds each stage reliably."

## Where It's Taught

- **[[claude-bootcamp]]**, Week 2 ("Technical Depth") — spec-based development with Claude Code, plus PRDs, Design.md, and agent plans in engineering workflows.
- Promoted publicly via a dedicated "Build and Ship with Claude Code" free session (Session 2: "spec'ing a data pipeline end to end... going from raw CSV/API to a working analytics dashboard").

## Open Questions

- The corpus doesn't specify what distinguishes a "Spec" from an "Engineering Design" document in Mahesh's pipeline — likely covered in bootcamp live sessions not captured in this data.

## Related
- [[claude-code]] — the tool this methodology is built around
- [[claude-bootcamp]] — course where this is taught in depth
- [[mahesh-yadav]] — originator of this framing in the corpus
- [[agentic-ai]] — broader subject this methodology serves

## Sources
- LINKEDIN_POSTS: "Vibe coding was the move in early 2025..." (2026-07-09), "Here's what I see with data engineers using Claude Code..." (2026-07-06)
