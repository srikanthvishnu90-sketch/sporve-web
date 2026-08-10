/* Coach command bar — intent parser.
 *
 * The page is static and ships under a CSP that blocks every external request,
 * so it cannot call Anthropic directly, and an API key in client-side JS is a
 * public key. This function is the only place the key exists: the browser POSTs
 * a sentence to /api/ai (same origin) and gets back a structured action.
 *
 * The model NEVER executes anything. It returns {action, target, body} and the
 * client decides whether that is allowed, showing a confirmation for anything
 * that reaches a family. Parsing and doing are deliberately separate.
 */

import Anthropic from "@anthropic-ai/sdk";

/* Haiku 4.5 — the cheapest current model ($1/$5 per Mtok). Filling three fields
   from one sentence is a classification task, which is what it is best at. */
const MODEL = "claude-haiku-4-5";

/* Every verb the command bar can produce. The model may not invent one: the
   schema is strict, so an unmappable sentence comes back as "unknown" rather
   than as a plausible-looking action against the wrong feature. */
const ACTION_SCHEMA = {
  type: "object",
  properties: {
    action: {
      type: "string",
      enum: [
        "send_group_message",
        "create_group",
        "open_tab",
        "unknown",
      ],
      description: "The single operation the coach is asking for.",
    },
    target: {
      type: "string",
      description:
        "What the action applies to. For send_group_message and create_group, " +
        "the group name exactly as the coach said it (e.g. 'monday noon'). " +
        "For open_tab, one of: dashboard, schedule, bookings, roster, inbox, " +
        "listings, finances, reviews, media, notes. Empty string if none.",
    },
    body: {
      type: "string",
      description:
        "The message text to send, for send_group_message only. Write it as the " +
        "coach would send it to families. Empty string for every other action.",
    },
    restated: {
      type: "string",
      description:
        "One short sentence restating what will happen, shown to the coach " +
        "before anything is sent.",
    },
  },
  required: ["action", "target", "body", "restated"],
  additionalProperties: false,
};

const SYSTEM = `You turn a youth-sports coach's typed instruction into one structured action for their dashboard.

Rules:
- Return exactly one action. Never invent a capability that is not in the enum.
- "message <name> that <something>" means send_group_message: target is the group name, body is the something, rewritten as a clear message to families.
- Preserve the coach's meaning in body. Do not add pleasantries, emoji, or details they did not give you.
- If the instruction only names a place to go ("open my earnings"), use open_tab.
- If you cannot map it confidently, use "unknown" rather than guessing. A wrong action costs the coach a message to real families.
- restated is one plain sentence, addressed to the coach, e.g. "Send 'Practice is cancelled' to the Monday at noon group."`;

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  /* No key configured is a normal state, not a crash: the client falls back to
     its built-in router and the page keeps working. */
  if (!process.env.ANTHROPIC_API_KEY) {
    return res.status(503).json({ error: "ai_not_configured" });
  }

  const text = typeof req.body?.text === "string" ? req.body.text.trim() : "";
  if (!text) return res.status(400).json({ error: "empty_text" });
  if (text.length > 2000) return res.status(400).json({ error: "text_too_long" });

  /* Group names are passed in so the model resolves "monday noon" against what
     the coach actually has, instead of inventing a group that does not exist. */
  const groups = Array.isArray(req.body?.groups)
    ? req.body.groups.filter((g) => typeof g === "string").slice(0, 50)
    : [];

  const client = new Anthropic(); // reads ANTHROPIC_API_KEY from the environment

  try {
    const message = await client.messages.create({
      model: MODEL,
      max_tokens: 1024,
      system: SYSTEM,
      output_config: { format: { type: "json_schema", schema: ACTION_SCHEMA } },
      messages: [
        {
          role: "user",
          content:
            (groups.length
              ? `The coach's existing groups are: ${groups.join(", ")}.\n\n`
              : "The coach has no groups yet.\n\n") + `Instruction: ${text}`,
        },
      ],
    });

    /* A refusal returns HTTP 200 with empty content — read stop_reason first or
       content[0] throws. */
    if (message.stop_reason === "refusal") {
      return res.status(200).json({ action: "unknown", target: "", body: "", restated: "" });
    }

    const block = message.content.find((b) => b.type === "text");
    if (!block) {
      return res.status(200).json({ action: "unknown", target: "", body: "", restated: "" });
    }

    return res.status(200).json(JSON.parse(block.text));
  } catch (err) {
    /* Never leak the upstream error to the browser — it can carry request
       details. Log server-side, return a shape the client already handles. */
    console.error("ai handler failed:", err?.message || err);
    return res.status(502).json({ error: "ai_unavailable" });
  }
}
