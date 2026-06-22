import OpenAI from "openai";
import { createClient } from "@supabase/supabase-js";

// Node runtime (the OpenAI SDK needs Node, not the Edge runtime).
export const runtime = "nodejs";
export const maxDuration = 30;

// ── Models / providers ────────────────────────────────────────────────────
// Generation goes through OpenRouter (OpenAI-compatible). Set OPENROUTER_MODEL
// to any chat model you have credits for (e.g. anthropic/claude-3.5-sonnet,
// openai/gpt-4o, google/gemini-2.0-flash-001).
const OPENROUTER_MODEL = process.env.OPENROUTER_MODEL || "anthropic/claude-3.5-sonnet";

// Embeddings are OpenAI-compatible and configurable. OpenRouter does not expose
// an embeddings endpoint, so this defaults to OpenAI; point it elsewhere via env
// if you have another OpenAI-compatible embeddings provider. Must stay 1536-dim
// to match the vector(1536) column / match_kb() (migration 0024).
const EMBED_MODEL = process.env.EMBEDDINGS_MODEL || "text-embedding-3-small";
const EMBED_BASE_URL = process.env.EMBEDDINGS_BASE_URL || "https://api.openai.com/v1";
const EMBED_KEY = process.env.EMBEDDINGS_API_KEY || process.env.OPENAI_API_KEY || "";
const HAS_RAG = !!EMBED_KEY;

const SYSTEM = `You are "Groovia AI", the assistant for Immigroov — a marketplace where people book 1:1 video sessions with vetted immigration mentors (visas, work permits, study-abroad, PR/citizenship, relocation).

GROUNDING — this is critical, never break it:
- For any question about a specific country, visa type, eligibility, timelines, or how the immigration process works, you MUST call search_knowledge first and base your answer ONLY on the snippets it returns.
- If search_knowledge returns nothing relevant, say you don't have specific information on that yet and offer to connect them with a mentor. Do NOT invent fees, processing times, quotas, or eligibility rules. Never guess.
- To recommend mentors, call search_mentors and only mention mentors that appear in the results — never make up a mentor, rating, or price.

Recommending mentors:
- Mention each mentor by name with a one-line reason they fit.
- Include a Markdown booking link for each, pointing to their page: [Book with NAME →](/mentor/MENTOR_ID) using the mentor_id from search_mentors. The visitor must talk to you before booking, so always guide them to the booking link.
- search_mentors prices are starting prices ("from"); the exact, region-adjusted price shows at checkout.

Formatting:
- Use GitHub-flavored Markdown. When comparing 2+ options, visa routes, or mentors, present them as a Markdown table.
- Keep answers concise and friendly. No preamble like "Here is" — answer directly.

Boundaries:
- You are NOT a lawyer: give general information, not legal determinations or guarantees, and point to a qualified mentor/attorney for specific cases.
- Do not ask for or repeat sensitive personal data (passport numbers, government IDs, financial details).
- If asked something unrelated to immigration or Immigroov, briefly steer back.`;

type ChatTool = OpenAI.Chat.Completions.ChatCompletionTool;

const MENTOR_TOOL: ChatTool = {
  type: "function",
  function: {
    name: "search_mentors",
    description:
      "Search the Immigroov mentor marketplace. Call this whenever the visitor wants to find, compare, or pick a mentor, or asks a question a particular mentor would specialize in (a visa type, a destination country, or a topic like 'study abroad' or 'green card'). Returns matching mentors with mentor_id, title, specializations, languages, rating, and starting price.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string", description: "Keywords, e.g. 'H-1B', 'Canada express entry'." },
        specialization: { type: "string", description: "Single specialization name to filter by." },
        language: { type: "string", description: "Language the mentor must speak." },
        sort: {
          type: "string",
          enum: ["rating", "price_asc", "price_desc", "reviews"],
          description: "Sort order. Defaults to 'rating'.",
        },
      },
      required: [],
    },
  },
};

const KNOWLEDGE_TOOL: ChatTool = {
  type: "function",
  function: {
    name: "search_knowledge",
    description:
      "Semantic search over Immigroov's immigration knowledge base (country/visa guides, how the process works, FAQs, mentor profiles). Call BEFORE answering any factual question about a country, visa, eligibility, timeline, or how Immigroov works, and ground your answer in the snippets returned.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string", description: "Focused natural-language search query." },
        kind: {
          type: "string",
          enum: ["country", "guide", "faq", "service", "mentor"],
          description: "Optional filter to one kind of document.",
        },
      },
      required: ["query"],
    },
  },
};

type MentorRow = {
  mentor_id: number;
  name: string;
  title: string;
  profile_pic_url: string | null;
  avg_rating: number;
  review_count: number;
  min_price: number | null;
  currency: string | null;
  specializations: string[];
  languages: string[];
};

function sb() {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { auth: { persistSession: false } }
  );
}

async function embed(text: string): Promise<number[]> {
  const client = new OpenAI({ apiKey: EMBED_KEY, baseURL: EMBED_BASE_URL });
  const res = await client.embeddings.create({ model: EMBED_MODEL, input: text.slice(0, 8000) });
  return res.data[0].embedding as number[];
}

async function runSearch(input: any): Promise<MentorRow[]> {
  const { data, error } = await sb().rpc("search_mentors", {
    p_search: input?.query || null,
    p_specialization: input?.specialization || null,
    p_language: input?.language || null,
    p_sort: ["rating", "price_asc", "price_desc", "reviews"].includes(input?.sort)
      ? input.sort
      : "rating",
    p_limit: 6,
  });
  if (error) throw new Error(error.message);
  return (data || []) as MentorRow[];
}

