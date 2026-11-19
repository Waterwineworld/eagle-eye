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

## Schedule, special orders and more (database version 7)
- **Schedule**: each site has its responsible cleaner, cleaning days, a latest start time and an optional mid-day time. Temporary changes (another cleaner, closed, extra day) are dated. A sick report from the cleaner waits for the admin to pick a substitute, who gets the whole visit. Site teams were removed.
- **Missed-visit alerts** (in the app): a visit nobody started 15 min after its latest start time, sites without a cleaner in the coming week, sick reports without a substitute.
- **Special orders**: deep cleaning / extra work with date(s), place (site or address), planned time, cleaner and price; the cleaner clocks in to the order. Billing CSV of done orders.
- **Site card** (access, keys, alarm code, instructions, contact) shown to whoever works at the site that day.
- **Supply requests** from cleaners (Faults page for supervisors).
- **Pay**: editable supplement rules (evening, night, Saturday, Sunday/holiday — enter your agreement's rates), payroll CSV with supplement columns, travel log CSV (date, start time, from, to, km, purpose), profit per site on the Reports page (contract price + extra work vs labour cost with employer costs %).
- **Cleaner sign-off** of the previous pay period (confirm or ask a question); the admin sees ✓ / ? / ! (changed after confirming).
- **QR**: a QR clock-in is refused if the phone's position is far from the site; admins can renew a site's QR code. **Tauko** needs a note before it can end.
- **Privacy notice** (#/privacy) template, and the app can be added to the home screen (manifest + service worker; no push notifications yet).

## Home pages by role
- **Owner (admin):** Overview — payroll (next pay day, gross, decisions, sign-offs, PDF/CSV), profitability, quality and customers, service delivery, staff, special orders. Groups are folded by default; each title line shows the key figure.
- **Operations manager (inspector role):** Operations — today's visits, absences and substitutes (set the substitute right there), working hours (corrections, shifts open too long), faults and customers, supply requests, inspections due, special orders.
- **Developer account:** both, plus the full classic dashboard.
- Schedule on phones shows one day at a time (day strip, "problems only", "whole week"); temporary changes are folded.

## Cleaner screens (compact)
- **Clock in:** fits on one phone screen. A status card (not clocked in / clocked in at site, since, running timer), Clock out and **Change site** (closes the shift and opens the next one with one location check), today's planned visits and finished shifts with a total, and a pay-period bar (done / planned hours, pay day). Help and the privacy note are folded under "How does clocking work?".
- **My hours:** both pay periods, confirming the last period's hours, reporting an absence, supply requests and the shift list (add note / km).

## Folded cards, plain figures, demo banner
- Every card that starts with a heading is folded by default, on every page and for every role (the inspection form, site and template editors stay open). Cards that need action stay open: today's visits on the clock screen and hours still to confirm. An opened card stays open while the app is open.
- Charts were replaced with plain figures: monthly scores as a row of numbers (below target in red), averages as a list, inspection scores as a number.
- Demo mode shows a yellow banner on every page with a "Sign in with a real account" button, and the demo login page starts with the same button. The demo is at `?demo=1` on the live address.

## Cleaner arranges the substitute
- When reporting an absence, the cleaner picks the colleague who takes the shifts (or "Not arranged yet – supervisor arranges"). The colleague can then clock in at the absent cleaner's sites, only on the absence days. The cleaner can change or clear the substitute later on My hours; the OPM can still override it.
- Database: `report_absence` takes `p_sub`; new `set_my_substitute(p_abs,p_sub)` and `colleagues()` (names only, no phone numbers). A colleague who is away on the same days, inactive, or the cleaner themself is refused. **Re-run schema.sql.**
- My hours is compact on phones: pay periods as two short rows, smaller cards.

## OPM permissions (Settings → Operations manager permissions)
The admin switches what the operations manager (inspector role) may do. Defaults: inspections, faults, forgotten clock-outs, absences and substitutes, schedule changes, special orders, supply requests, reports = on; approving working hours, pay/prices/profitability, editing sites, managing cleaners = off. "Restore defaults" returns to these.
Always admin only: logins, settings and hourly rates, locking pay periods, deleting inspections and sites.
Enforced in the database too (`public.can(p)` reads `settings.data.perms`), so hiding a button is not the only protection. **Re-run schema.sql.**
