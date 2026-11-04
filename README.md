# Eagle Eye – Uusi Era

Cleaning-quality monitoring web app for Uusi Era Palvelut Oy: mobile inspections with weighted 0–5 scoring, deviations, customer view, monthly reports and cleaner performance.

- `index.html` – the app (single file, no build step). Add `?demo=1` to the address for a demo with sample data stored only in the browser.
- `supabase/schema.sql` – database setup: tables, roles and access rules. Run it once in the Supabase SQL Editor; it is safe to run again.

Roles: admin, inspector, cleaner, customer. New logins have no access until an admin gives them a role (Settings → Users).
