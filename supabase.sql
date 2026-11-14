-- রিসেল হাব: Supabase ডাটাবেস সেটআপ
-- Supabase → SQL Editor → New query-তে পুরোটা পেস্ট করে Run চাপুন।
-- আবার চালালেও কোনো ক্ষতি হয় না।

-- ============ টেবিল ============

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  phone text not null default '',
  payout text not null default '',
  approved boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  fee_in numeric not null default 0 check (fee_in >= 0),
  fee_out numeric not null default 0 check (fee_out >= 0),
  min_withdraw numeric not null default 0 check (min_withdraw >= 0),
  configured boolean not null default false
);
insert into public.settings (id) values (1) on conflict do nothing;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  price numeric not null check (price > 0),
  commission numeric not null check (commission >= 0),
  stock integer check (stock >= 0),
  sizes text[] not null default '{}',
  colors text[] not null default '{}',
  details text not null default '',
  images text[] not null default '{}',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (commission <= price)
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  reseller_id uuid not null references public.profiles(id),
  zone text not null check (zone in ('in', 'out')),
  customer_name text not null,
  customer_phone text not null,
  customer_address text not null,
  note text not null default '',
  status text not null default 'new' check (status in ('new', 'accepted', 'delivered', 'cancelled')),
  delivery numeric not null default 0,
  stock_taken boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists orders_reseller_idx on public.orders (reseller_id, created_at desc);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name text not null,
  qty integer not null check (qty between 1 and 999),
  size text not null default '',
  color text not null default '',
  price numeric not null,
  commission numeric not null
);
create index if not exists order_items_order_idx on public.order_items (order_id);

