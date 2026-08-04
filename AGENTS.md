# Maccheroni Agent Guide

Repository for a fully local macOS (Apple Silicon) transcription app. It
transcribes mixed-language conversations locally, including glossary injection
and speaker diarization.

## Project intent

- `PROJECT.md` is the project's intent hierarchy and append-only decision log.
  Read it before making an important judgment or completion claim.
- Sections 1-4 of `PROJECT.md` (diagnosis, pillars, non-goals, and judgment
  rules) are maintainer-owned. Renegotiate with the maintainer before editing
  them. The lower digest (sections 5-6, Decisions, and done criteria) may be
  updated as the project changes, but superseded decisions remain in the log
  with a replacement record.
- Sizable work starts from a written plan kept in local working notes outside
  the tracked tree.

## Operating notes

- Documentation, code identifiers, and commit messages are written in English.
  `README.md` is canonical and has nine localized siblings.
- This repository is public (PROJECT.md D31, 2026-08-04). Its remote is
  `github.com/gigio1023/maccheroni`. Push only when the maintainer explicitly
  asks. Never force push.
- The underlying research notes live outside this repository;
  `docs/research-digest.md` is the summary of record.
- Never commit real recordings or model caches. Test fixtures must use public
  or synthetic audio.
- The platform is fixed to macOS arm64.
- Before changing execution-scope values such as model, backend, chunk, token,
  timeout, retry, fallback, or cache settings, read
  `docs/engineering-constraint-policy.md`. Validate individual limits and their
  product-profile composition with the same calculation and tests.
- Before every commit, follow the commit conventions in `CONTRIBUTING.md`:
  an imperative English subject and a detailed technical body that records
  intent, background, the work itself, and verification, written so the body
  alone reconstructs the change and is safe to publish globally (no personal
  information or sensitive content).
- Do not add AI co-author trailers or session links to commit messages. Do not
  describe implementation authorship in public documentation or the repository
  description (decided 2026-08-04).
