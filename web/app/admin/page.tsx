"use client";
import AdminManager from "@/components/AdminManager";

// Admin overview — cross-mentor activity + the full ledger. Reached via the top-nav
// Admin toggle. The admin_* RPCs are ungated for the demo; gate to an admin role for prod.
export default function AdminPage() {
  return (
    <div className="container">
      <div className="section-head">
        <div>
          <h2 className="sec">Admin overview</h2>
          <div className="lead">All bookings and ledger activity across every mentor.</div>
        </div>
      </div>
      <AdminManager />
    </div>
  );
}
