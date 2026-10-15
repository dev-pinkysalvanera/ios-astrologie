/**
 * Server-side output moderation — lightweight regex-based content filter.
 *
 * Runs on every streamed Gemini chunk before it reaches the client. Patterns
 * are intentionally broad: the goal is to catch obvious violations, not to
 * replace Gemini's own safety settings.
 *
 * Trade-offs:
 *  - False positives are possible (e.g. "kill" in a legitimate astrology context).
 *    The cost of a false positive (one chunk replaced with "[Content filtered]")
 *    is low relative to the cost of a false negative.
 *  - Regex matching is O(n * patterns). The pattern list is short, so this stays
 *    under a microsecond per chunk in practice.
 */

/** Result of moderating a text chunk. */
export type ModerationResult =
  | { passed: true; text: string }
  | { passed: false; reason: string };

/**
 * Disallowed content patterns — regex-based, case-insensitive.
 * Each entry has a compiled regex and a human-readable reason for blocking.
 */
const BLOCKLIST: { pattern: RegExp; reason: string }[] = [
  // Explicit sexual content
  {
    pattern:
      /\b(explicit\s+sexual|pornograph|erotic\s+content|sexually\s+explicit|sexual\s+intercourse\s+description)\b/i,
    reason: "Sexual content detected.",
  },
  // Graphic violence descriptions
  {
    pattern:
      /\b(graphic\s+violence|dismember|mutilat|gore\s+detail|torture\s+instruction|how\s+to\s+kill\s+someone)\b/i,
    reason: "Violent content detected.",
  },
  // Self-harm / suicide instructions
  {
    pattern:
      /\b(suicide\s+method|how\s+to\s+(harm|cut|kill)\s+(yourself|myself)|self[- ]harm\s+instruction|end\s+your\s+life)\b/i,
    reason: "Self-harm content detected.",
  },
  // Drug manufacturing
  {
    pattern:
      /\b(how\s+to\s+(make|cook|synthesize)\s+(meth|cocaine|heroin|fentanyl)|drug\s+manufactur)/i,
    reason: "Drug manufacturing content detected.",
  },
  // Weapons / explosives instructions
  {
    pattern:
      /\b(how\s+to\s+(make|build)\s+(a\s+)?(bomb|explosive|weapon)|explosive\s+recipe)\b/i,
    reason: "Weapons/explosives content detected.",
  },
];

/**
 * Scan a text chunk against the blocklist.
 *
 * @param text - The text to moderate (typically a single SSE chunk from Gemini).
 * @returns `{ passed: true, text }` if clean, `{ passed: false, reason }` if blocked.
 */
export function moderateOutput(text: string): ModerationResult {
  for (const { pattern, reason } of BLOCKLIST) {
    if (pattern.test(text)) {
      return { passed: false, reason };
    }
  }
  return { passed: true, text };
}

// ---------------------------------------------------------------------------
// Input: known jailbreak framing (Week 10 Task 10)
// ---------------------------------------------------------------------------

/**
 * Known jailbreak phrasings, checked on the person's message before Gemini is
 * called.
 *
 * A speed bump, not the wall: rephrasing gets past any denylist. It catches
 * the copy-pasted attempts cheaply, without a second Gemini call. Patterns are
 * narrow on purpose ("act as", say, is left out because "act as my astrologer"
 * is a fair request), so a false positive is rare and costs one rephrase.
 */
const JAILBREAK_PATTERNS: { pattern: RegExp; reason: string }[] = [
  {
    pattern:
      /\b(ignore|disregard|forget)\s+(all\s+|any\s+)?(the\s+|your\s+)?(previous|prior|above|earlier|system)\s+(instructions|rules|prompts?|messages)\b/i,
    reason: "instruction-override",
  },
  { pattern: /\byou\s+are\s+now\b/i, reason: "persona-swap" },
  { pattern: /\bpretend\s+(to\s+be|you\s+are)\b/i, reason: "persona-swap" },
  { pattern: /\b(role[- ]?play|roleplaying)\b/i, reason: "roleplay" },
  {
    pattern: /\bwrite\s+(me\s+)?a\s+(story|scene|script)\s+(where|in\s+which)\b/i,
    reason: "fiction-framing",
  },
  {
    pattern:
      /\b(reveal|show|print|repeat|output)\b.{0,30}\b(system\s+prompt|your\s+instructions)\b/i,
    reason: "prompt-extraction",
  },
  { pattern: /\b(developer|god|jailbreak)\s+mode\b/i, reason: "mode-switch" },
];

/**
 * Which jailbreak pattern `message` matches, or `null` when it matches none.
 *
 * The returned label is for logs only; the person is told the same thing
 * whichever pattern matched.
 */
export function detectJailbreak(message: string): string | null {
  for (const { pattern, reason } of JAILBREAK_PATTERNS) {
    if (pattern.test(message)) return reason;
  }
  return null;
}
