-- Eagle Eye database setup. Paste into Supabase > SQL Editor and click Run.
-- Safe to run more than once. The earliest user in Authentication > Users becomes admin
-- if there is no admin yet.

-- ===== tables =====
create table if not exists public.customers(id text primary key, name text not null);
create table if not exists public.cleaners(id text primary key, name text not null, active boolean not null default true);
-- phone numbers are kept apart so customers can see a cleaner's name but not their number
create table if not exists public.cleaner_contacts(id text primary key references public.cleaners on delete cascade, phone text);
create table if not exists public.items(id text primary key, area text not null, w int not null, pos int not null default 0, fi text not null, en text);
create table if not exists public.site_types(id text primary key, fi text not null, en text, items jsonb not null default '{}');
create table if not exists public.sites(
 id text primary key, name text not null, address text,
 customer_id text references public.customers on delete restrict,
 cleaner_id text references public.cleaners on delete set null,
 target real not null default 85, type text, items jsonb not null default '{}');
create table if not exists public.inspections(
 id text primary key, site_id text not null references public.sites on delete cascade,
 cleaner_id text references public.cleaners on delete set null,
 inspector text, date date not null, rep text, notes text, items jsonb not null, score real, cscore real);
create table if not exists public.issues(
 id text primary key, site_id text not null references public.sites on delete cascade,
 inspection_id text references public.inspections on delete cascade, item_id text, score real,
 cleaner_id text references public.cleaners on delete set null,
 comment text, photo text, after_photo text, cleaner_note text, reject_note text,
 status text not null default 'open' check(status in('open','progress','review','fixed')),
 created date not null default current_date, due date not null default current_date+3, fixed_at date,
 source text not null default 'inspection' check(source in('inspection','customer')),
 cat text not null default 'cleaning' check(cat in('cleaning','maintenance')));
create table if not exists public.settings(id int primary key default 1 check(id=1), data jsonb not null);
insert into public.settings(id,data) values(1,'{"reward":90,"minInsp":4,"fixDays":3,"issueAt":2}') on conflict do nothing;
-- a new login has no access at all until an admin gives it a role
create table if not exists public.profiles(
 id uuid primary key references auth.users on delete cascade, email text, name text,
 role text not null default 'pending' check(role in('pending','admin','inspector','cleaner','customer')),
 customer_id text references public.customers on delete set null,
 cleaner_id text references public.cleaners on delete set null);
-- added in version 2: customer contact details, when the customer was told about a fault and its fix, and cleaner absences
alter table public.customers add column if not exists email text;
alter table public.customers add column if not exists contact text;
alter table public.issues add column if not exists informed_at date;
alter table public.issues add column if not exists fixed_informed_at date;
-- while a cleaner is away, inspections of their sites are credited to the substitute
create table if not exists public.absences(
 id text primary key, cleaner_id text not null references public.cleaners on delete cascade,
 substitute_id text references public.cleaners on delete set null,
 start_date date not null, end_date date not null, reason text, check(end_date>=start_date));
-- added in version 4: clocking in and out. A site's location comes from its address; positions sent when
-- clocking in or out are only compared with it and are never stored (no tracking of staff).
alter table public.sites add column if not exists lat double precision;
alter table public.sites add column if not exists lng double precision;
alter table public.sites add column if not exists radius int not null default 200;
-- version 5: a site can have a team of cleaners besides the responsible one; an inspection records everyone on duty
alter table public.sites add column if not exists team text[] not null default '{}';
alter table public.inspections add column if not exists cleaners text[];
-- the QR code on each site's wall, kept apart so cleaners can't read the codes and clock in from elsewhere
create table if not exists public.site_qr(id text primary key references public.sites on delete cascade, code text not null unique);
insert into public.site_qr(id,code) select id,replace(gen_random_uuid()::text,'-','') from public.sites on conflict do nothing;
create table if not exists public.shifts(
 id text primary key, cleaner_id text not null references public.cleaners on delete cascade,
 site_id text not null references public.sites on delete cascade,
 start_at timestamptz not null default now(), end_at timestamptz,
 start_method text not null check(start_method in('gps','qr','manual')), end_method text check(end_method in('gps','qr','manual','correction')),
 note text, request_end_at timestamptz, request_note text, request_status text check(request_status in('pending','approved','rejected')),
 check(end_at is null or end_at>=start_at));
