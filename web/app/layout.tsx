import "./globals.css";
import type { Metadata } from "next";
import Nav from "@/components/Nav";
import Footer from "@/components/Footer";
import ChatWidget from "@/components/ChatWidget";

export const metadata: Metadata = {
  title: "Immigroov — 1:1 Immigration Mentoring",
  description: "Book private 1:1 video sessions with vetted immigration mentors — in your language, your timezone and fair local pricing.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Nav />
        {children}
        <Footer />
        <ChatWidget />
      </body>
    </html>
  );
}
