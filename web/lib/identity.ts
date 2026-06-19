// Demo identity: just an email kept in localStorage. No passwords/magic links.
export const getEmail = () => (typeof window !== "undefined" ? localStorage.getItem("ig_email") : null);
export function setEmail(e: string) {
  localStorage.setItem("ig_email", e.trim().toLowerCase());
  window.dispatchEvent(new Event("ig-auth"));
}
export function clearEmail() {
  localStorage.removeItem("ig_email");
  window.dispatchEvent(new Event("ig-auth"));
}
