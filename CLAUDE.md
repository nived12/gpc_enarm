# GPCEnarm

An ENARM simulator built on Mexico's public Guías de Práctica Clínica. Clinical cases are
generated from graded GPC recommendations, and every answer cites the recommendation it
came from. Free for a granted-premium list, paid for everyone else.

The full build plan lives outside the repo at `../initial_plan.md`
(`/Users/nived/enarm_simulador/initial_plan.md`), mirrored to
`~/.claude/plans/i-want-to-create-crispy-stardust.md`.

## Non-negotiables

**Nothing reaches production without the owner's yes, asked for each time.** Railway
deploys `main` automatically, so a `git push` to `main` is a production deploy. The same
goes for anything else that changes the live site: setting or removing Railway
variables (which redeploys), redeploying or restarting a service, and writing to the
production database or running tasks in its console. Commit locally, say what would go
out, and wait for the owner to agree. One approval covers that one action, not the
next.

**Merging needs the owner's yes too.** Work on a branch or worktree stays there until
the owner agrees to merge it into `main`, even locally, and no branch is pushed to
GitHub without asking.

**Code is English. The UI is Spanish.** Every identifier — class, table, column, enum
value, route, partial, i18n key, comment — is English. Spanish exists only as *values* in
`config/locales/es.yml`. Domain terms get translated, not transliterated: `pass_number`
not `vuelta`, `catalog_key` not `clave`, `case_workshop` not `taller_casos`, `attending`
not `adscrito`, `core` not `troncal`. Someone reading this code in six months should not
need Spanish; the student using it should not see a word of English.

**Names must mean something to a reader who has not seen the source system.** `DDIMBE` is
a path segment on the government site and is not spelled out anywhere, even on that site.
So the fetchers are `Gpc::LiveCatalogFetcher` and `Gpc::ArchiveCatalogFetcher`, and the
`Guideline#source` enum is `live_site` / `web_archive`. If a name needs a glossary, it is
the wrong name.

**Never guess.** If the behaviour of a gem, an API or a config is not certain, read the
source in the bundle or fetch the docs. A plausible-looking wrong answer costs more than
the two minutes it takes to check. This applies hardest to the GPC endpoints, which are
undocumented.

**Spanish copy never assumes the reader's gender.** Write `Te damos la bienvenida`, not
`Bienvenido` or `Bienvenida`; `colega`, not `compañero`. Reach for a gender-neutral noun or
rephrase around the adjective — never `@` or `x` endings, which screen readers mangle.
Agreement with a grammatical noun is fine and unavoidable (`Contraseña actualizada`); what
is banned is agreement with *the user*. A clinical vignette's patient has whatever gender
the case calls for; that is content, not interface.

**All user-facing text goes through i18n**, and `es.yml` / `en.yml` stay key-for-key
identical — `spec/config/locales_spec.rb` enforces it. `default_locale` is `:es`, and
`rails-i18n` supplies the Spanish for everything Rails itself emits.

**Comments explain what code cannot.** A non-obvious constraint, a decision that looks
wrong until explained, the origin of a magic value. No section dividers, no narration of
what the next line does.

## Conventions

- Double quotes. Run `bundle exec rubocop -A` on changed files after every edit.
- **Service objects**: `Namespace::Doer < ApplicationService`, one public `call`, private
  `attr_reader`. Return a `Response`; never raise for expected failure. Use the `-er` noun
  form (`Questions::Generator`), never a `-Service` suffix.
  - A service that adds an error on an attribute **must expose a reader for it** —
    `Errorable#read_attribute_for_validation` sends the attribute name to the service.
    Errors on `:base` are the only ones that need no reader.
- **String enums only**, declared with an explicit hash and a `prefix:`.
- bigint PKs. jsonb with `default: {}` / `[]`, `null: false`. Money `decimal(12,2)`,
  AI cost `decimal(12,8)`.
- Jbuilder for any JSON, never inline.
- Authorize in controllers. No Pundit, no Devise, no ViewComponent, no admin gem.

## Design

Tokens live in `app/assets/stylesheets/application.tailwind.css`. The light palette is
sampled from alan.com and each borrowed value carries an `alan:` note; dark is derived from
the same indigo ramp. Alan Sans for interface, Literata for clinical vignettes, system mono
for short strings. **Do not add a colour that is not a token**, and do not use `--highlight`
anywhere except the span of a recommendation a question was generated from.

