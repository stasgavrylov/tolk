# Tolk: product spec (v1)

Native macOS translator with a DeepL-like UI, backed by the user's ChatGPT subscription.
Agreed in the grilling session on project start; this file is the source of truth for scope.

## Platform and distribution
- Swift 6, SwiftUI + AppKit where needed, macOS 26+ only. Personal use; not sandboxed; ad-hoc signed.
- App name **Tolk**, bundle ID `dev.stas.tolk`. Built into `./build`; may be installed to `/Applications`.
- Icon: **Two voices** — forest-green and sage speech cards on ivory. Editable source:
  `Resources/AppIcon.svg`; the packaged `Resources/AppIcon.icns` includes standard and Retina sizes.
- Dependencies: `KeyboardShortcuts` (sindresorhus) only, unless another clearly earns its place.

## Backend
- Sign in with ChatGPT subscription via Codex OAuth (PKCE, `auth.openai.com`, localhost callback).
  Tokens in Keychain, auto refresh. Requests to `chatgpt.com/backend-api/codex/responses` (SSE streaming).
- Provider protocol so an API-key provider can be added later (not in v1).
- Model selectable in Settings. Default: the fastest measured model at minimal reasoning for live translation;
  suggestions may use a separately configured model/effort.
- Dev smoke checks may read Pi's existing token from `~/.pi/agent/auth.json` read-only (never refresh,
  print, write, or commit it).

## AI settings and usage
- **AI** combines the former Account and Model settings: ChatGPT sign-in, live translation model/effort,
  suggestions model/effort, and Usage. The old model benchmark note is removed.
- Settings tabs use the same compact rounded-rectangle picker as the main screen switcher, not capsules.
  Native tab pages retain form state when switching sections; sign-in recovery opens AI.
- Usage shows **Today / All time** input, output, and total tokens, plus totals by requested model.
  Cached input and reasoning output appear when reported; they are subsets, not additional tokens.
  Partially reported breakdowns are labeled; missing or invalid reports never masquerade as zero usage.
- Accounting lives in the shared Codex client and covers translation, alternatives, idioms, sentence
  adjustment, and phrase finding. Each logical request is counted once, including a 401 retry or duplicate
  terminal events. Failed/incomplete responses may still report spent tokens; interrupted requests without
  metadata remain unknown. Attempts blocked before a network request do not count.
- Stats start with this feature and persist locally in a separate SwiftData store, aggregated by local
  calendar date at request completion and requested model. Dev runs use a separate store. No prompts,
  responses, credentials, or account identifiers are retained in usage data. Counts cover Tolk on this Mac
  across signed-in accounts, not account-wide billing or quota; no dollar estimates.
- Usage is independent of pausing/clearing translation history. Storage failures are visible and do not
  break translation; a later save does not silently clear a warning about already missing counts.

## Window and UI
- Main window: joined source / translation panes, language pickers with Detect, swap, copy,
  character count, and streaming output. Quiet green result surface in light and dark appearances.
- Screen switcher: compact rounded rectangles with even insets, not capsule-style toolbar chrome.
- Tone menu sits directly beside the target language. Language pairs use an icon-only title-bar menu
  with a visible dropdown indicator; no permanent quick-pair shortcut strip.
- Default window 960×520; compact window 720×380. History shares wide windows and overlays the
  workspace as a temporary drawer in compact windows.
- Menu-bar icon; option to hide the Dock icon.
- Languages: Ukrainian, English, Dutch by default. Other languages can be added in Settings.
  Saved language lists are preserved.
- UI language: English.

## Translation behavior
- Source auto-detect by default (Apple `NaturalLanguage`), manual override. If detected == target,
  pick the next sensible target from the pair list.
- Live: ~500 ms debounce, streamed output; ⌘↩ forces translation. Settings toggle for manual-only mode.
- Tone: Auto / Formal / Informal, persisted per target language (ти/ви, je/u).
- Manual mode has a visible Translate action. Streaming has Stop; incomplete or previous results are
  labeled, and copying is unavailable while translation or sentence adjustment is running.
