# Immigroov — Supabase Cost Report

_Scope: Supabase infrastructure cost only._

---

## 1. TL;DR

- **$25/month (Pro plan) is sufficient for launch and early growth.**
- It comfortably hosts **thousands of mentors** and **~10,000 video sessions/month**.
- The cost curve is **gradual and compute-driven, not a cliff**: `$25 → $30 → $75`.
- **The real bottleneck is compute (DB CPU/RAM/concurrency)** — not storage, bandwidth, users, or functions, which stay cheap even when exceeded.
- Honest framing: _not_ "$25 forever for unlimited scale," but **"$25 covers launch + early growth; scaling is a predictable, reversible, one-size-at-a-time bump."**

---

## 1b. How long do we stay at $25 — and is it enough?

**Short answer: $25/month covers us from launch through early growth — realistically
months to a couple of years — until Immigroov becomes a genuinely busy platform. And
even then the next step is ~$30, not a jump.**

**What ends the $25 is load, not a calendar date.** $25 doesn't expire after X months;
it only ends when many people hit the database *at the same time* and the Micro engine
gets stressed. Storage and users will **not** push us off $25 for a long time:
- Thousands of mentors → fine (and past that, cents per GB).
- 80,000–160,000 sessions of stored history → fits the included disk.
- Up to 100,000 active users/month included.

So the only thing that moves us off $25 is **concurrent traffic** — a "good problem."

### Cost ladder by growth stage

| Stage | ~Sessions/month | What's happening | Monthly cost |
|---|---|---|---|
| **Launch** | 0 – 5,000 | First mentors & users | **$25** |
| **Early growth** | 5,000 – ~10,000 | Steady bookings, light chat | **$25** |
| **Getting busy** | ~10,000 – 30,000 | Real concurrency / active chat | **~$30** (→ Small) |
| **Busy platform** | 30,000 – 50,000+ | Heavy simultaneous load | **~$75** (→ Medium) |

### Translated to time (depends on growth speed)
- **Slow / steady growth:** $25 for **1–2+ years**.
- **Fast growth:** "getting busy" in **a few months**, then **~$30**.
- Either way the move is **gradual and reversible** (scale up for a busy week, back down after).

> **Bottom line: $25 is sufficient, and we stay on it through launch + early growth.
> When we outgrow it, it's a +$5 step to ~$30 — not a cliff. For the foreseeable
> roadmap our number is "$25, eventually ~$30." There is no point where the bill
> suddenly explodes.**

---

## 2. What the $25 Pro plan includes

| Resource | Included | Overage price |
|---|---|---|
| Compute (Micro engine) | 1 instance, **covered by the $10 credit** | size up = pay the difference |
| Database disk | 8 GB | $0.125 / GB |
| File storage | 100 GB | $0.0213 / GB |
| Egress / bandwidth | 250 GB/mo | $0.09 / GB |
| Monthly active users (MAU) | 100,000 | $0.00325 / MAU |
| Edge function calls | 2,000,000/mo | $2 / million |
| Realtime messages | 5,000,000/mo | $2.50 / million |
| Backups | Daily (7-day retention) | — |

**The $10 credit**: a monthly compute allowance included with Pro. The Micro engine
costs exactly $10/mo, so the credit cancels it → flat **$25/mo**. The credit is
**per organization (not per project)** and **does not roll over**.

---

## 3. Capacity analysis (with lower & upper limits)

Per-unit estimates (realistic, chat-inclusive):
- **Per session stored:** 50–100 KB (chat dominates)
- **Per mentor stored:** 2–10 MB (photo + certificates + ID docs)

| Dimension | Limited by | Lower limit | Upper limit |
|---|---|---|---|
| **Mentors** | 100 GB file storage | **~10,000** (10 MB each) | **~50,000** (2 MB each) |
| **Session history** | 8 GB DB disk | **~80,000 sessions** (100 KB) | **~160,000 sessions** (50 KB) |
| **Sessions / month** | **Compute (Micro)** | **~10,000** (comfortable) | **~50,000** (Micro pushed) |
| **Active users / month** | MAU quota | — | **100,000** (hard cap) |

