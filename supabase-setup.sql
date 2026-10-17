-- ============================================================
-- Vantix store — complete database setup
-- Run this ONCE in your dashboard: SQL Editor → New query → paste → Run
-- Safe to re-run (uses IF NOT EXISTS / OR REPLACE everywhere).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Profiles (one row per signed-up user)
-- ------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_url text,
  discord text,
  role text not null default 'customer' check (role in ('customer', 'admin')),
  created_at timestamptz not null default now()
);

grant select, update on public.profiles to authenticated;
grant all on public.profiles to service_role;

alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select to authenticated using (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update to authenticated using (auth.uid() = id);

-- Auto-create a profile on signup (carries over the display name / avatar
-- from email signup or Google/Discord).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill profiles for accounts created before this trigger existed.
insert into public.profiles (id, display_name, avatar_url)
select u.id,
  coalesce(u.raw_user_meta_data ->> 'display_name', u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name'),
  u.raw_user_meta_data ->> 'avatar_url'
from auth.users u
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- 2. Admin helper (used by policies below)
-- ------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  )
$$;

-- ------------------------------------------------------------
-- 3. Products (store catalog)
-- ------------------------------------------------------------
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  tagline text not null default '',
  description text not null default '',
  price numeric(10,2) not null default 0 check (price >= 0),
  platform text not null default 'pc' check (platform in ('pc', 'ios', 'other')),
  version text not null default '1.0.0',
  stock text not null default 'in' check (stock in ('in', 'low', 'out')),
  hue int not null default 220,
  rating numeric(2,1) not null default 5.0,
  sales int not null default 0,
  features text[] not null default '{}',
  image_url text,
  download_url text,
  published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

grant select on public.products to anon;
grant select on public.products to authenticated;
grant all on public.products to service_role;

alter table public.products enable row level security;

drop policy if exists "products_public_read" on public.products;
create policy "products_public_read" on public.products
  for select to anon, authenticated using (published = true or public.is_admin());

drop policy if exists "products_admin_write" on public.products;
create policy "products_admin_write" on public.products
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ------------------------------------------------------------
-- 4. Product versions (release history + downloadable builds)
-- ------------------------------------------------------------
create table if not exists public.product_versions (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  version text not null,
  notes text[] not null default '{}',
  file_url text,
  is_current boolean not null default false,
  released_at timestamptz not null default now(),
  unique (product_id, version)
);

grant select on public.product_versions to anon;
grant select on public.product_versions to authenticated;
grant all on public.product_versions to service_role;

alter table public.product_versions enable row level security;

drop policy if exists "versions_public_read" on public.product_versions;
create policy "versions_public_read" on public.product_versions
  for select to anon, authenticated using (true);

drop policy if exists "versions_admin_write" on public.product_versions;
create policy "versions_admin_write" on public.product_versions
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ------------------------------------------------------------
-- 5. Orders + order items
-- ------------------------------------------------------------
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,           -- e.g. VX-20512
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null,
  full_name text,
  country text,
  discord text,
  subtotal numeric(10,2) not null default 0,
  discount numeric(10,2) not null default 0,
  fee numeric(10,2) not null default 0,
  total numeric(10,2) not null default 0,
  coupon_code text,
  payment_method text check (payment_method in ('card', 'paypal', 'upi', 'crypto')),
  payment_status text not null default 'pending'
    check (payment_status in ('paid', 'pending', 'failed', 'refunded')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists orders_user_idx on public.orders(user_id);

grant select, insert on public.orders to authenticated;
grant all on public.orders to service_role;

alter table public.orders enable row level security;

drop policy if exists "orders_select_own" on public.orders;
create policy "orders_select_own" on public.orders
  for select to authenticated using (auth.uid() = user_id or public.is_admin());

drop policy if exists "orders_insert_own" on public.orders;
create policy "orders_insert_own" on public.orders
  for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists "orders_admin_update" on public.orders;
create policy "orders_admin_update" on public.orders
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid not null references public.products(id),
  price numeric(10,2) not null,
  created_at timestamptz not null default now()
);

create index if not exists order_items_order_idx on public.order_items(order_id);

grant select, insert on public.order_items to authenticated;
grant all on public.order_items to service_role;

alter table public.order_items enable row level security;

drop policy if exists "order_items_select_own" on public.order_items;
create policy "order_items_select_own" on public.order_items
  for select to authenticated using (
    exists (select 1 from public.orders o where o.id = order_id and (o.user_id = auth.uid() or public.is_admin()))
  );

drop policy if exists "order_items_insert_own" on public.order_items;
create policy "order_items_insert_own" on public.order_items
  for insert to authenticated with check (
    exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid())
  );