create table if not exists public.payouts (
  id uuid primary key default gen_random_uuid(),
  reseller_id uuid not null references public.profiles(id),
  amount numeric not null check (amount > 0),
  note text not null default '',
  request_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists payouts_reseller_idx on public.payouts (reseller_id);

create table if not exists public.withdrawals (
  id uuid primary key default gen_random_uuid(),
  reseller_id uuid not null references public.profiles(id),
  amount numeric not null check (amount > 0),
  payout text not null default '',
  status text not null default 'pending' check (status in ('pending', 'paid', 'rejected')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists withdrawals_reseller_idx on public.withdrawals (reseller_id, created_at desc);

-- ============ সাহায্যকারী ফাংশন ============

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin()
      or exists (select 1 from public.profiles where id = auth.uid() and approved)
$$;

-- রিসেলারের বাকি পাওনা (ডেলিভারি হওয়া অর্ডারের কমিশন − পরিশোধ)। শুধু ভেতরের ব্যবহারের জন্য।
create or replace function public._due(p_uid uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(i.qty * i.commission)
                     from public.orders o join public.order_items i on i.order_id = o.id
                    where o.reseller_id = p_uid and o.status = 'delivered'), 0)
       - coalesce((select sum(amount) from public.payouts where reseller_id = p_uid), 0)
$$;

-- ============ নতুন ব্যবহারকারীর প্রোফাইল ============

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, phone, payout)
  values (new.id,
          coalesce(left(new.raw_user_meta_data ->> 'name', 80), ''),
          coalesce(left(new.raw_user_meta_data ->> 'phone', 20), ''),
          coalesce(left(new.raw_user_meta_data ->> 'payout', 40), ''))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============ অ্যাপের কাজ (RPC) ============

-- রিসেলারের অর্ডার। দাম, কমিশন ও ডেলিভারি চার্জ সার্ভার নিজে বসায়, রিসেলার বদলাতে পারে না।
create or replace function public.place_order(
  p_product uuid, p_qty integer, p_size text, p_color text, p_zone text,
  p_name text, p_phone text, p_address text, p_note text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  pr public.products;
  st public.settings;
  oid uuid;
  fee numeric;
begin
  if auth.uid() is null or not public.is_approved() then
    raise exception 'আপনার অ্যাকাউন্ট এখনও অনুমোদিত হয়নি';
  end if;
  select * into pr from public.products where id = p_product and active;
  if not found then raise exception 'পণ্যটি এখন পাওয়া যাচ্ছে না'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 999 then raise exception 'পিস ঠিক নেই'; end if;
  if pr.stock is not null and p_qty > pr.stock then
    if pr.stock <= 0 then raise exception 'স্টক শেষ'; end if;
    raise exception 'স্টকে মাত্র % পিস আছে', pr.stock;
  end if;
  if cardinality(pr.sizes) > 0 and not (coalesce(p_size, '') = any (pr.sizes)) then
    raise exception 'সাইজ বেছে নিন';
  end if;
  if cardinality(pr.colors) > 0 and not (coalesce(p_color, '') = any (pr.colors)) then
    raise exception 'রং বেছে নিন';
  end if;
  if p_zone is null or p_zone not in ('in', 'out') then raise exception 'ডেলিভারি এলাকা বেছে নিন'; end if;
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'কাস্টমারের নাম দিন'; end if;
  if length(trim(coalesce(p_address, ''))) = 0 then raise exception 'ঠিকানা দিন'; end if;
  if coalesce(p_phone, '') !~ '^01[3-9][0-9]{8}$' then raise exception 'সঠিক ১১ সংখ্যার মোবাইল নম্বর দিন'; end if;

  select * into st from public.settings where id = 1;
  fee := case when p_zone = 'out' then st.fee_out else st.fee_in end;

  insert into public.orders (reseller_id, zone, customer_name, customer_phone, customer_address, note, delivery)
  values (auth.uid(), p_zone, left(trim(p_name), 80), p_phone, left(trim(p_address), 300), left(coalesce(p_note, ''), 300), fee)
  returning id into oid;

  insert into public.order_items (order_id, product_id, name, qty, size, color, price, commission)
  values (oid, pr.id, pr.name, p_qty,
          case when cardinality(pr.sizes) > 0 then p_size else '' end,
          case when cardinality(pr.colors) > 0 then p_color else '' end,
          pr.price, pr.commission);
  return oid;
end $$;

-- অ্যাডমিনের অর্ডার স্ট্যাটাস বদল। গ্রহণে স্টক কমে, বাতিলে ফেরত আসে, সবটা একসাথে।
create or replace function public.set_order_status(p_order uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare
  o public.orders;
  it record;
  pr public.products;
  take boolean;
  give boolean;
begin
  if not public.is_admin() then raise exception 'অনুমতি নেই'; end if;
  if p_status is null or p_status not in ('new', 'accepted', 'delivered', 'cancelled') then
    raise exception 'স্ট্যাটাস ঠিক নেই';
  end if;
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'অর্ডার পাওয়া যায়নি'; end if;

  take := p_status in ('accepted', 'delivered') and not o.stock_taken;
  give := p_status in ('cancelled', 'new') and o.stock_taken;

  if take or give then
    for it in
      select product_id, sum(qty)::int as q
        from public.order_items
       where order_id = p_order and product_id is not null
       group by product_id
       order by product_id
    loop
      select * into pr from public.products where id = it.product_id for update;
      if found and pr.stock is not null then
        if take and pr.stock < it.q then
          raise exception '“%” স্টকে মাত্র % পিস আছে। আগে স্টক বাড়ান।', pr.name, pr.stock;
        end if;
        update public.products
           set stock = case when take then stock - it.q else stock + it.q end
         where id = pr.id;
      end if;
    end loop;
  end if;

  update public.orders
     set status = p_status,
         stock_taken = case when take then true when give then false else stock_taken end,
         updated_at = now()
   where id = p_order;
end $$;

-- রিসেলারের কমিশন তোলার অনুরোধ
create or replace function public.request_withdrawal(p_amount numeric) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  pf public.profiles;
  st public.settings;
  avail numeric;
  wid uuid;
begin
  if auth.uid() is null or not public.is_approved() then
    raise exception 'আপনার অ্যাকাউন্ট এখনও অনুমোদিত হয়নি';
  end if;
  select * into pf from public.profiles where id = auth.uid();
  if length(trim(coalesce(pf.payout, ''))) = 0 then
    raise exception 'আগে প্রোফাইলে কমিশন পাওয়ার নম্বর দিন';
  end if;
  select * into st from public.settings where id = 1;
  avail := public._due(auth.uid())
         - coalesce((select sum(amount) from public.withdrawals
                      where reseller_id = auth.uid() and status = 'pending'), 0);
  if p_amount is null or p_amount <= 0 then raise exception 'পরিমাণ দিন'; end if;
  if p_amount > avail then raise exception 'সর্বোচ্চ ৳% তোলা যাবে', trim_scale(avail); end if;
  if st.min_withdraw > 0 and p_amount < st.min_withdraw then
    raise exception 'ন্যূনতম ৳% তুলতে হবে', trim_scale(st.min_withdraw);
  end if;
  insert into public.withdrawals (reseller_id, amount, payout)
  values (auth.uid(), p_amount, pf.payout) returning id into wid;
  return wid;
end $$;

-- অ্যাডমিন: অনুরোধ পরিশোধ বা বাতিল (p_action = 'paid' বা 'rejected')
create or replace function public.resolve_withdrawal(p_id uuid, p_action text) returns void
language plpgsql security definer set search_path = public as $$
declare
  w public.withdrawals;
begin
  if not public.is_admin() then raise exception 'অনুমতি নেই'; end if;
  select * into w from public.withdrawals where id = p_id for update;
  if not found or w.status <> 'pending' then raise exception 'অনুরোধটি আর অপেক্ষায় নেই'; end if;
  if p_action = 'paid' then
    if w.amount > public._due(w.reseller_id) then
      raise exception 'বাকি পাওনা অনুরোধের চেয়ে কম। অনুরোধটি বাতিল করুন।';
    end if;
    insert into public.payouts (reseller_id, amount, note, request_id)
    values (w.reseller_id, w.amount, 'উত্তোলনের অনুরোধ', w.id);
    update public.withdrawals set status = 'paid', resolved_at = now() where id = w.id;
  elsif p_action = 'rejected' then
    update public.withdrawals set status = 'rejected', resolved_at = now() where id = w.id;
  else
    raise exception 'কাজ ঠিক নেই';
  end if;
end $$;

-- অ্যাডমিন: নিজে থেকে পরিশোধ রেকর্ড
create or replace function public.record_payout(p_reseller uuid, p_amount numeric, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'অনুমতি নেই'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'পরিমাণ দিন'; end if;
  if p_amount > public._due(p_reseller) then raise exception 'বাকি পাওনার বেশি লেখা যাবে না'; end if;
  insert into public.payouts (reseller_id, amount, note)
  values (p_reseller, p_amount, left(coalesce(p_note, ''), 200));
end $$;

-- অ্যাডমিন: রিসেলার অনুমোদন বা অনুমোদন তুলে নেওয়া
create or replace function public.set_approved(p_uid uuid, p_approved boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'অনুমতি নেই'; end if;
  update public.profiles set approved = coalesce(p_approved, false) where id = p_uid;
end $$;

-- ============ গোপনীয়তার নিয়ম (Row Level Security) ============

alter table public.admins enable row level security;
alter table public.profiles enable row level security;
alter table public.settings enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.payouts enable row level security;
alter table public.withdrawals enable row level security;

drop policy if exists admins_self on public.admins;
create policy admins_self on public.admins for select to authenticated
  using (user_id = auth.uid());

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists settings_read on public.settings;
create policy settings_read on public.settings for select to authenticated
  using (public.is_approved());
drop policy if exists settings_admin_update on public.settings;
create policy settings_admin_update on public.settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists products_read on public.products;
create policy products_read on public.products for select to authenticated
  using (public.is_approved());
drop policy if exists products_admin on public.products;
create policy products_admin on public.products for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders for select to authenticated
  using (reseller_id = auth.uid() or public.is_admin());

drop policy if exists order_items_read on public.order_items;
create policy order_items_read on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o
                  where o.id = order_id and (o.reseller_id = auth.uid() or public.is_admin())));

drop policy if exists payouts_read on public.payouts;
create policy payouts_read on public.payouts for select to authenticated
  using (reseller_id = auth.uid() or public.is_admin());

drop policy if exists withdrawals_read on public.withdrawals;
create policy withdrawals_read on public.withdrawals for select to authenticated
  using (reseller_id = auth.uid() or public.is_admin());

-- ============ কে কী করতে পারবে (অনুমতি) ============

revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

grant usage on schema public to anon, authenticated;
grant select on public.admins, public.profiles, public.settings, public.products,
                public.orders, public.order_items, public.payouts, public.withdrawals to authenticated;
grant update (name, phone, payout) on public.profiles to authenticated;
grant update on public.settings to authenticated;
grant insert, update, delete on public.products to authenticated;

grant execute on function
  public.is_admin(),
  public.is_approved(),
  public.place_order(uuid, integer, text, text, text, text, text, text, text),
  public.set_order_status(uuid, text),
  public.request_withdrawal(numeric),
  public.resolve_withdrawal(uuid, text),
  public.record_payout(uuid, numeric, text),
  public.set_approved(uuid, boolean)
to authenticated;

-- ============ পণ্যের ছবির জায়গা ============

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 5242880,
        array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do update
  set public = true, file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

drop policy if exists "admin reads product images" on storage.objects;
create policy "admin reads product images" on storage.objects for select to authenticated
  using (bucket_id = 'product-images' and public.is_admin());
drop policy if exists "admin uploads product images" on storage.objects;
create policy "admin uploads product images" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and public.is_admin());
drop policy if exists "admin updates product images" on storage.objects;
create policy "admin updates product images" on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and public.is_admin())
  with check (bucket_id = 'product-images' and public.is_admin());
drop policy if exists "admin deletes product images" on storage.objects;
create policy "admin deletes product images" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and public.is_admin());

-- ============ লাইভ আপডেট (নতুন অর্ডার সাথে সাথে দেখাবে) ============

do $$
begin
  begin
    alter publication supabase_realtime add table
      public.products, public.orders, public.order_items,
      public.payouts, public.withdrawals, public.profiles, public.settings;
  exception when others then
    null;
  end;
end $$;
