// Groovia AI gating: a visitor must see/use the assistant before they can book.
// "Engaged" is set once they send a message or dismiss the intro popup.
const KEY = "groovia_engaged";

export const isEngaged = () =>
  typeof window !== "undefined" && localStorage.getItem(KEY) === "1";

export function setEngaged() {
  if (typeof window === "undefined") return;
  if (localStorage.getItem(KEY) === "1") return;
  localStorage.setItem(KEY, "1");
  window.dispatchEvent(new Event("groovia-engaged"));
}

// Ask the ChatWidget to open (used by the booking gate).
export function openGroovia() {
  if (typeof window !== "undefined") window.dispatchEvent(new Event("groovia-open"));
}