async function runKnowledge(input: any) {
  const q = String(input?.query || "").slice(0, 1000);
  if (!q) return [];
  const vec = await embed(q);
  const { data, error } = await sb().rpc("match_kb", {
    query_embedding: vec,
    match_count: 5,
    filter_kind: typeof input?.kind === "string" ? input.kind : null,
  });
  if (error) throw new Error(error.message);
  return (data || [])
    .filter((d: any) => d.similarity >= 0.2)
    .map((d: any) => ({
      title: d.title,
      content: String(d.content || "").slice(0, 900),
      url: d.url,
      similarity: Number(d.similarity?.toFixed?.(3) ?? d.similarity),
    }));
}

const forModel = (m: MentorRow) => ({
  mentor_id: m.mentor_id,
  name: m.name,
  title: m.title,
  rating: Number(m.avg_rating),
  reviews: m.review_count,
  from_price: m.min_price,
  currency: m.currency,
  specializations: m.specializations,
  languages: m.languages,
});

export async function POST(req: Request) {
  if (!process.env.OPENROUTER_API_KEY) {
    return Response.json(
      { error: "AI assistant is not configured yet (missing OPENROUTER_API_KEY)." },
      { status: 503 }
    );
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return Response.json({ error: "Invalid request." }, { status: 400 });
  }

  const incoming = Array.isArray(body?.messages) ? body.messages : [];
  const history: OpenAI.Chat.Completions.ChatCompletionMessageParam[] = incoming
    .filter(
      (m: any) =>
        (m?.role === "user" || m?.role === "assistant") && typeof m?.content === "string"
    )
    .slice(-20)
    .map((m: any) => ({ role: m.role, content: String(m.content).slice(0, 4000) }));

  if (history.length === 0 || history[history.length - 1].role !== "user") {
    return Response.json({ error: "Send a message to start." }, { status: 400 });
  }

  const messages: OpenAI.Chat.Completions.ChatCompletionMessageParam[] = [
    { role: "system", content: SYSTEM },
    ...history,
  ];
  const tools = HAS_RAG ? [KNOWLEDGE_TOOL, MENTOR_TOOL] : [MENTOR_TOOL];

  const client = new OpenAI({
    apiKey: process.env.OPENROUTER_API_KEY,
    baseURL: "https://openrouter.ai/api/v1",
    defaultHeaders: { "X-Title": "Immigroov" },
  });
  const mentorsById = new Map<number, MentorRow>();

  try {
    for (let step = 0; step < 5; step++) {
      const completion = await client.chat.completions.create({
        model: OPENROUTER_MODEL,
        max_tokens: 1024,
        messages,
        tools,
        tool_choice: "auto",
      });

      const msg = completion.choices[0].message;

      if (msg.tool_calls && msg.tool_calls.length > 0) {
        messages.push({
          role: "assistant",
          content: msg.content ?? "",
          tool_calls: msg.tool_calls,
        });

        for (const call of msg.tool_calls) {
          if (call.type !== "function") continue;
          let args: any = {};
          try {
            args = JSON.parse(call.function.arguments || "{}");
          } catch {
            /* leave args empty */
          }
          let content = "";
          try {
            if (call.function.name === "search_mentors") {
              const rows = await runSearch(args);
              rows.forEach((r) => mentorsById.set(r.mentor_id, r));
              content = JSON.stringify(rows.map(forModel));
            } else if (call.function.name === "search_knowledge") {
              const snippets = await runKnowledge(args);
              content = snippets.length
                ? JSON.stringify(snippets)
                : "No matching knowledge-base entries.";
            } else {
              content = "Unknown tool.";
            }
          } catch (e: any) {
            content = `Tool failed: ${e?.message || "unknown error"}`;
          }
          messages.push({ role: "tool", tool_call_id: call.id, content });
        }
        continue;
      }

      // Final answer.
      const reply = (msg.content || "").trim();
      const named = [...mentorsById.values()]
        .filter((m) => m.name && reply.toLowerCase().includes(m.name.toLowerCase()))
        .slice(0, 4);
      const mentors = (named.length ? named : [...mentorsById.values()].slice(0, 4)).map((m) => ({
        mentor_id: m.mentor_id,
        name: m.name,
        title: m.title,
        profile_pic_url: m.profile_pic_url,
        avg_rating: Number(m.avg_rating),
        review_count: m.review_count,
        min_price: m.min_price,
        currency: m.currency,
        specializations: m.specializations,
      }));

      return Response.json({
        reply: reply || "Sorry, I didn't catch that — could you rephrase?",
        mentors,
      });
    }

    return Response.json({
      reply: "That took longer than expected — could you try asking again?",
      mentors: [],
    });
  } catch (e: any) {
    const status = e?.status || e?.response?.status;
    if (status === 401) {
      return Response.json({ error: "AI assistant auth failed (check OPENROUTER_API_KEY)." }, { status: 503 });
    }
    if (status === 429) {
      return Response.json(
        { error: "The assistant is busy right now — please try again in a moment." },
        { status: 429 }
      );
    }
    console.error("[/api/chat]", e);
    return Response.json(
      { error: "Something went wrong reaching the assistant." },
      { status: 500 }
    );
  }
}
