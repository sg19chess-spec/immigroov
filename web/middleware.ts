import { NextResponse, type NextRequest } from "next/server";

// Edge middleware: Vercel resolves the visitor's country at the edge for free
// (no external API call). We stash it in a cookie the client reads as the
// primary geo source; the client-side provider chain is only a fallback.
export function middleware(request: NextRequest) {
  const res = NextResponse.next();
  const country = (
    (request as any).geo?.country ||
    request.headers.get("x-vercel-ip-country") ||
    ""
  ).toUpperCase();
  if (/^[A-Z]{2}$/.test(country)) {
    res.cookies.set("ig_geo", country, { path: "/", maxAge: 86400, sameSite: "lax" });
  }
  return res;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
