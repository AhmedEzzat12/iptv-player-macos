# On-device AI features for Tuner (research)

Date: 2026-10-08. Status: research only, nothing implemented. Scope: AI features that run **on the device**
(Mac with macOS 15+, iPhone/iPad with iOS/iPadOS 26+), work offline, keep all data local, and don't bloat the app.
Out of scope at the owner's request: merging duplicate listings of the same title, spoiler-free recaps/summaries,
and English↔Arabic plot translation. Cloud LLM APIs (including Apple's Private Cloud Compute model, new in OS 27)
are excluded too.

Labels used below: **[measured]** = run for this document on the maintainer's Mac (M1 Pro, 32 GB, macOS 27.0.1,
Xcode 27 SDK); **[SDK]** = read from the macOS 27 / iOS 27 SDK interfaces and headers; **[doc]** = Apple
documentation or a model card (linked); **[unverified]** = estimate or secondary source, check before relying on it.

---

## TL;DR

**Recommendation: build the recommendations on a small multilingual *embedding* model plus plain scoring over the
user's own signals, and use Apple's on-device LLM (Foundation Models) only as an optional extra for English
query understanding and short explanations, never as a requirement.**

1. **Embeddings are the core.** One vector per movie/series (title + year + genre + category + plot, in whatever
   mix of English and Arabic the provider supplies) gives "More like this", "Because you watched X", "Top picks",
   mood rows, genre inference for untagged titles and semantic search, with a single model and one index.
   - Model: **`intfloat/multilingual-e5-small`** (118 M params, 384-d, MIT, 100 languages incl. Arabic; Arabic
     Mr.TyDi MRR@10 71.5 vs 36.7 for BM25) [doc]. Alternative to evaluate: **`ibm-granite/granite-embedding-107m-multilingual`**
     (Apache-2.0, 384-d, 6 layers, so about half the compute; Arabic is one of its 12 fine-tuned languages) [doc].
   - Runtime: **Core ML's `MLTensor` via [swift-embeddings](https://github.com/jkrukowski/swift-embeddings)**
     (MIT, pure SwiftPM, loads Hugging Face safetensors, has XLM-RoBERTa + multilingual-e5-small support), or a
     Core ML conversion of the same model. Both build with plain `swift build`, run on Intel and Apple silicon and on
     iOS. **Not MLX** for the core path: SwiftPM on the command line can't compile MLX's Metal shaders and MLX needs
     Apple silicon.
   - The model is **downloaded on first use** (≈ 235 MB fp16, less if quantised), like the IMDb data sets today, not
     bundled.