Mobile-first, 44px minimum tap targets, every list gets loading / empty / error / populated
states. The home screen is: your average, today's plan, and a button that starts the quiz.
Nothing else above the fold — including upgrade prompts.

## Rules the domain imposes on the code

The reasoning behind each of these is in the plan; what follows is only what changes how
you write code here.

**Most of the corpus has expired, and it cannot be dropped.** The live catalog holds
nothing older than 2020, and Cirugía General is almost entirely among the expired ones.
`Guideline::VALIDITY_YEARS`, `.current`, `.expired`, `.undated` and `#expired?` exist for
this. An undated guideline is never expired — unknown is not out of date. **Prefer current
guidelines when generating, and show the year on every citation.**

**A vignette carries the whole patient, not just the answer.** A real ENARM item is
150–200 words — comorbidities with durations, complete vitals with units, a systematic
examination including normal findings — and asks about one part of it. Deciding what
matters is the skill being tested, so a vignette where every fact points at the answer is
easier than the exam it simulates. `Questions::Prompt::DETAIL_LEVELS` carries
`focused` and `full_workup`; mix them, because not every real item is long.
The extra material is **realistic completeness, never misdirection** — never invent a
finding that contradicts the diagnosis.

**A vignette is set where the exam sets it.** The convocatoria frames every case in Salud
Pública, Urgencias or Medicina Familiar, drawing its content from the four troncales. A
generated case opens in one of those settings — a consultorio familiar, urgencias, a
public-health situation — not in a generic ward. **A case is filed twice**: `specialty` is
what it is about, `setting` (one of the three cross-cutting specialties, nil when unknown)
is where it happens, and the owner decided (2026-09-23) that it counts under both.
Anything that counts or filters an area goes through `ClinicalCase.in_area` /
`.count_by_area`, never `specialty_id` alone; whole-bank totals count cases, since areas
overlap. Cases without a setting are read from the stem by `questions:classify_settings`.

**The exam gives about one minute per item.** Anything that simulates exam conditions uses
that pacing, not a comfortable one; running out of time is one of the things being tested.

**`Answer#error_reason` is the student's own account of why they missed it**, not an
inference. Never derive it, never guess it from timing — an empty value means they did not
say, and weak-spot targeting has to treat that as unknown rather than as `did_not_know`.

**English is per case, never per question**, at `ENGLISH_SHARE`. A case and its questions
must be one language, and the `quote` stays in Spanish whatever the case language: the
substring gate checks it against a Spanish guideline, so an English quote fails every time.

**A guideline's own figures are the answer key, so they never appear with a question.**
Its algorithms, criteria tables and scales are reference material: shown beside the
vignette they turn an item into an open-book lookup (the pilot's case 134 showed the very
pathway its questions asked about). They belong to the explanation, after the answer —
`Recommendation#figure` finds the one a cited statement points at ("ver cuadro 2"). The
generator is told nothing about figures, and the prompt forbids questions and options
that mention one. `ClinicalCase#clinical_image` is kept for images that *are* the question
— an ECG or a film to interpret — which the GPCs do not contain; see the plan.

**The corpus files its working papers as figures too.** A GRADE appraisal is published
under "CUADRO 4" exactly like a criteria table is, so the heading decides whether a section
holds figures and the **filename** decides whether each one is medicine —
`Gpc::ImageParser::METHODOLOGY_FILE`. Never widen that filter without measuring what it
lets through.

**Only `published` cases reach students, and only `Questions::Publisher` publishes.**
A case qualifies when the verifier supported it and nobody withdrew it (`flagged`,
`retired`). The exam builder reads `status_published` and nothing else; never point a
student-facing query at `publishable` or at drafts. After a verification run, run
`questions:publish`. A second opinion can only take a live case off the bank, through
`ClinicalCase#status_after_verdict`; the verifier and the importer's verdict sync both
use it. Besides answering blind, the verifier names item-writing defects
(`Questions::Verifier::FLAWS`); a case it supports but finds one in is `flawed`, kept
off the bank and queued for review with the defect named. A new defect found by reading
cases goes in both places: a rule in `Questions::Prompt` and a code in `FLAWS`.

