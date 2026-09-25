# docs

The documentation book for BOEM's offshore environmental sensitivity index products
(**marinesensitivity.org/docs**): the science (receptors, stressors, extinction risk, scoring), the
data sources, the applications (Scores, Species, and the Atlas), the API, the server, and the
release notes — rendered **once per release version** so every number a chapter prints is computed
from that release's own published tables.

## How the book is built

- **Versioned rendering.** CI (`.github/workflows/`) renders the book once per version listed in
  the release registry (`versions.json` on S3), passing `DOCS_VER`; `libs/versioned.R` resolves
  every URL, table and count for that version (`doc_app_url()`, `doc_atlas_url()`, …). Never
  hardcode a number a release could change — call the helper inside a code chunk (inline `r` outside
  a chunk silently renders as text).
- **Public vs restricted.** Public releases publish to GitHub Pages (`marinesensitivity.org/docs/
  {ver}/…`); restricted pre-releases (`access: restricted` in `versions.json`) are pushed to the
  `gh-pages-preview` branch and served only through the signed-in review host
  (`preview.marinesensitivity.org/docs/{ver}/`). The version is the URL **path** on both app hosts
  (`/v7/scores/`, `/v9/atlas/`); an old `?ver=` link is 301'd to the path form.
- **Rendering locally.** `quarto render <chapter>.qmd` in this project renders the **whole book**
  (34 files) — there is no chapter-only render — and `mermaid-format: png` routes every diagram
  through headless Chrome, which can hang indefinitely. For a quick check use `quarto check`,
  `pandoc -t html` on the chapter (expect `@fig-`/`@sec-` citeproc noise), and verify every
  cross-reference resolves to a defined `{#…}` anchor; leave the real render to CI.
- **Screenshots.** App figures are captured from real builds by the atlas repo's eyes-on harness
  (`atlas/scripts/eyes-shots.mjs`) or a scripted Playwright state; a figure captured on an older
  build must say so in its caption until recaptured (`images/atlas/desktop-places.png` was captured
  on 0.10.48 and replaced on 0.10.62).

## Writing rules

- **State only what is live.** A chapter's "as of" version must be one Pages actually serves; a
  behaviour that ships later is written "from 0.10.59" until then. The 2026-09-25 fact-check of the
  Atlas chapter found version-gated passages describing an unpushed build and two false privacy
  statements copied from an ambiguous dialog — see `CLAUDE.md` for the checking discipline.
- **Every claim about an app has a source line** in that app's repository (its CHANGELOG, a
  `docs/*.md`, or the code path). Numbers about a release come from its published tables; the
  input-registry counts in the Atlas chapter (1,873 of 2,619 `rng_iucn` inputs without a registry
  row on v7) were checked against `v7/tables/*.parquet`.
- The apps chapters describe the version-in-path URLs, the preview host, and the Atlas's own
  limitations honestly (`apps/atlas.qmd` "Known limitations (as of …)"), never a planned state.

## Repo layout

Chapters are the top-level `*.qmd`; `apps/` holds the per-app chapters; `libs/` the R helpers
(`versioned.R`) and pre-render scripts; `images/` the figures; `_extensions/`, `_quarto.yml`,
`glossary.yml`, `references.bib` the book machinery; `releases/` the per-release notes.
