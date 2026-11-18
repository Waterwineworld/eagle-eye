# Eagle Eye – Uusi Era

Cleaning-quality monitoring web app for Uusi Era Palvelut Oy: mobile inspections with weighted 0–5 scoring, deviations, customer view, monthly reports and cleaner performance.

- `index.html` – the app (single file, no build step). Add `?demo=1` to the address for a demo with sample data stored only in the browser.
- `supabase/schema.sql` – database setup: tables, roles and access rules. Run it once in the Supabase SQL Editor; it is safe to run again.

Roles: admin, inspector, cleaner, customer. Admins add users in Settings → Users (needs the admin-users Edge Function, see supabase/functions). Cleaners clock in and out at the site: the phone’s position is checked once against the site’s location (or the site’s QR code is scanned) and is never stored.

After updating the app, run `supabase/schema.sql` again in the Supabase SQL Editor; it upgrades the database in place.

## Working hours and pay (database version 6)
- **Tauko**: a clock-in with no site, allowed anywhere without a location check (e.g. working at a site not assigned to you). Recorded, not paid unless an admin decides so.
- **Planned time** per site for the main visit and an optional mid-day visit (empty = no planned time, the cleaner is trusted). Hours up to the allowance (default 25 min) over are approved automatically; bigger overruns wait for the admin.
- **Flags**: under 5 min = mistaken clock-in (left out), over 12 h at one site in a day, shift still open 60 min past its planned time. All thresholds are in Settings → Working time and pay. Each flag links to the shift page where the admin approves, pays the planned time, sets hours (with a reason) or discards.
- **Kilometres**: on sites marked "travel paid" the cleaner enters km to the site; pay = payable hours × hourly rate + km × €/km. Payroll PDF/CSV on the Working hours page.
- **Approve and lock** a finished pay period; the database refuses changes to locked periods until an admin unlocks.