create index if not exists shifts_cleaner on public.shifts(cleaner_id,start_at);
create unique index if not exists shifts_one_open on public.shifts(cleaner_id) where end_at is null;
-- version 6: Tauko, planned time per visit, travel kilometres, admin review of hours, pay rates and locked pay periods.
-- A shift without a site is a Tauko clock-in: allowed anywhere in Finland, e.g. when working at a site that isn't assigned to you.
alter table public.shifts alter column site_id drop not null;
alter table public.shifts drop constraint if exists shifts_start_method_check;
alter table public.shifts add constraint shifts_start_method_check check(start_method in('gps','qr','manual','tauko'));
alter table public.shifts drop constraint if exists shifts_end_method_check;
alter table public.shifts add constraint shifts_end_method_check check(end_method in('gps','qr','manual','correction','tauko'));
alter table public.shifts add column if not exists visit text not null default 'main';
alter table public.shifts drop constraint if exists shifts_visit_check;
alter table public.shifts add constraint shifts_visit_check check(visit in('main','midday'));
alter table public.shifts add column if not exists km real;
alter table public.shifts drop constraint if exists shifts_km_check;
alter table public.shifts add constraint shifts_km_check check(km is null or (km>=0 and km<=2000));
-- the admin's decision on flagged hours; the recorded start and end times are never changed by it
alter table public.shifts add column if not exists review text;
alter table public.shifts drop constraint if exists shifts_review_check;
alter table public.shifts add constraint shifts_review_check check(review in('approved','planned','manual','kept','discarded'));
alter table public.shifts add column if not exists pay_min int;
alter table public.shifts drop constraint if exists shifts_pay_min_check;
alter table public.shifts add constraint shifts_pay_min_check check(pay_min is null or (pay_min>=0 and pay_min<=1440));
alter table public.shifts add column if not exists review_note text;
alter table public.shifts add column if not exists reviewed_at timestamptz;
alter table public.shifts add column if not exists reviewed_by text;
-- planned minutes for the main visit (empty: no planned time, the cleaner is trusted), an optional mid-day visit,
-- and whether travel kilometres to the site are paid
alter table public.sites add column if not exists plan_min int;
alter table public.sites add column if not exists plan2_min int;
alter table public.sites add column if not exists km_paid boolean not null default false;
-- hourly wage per cleaner (admins only); the default rate is in settings
create table if not exists public.cleaner_pay(id text primary key references public.cleaners on delete cascade, hour_rate numeric(8,2));
-- an approved pay period: its hours can no longer be changed until an admin unlocks it
create table if not exists public.pay_locks(id text primary key, locked_at timestamptz not null default now(), locked_by text);
create index if not exists inspections_site on public.inspections(site_id);
create index if not exists inspections_cleaner on public.inspections(cleaner_id);
create index if not exists issues_site on public.issues(site_id);
create index if not exists issues_cleaner on public.issues(cleaner_id);
create index if not exists issues_inspection on public.issues(inspection_id);
create index if not exists sites_customer on public.sites(customer_id);
create index if not exists sites_cleaner on public.sites(cleaner_id);

-- ===== helpers (security definer so policies can read these tables without recursion) =====
create or replace function public.my_role() returns text language sql stable security definer set search_path=public as
 $$ select role from public.profiles where id=auth.uid() $$;
create or replace function public.my_customer() returns text language sql stable security definer set search_path=public as
 $$ select customer_id from public.profiles where id=auth.uid() $$;
create or replace function public.my_cleaner() returns text language sql stable security definer set search_path=public as
 $$ select cleaner_id from public.profiles where id=auth.uid() $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path=public as
 $$ select coalesce(public.my_role() in('admin','inspector'),false) $$;
create or replace function public.is_active() returns boolean language sql stable security definer set search_path=public as
 $$ select coalesce(public.my_role() in('admin','inspector','cleaner','customer'),false) $$;