**Difficulty uses the exam's own vocabulary** — `low`/`medium`/`high`, rendered Baja /
Media / Alta — never a competitor's Interno/Residente/Adscrito. Score is a plain
percentage; do not weight it.

## Testing

```bash
bundle exec rspec                 # fast inner loop
bin/ci-test                       # parallel, all cores
COVERAGE=1 bin/ci-test            # + merged coverage
bin/coverage-check                # ratchet against .coverage-floor.json
bin/coverage-check --raise        # lock in an improvement, then commit the floor
```

- Request specs need an explicit `type: :request`; `infer_spec_type_from_file_location!`
  is off on purpose.
- No spec may make a live LLM call. `spec/support/llm_guard.rb` fails the suite on any
  request to a provider host.
- Coverage floor only ever moves up. It is at 99.7% line / 100% branch; keep it there.
  Prefer deleting a speculative branch to writing a spec that proves it is unreachable.
- `bundle exec rspec`, `rubocop` and `brakeman` are all green before a phase is closed.
- End-to-end specs live in `spec/system` and drive Chromium through Playwright
  (`capybara-playwright-driver`). One-time setup: `npx playwright install chromium`.
  Tag an example `viewport: :phone` for 375px and `color_scheme: :dark` for a dark system
  theme; `HEADED=1` opens a visible, slowed-down window. One file per flow a student
  depends on, each run once at the width that matters for it — not every flow at every
  width. Shared steps live in `spec/support/system_helpers.rb`; request specs carry the
  branches.

## Gotchas already paid for

- **`json` is pinned to 2.x.** json 3.0 dropped the positional-options form of
  `JSON.parse` that `ActiveSupport::JSON.decode` still calls, which breaks encrypted
  cookie decryption on every request after the first. See the Gemfile note.
- **Never link stylesheets with `stylesheet_link_tag :app`.** The symbol form globs the
  Propshaft load path and ships the raw Tailwind source to the browser. Link
  `"application"` — the built bundle — and keep `app/assets/stylesheets` in
  `config.assets.excluded_paths`.
- **A stray `public/assets` silently freezes every CSS and JS change.** Propshaft serves
  a precompiled asset in preference to `app/assets/builds`, so one `rails assets:precompile`
  run leaves a compiled copy that shadows the live build **forever** — the page renders
  fresh HTML with a stale stylesheet, which reads as "my Tailwind classes do not work"
  rather than as a caching problem. Symptom: new utilities are present in
  `app/assets/builds/application.css` but missing from what the server serves, and the
  digest in the `<link>` never changes. Fix: `rm -rf public/assets` **and restart** — the
  running server caches the resolved path, so removing the directory alone does nothing.
  `public/assets` is gitignored, so this never shows up in a diff. `bin/dev` and
  `bin/ci-test` now delete it on start; a server started any other way does not.
- **Use `bin/dev`, not `bin/rails server`.** The plain server runs no asset watcher, so
  CSS and JS changes silently do not appear.
- **`rate_limit` captures its store at class-definition time.** The test environment gives
  Action Controller a `:memory_store` of its own so limiters are testable; `rails_helper`
  clears it between examples.
- **The GPC grading strip is not a fixed grammar.** `1++ NICE Hong K, 2021` is the
  common spelling, but `SIGN D Taylor M, 2015` puts the scale first, `Muy baja GRADE …`
  has a two-word grade, and `PBP`, `C-LD` and `IIA` look like scale acronyms and are
  grades. The scale is recognised by shape, not by a list of societies — the catalog
  cites 30-odd — and `Recommendation#label` keeps the strip verbatim, so a bad split
  never loses the citation. About 11% name no scale at all; that is the authors, not us.
- **`div.separador` only means "grading strip" inside a graded section.** The anexos
  reuse it for the directory and for the tables that define the scales, so parsing
  every section manufactured 457 recommendations out of institution names. Only
  `GuidelineSection#graded?` sections are read for recommendations.
- **Sample before writing a parser, then check the whole corpus after.** Three sections
  per guideline said 1.5% of strips were unparseable; all 3,076 said 22%.
