# Personal phrase learning vertical slice (2026-10-28)

Development branch only: `dev/learning-events`. Never merge automatically to `main`.

## What has actually been implemented

- `PersonalPhraseLearning.swift`: conservative local-only phrase observations, no-tone full syllable structure checking and explicit Rime confirmed/committed **single-character** provenance, deliberate space/newline boundary, two identical observations, local JSON atomic persistence. First observation is persisted and can complete in another process; older JSON arrays are migrated on read. No host text scraping or typed-data logging.
- `PersonalCandidateFusion.swift`: actual learned phrases are generated and displayed **before** Rime candidates, with stable original Rime index mapping for both normal candidate bar and expanded panel.
- `KeyboardViewController.swift`: candidate click/commit integration, field-type gate, document-switch cancellation, backspace negative feedback for immediate personal suggestion correction, whole vocabulary reset, and per-word forgetting (first 20 entries in settings).
- `PersonalPhraseSmoke.swift` + `rime-runtime.yml`: actual iOS Simulator librime candidate selection, absent phrase baseline, first observation across process restart, Top-1 merged suggestions for both full no-tone and initials, native candidate index preservation, negative feedback, disallowed-field rejection, cancellation, reset. All fixture strings are invented/public examples.

## Verified evidence and separate limitations

- Earlier native preference learning for **already present** phrase was confirmed in run [40636464758](https://github.com/jush0147/stoat-keyboard/actions/runs/40636464758). This is **not** the new-word path.
- Initial previously **absent** phrase vertical slice passed real Simulator in [40643132826](https://github.com/jush0147/stoat-keyboard/actions/runs/40643132826): actual librime confirmed single-character selections, user phrase full/initial lookup, fresh-process persistence and reset. The fixed fixture was `靠拷` with `dl + dl` and `dd`.
- Latest complete App/Extension compile after moving learned words into the top candidate position: [40644010578](https://github.com/jush0147/stoat-keyboard/actions/runs/40644010578) (success).
- More stringent cross-process **first observation**, privacy and Top-1 fused candidate Simulator acceptance run: [40644050799](https://github.com/jush0147/stoat-keyboard/actions/runs/40644050799). Check its final conclusion; **do not assume success from compilation alone**.

## Current safety scope

Accepts only: Rime selection **with commit equal to selected text**, exactly one Han character per event, structurally complete no-tone syllable, normal text fields, contiguous chosen segments and explicit boundary. Does not learn from arbitrary host text or initials-only *as pronunciation evidence*. Phrase search accepts initials only **after** full phonetic evidence.
 
Rejects/defers: intermediate Rime composition segment selection without a verified final commit, ambiguous grouped reading, punctuation/implicit Chinese phrase boundaries, arbitrary synthesized words, secure/special field input and unverified document changes. The current phonetic check is structural and engine-selection-backed, not a general-purpose full dictionary alignment proof.

Known functional limits: only typed **independent one-character Rime commits** are presently trainable; selecting a character while Rime continues composing other syllables is not yet captured as a learnable segment. Two occurrences are a conservative prototype threshold, not a Gboard measurement. UI touch interactions are compiled but not proven in a real third-party keyboard extension hosted inside another App. The dictionary/UI ergonomics and spatial touch correction remain untouched.

## Next work

1. Inspect final run 40644050799; repair actual compiler/Simulator issues before expanding behavior.
2. Trace real Rime **partial segment** provenance through its context/composition API; require verified per-segment phonetics and final committed text before training.
3. Add explicit Chinese punctuation-boundary test without guessing arbitrary word breaks; cancel on editing/focus and consider opt-out defaults.
4. Test keyboard Extension UI interaction in hosted Simulator App via UI automation, including selected personal candidate and restoring native candidate indices.
5. Extend shorthand/whole-sentence quality tests (e.g. `ㄨㄅㄓㄉ`) only after this vertical slice is stable.

## Follow-up after the enhanced runtime pass

- [Simulator run 40644050799](https://github.com/jush0147/stoat-keyboard/actions/runs/40644050799) finished **SUCCESS**, verifying saved first observation across processes, a second actual Rime candidate selection, merged full-no-tone/initial-only Top-1, original native index mapping, negative feedback, disallowed field, cancellation and reset.
- `PersonalPhraseLearning.finishAfterSymbol` now recognizes explicit Chinese punctuation (，。、！？；：) and ASCII terminal punctuation as phrase boundaries; numbers, quote pairs, and decorative symbols invalidate pending evidence instead of being learned.
- `KeyboardViewController` calls the same boundary helper from the idle punctuation row and the 123 symbols page. A temporary switch from Zhuyin to 123 preserves pending evidence only until the next explicit symbol; other mode changes cancel.
- A genuine iOS Simulator punctuation/no-boundary scenario was added to `PersonalPhraseSmoke` and the runtime CI assertion. [Run 40644857534](https://github.com/jush0147/stoat-keyboard/actions/runs/40644857534) was **pending** at documentation time; check the final status before claiming punctuation behavior passed.
- Full App/Extension build after the production punctuation integration: [run 40644812347](https://github.com/jush0147/stoat-keyboard/actions/runs/40644812347) **SUCCESS**.
- Do not count a build or a queued runtime test as proof of end-to-end punctuation behavior. The separate Simulator-backed new-word test is mandatory.

## Explicit partial two-syllable selection (cloud product integration)

The native engine probe [run 40645409715](https://github.com/jush0147/stoat-keyboard/actions/runs/40645409715) **SUCCESS** observed actual `dldl` input (ㄎㄠ ㄎㄠ), first expanded-panel confirmation `靠` with **no commit** and Rime preedit becoming `靠ㄎㄠ`; selecting `拷` next produced a single final commit `靠拷`. The first selection is **not** independently committed and must not be prematurely fed into a personal lexicon.

New product implementation at `RimeEngineLibrime.verifiedSelection`: when the live Rime preedit reports **exactly two space-separated full Zhuyin syllables**, reverse-map those syllables to the exact DaQian raw input, capture one explicitly selected Han character with its genuine prefix/preview and selection offset, and defer training. Only when a second explicit selection produces an actual Rime commit *exactly equal* to the two chosen Han characters, with original input unchanged, emit two verified segment events. Any new key, clear, schema option change, failed selection, changed original input or mismatch discards tentative evidence. Supports normal and expanded candidate selection through one shared path. No inference from initial-only input, host text, external text or unverifiable readings.

`KeyboardViewController.apply` consumes the new `confirmedSegments` only **after the actual full native commit**, reusing the same privacy-gated local `PersonalPhraseLearning` and explicit boundary. This is an intentionally narrow **two-character** vertical slice; arbitrary partial selections, syllable ambiguity, homophonic alignment and full-sentence phrase boundaries remain unimplemented.

The real Simulator segmented integration acceptance was added to `PersonalPhraseSmoke` and `rime-runtime.yml`, targeting full `ㄎㄠㄎㄠ` and initials `ㄎㄎ` recall after repeated completed two-stage selections, including cancellation. [Run 40646192499](https://github.com/jush0147/stoat-keyboard/actions/runs/40646192499) was **in progress at documentation time**; check final result before claiming the integration passed. Full App and Extension compile for the production segmented handler [run 40646135234](https://github.com/jush0147/stoat-keyboard/actions/runs/40646135234) **SUCCESS**.
