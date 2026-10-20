-- AivaroCart initial Supabase schema
-- Run once in Supabase Dashboard > SQL Editor > New query.
-- Orders/payments must be created by trusted server-side code / Edge Functions,
-- not directly by browser clients.

create extension if not exists pgcrypto;

create type public.app_role as enum ('customer', 'admin');
create type public.order_status as enum ('pending', 'confirmed', 'processing', 'shipped', 'delivered', 'cancelled', 'refunded');
create type public.payment_status as enum ('pending', 'authorized', 'paid', 'failed', 'refunded');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Role assignments are not writable by normal users. Assign the first admin manually
-- in the SQL Editor after signing up, using the instructions in the setup guide.
create table public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role public.app_role not null default 'customer',
  created_at timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.user_roles ur
    where ur.user_id = (select auth.uid()) and ur.role = 'admin'
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''))
  on conflict (id) do nothing;

  insert into public.user_roles (user_id, role)
  values (new.id, 'customer')
  on conflict (user_id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  slug text not null unique,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.categories(id) on delete set null,
  name text not null,
  slug text not null unique,
  description text,
  price_paise bigint not null check (price_paise >= 0),
  compare_at_price_paise bigint check (compare_at_price_paise is null or compare_at_price_paise >= price_paise),
  currency text not null default 'INR' check (currency = 'INR'),
  sku text unique,
  stock_quantity integer not null default 0 check (stock_quantity >= 0),
  image_urls text[] not null default '{}',
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.carts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.cart_items (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references public.carts(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity integer not null check (quantity between 1 and 99),
  created_at timestamptz not null default now(),
  unique (cart_id, product_id)
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default ('AC-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))),
  user_id uuid not null references auth.users(id) on delete restrict,
  status public.order_status not null default 'pending',
  subtotal_paise bigint not null check (subtotal_paise >= 0),
  shipping_paise bigint not null default 0 check (shipping_paise >= 0),
  discount_paise bigint not null default 0 check (discount_paise >= 0),
  total_paise bigint not null check (total_paise >= 0),
  currency text not null default 'INR' check (currency = 'INR'),
  shipping_name text not null,
  shipping_phone text not null,
  shipping_address jsonb not null,
  customer_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index orders_user_created_idx on public.orders (user_id, created_at desc);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  sku text,
  unit_price_paise bigint not null check (unit_price_paise >= 0),
  quantity integer not null check (quantity between 1 and 99),
  line_total_paise bigint not null check (line_total_paise >= 0)
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete restrict,
  provider text not null check (provider in ('razorpay', 'cod')),
  provider_order_id text,
  provider_payment_id text,
  status public.payment_status not null default 'pending',
  amount_paise bigint not null check (amount_paise >= 0),
  currency text not null default 'INR' check (currency = 'INR'),
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  unique (provider_payment_id)
);

create table public.coupons (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  discount_type text not null check (discount_type in ('percent', 'fixed')),
  discount_value integer not null check (discount_value > 0),
  minimum_order_paise bigint not null default 0 check (minimum_order_paise >= 0),
  max_discount_paise bigint check (max_discount_paise is null or max_discount_paise >= 0),
  starts_at timestamptz,
  expires_at timestamptz,
  usage_limit integer check (usage_limit is null or usage_limit > 0),
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  check (expires_at is null or starts_at is null or expires_at > starts_at)
);

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  title text,
  body text,
  is_approved boolean not null default false,
  created_at timestamptz not null default now(),
  unique (product_id, user_id)
);

-- RLS on every table exposed to the API.
alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.carts enable row level security;
alter table public.cart_items enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.payments enable row level security;
alter table public.coupons enable row level security;
alter table public.reviews enable row level security;

-- Start with no table privileges for API roles, then grant only needed operations.
revoke all on public.profiles, public.user_roles, public.categories, public.products,
  public.carts, public.cart_items, public.orders, public.order_items,
  public.payments, public.coupons, public.reviews from anon, authenticated;

grant select on public.categories, public.products, public.coupons, public.reviews to anon, authenticated;
grant select, update, insert, delete on public.profiles to authenticated;
grant select on public.user_roles to authenticated;
grant insert, update, delete on public.categories, public.products, public.coupons, public.reviews to authenticated;
grant select, insert, update, delete on public.carts, public.cart_items to authenticated;
grant select on public.orders, public.order_items, public.payments to authenticated;
grant insert on public.reviews to authenticated;

-- Profiles: each customer can see/update only their own profile. No role column exists here.
create policy "profile read own or admin" on public.profiles
  for select to authenticated using (id = (select auth.uid()) or public.is_admin());
create policy "profile update own" on public.profiles
  for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy "admin manage profiles" on public.profiles
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Users can read their own role but cannot write roles from the browser.
create policy "read own role or admin" on public.user_roles
  for select to authenticated using (user_id = (select auth.uid()) or public.is_admin());

-- Active catalog is public; only admins can manage it.
create policy "public read active categories" on public.categories
  for select to anon, authenticated using (is_active or public.is_admin());
create policy "admin manage categories" on public.categories
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "public read active products" on public.products
  for select to anon, authenticated using (is_active or public.is_admin());
create policy "admin manage products" on public.products
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Coupons are visible only when active and in their valid time window; actual validation
-- and redemption limits must still be enforced in server-side checkout logic.
create policy "public read valid coupons" on public.coupons
  for select to anon, authenticated using (
    is_active
    and (starts_at is null or starts_at <= now())
    and (expires_at is null or expires_at > now())
    or public.is_admin()
  );
create policy "admin manage coupons" on public.coupons
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Cart rows belong to the signed-in owner. Cart creation and item changes are user-scoped.
create policy "cart owner or admin read" on public.carts
  for select to authenticated using (user_id = (select auth.uid()) or public.is_admin());
create policy "cart owner create" on public.carts
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "cart owner update" on public.carts
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "cart owner delete" on public.carts
  for delete to authenticated using (user_id = (select auth.uid()) or public.is_admin());
create policy "cart items owner read" on public.cart_items
  for select to authenticated using (
    exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid()))
    or public.is_admin()
  );