- **Most recommendations come from archived PDFs, and those are laid out, not marked
  up.** `Gpc::ArchiveRecommendationParser` reads the evidence table by column position
  and statement shape, in four steps under `Gpc::ArchiveTable` (region, layout, rows,
  grading label). When a token could be statement or grading, the statement wins:
  a lost citation is cosmetic, a lost word makes every quote of that sentence fail the
  gate. Rows extraction damaged are **dropped, never repaired** — the characters
  underneath are gone. Judge any change by running it over all 595 documents and by the
  rejection reasons of a live batch; the first live batch found three defects no
  fixture showed.
- **Sections parsed from a PDF are derived.** They point at their document through
  `source_section`, are never exported, and are rebuilt by `gpc:reparse`. Questions cite
  their recommendations, so a rebuild keeps every row whose text survived and refuses to
  delete one a question cites — never `destroy_all` a section's recommendations.
- **Generate through `Questions::GenerationRunner`, from `Guideline.generatable`.** That
  scope drops nursing guidelines (the ENARM examines physicians) and editions a newer one
  of the same number replaced. The spending cap prices calls from
  `Llm::Provider::PRICES`; changing the model means updating its price there, or the cap
  refuses to run.
- **`deepseek-flash` thinks before answering, and the thinking is billed as output.**
  Measured live 2026-09-20 on a real generation prompt: 5,682 output tokens, of which
  **4,638 were reasoning** and 1,044 were the answer. With `max_tokens: 4000` it spent the
  entire budget thinking and returned an **empty string with `finish_reason: "length"`
  and no error** — the failure mode to fear, because it looks like success.
  Pass `thinking: {type: "disabled"}` or `reasoning_effort: "none"` and it drops to zero
  reasoning tokens and still returns valid JSON — 4.4x cheaper output. Verified against
  the API, not just the docs: `reasoning_effort: "minimal"` is silently mapped to `"low"`
  and still thinks, so it is not a way to turn this off. Gemini Flash-Lite reports zero
  reasoning tokens on the same prompt and needs none of this.
- **Gemini rejects unknown request fields; DeepSeek accepts them.** Sending `thinking`
  to Gemini's OpenAI-compatible endpoint returns 400 "Unknown name: thinking" and the
  request never runs. Provider capabilities are declared in `Llm::Provider::PRESETS`
  and `Llm::Completion` asks before sending. Do not assume a provider ignores a field
  it does not know — test it against that provider, not against the other one.
- **The `source_quote` gate normalises whitespace and case, and must.** Extraction keeps
  the source's line breaks ("se deben evitar:\nPicos hiperóxicos") and no model
  reproduces them when quoting; models also lowercase a leading "Se" to fit the quote
  into their own sentence. Measured across two unrelated model families, those two
  accounted for **every** citation rejection in the first provider comparison — the gate
  was refusing correct quotes, not catching hallucinations. Neither normalisation changes
  a word, so a paraphrase still cannot pass.
- **Tell the model not to elide.** Left to itself Gemini writes `[...]` inside a quote,
  which is honest prose and fatal to a substring check. One prompt line removes it.
- **Generation is non-deterministic, so a small sample cannot rank models.** The same
  8-guideline comparison scored Gemini 97% and then 91% on consecutive runs. At 32
  questions the confidence interval is about ±8 points: use these runs to find *defects*,
  and a much larger sample before believing any ranking.
- **The live GPC site has no URL for a section.** Sections load by AJAX from
  `link-cargar-seccion[data-id]` — no `href`, no anchor, nothing addressable — so the best
  a link can do is open the guideline at its first section, which reads as being dumped on
  a landing page. Verified 2026-09-21 against the live page.
  The menu is a two-level accordion — chapter, then the question the site numbers itself,
  then the section — so `GuidelineSection#menu_path` repeats that path verbatim
  ("DIAGNÓSTICO › PREGUNTA 3 › RECOMENDACIONES CLAVE") and a citation tells the reader
  what to click. `Gpc::NavigationRefresher` backfills it from one page per guideline;
  a full re-ingest would cost ~3,100 requests for metadata the bodies do not carry.
  **A chapter can hold loose sections and numbered questions at once** — ANEXOS carries
  GLOSARIO DE TERMINOS beside three questions — so the path is walked from each leaf
  outwards, never descended from the chapters, which silently drops the loose ones.
- **Solid Queue, Cache and Cable share the primary database.** One Railway service, no
  Redis. Their tables are in `db/migrate`, not separate schemas.
