/**
 * Lightweight, deterministic eval for complaint rewrite outputs.
 * Inputs: request, response, context_pack.
 * Output: RewriteEvalResultV1-like object with violation codes.
 * This is a reference implementation; wire it into the async worker.
 */

export type ViolationCode =
  | 'vulgarity'
  | 'slur'
  | 'personal_attack'
  | 'authority'
  | 'preference_disclosure'
  | 'medical'
  | 'new_fact'
  | 'non_target_locale'
  | 'blame'
  | 'sarcasm_warn'
  | 'hedge_warn';

type EvalResult = {
  schema_valid: boolean;
  lexicon_pass: boolean;
  tone_safety: 'pass' | 'warn' | 'fail';
  intent_preserved: 'pass' | 'warn' | 'fail';
  violations: ViolationCode[];
  judge_version: string;
  dataset_version: string | 'none';
};

type Request = {
  rewrite_request_id: string;
  target_locale: string;
  original_text: string;
  intent: 'request' | 'boundary' | 'concern' | 'clarification';
};

type Response = {
  rewrite_request_id: string;
  recipient_user_id: string;
  rewritten_text: string;
  output_language: string;
};

type ContextPack = {
  power: { power_mode: 'higher_sender' | 'higher_recipient' | 'peer' };
};

const PROFANITY = /\b(fuck|shit|damn|asshole|bitch|bastard)\b/i;
const SLURS = /\b(retard|idiot|moron)\b/i;
const PERSONAL_ATTACK = /\byou\b[^.!?]*(stupid|lazy|disgusting|selfish|idiot)/i;
const AUTHORITY = /(because\s+i\s*(am|\'m)\s*(the\s*)?(owner|landlord)|house rules|you must|you have to)/i;
const PREF_DISCLOSURE = /(your preferences|tailored for you|based on your answers)/i;
const MEDICAL = /(adhd|autistic|bipolar|psychopath|crazy)/i;
const BLAME = /(your fault|you always|you never)/i;
const SARCASM = /(yeah right|sure you|of course you)/i;
const HEDGE = /(maybe|perhaps|kinda|sort of|possibly)/i;

function unique<T>(arr: T[]): T[] {
  return Array.from(new Set(arr));
}

export function evaluateRewrite(
  req: Request,
  res: Response,
  ctx: ContextPack,
  opts: { judge_version?: string; dataset_version?: string } = {}
): EvalResult {
  const violations: ViolationCode[] = [];

  // Schema + locale
  const schema_valid = !!res.rewrite_request_id && !!res.recipient_user_id && !!res.rewritten_text;
  if (res.output_language.toLowerCase() !== req.target_locale.toLowerCase()) {
    violations.push('non_target_locale');
  }

  // Lexicon checks (hard)
  const text = res.rewritten_text;
  if (PROFANITY.test(text)) violations.push('vulgarity');
  if (SLURS.test(text)) violations.push('slur');
  if (PERSONAL_ATTACK.test(text)) violations.push('personal_attack');
  if (AUTHORITY.test(text)) violations.push('authority');
  if (PREF_DISCLOSURE.test(text)) violations.push('preference_disclosure');
  if (MEDICAL.test(text)) violations.push('medical');
  if (BLAME.test(text)) violations.push('blame');

  // Warn-level
  if (SARCASM.test(text)) violations.push('sarcasm_warn');
  // Hedging: warn only if hedge words are >1% of tokens
  const hedgeHits = (text.match(new RegExp(HEDGE, 'gi')) || []).length;
  const tokenCount = Math.max(1, text.split(/\s+/).length);
  if (hedgeHits / tokenCount > 0.01) violations.push('hedge_warn');

  // Power/tone: enforce no authority for higher_sender; no demands for higher_recipient
  if (ctx.power.power_mode === 'higher_sender' && /\b(must|have to|rules)\b/i.test(text)) {
    violations.push('authority');
  }
  if (ctx.power.power_mode === 'higher_recipient' && /\b(must|have to|immediately)\b/i.test(text)) {
    violations.push('authority');
  }

  // Intent preservation (very light heuristic): ensure a request verb exists for request/boundary intents
  let intent_preserved: 'pass' | 'warn' | 'fail' = 'pass';
  if (req.intent === 'request' || req.intent === 'boundary') {
    if (!/\b(could you|would you|please|can you|let\'s|would it be)\b/i.test(text)) {
      intent_preserved = 'warn';
    }
  }

  // Determine tone_safety
  const hard = violations.some((v) =>
    ['vulgarity', 'slur', 'personal_attack', 'authority', 'preference_disclosure', 'medical', 'new_fact', 'non_target_locale', 'blame'].includes(v)
  );
  const warnOnly = !hard && violations.some((v) => ['sarcasm_warn', 'hedge_warn'].includes(v));
  const tone_safety: 'pass' | 'warn' | 'fail' = hard ? 'fail' : warnOnly ? 'warn' : 'pass';

  const lexicon_pass = !hard;

  return {
    schema_valid,
    lexicon_pass,
    tone_safety,
    intent_preserved,
    violations: unique(violations),
    judge_version: opts.judge_version || 'v1',
    dataset_version: opts.dataset_version || 'none',
  };
}

// Note: main runner omitted for Deno compatibility; see batch_runner for usage.