create policy "cart items owner insert" on public.cart_items
  for insert to authenticated with check (
    exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid()))
  );
create policy "cart items owner update" on public.cart_items
  for update to authenticated using (
    exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid()))
  ) with check (
    exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid()))
  );
create policy "cart items owner delete" on public.cart_items
  for delete to authenticated using (
    exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid()))
    or public.is_admin()
  );

-- Orders/payment records are read-only to browser users. Trusted Edge Functions create/change them.
create policy "customer read own orders or admin" on public.orders
  for select to authenticated using (user_id = (select auth.uid()) or public.is_admin());
create policy "customer read own order items or admin" on public.order_items
  for select to authenticated using (
    exists (select 1 from public.orders o where o.id = order_id and o.user_id = (select auth.uid()))
    or public.is_admin()
  );
create policy "customer read own payments or admin" on public.payments
  for select to authenticated using (
    exists (select 1 from public.orders o where o.id = order_id and o.user_id = (select auth.uid()))
    or public.is_admin()
  );

-- Customers can submit their own reviews, which are unapproved by default.
create policy "public read approved reviews" on public.reviews
  for select to anon, authenticated using (is_approved or user_id = (select auth.uid()) or public.is_admin());
create policy "customer create own review" on public.reviews
  for insert to authenticated with check (user_id = (select auth.uid()) and is_approved = false);
create policy "admin manage reviews" on public.reviews
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- NOTE: no admin user is created by this script. Do not add an admin role via frontend code.
-- After creating and confirming your own Supabase Auth user, use the SQL Editor to run:
-- insert into public.user_roles (user_id, role)
-- select id, 'admin'::public.app_role from auth.users where email = 'YOUR-OWN-LOGIN-EMAIL'
-- on conflict (user_id) do update set role = 'admin';
