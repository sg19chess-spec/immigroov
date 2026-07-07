"use client";
import { useEffect, useRef, useState } from "react";
import { useParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { myTz, fmtTime, fmtDate } from "@/lib/format";

type WindowState = "waiting" | "open" | "closed" | "cancelled";
type PageState =
  | "loading" | "invalid_token" | "cancelled" | "waiting"
  | "ready" | "joining" | "already_joined" | "closed" | "error";

type CheckResult = {
  state: WindowState;
  slot_time: string;
  window_opens_at: string;
  window_closes_at: string;
  already_joined: boolean;
  meeting_url: string | null;
};

function countdown(targetIso: string) {
  const ms = new Date(targetIso).getTime() - Date.now();
  if (ms <= 0) return "any moment now";
  const totalSec = Math.floor(ms / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

export default function JoinPage() {
  const params = useParams();
  const token = params?.token as string;
  const supabase = createClient();
  const tz = myTz();

  const [pageState, setPageState] = useState<PageState>("loading");
  const [check, setCheck] = useState<CheckResult | null>(null);
  const [, forceTick] = useState(0); // re-render every second for the countdown
  const [errMsg, setErrMsg] = useState<string | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  function scheduleNext(delayMs: number) {
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(poll, delayMs);
  }

  async function poll() {
    const { data, error } = await supabase.rpc("check_join_window_by_token", { p_token: token });
    if (error) {
      setErrMsg(error.message || "");
      setPageState(error.message?.toLowerCase().includes("invalid") ? "invalid_token" : "error");
      return;
    }
    const c = data as CheckResult;
    setCheck(c);

    if (c.state === "cancelled") { setPageState("cancelled"); return; }
    if (c.state === "closed") { setPageState("closed"); return; }
    if (c.state === "open") {
      setPageState(c.already_joined ? "already_joined" : "ready");
      // keep polling gently in case status changes (e.g. mentor cancels mid-window)
      scheduleNext(20000);
      return;
    }
    // waiting
    setPageState("waiting");
    const msToOpen = new Date(c.window_opens_at).getTime() - Date.now();
    scheduleNext(msToOpen < 60000 ? 5000 : 20000);
  }

  useEffect(() => {
    if (!token) return;
    poll();
    return () => { if (timerRef.current) clearTimeout(timerRef.current); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token]);

  // tick every second while waiting, purely for the countdown display
  useEffect(() => {
    if (pageState !== "waiting") return;
    const id = setInterval(() => forceTick((n) => n + 1), 1000);
    return () => clearInterval(id);
  }, [pageState]);

  async function handleJoin() {
    setPageState("joining");
    const { data, error } = await supabase.rpc("record_session_join_by_token", { p_token: token });
    if (error) {
      setErrMsg(error.message || "");
      setPageState("error");
      return;
    }
    const url = (data as any)?.meeting_url;
    if (!url) {
      setErrMsg("This session doesn't have a video link.");
      setPageState("error");
      return;
    }
    window.location.href = url;
  }

  function handleRejoin() {
    if (check?.meeting_url) window.location.href = check.meeting_url;
  }

  return (
    <div className="container" style={{ maxWidth: 520 }}>
      <div className="card" style={{ textAlign: "center" }}>
        {pageState === "loading" && <p className="muted">Checking your join link…</p>}

        {pageState === "invalid_token" && (
          <>
            <h2 className="sec">Link not recognized</h2>
            <p className="muted">This join link doesn't match a session we can find. Double-check the link from your email, or contact support.</p>
          </>
        )}

        {pageState === "cancelled" && (
          <>
            <h2 className="sec">This session was cancelled</h2>
            <p className="muted">There's nothing to join — this booking is no longer active.</p>
          </>
        )}

        {pageState === "waiting" && check && (
          <>
            <h2 className="sec">Not quite time yet</h2>
            <p className="muted">Your session is on {fmtDate(check.slot_time, tz)} at {fmtTime(check.slot_time, tz)} ({tz}).</p>
            <p style={{ fontSize: 28, fontWeight: 700, margin: "16px 0" }}>{countdown(check.window_opens_at)}</p>
            <p className="faint">The Join button will unlock shortly before the start time.</p>
          </>
        )}

        {pageState === "ready" && check && (
          <>
            <h2 className="sec">Ready to join</h2>
            <p className="muted">Your session is starting now.</p>
            <button className="btn btn-cta btn-lg" style={{ marginTop: 16 }} onClick={handleJoin}>
              Join Meeting
            </button>
          </>
        )}

        {pageState === "joining" && <p className="muted">Joining…</p>}

        {pageState === "already_joined" && (
          <>
            <h2 className="sec">You've already joined this session</h2>
            <button className="btn btn-ghost btn-lg" style={{ marginTop: 16 }} onClick={handleRejoin}>
              Rejoin Meeting
            </button>
          </>
        )}

        {pageState === "closed" && (
          <>
            <h2 className="sec">Attendance window has closed</h2>
            <p className="muted">This session's join window has ended. If you think this is a mistake, please contact support.</p>
          </>
        )}

        {pageState === "error" && (
          <>
            <h2 className="sec">Something went wrong</h2>
            <p className="muted">{errMsg || "Please try again, or contact support if this keeps happening."}</p>
          </>
        )}
      </div>
    </div>
  );
}
