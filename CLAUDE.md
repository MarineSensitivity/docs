# CLAUDE.md (docs)

Guidance for Claude Code in `MarineSensitivity/docs`. The parent conventions in `../CLAUDE.md`
apply (2-space indent, snake_case, `|>`, lowercase comments).

## Non-negotiables

- **Numbers come from the release, never from prose.** Anything a release could change (counts,
  URLs, version labels) is computed in a code chunk through `libs/versioned.R` under `DOCS_VER`.
  Inline `r` **outside** a chunk renders as literal text — the book has shipped that mistake.
- **Never render the whole book locally by accident.** `quarto render apps/atlas.qmd` renders all
  34 files here, and `mermaid-format: png` (kept on for the CI lightbox) drives headless Chrome,
  which hangs unpredictably (`../workflows/CLAUDE.md` has the diagnosis). Validate with `quarto
  check`, `pandoc -t html` on the changed chapter, and a cross-reference sweep (`@sec-…`, `@fig-…`
  against defined anchors); CI renders for real. If a render is truly needed, run it with
  `-M mermaid-format:js` and kill any orphaned `headless=new` Chrome parented to Quarto's deno.
- **Only live behaviour is present tense.** A chapter says "as of <version Pages serves>"; anything
  merged but not deployed is "from <version>". Hold a docs merge until the described build is live;
  the atlas repo's `gh-pages` commit message (`deploy: <sha>`) is the proof.
- **Fact-check before merge.** Every docs change to an app chapter gets an Opus 5.5 fact-check
  against the app's source with the live state stated in the brief (what is deployed, what the
  data currently says). The 2026-09-25 check of `apps/atlas.qmd` caught: feedback privacy sentences
  that contradicted `scripts/feedback/Code.gs` (the public issue is always filed; the email never
  enters it), a GeoPackage refusal the code cannot produce, "Reproduce in R" calling an exported
  function unreleased, and species counts with the wrong denominator. Writers cannot verify what
  they were told; give the checker the sources.
- **Screenshots carry their provenance.** A figure captured on an older build states it in the
  caption until recaptured; captions and `fig-alt` describe the pixels, not the intended state.
- **Restricted releases never reach GitHub Pages.** Their pages go to `gh-pages-preview` and the
  review host; do not link a restricted version's chapter from a public page.

## Workflow

Branch → change → `quarto check` + pandoc parse + cross-reference sweep → Opus fact-check → merge
to `main` → CI renders every version → confirm the live page (cache-busted curl for the changed
heading). The Atlas chapter's open items live in
`../workflows/.claude/plans_todo/2026-09-25 atlas app plan, round 3.md`.
