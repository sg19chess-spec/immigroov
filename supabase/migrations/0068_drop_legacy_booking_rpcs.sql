-- =============================================================================
-- 0068 — Drop the legacy, anon-callable booking/payment RPCs that bypass the
-- 0065 server-side pricing engine.
--
-- Postgres overloads functions by signature, so earlier `create or replace` /
-- single-signature drops left several OLD overloads alive and still granted to
-- anon. Each of these lets a caller create a confirmed booking + paid payment
-- row with a CLIENT-SUPPLIED price (or an instant mock "paid"), bypassing PPP,
-- the platform fee, and server FX — the exact fraud vector 0065 was meant to
-- close. None are referenced by the frontend (which uses cancel_booking and the
-- new book_session_guest(uuid,...) overload) and none are called internally by
-- any trigger/function/cron (verified by grep over all migrations).
--
-- After this, the ONLY booking-creation path is book_session_guest(uuid,...),
-- which commits a server-priced binding quote — the correct foundation for
-- real payments.
-- =============================================================================

-- Old guest booking with client-supplied p_mentee_cost (pre-quote).
drop function if exists book_session_guest(bigint,bigint,timestamptz,text,numeric,text,text,text,jsonb);

-- Logged-in booking overloads with client-supplied cost / ppp factor.
drop function if exists book_session(bigint,bigint,timestamptz,text,numeric,jsonb);              -- 0018
drop function if exists book_session(bigint,bigint,timestamptz,text,numeric,jsonb,text,numeric);  -- 0023 (+p_ppp_factor)

-- Demo/mock money paths (instant "paid", no real charge; also client-priced).
drop function if exists demo_book_and_pay(bigint,bigint,timestamptz,text,text,text,text,numeric,jsonb);
drop function if exists book_and_pay_mock(bigint,bigint,timestamptz,text,text,uuid,text,text,text);
drop function if exists cancel_and_refund_mock(bigint,text);
