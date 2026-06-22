"use client";
import { useEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { money } from "@/lib/format";
import { isEngaged, setEngaged } from "@/lib/groovia";

type Mentor = {
  mentor_id: number;
  name: string;
  title: string;
  profile_pic_url: string | null;
  avg_rating: number;
  review_count: number;
  min_price: number | null;
  currency: string | null;
  specializations: string[];
};
type Msg = { role: "user" | "assistant"; content: string; mentors?: Mentor[] };
type View = "modal" | "docked" | "min";

const WELCOME: Msg = {
  role: "assistant",
  content:
    "Hi, I'm **Groovia AI** 👋\n\nTell me what you're working on — a visa type, a destination country, or just *\"I'm not sure where to start\"* — and I'll point you to the right mentor and help you book.",
};
const PROMPTS = ["H-1B help", "Study in Canada", "Compare US vs UK work visas", "How does booking work?"];

// Markdown renderers: internal links navigate (and minimise the widget); tables/links styled via CSS.
const mdComponents = (closeTo: () => void) => ({
  a: ({ href, children }: any) => {
    const internal = typeof href === "string" && href.startsWith("/");
    return (
      <a
        href={href}
        target={internal ? undefined : "_blank"}
        rel={internal ? undefined : "noopener noreferrer"}
        onClick={() => internal && closeTo()}
      >
        {children}
      </a>
    );
  },
});

export default function ChatWidget() {
  const [mounted, setMounted] = useState(false);
  const [view, setView] = useState<View>("min");
  const [msgs, setMsgs] = useState<Msg[]>([WELCOME]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const bodyRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  // First-visit popup; otherwise just the bubble.
  useEffect(() => {
    setMounted(true);
    setView(isEngaged() ? "min" : "modal");
  }, []);

  // Booking gate (or anything) can ask us to open.
  useEffect(() => {
    const open = () => setView(isEngaged() ? "docked" : "modal");
    window.addEventListener("groovia-open", open);
    return () => window.removeEventListener("groovia-open", open);
  }, []);

  useEffect(() => {
    bodyRef.current?.scrollTo({ top: bodyRef.current.scrollHeight, behavior: "smooth" });
  }, [msgs, busy, view]);
  useEffect(() => {
    if (view !== "min") inputRef.current?.focus();
  }, [view]);

  function minimise() {
    setEngaged();
    setView("min");
  }

  async function send(text: string) {
    const q = text.trim();
    if (!q || busy) return;
    setEngaged();
    const next = [...msgs, { role: "user" as const, content: q }];
    setMsgs(next);
    setInput("");
    setBusy(true);
    try {
      const res = await fetch("/api/chat", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ messages: next.map((m) => ({ role: m.role, content: m.content })) }),
      });
      const data = await res.json();
      setMsgs((m) => [
        ...m,
        res.ok
          ? { role: "assistant", content: data.reply, mentors: data.mentors || [] }
          : {
              role: "assistant",
              content:
                (data?.error || "Sorry, something went wrong.") +
                (data?.detail ? `\n\n\`${data.detail}\`` : ""),
            },
      ]);
    } catch {
      setMsgs((m) => [...m, { role: "assistant", content: "I couldn't reach the server — please try again." }]);
    } finally {
      setBusy(false);
    }
  }

  if (!mounted) return null;

  const open = view !== "min";

  return (
    <>
      {/* dim background only for the first-visit modal */}
      {view === "modal" && <div className="cw-backdrop" onClick={minimise} />}

      <button
        className={`cw-fab ${open ? "hidden" : ""}`}
        onClick={() => setView("docked")}
        aria-label="Open Groovia AI"
      >
        <span className="cw-fab-ic">💬</span>
        <span className="cw-fab-txt">Ask Groovia&nbsp;AI</span>
      </button>

      {open && (
        <div className={`cw-panel ${view === "modal" ? "modal" : "docked"}`} role="dialog" aria-label="Groovia AI">
          <div className="cw-head">
            <div className="cw-avatar">G<span className="cw-dot" /></div>
            <div>
              <div className="cw-title">Groovia AI</div>
              <div className="cw-sub">Your immigration guide · online</div>
            </div>
            <button className="cw-x" onClick={minimise} aria-label="Minimise">⌄</button>
          </div>

          <div className="cw-body" ref={bodyRef}>
            {msgs.map((m, i) => (
              <div key={i} className={`cw-row ${m.role}`}>
                <div className="cw-bubble">
                  {m.role === "assistant" ? (
                    <div className="cw-md">
                      <ReactMarkdown remarkPlugins={[remarkGfm]} components={mdComponents(minimise)}>
                        {m.content}
                      </ReactMarkdown>
                    </div>
                  ) : (
                    m.content
                  )}
                </div>
                {m.mentors && m.mentors.length > 0 && (
                  <div className="cw-cards">
                    {m.mentors.map((mt) => (
                      <a
                        key={mt.mentor_id}
                        href={`/mentor/${mt.mentor_id}`}
                        className="cw-card"
                        onClick={minimise}
                      >
                        <img src={mt.profile_pic_url || "https://i.pravatar.cc/150"} alt="" width={40} height={40} />
                        <div className="cw-card-info">
                          <div className="cw-card-name">{mt.name}</div>
                          <div className="cw-card-meta">★ {Number(mt.avg_rating).toFixed(1)} · {mt.title}</div>
                        </div>
                        <div className="cw-card-price">
                          {mt.min_price != null && <span>{money(mt.min_price, mt.currency || "USD")}</span>}
                          <small>Book →</small>
                        </div>
                      </a>
                    ))}
                  </div>
                )}
              </div>
            ))}
            {busy && (
              <div className="cw-row assistant">
                <div className="cw-bubble cw-typing"><span /><span /><span /></div>
              </div>
            )}
          </div>

          {msgs.length <= 1 && (
            <div className="cw-prompts">
              {PROMPTS.map((p) => (
                <button key={p} onClick={() => send(p)} disabled={busy}>{p}</button>
              ))}
            </div>
          )}

          <form className="cw-input" onSubmit={(e) => { e.preventDefault(); send(input); }}>
            <textarea
              ref={inputRef}
              value={input}
              rows={1}
              placeholder="Ask about visas, mentors, booking…"
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(input); }
              }}
            />
            <button type="submit" disabled={busy || !input.trim()} aria-label="Send">➤</button>
          </form>
          <div className="cw-foot">Groovia AI can be wrong — confirm specifics with your mentor.</div>
        </div>
      )}
    </>
  );
}