-- where the signed-in cleaner works today: responsible, in the site's team, or covering an absent colleague
create or replace function public.works_at(sid text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(public.my_cleaner() is not null and (
  exists(select 1 from public.sites s where s.id=sid and (s.cleaner_id=public.my_cleaner() or public.my_cleaner()=any(s.team)))
  or exists(select 1 from public.absences a join public.sites s on (s.cleaner_id=a.cleaner_id or a.cleaner_id=any(s.team))
   where s.id=sid and a.substitute_id=public.my_cleaner() and current_date between a.start_date and a.end_date)),false) $$;
create or replace function public.can_see_site(sid text) returns boolean language sql stable security definer set search_path=public as $$
 select case public.my_role()
  when 'admin' then true when 'inspector' then true
  when 'customer' then exists(select 1 from public.sites s where s.id=sid and s.customer_id=public.my_customer())
  when 'cleaner' then public.works_at(sid)
   or exists(select 1 from public.issues i where i.site_id=sid and i.cleaner_id=public.my_cleaner())
   or exists(select 1 from public.inspections n where n.site_id=sid and (n.cleaner_id=public.my_cleaner() or public.my_cleaner()=any(n.cleaners)))
  else false end $$;
create or replace function public.can_see_cleaner(cid text) returns boolean language sql stable security definer set search_path=public as $$
 select case public.my_role()
  when 'admin' then true when 'inspector' then true
  when 'cleaner' then cid=public.my_cleaner()
  when 'customer' then exists(select 1 from public.sites s where (s.cleaner_id=cid or cid=any(s.team)) and s.customer_id=public.my_customer())
   or exists(select 1 from public.inspections n join public.sites s on s.id=n.site_id where (n.cleaner_id=cid or cid=any(n.cleaners)) and s.customer_id=public.my_customer())
   or exists(select 1 from public.issues i join public.sites s on s.id=i.site_id where i.cleaner_id=cid and s.customer_id=public.my_customer())
  else false end $$;

-- ===== new logins get a profile automatically =====
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.profiles(id,email) values(new.id,new.email) on conflict(id) do nothing; return new; end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
insert into public.profiles(id,email) select id,email from auth.users on conflict(id) do nothing;
update public.profiles set role='admin' where not exists(select 1 from public.profiles where role='admin')
 and id=(select id from auth.users order by created_at limit 1);

-- ===== the developer account: always admin, and nobody can change or remove it from the app =====
-- It is the first login ever created (the one that set the system up). To move the flag to another
-- account, run here in the SQL Editor:  update public.profiles set is_developer=(email='new@address');
alter table public.profiles add column if not exists is_developer boolean not null default false;
update public.profiles set is_developer=true where not exists(select 1 from public.profiles where is_developer)
 and id=(select id from auth.users order by created_at limit 1);
update public.profiles set role='admin' where is_developer;
create or replace function public.profiles_guard() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then return coalesce(new,old); end if; -- the SQL Editor stays in full control
 if tg_op='DELETE' then
  if old.is_developer then raise exception 'the developer account cannot be removed'; end if;
  return old;
 end if;
 if old.is_developer and (new.role<>'admin' or not new.is_developer) then raise exception 'the developer account cannot be changed'; end if;
 if new.is_developer and not old.is_developer then raise exception 'only the database owner can mark a developer account'; end if;
 return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update or delete on public.profiles for each row execute function public.profiles_guard();
revoke all on function public.profiles_guard() from public,anon,authenticated;

-- ===== limits on what each role may change in a deviation =====
create or replace function public.issues_guard() returns trigger language plpgsql security definer set search_path=public as $$
declare r text:=public.my_role(); days int;
begin
 if auth.uid() is null or r='admin' then return new; end if; -- SQL editor and admins are unrestricted
 if tg_op='INSERT' and r='customer' then
  select coalesce((data->>'fixDays')::int,3) into days from public.settings where id=1;
  select cleaner_id into new.cleaner_id from public.sites where id=new.site_id;
  new.status:='open'; new.source:='customer'; new.cat:='cleaning'; new.inspection_id:=null; new.item_id:=null; new.score:=null;
  new.after_photo:=null; new.cleaner_note:=null; new.reject_note:=null; new.fixed_at:=null; new.created:=current_date; new.due:=current_date+days;
 elsif tg_op='UPDATE' and r='cleaner' then
  if new.status not in('progress','review') then raise exception 'cleaners can only start a deviation or send it for review'; end if;
  -- a cleaner may record their own work and nothing else
  new.id:=old.id; new.site_id:=old.site_id; new.inspection_id:=old.inspection_id; new.item_id:=old.item_id; new.score:=old.score;
  new.cleaner_id:=old.cleaner_id; new.comment:=old.comment; new.photo:=old.photo; new.reject_note:=old.reject_note;
  new.created:=old.created; new.due:=old.due; new.source:=old.source; new.cat:=old.cat;
  new.fixed_at:=case when new.status='review' then current_date else old.fixed_at end;
 elsif tg_op='UPDATE' and r='inspector' then
  new.cat:=old.cat; -- the cause affects cleaner rewards, so only an admin can change it afterwards
 end if;
 return new;
end $$;
drop trigger if exists issues_guard on public.issues;
create trigger issues_guard before insert or update on public.issues for each row execute function public.issues_guard();

-- saves an inspection and its deviations together; retrying after a lost connection is harmless
create or replace function public.save_inspection(p_inspection jsonb,p_issues jsonb) returns void language plpgsql set search_path=public as $$
begin
 insert into public.inspections select * from jsonb_populate_record(null::public.inspections,p_inspection) on conflict(id) do nothing;
 insert into public.issues select * from jsonb_populate_recordset(null::public.issues,p_issues) on conflict(id) do nothing;
end $$;

-- ===== access rules =====
do $$ declare t text; begin
 foreach t in array array['customers','cleaners','cleaner_contacts','items','site_types','sites','inspections','issues','settings','profiles','absences','shifts','site_qr','cleaner_pay','pay_locks'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from anon',t);
  execute format('grant select,insert,update,delete on public.%I to authenticated',t);
 end loop;
end $$;
do $$ declare p record; begin
 for p in select policyname,tablename from pg_policies where schemaname='public' loop
  execute format('drop policy %I on public.%I',p.policyname,p.tablename);
 end loop;
end $$;
-- catalog: everyone with a role reads, only admins change
create policy read on public.items for select to authenticated using(public.is_active());
create policy admin_write on public.items for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
create policy read on public.site_types for select to authenticated using(public.is_active());
create policy admin_write on public.site_types for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
create policy read on public.settings for select to authenticated using(public.is_active());
create policy admin_write on public.settings for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
-- customers see only themselves; cleaners don't need the customer list
create policy read on public.customers for select to authenticated using(public.is_staff() or id=public.my_customer());
create policy admin_write on public.customers for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
create policy read on public.cleaners for select to authenticated using(public.can_see_cleaner(id));
create policy admin_write on public.cleaners for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
create policy read on public.cleaner_contacts for select to authenticated using(public.is_staff());
create policy admin_write on public.cleaner_contacts for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
create policy read on public.shifts for select to authenticated using(public.is_staff() or cleaner_id=public.my_cleaner());
create policy staff_update on public.shifts for update to authenticated using(public.is_staff()) with check(public.is_staff());
create policy admin_insert on public.shifts for insert to authenticated with check(public.my_role()='admin');
create policy admin_delete on public.shifts for delete to authenticated using(public.my_role()='admin');
create policy admin_all on public.cleaner_pay for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
create policy read on public.pay_locks for select to authenticated using(public.is_active());
create policy admin_write on public.pay_locks for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
create policy read on public.site_qr for select to authenticated using(public.is_staff());
create policy admin_write on public.site_qr for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
create policy read on public.absences for select to authenticated using(public.is_staff());
create policy admin_write on public.absences for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
create policy read on public.sites for select to authenticated using(public.can_see_site(id));
create policy admin_write on public.sites for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
-- inspections: inspectors add, admins change; customers read their sites; cleaners read their own
create policy read on public.inspections for select to authenticated
 using(public.is_staff() or cleaner_id=public.my_cleaner() or public.my_cleaner()=any(cleaners) or (public.my_role()='customer' and public.can_see_site(site_id)));
create policy staff_insert on public.inspections for insert to authenticated with check(public.is_staff());
create policy admin_update on public.inspections for update to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
create policy admin_delete on public.inspections for delete to authenticated using(public.my_role()='admin');
-- deviations: see issues_guard above for which fields each role may touch
create policy read on public.issues for select to authenticated
 using(public.is_staff() or cleaner_id=public.my_cleaner() or (public.my_role()='customer' and public.can_see_site(site_id)));
create policy staff_insert on public.issues for insert to authenticated with check(public.is_staff());
create policy customer_insert on public.issues for insert to authenticated with check(public.my_role()='customer' and source='customer' and public.can_see_site(site_id));
create policy staff_update on public.issues for update to authenticated using(public.is_staff()) with check(public.is_staff());
create policy cleaner_update on public.issues for update to authenticated
 using(public.my_role()='cleaner' and cleaner_id=public.my_cleaner()) with check(public.my_role()='cleaner' and cleaner_id=public.my_cleaner());
create policy admin_delete on public.issues for delete to authenticated using(public.my_role()='admin');
-- profiles: read your own; only admins see others or change roles
create policy read_own on public.profiles for select to authenticated using(id=auth.uid() or public.my_role()='admin');
create policy admin_update on public.profiles for update to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');

-- ===== clocking in and out =====
create or replace function public.dist_m(lat1 float8,lng1 float8,lat2 float8,lng2 float8) returns float8 language sql immutable as
 $$ select 2*6371000*asin(sqrt(power(sin(radians(lat2-lat1)/2),2)+cos(radians(lat1))*cos(radians(lat2))*power(sin(radians(lng2-lng1)/2),2))) $$;
-- new sites get their own QR code
create or replace function public.site_qr_new() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.site_qr(id,code) values(new.id,replace(gen_random_uuid()::text,'-','')) on conflict do nothing; return new; end $$;
drop trigger if exists site_qr_new on public.sites;
create trigger site_qr_new after insert on public.sites for each row execute function public.site_qr_new();
-- is the cleaner at this site right now? Either the phone is within the site's radius, or they scanned its QR code.
create or replace function public.at_site(p_site text,p_lat float8,p_lng float8,p_acc float8,p_qr text) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare s record; d float8;
begin
 if p_qr is not null then
  if exists(select 1 from public.site_qr q where q.id=p_site and q.code=p_qr) then return jsonb_build_object('ok',true,'method','qr'); end if;
  return jsonb_build_object('ok',false,'reason','bad_qr');
 end if;
 if p_lat is null or p_lng is null then return jsonb_build_object('ok',false,'reason','no_location'); end if;
 select * into s from public.sites where id=p_site;
 if s.lat is null then return jsonb_build_object('ok',false,'reason','no_site_location'); end if;
 d:=public.dist_m(p_lat,p_lng,s.lat,s.lng);
 if d<=s.radius+least(coalesce(p_acc,0),100) then return jsonb_build_object('ok',true,'method','gps'); end if;
 return jsonb_build_object('ok',false,'reason','too_far','distance',round(d));
end $$;
drop function if exists public.clock_in(text,float8,float8,float8,text);
create or replace function public.clock_in(p_site text,p_lat float8,p_lng float8,p_acc float8,p_qr text,p_tauko boolean default false) returns jsonb language plpgsql security definer set search_path=public as $$
declare c text:=public.my_cleaner(); sid text:=p_site; chk jsonb; nid text; v text:='main';
begin
 if public.my_role() is distinct from 'cleaner' or c is null then return jsonb_build_object('ok',false,'reason','not_cleaner'); end if;
 if exists(select 1 from public.shifts where cleaner_id=c and end_at is null) then return jsonb_build_object('ok',false,'reason','already_in'); end if;
 -- Tauko works anywhere: no site and no position check
 if coalesce(p_tauko,false) then
  nid:='sh'||replace(gen_random_uuid()::text,'-','');
  insert into public.shifts(id,cleaner_id,site_id,start_at,start_method) values(nid,c,null,now(),'tauko');
  return jsonb_build_object('ok',true,'shift',nid,'site',null,'method','tauko');
 end if;
 -- a scanned code names its own site; otherwise use the chosen site, or the nearest of the cleaner's sites
 if p_qr is not null then select q.id into sid from public.site_qr q where q.code=p_qr; end if;
 if sid is null and p_lat is not null then
  select s.id into sid from public.sites s where s.lat is not null and public.works_at(s.id) order by public.dist_m(p_lat,p_lng,s.lat,s.lng) limit 1;
 end if;
 if sid is null or not public.works_at(sid) then return jsonb_build_object('ok',false,'reason',case when p_qr is not null then 'bad_qr' when p_lat is null then 'no_location' else 'no_site' end); end if;
 chk:=public.at_site(sid,p_lat,p_lng,p_acc,p_qr);
 if not (chk->>'ok')::boolean then return chk||jsonb_build_object('site',sid); end if;
 nid:='sh'||replace(gen_random_uuid()::text,'-','');
 -- a site with a mid-day visit: the second clock-in of the day there is the mid-day visit (the cleaner can change it)
 if exists(select 1 from public.sites s where s.id=sid and s.plan2_min is not null) and exists(select 1 from public.shifts x where x.cleaner_id=c and x.site_id=sid and x.visit='main'
   and (x.start_at at time zone 'Europe/Helsinki')::date=(now() at time zone 'Europe/Helsinki')::date) then v:='midday'; end if;
 insert into public.shifts(id,cleaner_id,site_id,start_at,start_method,visit) values(nid,c,sid,now(),chk->>'method',v);
 return jsonb_build_object('ok',true,'shift',nid,'site',sid,'method',chk->>'method','visit',v);
end $$;
create or replace function public.clock_out(p_lat float8,p_lng float8,p_acc float8,p_qr text) returns jsonb language plpgsql security definer set search_path=public as $$
declare c text:=public.my_cleaner(); sh record; chk jsonb;
begin
 if public.my_role() is distinct from 'cleaner' or c is null then return jsonb_build_object('ok',false,'reason','not_cleaner'); end if;
 select * into sh from public.shifts where cleaner_id=c and end_at is null;
 if not found then return jsonb_build_object('ok',false,'reason','not_in'); end if;
 if sh.site_id is null then
  update public.shifts set end_at=now(),end_method='tauko' where id=sh.id;
  return jsonb_build_object('ok',true,'shift',sh.id,'method','tauko');
 end if;
 chk:=public.at_site(sh.site_id,p_lat,p_lng,p_acc,p_qr);
 if not (chk->>'ok')::boolean then return chk||jsonb_build_object('site',sh.site_id); end if;
 update public.shifts set end_at=now(),end_method=chk->>'method' where id=sh.id;
 return jsonb_build_object('ok',true,'shift',sh.id,'method',chk->>'method');
end $$;
-- forgot to clock out: the cleaner states the real end time and a supervisor approves it
create or replace function public.request_correction(p_end timestamptz,p_note text) returns jsonb language plpgsql security definer set search_path=public as $$
declare c text:=public.my_cleaner(); sh record;
begin
 if public.my_role() is distinct from 'cleaner' or c is null then return jsonb_build_object('ok',false,'reason','not_cleaner'); end if;
 select * into sh from public.shifts where cleaner_id=c and end_at is null;
 if not found then return jsonb_build_object('ok',false,'reason','not_in'); end if;
 if p_end<=sh.start_at or p_end>now() then return jsonb_build_object('ok',false,'reason','bad_time'); end if;
 update public.shifts set request_end_at=p_end,request_note=nullif(trim(p_note),''),request_status='pending' where id=sh.id;
 return jsonb_build_object('ok',true,'shift',sh.id);
end $$;
-- the cleaner adds which visit it was, kilometres driven to the site (only where they are paid) and a note;
-- possible while the shift is open and for two days after, until an admin has reviewed it
create or replace function public.set_shift_info(p_shift text,p_visit text,p_km real,p_note text) returns jsonb language plpgsql security definer set search_path=public as $$
declare c text:=public.my_cleaner(); sh record; kp boolean;
begin
 if public.my_role() is distinct from 'cleaner' or c is null then return jsonb_build_object('ok',false,'reason','not_cleaner'); end if;
 select * into sh from public.shifts where id=p_shift and cleaner_id=c;
 if not found then return jsonb_build_object('ok',false,'reason','not_found'); end if;
 if sh.review is not null or (sh.end_at is not null and sh.end_at<now()-interval '2 days') then return jsonb_build_object('ok',false,'reason','too_late'); end if;
 if p_km is not null and (p_km<0 or p_km>2000) then return jsonb_build_object('ok',false,'reason','bad_km'); end if;
 select km_paid into kp from public.sites where id=sh.site_id;
 update public.shifts set visit=case when p_visit in('main','midday') then p_visit else visit end,km=case when coalesce(kp,false) then p_km else null end,
  note=nullif(left(trim(coalesce(p_note,'')),300),'') where id=sh.id;
 return jsonb_build_object('ok',true,'shift',sh.id);
end $$;
-- pay periods run 1st–15th (key YYYY-MM-1) and 16th–end (YYYY-MM-2), Finnish time
create or replace function public.pay_key(ts timestamptz) returns text language sql stable as
 $$ select to_char(ts at time zone 'Europe/Helsinki','YYYY-MM')||'-'||case when extract(day from ts at time zone 'Europe/Helsinki')<=15 then '1' else '2' end $$;
-- hours in a locked (approved) pay period can't change; only admins decide on flagged hours
create or replace function public.shifts_guard() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then return coalesce(new,old); end if; -- the SQL Editor stays in full control
 if tg_op in('UPDATE','DELETE') and exists(select 1 from public.pay_locks where id=public.pay_key(old.start_at)) then raise exception 'this pay period is approved and locked'; end if;
 if tg_op in('INSERT','UPDATE') and exists(select 1 from public.pay_locks where id=public.pay_key(new.start_at)) then raise exception 'this pay period is approved and locked'; end if;
 if tg_op='UPDATE' and public.my_role() is distinct from 'admin' and (new.review is distinct from old.review or new.pay_min is distinct from old.pay_min
   or new.review_note is distinct from old.review_note or new.reviewed_at is distinct from old.reviewed_at or new.reviewed_by is distinct from old.reviewed_by) then
  raise exception 'only an admin can approve working hours'; end if;
 return coalesce(new,old);
end $$;
drop trigger if exists shifts_guard on public.shifts;
create trigger shifts_guard before insert or update or delete on public.shifts for each row execute function public.shifts_guard();
revoke all on function public.shifts_guard() from public,anon,authenticated;
revoke all on function public.at_site(text,float8,float8,float8,text) from public,anon,authenticated;
revoke all on function public.site_qr_new() from public,anon,authenticated;
do $$ declare f text; begin
 foreach f in array array['clock_in(text,float8,float8,float8,text,boolean)','clock_out(float8,float8,float8,text)','request_correction(timestamptz,text)','set_shift_info(text,text,real,text)'] loop
  execute format('revoke all on function public.%s from public,anon',f); execute format('grant execute on function public.%s to authenticated',f);
 end loop; end $$;

revoke all on function public.save_inspection(jsonb,jsonb) from public,anon;
grant execute on function public.save_inspection(jsonb,jsonb) to authenticated;
revoke all on function public.handle_new_user() from public,anon,authenticated;
revoke all on function public.issues_guard() from public,anon,authenticated;

-- ===== photos: private bucket, one folder per site =====
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('photos','photos',false,3145728,array['image/jpeg']) on conflict(id) do nothing;
drop policy if exists ee_photos_read on storage.objects;
drop policy if exists ee_photos_add on storage.objects;
drop policy if exists ee_photos_delete on storage.objects;
create policy ee_photos_read on storage.objects for select to authenticated
 using(bucket_id='photos' and public.can_see_site((storage.foldername(name))[1]));
create policy ee_photos_add on storage.objects for insert to authenticated
 with check(bucket_id='photos' and public.can_see_site((storage.foldername(name))[1]));
create policy ee_photos_delete on storage.objects for delete to authenticated
 using(bucket_id='photos' and public.my_role()='admin');
