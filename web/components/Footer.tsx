import Link from "next/link";

// Global footer — trust + navigation. Static links only; no behavior.
export default function Footer() {
  return (
    <footer className="footer">
      <div className="footer-in">
        <div>
          <div className="footer-brand"><span className="logo">I<b>G</b></span> Immigroov</div>
          <p className="footer-mission">
            1:1 mentoring with vetted immigration experts — in your language, your timezone and
            fair local pricing. Private by design, with contact details always masked.
          </p>
          <p className="footer-disc">
            Immigroov connects you with independent mentors for guidance and is not a law firm.
            Sessions are informational and do not constitute legal advice.
          </p>
        </div>

        <div>
          <h6>Explore</h6>
          <Link href="/">Browse mentors</Link>
          <Link href="/webinars">Live webinars</Link>
          <Link href="/chat">Messages</Link>
          <Link href="/bookings">My sessions</Link>
        </div>

        <div>
          <h6>Support</h6>
          <a href="mailto:hello@immigroov.com">Contact us</a>
          <Link href="/">Ask Groovia AI</Link>
          <a href="mailto:privacy@immigroov.com">Privacy requests</a>
        </div>
      </div>
      <div className="footer-bottom-in">
        <span>© {new Date().getFullYear()} Immigroov · Confidential</span>
        <span>🔒 Your privacy protected — contact details never shared</span>
      </div>
    </footer>
  );
}