-- ------------------------------------------------------------
-- 6. License keys (inventory + assignment to orders)
-- ------------------------------------------------------------
create table if not exists public.license_keys (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  order_id uuid references public.orders(id) on delete set null,
  key text not null unique,
  status text not null default 'unassigned'
    check (status in ('unassigned', 'active', 'expired', 'revoked')),
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists license_keys_product_idx on public.license_keys(product_id);
create index if not exists license_keys_order_idx on public.license_keys(order_id);

grant select on public.license_keys to authenticated;
grant all on public.license_keys to service_role;

alter table public.license_keys enable row level security;

-- Customers see only keys attached to their own orders; admins see all.
drop policy if exists "keys_select_own" on public.license_keys;
create policy "keys_select_own" on public.license_keys
  for select to authenticated using (
    public.is_admin() or exists (
      select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid()
    )
  );

drop policy if exists "keys_admin_write" on public.license_keys;
create policy "keys_admin_write" on public.license_keys
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ------------------------------------------------------------
-- 7. Coupons
-- ------------------------------------------------------------
create table if not exists public.coupons (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  percent_off int not null check (percent_off between 1 and 100),
  max_uses int,
  uses int not null default 0,
  expires_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

grant select on public.coupons to authenticated;
grant all on public.coupons to service_role;

alter table public.coupons enable row level security;

-- Signed-in users may validate an active coupon code at checkout.
drop policy if exists "coupons_read_active" on public.coupons;
create policy "coupons_read_active" on public.coupons
  for select to authenticated using (active = true or public.is_admin());

drop policy if exists "coupons_admin_write" on public.coupons;
create policy "coupons_admin_write" on public.coupons
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ------------------------------------------------------------
-- 8. Support tickets
-- ------------------------------------------------------------
create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  subject text not null,
  message text not null,
  status text not null default 'open' check (status in ('open', 'answered', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

grant select, insert on public.support_tickets to authenticated;
grant all on public.support_tickets to service_role;

alter table public.support_tickets enable row level security;

drop policy if exists "tickets_select_own" on public.support_tickets;
create policy "tickets_select_own" on public.support_tickets
  for select to authenticated using (auth.uid() = user_id or public.is_admin());

drop policy if exists "tickets_insert_own" on public.support_tickets;
create policy "tickets_insert_own" on public.support_tickets
  for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists "tickets_admin_update" on public.support_tickets;
create policy "tickets_admin_update" on public.support_tickets
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- ------------------------------------------------------------
-- 9. Store settings (single row, admin-editable)
-- ------------------------------------------------------------
create table if not exists public.store_settings (
  id int primary key default 1 check (id = 1),
  store_name text not null default 'Vantix',
  currency text not null default 'USD',
  fee_rate numeric(4,3) not null default 0.05,
  maintenance_mode boolean not null default false,
  support_email text,
  discord_invite text,
  auto_reply text,
  updated_at timestamptz not null default now()
);

insert into public.store_settings (id) values (1) on conflict (id) do nothing;

grant select on public.store_settings to anon;
grant select on public.store_settings to authenticated;
grant all on public.store_settings to service_role;

alter table public.store_settings enable row level security;

drop policy if exists "settings_public_read" on public.store_settings;
create policy "settings_public_read" on public.store_settings
  for select to anon, authenticated using (true);

drop policy if exists "settings_admin_write" on public.store_settings;
create policy "settings_admin_write" on public.store_settings
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ------------------------------------------------------------
-- 10. updated_at auto-touch
-- ------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists touch_products on public.products;
create trigger touch_products before update on public.products
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_orders on public.orders;
create trigger touch_orders before update on public.orders
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_tickets on public.support_tickets;
create trigger touch_tickets before update on public.support_tickets
  for each row execute function public.touch_updated_at();

-- ============================================================
-- Done. Next steps:
-- 1. Make yourself admin (sign up first, then run):
--      update public.profiles set role = 'admin' where id = 'your-user-id';
--    (Find your user id under Authentication → Users.)
-- 2. Add products via the admin page or with inserts like:
--      insert into public.products (slug, name, tagline, price, platform, version)
--      values ('my-tool', 'My Tool', 'Short tagline', 9.99, 'pc', '1.0.0');
-- ============================================================
