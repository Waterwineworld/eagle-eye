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
create or replace function public.can_see_site(sid text) returns boolean language sql stable security definer set search_path=public as $$
 select case public.my_role()
  when 'admin' then true when 'inspector' then true
  when 'customer' then exists(select 1 from public.sites s where s.id=sid and s.customer_id=public.my_customer())
  when 'cleaner' then exists(select 1 from public.sites s where s.id=sid and s.cleaner_id=public.my_cleaner())
   or exists(select 1 from public.issues i where i.site_id=sid and i.cleaner_id=public.my_cleaner())
   or exists(select 1 from public.inspections n where n.site_id=sid and n.cleaner_id=public.my_cleaner())
  else false end $$;
create or replace function public.can_see_cleaner(cid text) returns boolean language sql stable security definer set search_path=public as $$
 select case public.my_role()
  when 'admin' then true when 'inspector' then true
  when 'cleaner' then cid=public.my_cleaner()
  when 'customer' then exists(select 1 from public.sites s where s.cleaner_id=cid and s.customer_id=public.my_customer())
   or exists(select 1 from public.inspections n join public.sites s on s.id=n.site_id where n.cleaner_id=cid and s.customer_id=public.my_customer())
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
 foreach t in array array['customers','cleaners','cleaner_contacts','items','site_types','sites','inspections','issues','settings','profiles'] loop
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
create policy read on public.sites for select to authenticated using(public.can_see_site(id));
create policy admin_write on public.sites for all to authenticated using(public.my_role()='admin') with check(public.my_role()='admin');
-- inspections: inspectors add, admins change; customers read their sites; cleaners read their own
create policy read on public.inspections for select to authenticated
 using(public.is_staff() or cleaner_id=public.my_cleaner() or (public.my_role()='customer' and public.can_see_site(site_id)));
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
