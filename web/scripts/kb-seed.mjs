// Static platform knowledge for the AI assistant's vector store (FAQs + guides).
// Country details live in the country_docs table; mentor details come from
// kb_mentor_source(). Both are merged in by ingest.mjs. PUBLIC content only —
// no legal advice, no personal data.

export const SEED = [
  // ── How Immigroov works (FAQ) ──────────────────────────────────────────
  {
    kind: "faq",
    source_key: "how-it-works",
    title: "How Immigroov works",
    content:
      "Immigroov is a marketplace for booking 1:1 video sessions with vetted immigration mentors. You browse mentors by specialization, country, and language, pick a service (for example a 30 or 60 minute consultation), choose an open time slot, and book. Sessions happen over a video link (Jitsi). Mentors share guidance from lived and professional experience; they are not a substitute for a licensed attorney for case-specific legal advice.",
  },
  {
    kind: "faq",
    source_key: "booking-timezones",
    title: "Booking and time zones",
    content:
      "When you open a mentor's page you pick a service, then a date on the calendar. Only dates the mentor is available are selectable; choosing a date opens the available time slots. All times are shown in your own time zone, automatically converted from the mentor's availability, so you never have to do the math. You'll get a confirmation by email with the video link.",
  },
  {
    kind: "faq",
    source_key: "pricing-currency",
    title: "Pricing, currency, and fair pricing",
    content:
      "Each mentor sets their price. Prices are shown in your local currency, converted from the mentor's listing currency. Immigroov applies purchasing-power-parity (PPP) fair pricing, so visitors from lower-cost countries may see a reduced price while higher-income markets pay the standard rate. The exact amount is always shown at checkout before you confirm. Immigroov adds a small platform fee on top of the mentor's rate.",
  },
  {
    kind: "faq",
    source_key: "mentor-vs-lawyer",
    title: "Mentor vs. immigration lawyer",
    content:
      "Immigroov mentors offer guidance, planning, document-preparation tips, and first-hand experience with specific visa routes and countries. They can help you understand your options, avoid common mistakes, and prepare. For a binding legal opinion, formal eligibility assessment, or representation before authorities, consult a licensed immigration attorney. A mentor can help you decide whether you need one.",
  },
  {
    kind: "guide",
    source_key: "prepare-session",
    title: "Getting the most from a mentoring session",
    content:
      "Before your session, write down your goal (study, work, permanent residency, family), your current status and nationality, your target country, and your timeline. Gather any deadlines and a short summary of your situation. Bring specific questions. During the session, take notes and ask the mentor what to do next and what to watch out for. Don't share sensitive identifiers like passport or government ID numbers unless truly necessary.",
  },
  {
    kind: "guide",
    source_key: "choosing-visa-type",
    title: "Choosing the right visa route",
    content:
      "Immigration routes usually fall into a few families: study visas (enrolment at an institution), work visas (employer sponsorship or skilled-worker points systems), permanent residency or skilled-migration programs, family or partner visas, and investor/entrepreneur routes. The best route depends on your goal, qualifications, work experience, language ability, and how long you want to stay. A mentor who specializes in your destination can help you compare routes for your situation.",
  },
];