**Key insight — storage limits are soft and cheap, compute is the real wall:**
- A full year at 10,000 sessions/mo ≈ 12 GB DB → ~4 GB over → **~$0.50/month**.
- 20,000 mentors at 10 MB ≈ 200 GB → 100 GB over → **~$2/month**.
- Going "over" on storage adds **dollars, not a tier jump**. Compute is what forces a real step up.

---

## 4. Why compute is the bottleneck (and whether Micro is enough)

Our workload is **light on the database**:
- Browse / search / book = a few simple, fast queries on small tables.
- **Video runs on Jitsi** — during a call the DB does nothing.
- The frontend goes through Supabase's API layer (PostgREST), which **pools connections** — 10,000 users ≠ 10,000 DB connections.

➡️ **Micro (1 GB RAM, 2 shared cores, 200 pooled connections) is enough for launch and early growth** — hundreds to low-thousands of daily active users, ~10,000 sessions/month.

**The one caveat: live chat / realtime.** Many users connected and typing at once is
the workload most likely to pressure the 1 GB RAM first. Booking + browsing alone is fine.

**When to upgrade (watch in Dashboard → Reports → Database):**
- CPU consistently > 70%, or
- RAM near the 1 GB ceiling, or
- query latency rising / connection pool maxing during peak hours.

---

## 5. Compute tiers & cost (the scaling curve)

| Size | List price | Specs | After $10 credit | **Total bill** |
|---|---|---|---|---|
| **Micro** (launch) | $10/mo | 1 GB RAM, 200 pooled conns | –$10 | **$25/mo** |
| **Small** | $15/mo | 2 GB RAM, 400 pooled conns | +$5 | **~$30/mo** |
| **Medium** | $60/mo | 4 GB RAM, 600 pooled conns | +$50 | **~$75/mo** |
| Large | $110/mo | 8 GB RAM, 800 pooled conns | +$100 | ~$125/mo |

- **Billed hourly**, scale up/down anytime, **no downtime, no migration, reversible**.
- Micro → Small is the natural first step and likely covers real early traffic + light chat.
- Medium only for genuinely busy concurrent load.

---

## 6. Billing gotchas (avoidable with discipline)

| # | Gotcha | How to avoid |
|---|---|---|
| 1 | Compute is billed **per project**, but only **one $10 credit** per org | Keep **one** prod project; use local dev / branches, not a 2nd always-on project |
| 2 | Pro projects **never pause** — compute bills 24/7 even when idle | Don't leave extra projects running |
| 3 | **Spend cap does not limit compute size** (only usage overages) | Keep cap **on**; treat sizing-up as a deliberate decision |
| 4 | **Disk grows but doesn't shrink** — you keep paying for peak size | Archive/delete old chat; keep media in Storage, not Postgres |
| 5 | **Branches & read replicas** each bill compute (~$10/mo per branch left on) | Delete branches when done |
| 6 | The **$10 credit doesn't roll over** | — |

**Billing hygiene rule of thumb:** _one prod project · spend cap on · no forgotten
branches/replicas._ Do that and it's a flat $25 until concurrency forces a step up.

---

## 7. Schema note (keeps storage cheap)

- Chat (the `dm` feature) is **not yet built**. When added, use a **dedicated
  `messages` table** (not chat blobbed into the booking row) so rows stay small and
  old threads can be **archived/deleted**. This stops chat from dominating the 8 GB disk.

---

## 8. Recommendation

1. **Launch on Pro / Micro ($25/mo).**
2. **Keep the spend cap ON** and run **one** production project.
3. **Enable CPU/RAM alerts** in the dashboard; upgrade Micro → Small (~$30) reactively when graphs say so.
4. **Don't store video/recordings in Supabase** — it's object storage, not a streaming CDN; keep only links in the DB.
5. Build chat with a dedicated `messages` table + archiving when the time comes.

> **Bottom line: $25/month is enough to launch and grow. Scaling cost is gradual,
> compute-driven, and reversible — $25 → $30 → $75 as concurrency rises — not a trap.**
