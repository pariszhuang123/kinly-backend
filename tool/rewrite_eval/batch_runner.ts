import fs from 'node:fs';
import path from 'node:path';
import { evaluateRewrite } from './evaluator';

/**
 * Simple batch runner:
 * - Reads fixtures in docs/contracts/complaints/examples/eval_cases
 * - Expects provider outputs in a JSONL file: each line {case_id, rewritten_text, output_language}
 * - Emits results to stdout as JSONL with eval_result and case metadata.
 */

const FIXTURE_DIR = path.resolve(__dirname, '../../docs/contracts/complaints/examples/eval_cases');

function loadFixtures() {
  return fs
    .readdirSync(FIXTURE_DIR)
    .filter((f) => f.endsWith('.json'))
    .map((f) => JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, f), 'utf8')) as any);
}

function loadProviderOutputs(file: string) {
  return fs
    .readFileSync(file, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function main() {
  const outputsFile = process.argv[2];
  if (!outputsFile) {
    console.error('Usage: ts-node batch_runner.ts <provider_outputs.jsonl>');
    process.exit(1);
  }
  const fixtures = loadFixtures();
  const outputs = loadProviderOutputs(outputsFile);
  const fixtureById = new Map(fixtures.map((f) => [f.case_id, f]));

  for (const out of outputs) {
    const fx = fixtureById.get(out.case_id);
    if (!fx) {
      console.error(`Unknown case_id ${out.case_id}`);
      continue;
    }
    const evalResult = evaluateRewrite(
      {
        rewrite_request_id: fx.case_id,
        target_locale: fx.target_locale,
        original_text: fx.original_text,
        intent: fx.expected_intent,
      },
      {
        rewrite_request_id: fx.case_id,
        recipient_user_id: out.recipient_user_id || 'unknown',
        rewritten_text: out.rewritten_text,
        output_language: out.output_language,
      },
      { power: { power_mode: fx.power_mode } },
      { judge_version: 'v1', dataset_version: 'v1' }
    );

    const passedExpected = fx.expected_lexicon_violations.every((v: string) => evalResult.violations.includes(v));

    console.log(
      JSON.stringify({
        case_id: fx.case_id,
        eval_result: evalResult,
        expected_lexicon_violations: fx.expected_lexicon_violations,
        matched_expected: passedExpected,
      })
    );
  }
}

if (require.main === module) main();