2. **Index = a SQLite table of vectors (new GRDB migration v6) + brute-force search with Accelerate.** 60 000 × 384
   float32 dot products take **2.8 ms** on the M1 Pro [measured]; stored as Float16 the index is ≈ 46 MB, as int8
   ≈ 23 MB. No sqlite-vec (needs a custom SQLite build that GRDB doesn't support with SwiftPM) and no HNSW library
   needed at this size.
3. **Scoring is ordinary, testable Swift in TunerCore**: a taste profile (decayed, completion-weighted average of the
   vectors of what you watched or favourited), category/channel affinity, recency and rating priors, and MMR for
   diversity. All of this works on every device, offline, in English and Arabic.
4. **Foundation Models (Apple's ~3 B on-device model) is a bonus layer, behind availability checks**: it only exists
   on Apple-silicon devices with Apple Intelligence on and OS 26+; the Mac app still supports macOS 15 and Intel;
   **Arabic is not a supported language** (`supportedLanguages` on this Mac lists 24 locales, no `ar`) [measured];
   and it is slow for bulk work (**1.5–1.8 s per short structured call**, ~3 s cold) [measured], so labelling
   56 000 titles with it would take about a day. Use it for: parsing an English natural-language search into filters
   when the user presses Return, one-line "why this" explanations for a handful of items, and re-ranking the top 20.
5. **Collect better signals first** (cheap, no AI): an append-only `viewEvent` log (what was played, from which row,
   how long, when). Today the database only keeps the *last* time a channel was watched and per-item resume positions,
   which is thin for personalisation.

**Top 5 features to build first:** (1) "More like this" on detail pages, (2) "Because you watched X" rows on Home,
(3) "Top picks for you" + personalised Home row order, (4) smarter Continue Watching (finish soon / new episodes /
quietly drop abandoned shows), (5) semantic + natural-language search (multilingual embeddings for everyone;
Foundation Models filter parsing as an English-only enhancement).

**MVP effort:** roughly 2–3 weeks of focused work for phases 0–2 (signals, embedding index, the first four features),
see [Phased plan](#5-phased-plan).

---

## 1. What the codebase and data imply

| Fact (from the repo) | Consequence for AI features |
|---|---|
| Mac target is **macOS 15+, Intel or Apple silicon**; iOS/iPadOS **26+** (`Package.swift`, README) | Anything needing Apple Intelligence (macOS 26+, M1+/A17 Pro+) can only be an optional layer. Core path must run on macOS 15 Intel too. |
| Mac app builds with **SwiftPM on the command line** (`scripts/build-app.sh`), Swift 5 app target, Swift 6 `TunerCore`; macros whose plugins live only in Xcode's platform folder failed before (`@State`, see `docs/design.md`) | `@Generable`/`@Guide` macros may hit the same issue (the plugin is `libFoundationModelsMacros.dylib` in Xcode's platform plugin folder [SDK]). `DynamicGenerationSchema` does guided generation **without macros** and worked in a plain `swift` script [measured]. MLX's Metal shaders can't be built by SwiftPM CLI ([mlx-swift README](https://github.com/ml-explore/mlx-swift)). |
| Library size: ~12 k channels, ~41 k movies, ~15 k series; names and plots mixed English/Arabic | ≈ 56 k VOD items to embed. Needs a **cross-lingual** model: an English query must find an Arabic-described film and vice versa. Apple's NL embeddings use separate per-script models (below), so they can't do this. |
| `movie`/`series` rows carry `name, year, genre, plot, cast, director, rating, addedAt, categoryId`; many providers leave plot/genre empty in list endpoints, and full details (`VODDetails`) are fetched **lazily** when a title is opened | The embedding text must lean on **title + category name + year** and use plot/genre when present. Online metadata (`mediaMetadata`: genres, overview, cast, IMDb id) exists only for titles the user opened, which happens to be exactly the titles that build the taste profile. Open question: measure plot/genre coverage in a real library (one SQL query, see §7). |
| Provider rows are **fully replaced per source on each sync**, ids are deterministic (`StableID`) | Key embeddings by media id **plus a hash of the embedded text**; after a sync only new or changed texts get embedded. Like the `download` table, the embedding table should have no foreign keys so a resync doesn't wipe it. |
| User signals: `watchProgress` (position, duration, completed, updatedAt, seriesId), `vodFavorite`, `history` (**one row per channel, last watchedAt only**), `channelPref` favourites, `customGroup`, recent searches, `categoryPref` hidden/pinned | Good enough for a first taste profile; too thin for row-order learning or time-of-day patterns. Add an append-only `viewEvent` table (§4.2). |
| `CategoryGrouping` already classifies provider categories by EN/AR keywords (Genres, Languages, Kids, Sports…) | Category names are a strong, free signal ("Arabic Movies 2024", "Turkish Series", "Kids"). Feed them into the embedding text and into hard filters for search. |
| `Series.lastModified` is stored | Cheap "New episodes" detection without fetching every series' episode list. |
| Search today is `LIKE` over words (`AppDatabase.searchWords`) | Hybrid search = existing lexical results fused with vector results. SQLite FTS5 is available in the system SQLite [measured], but its `remove_diacritics` does **not** strip Arabic harakat (`مُسَلْسَل` didn't match `مسلسل`) [measured], so normalise Arabic before indexing either way. |

---

## 2. On-device model options (state in October 2026)

### 2.1 Apple Foundation Models framework (on-device LLM)

| Aspect | Finding |
|---|---|
| Model | ~3 B parameter model, 2-bit quantisation-aware training, KV-cache sharing ([2025 tech report](https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025), [arXiv 2507.13575](https://arxiv.org/abs/2507.13575)) [doc]. OS 27 ships a "rebuilt" model ([WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)) [doc]; the SDK exposes `SystemLanguageModel.Variant.core3` and `.coreAdvanced3` [SDK]; this Mac reports **"AFM 3 Core"** [measured]. Which devices get "Advanced" isn't documented [unverified]. |
| OS / API availability | `SystemLanguageModel`, `LanguageModelSession`: iOS/macOS/visionOS **26.0+**; `tokenCount(for:)` 26.4+; `contextSize` back-deployed (returns 4096 before OS 27); OS 27 adds the `LanguageModel` protocol (pluggable backends), `capabilities` (`.guidedGeneration`, `.toolCalling`, `.reasoning`, `.vision`), reasoning levels, image attachments, usage counts [SDK]. tvOS/watchOS (on-device) unavailable [SDK]. |
| Devices | Apple Intelligence devices only: iPhone 15 Pro/Pro Max, iPhone 16 and later; iPad with A17 Pro or M1+; Mac with M1 or later (and the A18 Pro MacBook Neo). Needs Apple Intelligence **turned on**, up to 8–14 GB of storage for the models ([Apple support 121115](https://support.apple.com/en-us/121115)) [doc]. **No Intel Macs, nothing on macOS 15.** |
| Availability states | `availability` → `.available` or `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)` [SDK]. The framework is `@Observable`, so UI can react when the model finishes downloading. |
| Context | **4096 tokens** on this Mac [measured] (instructions + prompt + schema + output). The WWDC26 session shows 8192 on its demo device [doc]; treat context as device-dependent and check `contextSize` / `tokenCount`. Enough to re-rank ~20 short candidates, not to "read the catalogue". |
| Speed | Apple's 2024 figures for iPhone 15 Pro: ~0.6 ms per prompt token to first token, ~30 tokens/s generation ([Apple ML blog](https://machinelearning.apple.com/research/introducing-apple-foundation-models)) [doc]. On the M1 Pro, macOS 27: first call **3.1 s** (cold), structured search-intent parse **1.5–1.8 s** per query [measured]. Call `prewarm()` when the search field gets focus. |
| Guided generation | `@Generable` / `@Guide` (macros) or `DynamicGenerationSchema` + `GenerationSchema` (no macros). Tested the latter: valid JSON every time [measured]. |
| Tool calling | `Tool` protocol since 26.0; OS 27 adds system tools including a **Spotlight search tool** for local RAG (`SpotlightSearchTool` in `_CoreSpotlight_FoundationModels`, OS 27+) [SDK][doc]. |
| Content tagging | `SystemLanguageModel(useCase: .contentTagging)` "always responds with tags… topics, emotions, actions, and objects" ([doc](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/usecase/contenttagging)). Useful for per-title mood tags, but at ~1–2 s per title it only suits small sets (items on screen, the user's history), not 56 k titles. |
| **Arabic** | Not among Apple Intelligence's languages (15 languages listed by Apple [doc]); `supportedLanguages` on this Mac: da, de, en (+AU/GB/IN), es (+419/US), fr (+CA), it, ja, ko, nb, nl, pt (+PT), sv, tr, vi, zh (+HK/TW): **no `ar`** [measured]. Apple's docs: when the framework detects an unsupported language it throws `unsupportedLanguageOrLocale`, and guardrails only cover supported languages ([doc](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)). In practice on 27.0.1 an all-Arabic prompt was **answered, not rejected**, but with an invented film title, and an Arabic query (`مسلسل تركي رومانسي`, "romantic Turkish series") was parsed wrongly (language "Arabic", similar-to "مسلسل تركي") [measured]. Conclusion: don't route Arabic text through it; it's unsupported and unreliable. Users whose device language is Arabic probably can't turn Apple Intelligence on at all [unverified]. |
| Observed quality issues | "light comedy from the 90s in Arabic" → `kind: series` (should be any/movie); "something like Breaking Bad" → model added `yearFrom 2008, yearTo 2013` from its own knowledge [measured]. Mitigate with enum-constrained fields, "leave empty unless stated" instructions, and rule-based post-validation. |
| Licence / cost | System framework, no download by the app, no cost. |

**Verdict:** great for *optional* English-language niceties; can't be the foundation of Tuner's recommendations
(Intel/macOS 15 users get nothing, Arabic unsupported, too slow for bulk).

### 2.2 Natural Language framework

| API | Finding |
|---|---|
| `NLEmbedding.sentenceEmbedding(for:)` | English (512-d) and French (640-d) exist; **Arabic returns `nil`** [measured]. Separate model per language, so no cross-lingual similarity. |
| `NLContextualEmbedding` (macOS 14 / iOS 17+) | Per-*script* transformer models: Latin (20 languages), Arabic (added in macOS 15 / iOS 18), Cyrillic, CJK, Indic, Thai [SDK header]. 512-d, max 256 tokens; Arabic assets are downloaded on demand (`hasAvailableAssets == false` here until requested) [measured]. Returns **token vectors** (you mean-pool them yourself) and is meant as a feature extractor for training classifiers ([WWDC23 "Explore Natural Language multilingual models"](https://developer.apple.com/videos/play/wwdc2023/10042/)), not trained for sentence similarity. English and Arabic vectors come from **different models**, so an English query can't be compared with an Arabic plot. |
| `NLLanguageRecognizer`, `NLTokenizer`, `NLTagger` | Useful helpers: detect a text's language/script (e.g. to decide whether Foundation Models may see it), tokenise Arabic for lexical search. |

**Verdict:** zero-download, but wrong tool for EN+AR similarity. Use only the helpers.

### 2.3 Core Spotlight semantic search

Since iOS 18 / macOS 15, `CSUserQuery` runs semantic as well as lexical matching over items the app indexed
([doc](https://developer.apple.com/documentation/corespotlight/building-a-search-interface-for-your-app),
[WWDC24 10131](https://developer.apple.com/videos/play/wwdc2024/10131/)); OS 27 adds a Spotlight search tool for
Foundation Models [SDK]. Downsides for Tuner: no control over the model or its languages (Arabic semantic support is
undocumented [unverified]); developers report semantic results not working as shown
([forum thread](https://developer.apple.com/forums/thread/767355)); indexing 56 k titles also puts the catalogue
into system Spotlight; and it only answers search queries, not "similar to X" or a taste profile. **Not recommended**
as the core; could be a later experiment for system-wide search.

### 2.4 Multilingual embedding models (run with Core ML / MLTensor)

| Model | Params / dim | Weights (HF) | Languages | Licence | Notes |
|---|---|---|---|---|---|
| [intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small) | 118 M / 384, 12 layers, 512 tokens | 471 MB fp32 (≈ 235 MB fp16) | ~100 (XLM-R), Arabic MRR@10 71.5 on Mr.TyDi | MIT | **Recommended.** Needs `query: ` / `passage: ` prefixes. Most parameters are the 250 k-token vocabulary table, so compute is light for its size. Supported by swift-embeddings. |
| [ibm-granite/granite-embedding-107m-multilingual](https://huggingface.co/ibm-granite/granite-embedding-107m-multilingual) | 107 M / 384, **6 layers** | 214 MB | 12 fine-tuned incl. Arabic (MTEB Arabic 63.2) | Apache-2.0 | ~2× faster than e5-small per the card. XLM-R architecture, so should load with the same code [unverified]. Evaluate head-to-head. |
| [sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2](https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2) | 118 M / 384, 128 tokens | 471 MB | 50+ incl. Arabic | Apache-2.0 | Older, short context; fine for titles. Baseline. |
| [google/embeddinggemma-300m](https://ai.google.dev/gemma/docs/embeddinggemma) | 308 M / 768 (MRL → 512/256/128), 2 k tokens | ≈ 600 MB fp16, ~200 MB quantised | 100+ | Gemma terms (gated download) | Best quality under 500 M on multilingual MTEB per Google ([blog](https://developers.googleblog.com/introducing-embeddinggemma/)) [doc]; ~3× the compute of e5-small; licence is custom. A "phase 4" upgrade candidate. |
| [Qwen/Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B) | 596 M / up to 1024 (MRL) | ≈ 1.2 GB fp16 | 100+ | Apache-2.0 | Strong but heavy for an iPhone background job. Mac-only option. |
| [BAAI/bge-m3](https://huggingface.co/BAAI/bge-m3) | 568 M / 1024 | ≈ 2.2 GB fp32 | 100+ | MIT | Too big for this use. |
| [static-similarity-mrl-multilingual-v1](https://huggingface.co/sentence-transformers/static-similarity-mrl-multilingual-v1) / [potion-multilingual-128M](https://huggingface.co/minishlab/potion-multilingual-128M) | static (no transformer), 1024 / 256-d | 434 MB / 512 MB fp32 (much smaller truncated + fp16) | 50+ / 101 incl. Arabic | Apache-2.0 / MIT | "100x to 400x faster" than e5-small on CPU, lower quality (≈ 91 % of LaBSE for potion) [doc]. Good **fallback for low-end/background** and for per-keystroke search; supported by swift-embeddings. |

**Runtimes for these models in Swift:**

| Runtime | Pros | Cons |
|---|---|---|
| **MLTensor** via [swift-embeddings](https://github.com/jkrukowski/swift-embeddings) (MIT; depends on swift-transformers for tokenizers) | Pure SwiftPM, no conversion step, loads HF safetensors; XLM-R / BERT / Qwen3 / Model2Vec / static models; MLTensor is Core ML (macOS 15 / iOS 18+), so runs on Intel and Apple silicon | Third-party, single maintainer; adds swift-transformers (+ Jinja etc.) to the dependency graph; MLTensor picks compute units itself (GPU on iOS may be blocked in the background) [unverified] |
| **Core ML model** (convert with [coremltools](https://apple.github.io/coremltools/docs-guides/), tokenizer via [swift-transformers](https://github.com/huggingface/swift-transformers)) | First-party runtime, can force `.cpuAndNeuralEngine`, int8/palettised weights shrink the file; compile at runtime with `MLModel.compileModel(at:)` (no Xcode needed at build time) | One-off Python conversion pipeline to maintain; fixed/enumerated input shapes for best ANE use; still need the tokenizer |
| **MLX Swift** ([mlx-swift](https://github.com/ml-explore/mlx-swift), [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm): `MLXEmbedders`, `MLXLLM`, `MLXFoundationModels`) | Fastest path to run open LLMs and embedders on Apple silicon; OS 27 bridges MLX models into `LanguageModelSession` (`MLXLanguageModel`) | **SwiftPM CLI can't build MLX's Metal shaders** (needs `xcodebuild`), Apple silicon only, GPU work can't run in the iOS background without a special entitlement (below), large dependency |
| **llama.cpp / GGUF** ([repo](https://github.com/ggml-org/llama.cpp), MIT; prebuilt [XCFramework](https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md) as a SwiftPM `binaryTarget`) | Runs both LLMs and embedding GGUFs (e5, bge-m3, EmbeddingGemma, Qwen3-Embedding), Metal shaders embedded in the binary, quantisation down to 4-bit | C API wrapped by hand, frequent breaking changes, ~10+ MB binary per platform [unverified]; same Apple-silicon / iOS-background GPU caveats |
| **Core AI** (new in OS 27 SDK, successor to Core ML for large models per press coverage) | First-party, aimed at LLMs | **OS 27+ only** in the SDK (`@available(macOS 27, iOS 27…)`) [SDK]: unusable for macOS 15/iOS 26 targets. Core ML is still in the SDK. Revisit in a year. |

### 2.5 Local LLMs other than Apple's (for Arabic or for Intel/macOS 15)

If generated text in Arabic or LLM features on non-Apple-Intelligence devices ever matter, the practical choices are
Qwen3 (Apache-2.0, "100+ languages and dialects", [model card](https://huggingface.co/Qwen/Qwen3-1.7B)) or Gemma
models via MLX or llama.cpp. Sizes: Qwen3-1.7B 4-bit ≈ **1.0 GB**, Qwen3-4B 4-bit ≈ **2.3 GB** download (MLX
community builds) [measured: HF file sizes]. That's a large download and 1–3 GB of RAM while loaded on an iPhone, for
features that are "nice to have". **Not recommended for the MVP**; worth a Mac-only experiment once OS 27's
`MLXLanguageModel` makes it a drop-in `LanguageModelSession` backend.

### 2.6 Side-by-side

| | Foundation Models | NL framework | Core Spotlight | e5-small / granite (MLTensor or Core ML) | Static multilingual | MLX / llama.cpp LLM |
|---|---|---|---|---|---|---|
| Runs on macOS 15 / Intel | No / No | Yes / Yes | Yes / Yes | **Yes / Yes** | Yes / Yes | macOS 14+ / **No** |
| iPhone requirement | 15 Pro+ with AI on | any | any | any iOS 26 device | any | 6–8 GB RAM devices realistically |
| Added size | 0 (system, 8–14 GB on device) | 0 (Arabic assets on demand) | 0 | ≈ 120–235 MB download | ≈ 30–60 MB after truncation | 1–2.3 GB download |
| EN↔AR in one space | n/a (AR unsupported) | **No** | unknown | **Yes** | Yes (weaker) | Yes |
| Per-item cost | 1–2 s per call | ms | ms | ms per item (batch) [see §2.7] | µs | 0.5–3 s per call |
| Good for | query parsing, explanations, rerank (EN) | language detection, tokenising | system-wide search later | similarity, profiles, search, zero-shot tags | fast fallback, typing-time search | Arabic generation (optional) |
| Maintenance | Apple's | Apple's | Apple's | pin model + package versions | same | heavy |

### 2.7 Measurements made for this document (M1 Pro, macOS 27.0.1)

- **Vector search, brute force with `cblas_sgemv`** (Accelerate), 60 000 random unit-length vectors:
  384-d f32 (92 MB) **2.8 ms**; 256-d f32 **1.1 ms**; 768-d f32 **6.3 ms**; full sort of 60 k scores 6.5 ms (use a
  top-k heap instead); naive Swift int8 loop over 384-d (23 MB) 8.6 ms. An iPhone should be within ~2–4× of this
  [unverified].
- **Foundation Models**: availability `.available`, `contextSize` 4096, variant "AFM 3 Core", 24 supported locales
  without Arabic; first call 3.1 s; four structured search-intent parses 1.5–1.8 s each.
- **NL framework**: Arabic sentence embedding `nil`; contextual embeddings: separate Latin and Arabic models.
- **SQLite FTS5** (system library): available; Arabic diacritics are not removed by `unicode61 remove_diacritics 2`.
- **Embedding throughput of e5-small/granite**: see §2.8.

### 2.8 Embedding throughput (to measure in phase 1)

Indexing cost decides whether this is invisible or annoying. Without a measured number for Tuner's exact runtime,
plan with these **estimates [unverified]**: e5-small on Apple silicon GPU/ANE with batch 32 and ~96 tokens/item:
~300–1 000 items/s on a recent Mac, ~100–300 items/s on a recent iPhone, i.e. **1–3 min (Mac) / 3–10 min (iPhone)
for 56 k titles once**, then seconds per sync (only new/changed texts). Granite-107m roughly halves this; the static
model makes it seconds. Phase 1 starts with a 1-day spike that measures this on the maintainer's Mac and iPhone
before committing (§5).

---

## 3. Features

### 3.1 Summary

Value: H/M/L for this app's single user. Cost is on-device cost per use after indexing. "FM" = Foundation Models.

| # | Feature | Value | Technique | Data needed | Cold start | On-device cost | Phase |
|---|---|---|---|---|---|---|---|
| 1 | **More like this** (detail page) | H | k-NN on the title's vector, filtered (same kind, not watched, not the same series), MMR for variety; boost same category/language | embedding index | works with zero history | 1 query, < 10 ms | 2 |
| 2 | **Because you watched X** (Home rows) | H | for 1–3 recent, mostly-finished titles: k-NN of X, exclude watched; row title from data ("Because you watched X") | index + `watchProgress` | needs 1 watched title | ≤ 3 queries | 2 |
| 3 | **Top picks for you** | H | taste vector = Σ wᵢ·vᵢ over watched/favourited items (w = completion × recency decay × favourite boost); score = cos(taste, item) + priors (rating, recently added) + category affinity; MMR | index + all user signals | fall back to favourites, pinned categories, recent searches; else "Recently added / Top rated" | 1 query | 2 |
| 4 | **Personalised Home row order** | M–H | score each shelf by decayed plays/opens that started from it (+ fixed floor for Continue Watching); later a simple bandit (Thompson sampling) | `viewEvent` with `origin` | default order until ~20 events | trivial | 3 |
| 5 | **Continue Watching smarts** | H | rules: "finish soon" (≥ 75 % or < 15 min left), next-episode cards, demote "abandoned" (< 20 % watched and untouched 21+ days; offer "Remove"), sort by predicted intent (recency × fraction) | `watchProgress`, episodes | none | trivial | 1 |
| 6 | **New episodes / returning shows** | H | series the user watched with `lastModified` > their last progress, or more episodes than the last time the list was fetched; Home row + badge | `series.lastModified`, `watchProgress`, cached episode counts | none | trivial (SQL) | 1 |
| 7 | **Semantic + natural-language search** | H | hybrid: existing lexical results + vector k-NN of `query: …` fused with Reciprocal Rank Fusion; rule-based filters (years "90s"/"التسعينات", kind "series"/"مسلسل"/"فيلم", language words, "like X" → X's vector); FM structured parse as an *English-only* extra on Return | index + category groups | works | embed query (~10–50 ms) + search; FM +1.5 s | 3 |
| 8 | **Mood / occasion rows** ("Light & funny", "Edge of your seat", "Family night", "Late-night thriller") | M | each mood = a few bilingual prototype sentences → vector query; intersect with taste; time-of-day aware; optional FM `contentTagging` on the user's history only | index (+ hour from `viewEvent`) | works | a few queries | 3 |
| 9 | **What's on now that you'd like** (EPG) | M–H | candidates = programmes airing now/next on channels with affinity (favourites, `history`, `viewEvent` watch time) ∪ programmes whose title fuzzy-matches watched series/teams; score by channel affinity + XMLTV category match + embedding of title/summary for the top few hundred only | `program`, channel signals | favourites only | embed ≤ 300 short texts per refresh | 3 |
| 10 | **Auto-tagging / genre inference** for titles without genre | M | zero-shot: cosine to bilingual genre prototypes, accept above a calibrated threshold, plus `CategoryGrouping` keywords; never overwrite provider/online genres; FM `contentTagging` only for items on screen (English text) | index | n/a | a matrix multiply per genre for all items (ms) | 2 (as an input to rows/filters) |
| 11 | **Smart Up Next: series** | M | at the end of a show's last available episode: suggest "More like this" for the show instead of nothing; skip specials logic stays in `EpisodeNavigation` | index | works | 1 query | 2 |
| 12 | **Smart Up Next: live sports** | M | extract "Team A vs Team B" / "أ × ب" from programme titles the user watched (regex first, FM for English titles as optional extra); find upcoming programmes in the EPG with the same team or competition; offer a reminder (existing `reminder` + auto-switch) | `program`, `viewEvent` | none | SQL + regex | 4 |
| 13 | **"Why this?" explanations** | L–M | template text first ("Because you watched X · Arabic · Comedy"); FM one-liner for English titles on capable devices | features above | n/a | FM 1–2 s, lazily, only when shown | 4 |
| 14 | **LLM re-rank of top picks** | L | FM gets top 20 (titles + 1-line descriptions, English only) + user's last 5 titles, returns an order; compare offline against the plain scorer before shipping | features above | n/a | FM 2–4 s, in background | 4 (only if eval shows a gain) |

### 3.2 Notes per feature

**Taste profile (shared by 2, 3, 8, 9).** Keep it explainable and testable:

- Item weight `w = completion × 0.5^(age/30 days) × (favourite ? 2 : 1)`; completion = `min(1, position/duration)`
  or 1 if `completed`; episodes roll up into their series (one vector per series, weight summed over its episodes,
  capped so one long show doesn't dominate).
- Several centroids beat one average when tastes are mixed (Arabic drama *and* US sci-fi): k-means (k = 2–4) over the
  weighted watched vectors, then one row per cluster ("Because you like X and Y"). Cheap at this scale.
- Negative signals: titles started and abandoned (< 10 % and not resumed) get a small negative weight; "Not
  interested" in a context menu writes an explicit negative.
- Hard filters before scoring: hidden categories, adult categories, sources that are disabled, items already
  completed, and (optionally) the user's preferred languages derived from what they watch (`CategoryGrouping`
  language groups + `NLLanguageRecognizer` on titles).

**More like this (1).** Use the online `mediaMetadata` text when it exists (genres, overview, cast, directors) — it
exists for the title being viewed, because opening it fetched it — but query against the provider-text index, so
both sides should be embedded from comparable text. Show 10–20 results, de-emphasise the same category so the row
isn't just "the same folder again".

**Search (7).** Keep the current lexical search as the first and fastest signal; add vector results after a short
debounce, and only call FM when (a) the device supports it, (b) `NLLanguageRecognizer` says the query is in a
supported language, (c) the user pressed Return, (d) the query has 3+ words. Constrain the FM schema with enums
(`kind ∈ {movie, series, live, any}`, language from a fixed list), instruct it to leave fields empty unless stated,
and validate (e.g. drop year ranges the query didn't mention). "Something like Breaking Bad": resolve the title in the
user's library first (it's usually there); use its vector; fall back to embedding the phrase.

**Auto-tagging (10).** Zero-shot by prototypes is cheap enough to run over all 56 k titles after each indexing pass.
Prototypes per genre, in both languages (e.g. *"A comedy film full of jokes and funny situations"* /
*"فيلم كوميدي مليء بالمواقف المضحكة"*). Calibrate thresholds on titles that *do* have a provider or online genre
(precision ≥ 0.8 before a tag is used for filtering). Store inferred tags separately (`inferredGenre`), never in
provider columns, which are replaced on sync.

**What's on now (9).** Programmes change every 30 min, so don't embed the guide wholesale. Most of the value comes from
channel affinity (which channels the user actually watches, and for how long, at this hour), with embeddings used to
break ties among a few hundred candidates.

**Continue Watching (5) and New episodes (6)** need no model at all and fix real annoyances; ship them first.

### 3.3 Cold start

Day one (no history): use favourites (channels and VOD), pinned categories (strong language/genre preference),
recent searches (embed them as queries), and priors (recently added, rating). Optional one-time "Pick a few titles you
like" sheet built from the user's own library's most-rated items in their pinned languages. Recommendations rows stay
hidden until there's at least one signal.

---

## 4. Architecture proposal

### 4.1 Where it lives

```
Sources/TunerCore/
  Recommendations/            (new; UI-free, Swift 6, tested)
    EmbeddingText.swift         builds the text per movie/series (title cleanup via TitleParser, category display
                                name, year, genre, cast[0..2], plot ≤ ~300 chars) + a stable hash; Arabic normalisation
    TextEmbedder.swift          protocol TextEmbedder: Sendable { var modelID: String; var dimension: Int;
                                func embed(_ texts: [String], role: .query/.passage) async throws -> [[Float]] }
                                + an implementation per runtime (MLTensor/Core ML), + a deterministic fake for tests
    EmbeddingIndexer.swift      actor: diff (mediaId, textHash) against the table, embed in batches, write in chunks,
                                report progress, cancellable, resumable
    VectorIndex.swift           actor: contiguous Float16 (or int8 + scale) buffer + id array, loaded lazily from the
                                DB; topK(query, filter, k) with Accelerate + a heap; MMR helper
    TasteProfile.swift          pure functions: weights, centroids (k-means), negatives
    Recommender.swift           actor façade: moreLikeThis(id), becauseYouWatched(), topPicks(), moodRow(mood),
                                onNow(), inferredGenres(id) → [ScoredItem]; all pure scoring is testable
    SearchRanker.swift          hybrid search: lexical + vector + RRF + rule-based query filters
    QueryUnderstanding.swift    rules (years, kinds, languages, "like X") in EN/AR; optional LLM parser protocol
    ModelStore.swift            downloads/verifies/deletes model files (like IMDbRatingsService's data sets)
  Database/
    AppDatabase+Recommendations.swift   embedding + viewEvent + recFeedback queries
Sources/Tuner/
  App/AIFeatures.swift        (thin) wires Recommender into AppModel, feature flags, background scheduling
  App/FoundationModelsParser.swift    #if canImport(FoundationModels), @available(macOS 26, iOS 26, *):
                                      implements the LLM-parser/explainer protocols with DynamicGenerationSchema
  Views/...                   new shelves on Home, a "More Like This" shelf on detail pages, search sections
```

- `TunerCore` defines the **protocols** (`TextEmbedder`, `QueryParsing`, `Explaining`); heavy or OS-gated
  implementations can sit in the app target or a separate SwiftPM target so `TunerCore` keeps compiling for
  macOS 15 with minimal dependencies. If swift-embeddings is used, put it in a new target (e.g. `TunerML`) that
  `TunerCore` doesn't depend on; tests use the fake embedder.
- Foundation Models types stay behind `#if canImport(FoundationModels)` and `if #available(macOS 26, iOS 26, *)`
  and `SystemLanguageModel.default.availability == .available`. Use `DynamicGenerationSchema` to avoid the macro
  plugin problem (or pass the Xcode plugin path the way `scripts/test.sh` does for Swift Testing).
- Logging: `Logger(subsystem: "app.tuner.macos", category: "Recommendations")`; log counts and timings, never
  titles of what the user watched, never URLs.

### 4.2 Storage (new migration, appended after v5)

```swift
m.registerMigration("v6") { db in
    // One vector per movie/series and model. No foreign keys (rows outlive a resync, like `download`);
    // orphans are deleted after each sync. textHash lets a resync skip unchanged titles.
    try db.create(table: "embedding") { t in
        t.column("mediaId", .text).notNull()
        t.column("kind", .text).notNull()          // movie | series
        t.column("model", .text).notNull()         // e.g. "multilingual-e5-small@<revision>/384/f16"
        t.column("textHash", .text).notNull()
        t.column("vector", .blob).notNull()        // little-endian Float16 × dim (or int8 + Float32 scale)
        t.column("updatedAt", .datetime).notNull()
        t.primaryKey(["mediaId", "model"])
    }
    // Append-only playback log for personalisation (what, from where, how long, when).
    try db.create(table: "viewEvent") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("mediaId", .text).notNull()       // movie, episode or channel id
        t.column("kind", .text).notNull()
        t.column("seriesId", .text)
        t.column("origin", .text)                  // "home.topPicks", "search", "guide", "upNext", …
        t.column("startedAt", .datetime).notNull()
        t.column("watchedSeconds", .double).notNull().defaults(to: 0)
    }
    try db.create(index: "viewEvent_started", on: "viewEvent", columns: ["startedAt"])
    // Explicit feedback ("Not interested", thumbs).
    try db.create(table: "recFeedback") { t in
        t.primaryKey("mediaId", .text)
        t.column("value", .integer).notNull()      // -1 / +1
        t.column("createdAt", .datetime).notNull()
    }
}
```

Sizes for 56 k titles at 384-d: Float16 BLOBs ≈ **43 MB** in the database (int8 ≈ 22 MB). The `viewEvent` table
stays tiny (thousands of rows a year); prune events older than ~2 years. Inferred genres can be computed on the fly
from the vectors or cached in a small `inferredGenre(mediaId, genre, score)` table if they're used in SQL filters.

Alternatives considered:

| Option | Verdict |
|---|---|
| SQLite BLOBs + in-memory brute force (above) | **Chosen.** One file, one migration, transactional with the library, ~3–10 ms per query. |
| Flat memory-mapped vector file next to the DB | Faster cold load and pages are evictable under memory pressure; worth it if loading 43 MB of BLOBs at launch is measurably slow. Can be added later as a cache of the table. |
| [sqlite-vec](https://github.com/asg017/sqlite-vec) | Pre-v1 ("expect breaking changes"), and loading extensions into Apple's system SQLite isn't possible; GRDB's custom SQLite build "is not compatible with the Swift Package Manager" ([GRDB docs](https://github.com/groue/GRDB.swift/blob/master/Documentation/CustomSQLiteBuilds.md)). No. |
| [USearch](https://github.com/unum-cloud/usearch) (HNSW, Swift bindings) | Only pays off at millions of vectors; brute force is already a few ms at 60 k. Keep in mind if the EPG gets embedded wholesale. |
| Core Spotlight index | See §2.3. Not as the core. |

### 4.3 Query-time memory and speed

| Index | RAM resident | Query (M1 Pro, measured) | Notes |
|---|---|---|---|
| 60 k × 384 f32 | 92 MB | 2.8 ms | simplest; too much RAM for an iPhone next to the player |
| 60 k × 384 f16 | 46 MB | ≈ 3–5 ms incl. conversion per chunk [unverified] | **recommended** default |
| 60 k × 384 int8 + scale | 23 MB | 8.6 ms naive loop; faster with SIMD | if memory matters on iPad/iPhone |
| 60 k × 256 (MRL models only) | 15–31 MB | 1.1 ms (f32) | only for EmbeddingGemma/Qwen3/static models |

Load the index lazily (first Home/Detail/Search use), drop it on memory warnings (`UIApplication.didReceiveMemoryWarningNotification`)
and while the player is full screen on iPhone if needed. The embedding model itself (≈ 120–240 MB) is only loaded
while indexing or embedding a query; unload it after ~1 min idle.

### 4.4 Incremental indexing

1. `SyncService` finishes a VOD sync → `AppModel` notifies `EmbeddingIndexer` (debounced, like the existing
   `libraryRevision` bump).
2. Indexer reads `(id, kind, text inputs)` for all movies/series in enabled sources, computes `EmbeddingText` +
   hash, loads existing `(mediaId, textHash)` for the current model, and queues only new/changed ids. Items with
   identical text share one embedding computation (hash → vector cache within the run).
3. Embeds in batches of 32–64, writes every ~1 000 items in one transaction (resumable after a crash or relaunch),
   reports progress (for a small Settings line "Preparing recommendations… 34 %").
4. Deletes rows whose `mediaId` no longer exists (after the sync transaction, never during it).
5. Priority order: titles in the user's history and favourites first (so recommendations work early), then recently
   added, then the rest.
6. Model change (new revision/dimension) → new `model` key; re-index in the background, keep using the old vectors
   until the new set is complete, then delete the old rows.

### 4.5 Background work, battery and platforms

| | Mac | iPhone / iPad |
|---|---|---|
| When to index | Right after a sync, at utility priority (`Task(priority: .utility)`), pausing while a stream is playing if it competes with playback; Low Power Mode (`ProcessInfo.isLowPowerModeEnabled`) defers it | Foreground: after a sync, in small batches while the app is idle and not playing. Background: `BGProcessingTaskRequest` with `requiresExternalPower = true` (overnight on the charger). The system can stop it any time; checkpoints make that harmless. |
| GPU | Fine | Apps can't use the GPU in the background (Tuner already stops GLES drawing there). `BGContinuedProcessingTask` (iOS 26) can request `.gpu`, but only with the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement and "not supported on all devices" [SDK header]; free/personal teams likely can't get it [unverified]. Plan for CPU/ANE-only background runs (Core ML `computeUnits = .cpuAndNeuralEngine`) or foreground-only indexing. |
| `BGContinuedProcessingTask` | n/a | Meant for user-started work with a Live Activity progress UI ([doc](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask), [WWDC25 227](https://developer.apple.com/videos/play/wwdc2025/227/)). Could back an explicit "Prepare recommendations now" button after the first sync. |
| Thermal | Check `ProcessInfo.thermalState`; pause at `.serious` | same |

Rough energy: a one-off 3–10 min accelerator job on first index, then seconds per sync [unverified]. Queries are
milliseconds.

### 4.6 Foundation Models layer and graceful fallback

```
if FeatureFlags.llmExtras,
   #available(macOS 26, iOS 26, *),
   SystemLanguageModel.default.availability == .available,
   NLLanguageRecognizer.dominantLanguage(for: text) ∈ supportedLanguages {
    use FM (prewarmed session, DynamicGenerationSchema, short timeout, catch every error)
} else {
    rules / templates / embeddings only    ← always correct, just less clever
}
```

- Every FM feature must have a non-LLM result that's already shown; FM only *improves* it (parsed filters, a
  nicer sentence, a re-order). Never block UI on it; cancel when the user types again.
- Handle `.unavailable(.modelNotReady)` by observing `availability` (the model is `@Observable`).
- Handle `unsupportedLanguageOrLocale`, guardrail violations, context overflow (`contextSize`, `tokenCount`) and
  timeouts as "no improvement".
- On macOS 15, Intel Macs and older iPhones the app simply never shows FM-only touches (e.g. the "why" sentence
  falls back to a template).

### 4.7 Feature flags and settings

- Settings → "Recommendations": master switch (default on once phase 2 ships), "Use Apple Intelligence when
  available" (default on), "Remove recommendation data" (deletes the `embedding` rows, model files and
  `viewEvent`/`recFeedback`), model download size and status, and "Pause history" (stop logging `viewEvent`).
- Internal flags (UserDefaults keys, not UI) per feature for staged rollout: `ai.moreLikeThis`, `ai.homeRows`,
  `ai.semanticSearch`, `ai.llmExtras`, `ai.rowOrdering`.

### 4.8 Privacy

- Everything stays in the app's container / Application Support (SQLite + model files). No network except the
  one-time model download from a pinned URL with a SHA-256 check (host it as a GitHub release asset of this repo or
  fetch from Hugging Face by commit hash).
- Nothing about viewing is sent anywhere; nothing is indexed into system Spotlight unless the user opts in later.
- Logs contain counts and durations only. No titles, no URLs (stream URLs carry credentials, see `CLAUDE.md`).
- "Remove recommendation data" and "Pause history" as above; deleting a source deletes its `viewEvent` rows like it
  deletes `watchProgress` today.

### 4.9 Evaluating quality offline

No A/B testing is possible with one user, so build a small, honest offline harness in TunerCore tests plus a debug
command:

1. **Leave-last-out replay** on the owner's real history (run locally, results never committed): for each of the
   last N completed titles, build the profile from what came before and check whether the title appears in the
   top-K. Report Hit@10, Recall@20, NDCG@10 and catalogue coverage vs baselines (Recently added, Top rated, same
   category). Ship a recommender only if it clearly beats the baselines.
2. **Synthetic test kit**: extend `scripts/testkit` with a few hundred synthetic bilingual titles in known clusters
   (EN and AR descriptions of the same synthetic plot, genres) so unit tests can assert "the Arabic twin is in the
   top 3" with a real model in an opt-in test, and with the fake embedder in the default suite.
3. **Search golden set**: ~50 queries (EN, AR, mixed, "like X", years, moods) with expected relevant ids from the
   synthetic kit; track MRR@10 for lexical vs hybrid.
4. **Genre inference**: precision/recall on titles that have a provider or online genre (held out).
5. **Speed/memory budget tests**: index build time per 1 000 items, query p95, resident memory, on the Mac and on
   one iPhone, recorded in `docs/testing.md`.
6. A debug overlay ("Why is this here?") showing the score parts (similarity, recency, rating, affinity) makes
   tuning by eye fast.

### 4.10 Testing in the existing style

- Swift Testing in `TunerCoreTests`: `EmbeddingText` (cleanup, Arabic normalisation, hash stability),
  `VectorIndex` (top-k, filters, MMR, Float16 round-trip), `TasteProfile` (weights, decay, clustering), `Recommender`
  scoring with a fake embedder that maps known strings to fixed vectors, `QueryUnderstanding` rules in EN/AR,
  migration v6 on an in-memory DB, indexer diffing/resume.
- No model downloads in the default test run; one opt-in test target or environment variable runs the real model.

---

## 5. Phased plan

Efforts are rough, for one developer working with an agent, including tests and docs (README, `docs/design.md`,
`docs/testing.md` per the repo rules).

| Phase | Scope | Effort | Exit criteria |
|---|---|---|---|
| **0. Signals & groundwork** | Migration v6 (`viewEvent`, `recFeedback`; `embedding` table can come in phase 1); log plays with `origin`; Arabic text normalisation helper; SQL to measure plot/genre coverage in the real library | 2–3 days | events recorded on Mac and iPhone; coverage numbers known |
| **1a. Spike: embedding runtime** | Try swift-embeddings (MLTensor) with multilingual-e5-small and granite-107m on Mac (Apple silicon + Intel if available) and one iPhone: build with `swift build` + `iOS/scripts/check-build.sh`, items/s, memory, EN↔AR sanity pairs; decide runtime + model | 1–2 days | a written decision with numbers in `docs/design.md` |
| **1b. Continue Watching smarts + New episodes** | Features 5 and 6 (no ML) | 2–3 days | rows on Home, tests |
| **1c. Embedding index** | `EmbeddingText`, `TextEmbedder`, `ModelStore` (download + checksum), `EmbeddingIndexer` (incremental, resumable), `VectorIndex`, v6 `embedding` table, Settings status line | 4–6 days | full library indexed on Mac and iPhone; resync re-embeds only changes |
| **2. First recommendations** | More like this, Because you watched X, Top picks, end-of-series Up Next suggestion, zero-shot genre inference (internal) + offline eval harness | 4–6 days | Hit@10 beats baselines on the owner's history; UI on both platforms |
| **3. Search & rows** | Hybrid semantic search (RRF + rules), mood rows, "What's on now that you'd like", row ordering from `viewEvent` | 5–8 days | search golden set improves MRR@10; no typing lag |
| **4. LLM extras (optional)** | FM search-intent parsing (EN), "why this" sentences, FM re-rank experiment, live-sports follow-ups, FM content tags for history items | 4–6 days | only shipped where eval shows a gain; zero regressions on unsupported devices |
| **5. Later / experiments** | EmbeddingGemma or Qwen3-Embedding on the Mac; OS 27 `MLXLanguageModel` with a multilingual LLM (Arabic explanations) as a Mac-only option; Core Spotlight indexing (opt-in); Core AI once the minimum OS is 27 | open | — |

**MVP = phases 0–2: about 2.5–4 weeks.**

---

## 6. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| **Sparse provider text** (no plot/genre for most movies) makes vectors little more than "title + category" | Weak "More like this" for obscure titles | Measure coverage first; include category names and year; optionally embed online metadata text for titles whose metadata is cached; accept that the taste profile, built from opened titles, has richer text than the candidates |
| Embedding runtime doesn't build cleanly with SwiftPM CLI / CLT, or MLTensor is slow on Intel | Blocks phase 1 | 1-day spike before committing; Core ML conversion as plan B; static multilingual model as plan C |
| Model download size (≈ 120–235 MB) | "Bloat" | Download on demand, quantise (int8/palettised Core ML), consider vocabulary pruning to tokens seen in EN/AR [unverified gain]; static-model option ≈ 30–60 MB |
| First full index on iPhone takes minutes and can't use the GPU in the background | Recommendations appear late on a new install | Index history/favourites first; foreground batches; overnight `BGProcessingTask` on power; show progress |
| Foundation Models unavailable (macOS 15, Intel, older iPhones, Apple Intelligence off) or rejects/garbles Arabic | Uneven experience | FM is never required; every FM feature has a non-LLM result; detect language before calling |
| FM hallucinates constraints (observed: invented year ranges, wrong kind) | Wrong search filters | Enum/optional fields, validation against the query text, show applied filters as removable chips |
| `@Generable` macro plugin missing in CLT builds | Compile failure | `DynamicGenerationSchema` (verified) or `-plugin-path` like `scripts/test.sh` |
| Filter bubble / repetitive rows | Boring Home | MMR diversity, cap per category, mix in "Recently added", exploration slot |
| Memory pressure on iPhone with player + index + model | Jetsam | Float16/int8 index, lazy load, unload model after use, drop index on memory warning |
| Third-party package churn (swift-embeddings, swift-transformers, MLX, llama.cpp) | Maintenance | Pin versions; keep a thin `TextEmbedder` protocol so the runtime is swappable; prefer first-party Core ML if the spike shows parity |
| Licences | Low (personal use) | e5-small MIT, granite Apache-2.0, swift-embeddings MIT, swift-transformers Apache-2.0, llama.cpp MIT, MLX MIT, Qwen3 Apache-2.0; **EmbeddingGemma/Gemma under Gemma terms** (gated download, use restrictions) — fine personally, but note it if the repo ever ships the weights |
| Adult content leaking into rows | Embarrassing | Hard-filter `isAdult` channels and adult/hidden categories before any scoring |

---

## 7. Open questions for the owner

1. **Text coverage:** how many movies/series in your real library have a non-empty `plot` / `genre`? (One query on a
   copy of the database: `SELECT COUNT(*), SUM(plot <> ''), SUM(genre <> '') FROM movie;` and the same for `series`.)
   This decides how much the embeddings can do.
2. **Model download:** is a one-time ≈ 120–235 MB download acceptable (on both Mac and iPhone)? Or should we aim for
   the static ≈ 30–60 MB model first and upgrade later?
3. **Dependencies:** OK to add swift-embeddings + swift-transformers (third-party) or prefer a first-party Core ML
   conversion (more setup, fewer packages)?
4. **History logging:** OK to start recording a `viewEvent` log (what/when/how long/from which row), with a
   "Pause history" switch?
5. **Apple Intelligence extras:** worth building English-only touches (NL query parsing, "why this" sentences) given
   your devices? Which Mac/iPhone models do you use, and is Apple Intelligence on?
6. **Language preference:** should recommendations prefer the languages you usually watch (inferred), or should that
   be an explicit setting (e.g. "Prefer Arabic and English titles")?
7. **Home layout:** how many new rows are welcome on Home (e.g. max 3 personalised rows), and should row order be
   automatic or fixed?
8. **Live TV:** is "What's on now that you'd like" / sports follow-ups more valuable than VOD recommendations for you?
   That changes the phase order.
9. **iPhone background indexing:** acceptable to index only while the app is open (plus overnight on the charger),
   or do you want an explicit "Prepare now" button with a Live Activity?

---

## 8. Sources

Apple (primary):
- Foundation Models: [framework docs](https://developer.apple.com/documentation/foundationmodels) ·
  [Supporting languages and locales](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models) ·
  [`UseCase.contentTagging`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/usecase/contenttagging) ·
  [`DynamicGenerationSchema`](https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema)
- WWDC: [WWDC25 286 Meet the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/286/) ·
  [WWDC25 301 Deep dive into the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/301/) ·
  [WWDC26 241 (Foundation Models, OS 27)](https://developer.apple.com/videos/play/wwdc2026/241/) ·
  [WWDC25 227 Finish tasks in the background](https://developer.apple.com/videos/play/wwdc2025/227/) ·
  [WWDC24 10131 Support semantic search with Core Spotlight](https://developer.apple.com/videos/play/wwdc2024/10131/) ·
  [WWDC23 10042 Explore Natural Language multilingual models](https://developer.apple.com/videos/play/wwdc2023/10042/)
- [Apple Intelligence requirements and languages (support 121115)](https://support.apple.com/en-us/121115)
- [Introducing Apple's On-Device and Server Foundation Models (2024)](https://machinelearning.apple.com/research/introducing-apple-foundation-models) ·
  [Apple Intelligence Foundation Language Models Tech Report 2025](https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025) ([arXiv](https://arxiv.org/abs/2507.13575))
- [NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding) ·
  [NLContextualEmbedding](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)
- [Building a search interface for your app (Core Spotlight, semantic search)](https://developer.apple.com/documentation/corespotlight/building-a-search-interface-for-your-app) ·
  [Developer forums: semantic search with CSUserQuery](https://developer.apple.com/forums/thread/767355)
- [BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask) ·
  [BGProcessingTaskRequest](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtaskrequest)
- [MLTensor](https://developer.apple.com/documentation/coreml/mltensor) ·
  [Accelerate BLAS](https://developer.apple.com/documentation/accelerate/blas) ·
  [coremltools](https://apple.github.io/coremltools/docs-guides/)
- SDK interfaces read locally: `FoundationModels.swiftinterface`, `_CoreSpotlight_FoundationModels.swiftinterface`,
  `CoreAIDelegates.swiftinterface` (macOS 27 SDK), `NLContextualEmbedding.h`, `NLEmbedding.h`, `BGTaskRequest.h`,
  `BGTaskScheduler.h` (iOS 27 SDK).

Models (model cards):
- [intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small) ·
  [ibm-granite/granite-embedding-107m-multilingual](https://huggingface.co/ibm-granite/granite-embedding-107m-multilingual) ·
  [paraphrase-multilingual-MiniLM-L12-v2](https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2) ·
  [EmbeddingGemma overview](https://ai.google.dev/gemma/docs/embeddinggemma) / [announcement](https://developers.googleblog.com/introducing-embeddinggemma/) ·
  [Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B) · [BGE-M3](https://huggingface.co/BAAI/bge-m3) ·
  [static-similarity-mrl-multilingual-v1](https://huggingface.co/sentence-transformers/static-similarity-mrl-multilingual-v1) ·
  [potion-multilingual-128M](https://huggingface.co/minishlab/potion-multilingual-128M) ·
  [Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) · [MTEB leaderboard](https://huggingface.co/spaces/mteb/leaderboard)

Libraries:
- [swift-embeddings](https://github.com/jkrukowski/swift-embeddings) · [swift-transformers](https://github.com/huggingface/swift-transformers) ·
  [mlx-swift](https://github.com/ml-explore/mlx-swift) · [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) ·
  [llama.cpp](https://github.com/ggml-org/llama.cpp) ([XCFramework](https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md)) ·
  [USearch](https://github.com/unum-cloud/usearch) · [sqlite-vec](https://github.com/asg017/sqlite-vec) ·
  [GRDB custom SQLite builds](https://github.com/groue/GRDB.swift/blob/master/Documentation/CustomSQLiteBuilds.md) ·
  [GRDB full-text search](https://github.com/groue/GRDB.swift/blob/master/Documentation/FullTextSearch.md) ·
  [SQLite FTS5](https://www.sqlite.org/fts5.html)

Recommender background:
- Gomez-Uribe & Hunt, *The Netflix Recommender System: Algorithms, Business Value, and Innovation*, ACM TMIS 2015
  ([doi](https://dl.acm.org/doi/10.1145/2843948)) · Netflix Tech Blog,
  [Learning a Personalized Homepage](https://netflixtechblog.com/learning-a-personalized-homepage-aa8ec670359a)
- Carbonell & Goldstein, *The use of MMR, diversity-based reranking…*, SIGIR 1998
  ([doi](https://dl.acm.org/doi/10.1145/290941.291025)) · Cormack, Clarke & Büttcher, *Reciprocal Rank Fusion…*,
  SIGIR 2009 ([doi](https://dl.acm.org/doi/10.1145/1571941.1572114))

Secondary (not relied on for decisions): press coverage of Core AI at WWDC26 (e.g.
[InfoQ](https://www.infoq.com/news/2026/06/apple-core-ai-wwdc)); the SDK confirms Core AI is OS 27+ only.
