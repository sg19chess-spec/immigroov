import "./globals.css";
import type { Metadata } from "next";
import Nav from "@/components/Nav";

export const metadata: Metadata = {
  title: "Immigroov — Mentor Marketplace",
  description: "Book 1:1 immigration mentoring sessions.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Nav />
        {children}
      </body>
    </html>
  );
}