- Failures preserve both texts. Expired sessions offer Sign in, not repeated Retry.

## Phrase suggestions
- Select a word or phrase (up to 12 words) in the **translation** pane with the mouse (drag, double/triple
  click, shift-click), or any selection + ⌘E → popover with ~5 alternatives for exactly the selection
  (synonyms, idioms, register variants). Each: replacement, short note, back-translation.
  Clicking replaces the selection and the rest of the sentence is re-smoothed to stay grammatical.
  Replacement plus adjustment is one undoable edit. If adjustment fails, keep the replacement and
  offer Retry adjustment and Undo; retry must not translate the source again.
- Each translation alternative has a small **Another like this** button, visible on hover or keyboard
  focus. It requests one new option anchored to that row's original meaning and style, with a new note
  and back-translation. Refreshing never applies a phrase or changes the other rows. Previously shown
  wording is excluded for the current popover; punctuation-only changes do not count as new wording.
  A pending row cannot start another refresh. Failure preserves its old option and allows retry.
  Closing the popover or changing the translation context cancels pending refreshes.
- Select text in the **source** pane → ⌘E → idiomatic target-language equivalents with explanations
  (does not modify the translation).
- Notes are in the source language.

## Phrase finder
- **Find a phrase** is a separate screen in the same window, beside **Translate** in a title-bar
  segmented control. Both screens retain their drafts, results, selections, and independent typing Undo
  during the session. Switching screens does not start a request.
- One-shot search: describe a meaning, word, feeling, or situation in any language, then choose a target
  language and Auto / Formal / Informal tone. Find phrases (or the existing ⌘↩ command) explicitly
  returns 3–5 natural expressions, not a literal translation or a conversation.
- The selected target is authoritative, including when the description is already in that language.
  Finder language/tone choices do not modify translation preferences. Uses the configured suggestions model.
- Each option has a short meaning/usage note and Copy. Notes use the description’s language, with
  English for ambiguous or mixed-language descriptions. The existing structured suggestions format is reused.
- Editing the description, target, or tone cancels the pending search without starting another.
  Stop, failure, and retry preserve the draft and previous suggestions; previous options retain their
  original target label. An empty result is distinct from a malformed response.
- Expired sessions offer Sign in. Completing sign-in enables an explicit retry; it never automatically
  submits a description. Copy and search do not add phrase searches to translation history.
- Translation-only commands are unavailable in the finder. Opening history or loading an external
  translation reveals Translate without discarding the finder draft. No new global hotkeys.

## Hotkeys
- In-app (rebindable in Settings, conflict warnings):
  - Swap (⌘⇧S): swap languages, move translation into source, re-translate.
  - Quick pairs ⌘1…⌘9: editable list. Defaults: UK→EN, EN→UK, EN→NL, NL→EN.
    Saved custom lists are preserved; other pairs can be added manually.
  - ⌘E suggestions, ⌘↩ translate / find phrases on the active screen (Stop while finding), ⌘Y history.
  - From Find a phrase, history switches to Translate; swap, quick pairs, phrase replacement, and
    Copy translation are disabled rather than modifying a hidden translation.
- Global (system-wide): **all off by default**, opt-in per action in Settings with empty recorders:
  - Show/hide window.
  - Translate selection (opens window prefilled). Optional ⌘C⌘C trigger, also off by default.
  - Translate selection and replace in place in the frontmost app.
  - Per-pair global hotkeys (translate selection with a given pair).
  - Requires Accessibility permission only when a selection-reading action is enabled.

## History
- SwiftData, local. Records each settled translation (after ~2 s pause, or on copy/swap), de-duplicated.
- Unlimited retention; search, star, delete, clear all, pause toggle. ⌘Y opens it; clicking restores.
- Restore is one undoable operation covering both texts, language direction, and tone. It dismisses
  history and returns focus to the editor without starting another translation.

## Out of scope for v1
- API-key provider, glossary, whole-sentence alternatives dropdown, document translation, push/remote.

## Done criteria
- App builds; tests pass; every feature above works end to end, verified live; every lll TRN task closed
  or explicitly deferred.
