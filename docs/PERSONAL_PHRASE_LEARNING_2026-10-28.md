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
