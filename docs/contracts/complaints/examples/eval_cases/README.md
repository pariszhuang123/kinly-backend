These fixtures follow the schema in complaint_rewrite_eval_dataset_v1. Use them for offline regression and batch_runner.ts.

Fields:
- case_id: string
- topic: noise|cleanliness|privacy|guests|schedule|communication|other
- power_mode: higher_sender|higher_recipient|peer
- rewrite_strength: light_touch|full_reframe
- source_locale / target_locale
- original_text
- expected_intent
- expected_lexicon_violations: array of codes from complaint_rewrite_lexicon_v1
