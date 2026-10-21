-- tommy's cart — database setup.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run once on a fresh project.

-- ─── profiles ───────────────────────────────────────────────────────────────
-- One row per auth user. Passwords live in auth.users (hashed by Supabase),
-- never here.
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null,
  email text not null,
  created_at timestamptz not null default now()
);

-- Only @usc.edu addresses may sign up; also creates the profile row.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if lower(new.email) !~ '^[^@\s]+@usc\.edu$' then
    raise exception 'tommy''s cart is for @usc.edu emails only';
  end if;
  insert into public.profiles (id, name, email)
  values (
    new.id,
    lower(coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1))),
    lower(new.email)
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─── listings ───────────────────────────────────────────────────────────────
create table public.listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid references public.profiles on delete cascade, -- null for demo listings
  seller_name text not null,
  title text not null check (length(title) between 1 and 120),
  cat text not null check (cat in ('fits', 'dorm', 'tech', 'books', 'tickets', 'bikes')),
  price int not null check (price > 0),
  cond text not null,
  description text not null default '',
  pickup text not null,
  photos text[] not null default '{}',
  cutout boolean not null default false,
  bg text,
  status text not null default 'active' check (status in ('active', 'sold')),
  sold_to text,
  pending_offers int not null default 0, -- public count; offer details stay private
  created_at timestamptz not null default now()
);

-- ─── offers ─────────────────────────────────────────────────────────────────
create table public.offers (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings on delete cascade,
  buyer_id uuid not null references public.profiles on delete cascade,
  buyer_name text not null,
  amount int not null check (amount > 0),
  msg text not null default '',
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  unique (listing_id, buyer_id)
);

-- ─── favorites ──────────────────────────────────────────────────────────────
create table public.favorites (
  user_id uuid not null references public.profiles on delete cascade,
  listing_id uuid not null references public.listings on delete cascade,
  primary key (user_id, listing_id)
);

-- ─── row level security ─────────────────────────────────────────────────────
alter table public.profiles enable row level security;
alter table public.listings enable row level security;
alter table public.offers enable row level security;
alter table public.favorites enable row level security;

create policy "read own profile" on public.profiles
  for select to authenticated using (id = auth.uid());

create policy "anyone can browse listings" on public.listings
  for select using (true);
create policy "sellers create their own listings" on public.listings
  for insert to authenticated with check (seller_id = auth.uid() and status = 'active' and pending_offers = 0);
create policy "sellers delete their own listings" on public.listings
  for delete to authenticated using (seller_id = auth.uid());

-- Buyers see their own offers; sellers see offers on their listings.
-- Offers are written only through send_offer() / decide_offer() below.
create policy "buyer or seller reads offers" on public.offers
  for select to authenticated using (
    buyer_id = auth.uid()
    or exists (select 1 from public.listings l where l.id = listing_id and l.seller_id = auth.uid())
  );

create policy "manage own favorites" on public.favorites
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ─── actions ────────────────────────────────────────────────────────────────
create function public.refresh_pending(lid uuid) returns void
language sql security definer set search_path = public as $$
  update listings set pending_offers =
    (select count(*) from offers where listing_id = lid and status = 'pending')
  where id = lid;
$$;
revoke execute on function public.refresh_pending(uuid) from public, anon, authenticated;

-- Make or update your offer on a listing.
create function public.send_offer(p_listing uuid, p_amount int, p_msg text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  l listings;
begin
  if uid is null then raise exception 'log in first'; end if;
  if p_amount is null or p_amount < 1 then raise exception 'enter an amount'; end if;
  select * into l from listings where id = p_listing;
  if not found or l.status <> 'active' then raise exception 'this listing is no longer available'; end if;
  if l.seller_id = uid then raise exception 'you can''t offer on your own listing'; end if;

  insert into offers (listing_id, buyer_id, buyer_name, amount, msg)
  values (p_listing, uid, (select name from profiles where id = uid), p_amount, coalesce(trim(p_msg), ''))
  on conflict (listing_id, buyer_id) do update
    set amount = excluded.amount, msg = excluded.msg, status = 'pending', created_at = now();

  perform refresh_pending(p_listing);
end $$;

-- Seller accepts (sells to that buyer, declining the rest) or declines an offer.
create function public.decide_offer(p_offer uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  o offers;
  l listings;
begin
  select * into o from offers where id = p_offer;
  if not found then raise exception 'offer not found'; end if;
  select * into l from listings where id = o.listing_id;
  if l.seller_id is distinct from auth.uid() then raise exception 'not your listing'; end if;
  if l.status <> 'active' or o.status <> 'pending' then raise exception 'already decided'; end if;

  if p_accept then
    update offers set status = case when id = p_offer then 'accepted' else 'declined' end
      where listing_id = l.id and (id = p_offer or status = 'pending');
    update listings set status = 'sold', sold_to = o.buyer_name where id = l.id;
  else
    update offers set status = 'declined' where id = p_offer;
  end if;

  perform refresh_pending(l.id);
end $$;

revoke execute on function public.send_offer(uuid, int, text) from public, anon;
revoke execute on function public.decide_offer(uuid, boolean) from public, anon;
grant execute on function public.send_offer(uuid, int, text) to authenticated;
grant execute on function public.decide_offer(uuid, boolean) to authenticated;

-- ─── photo storage ──────────────────────────────────────────────────────────
-- Public bucket: anyone can view photos; signed-in users upload into a folder
-- named after their user id.
insert into storage.buckets (id, name, public)
values ('listing-photos', 'listing-photos', true)
on conflict (id) do nothing;

create policy "upload own listing photos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'listing-photos' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "delete own listing photos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'listing-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- ─── demo listings ──────────────────────────────────────────────────────────
-- Photos point at the uploads/ folder that ships with the site.
insert into public.listings (seller_name, title, cat, price, cond, pickup, description, photos, cutout, bg, created_at) values
  ('maya k.',   'comme des garçons converse, w8', 'fits',    65,  'like new', 'village',             'Worn maybe five times. Hearts still bright, soles clean.',           '{uploads/pasted-1792533674911-0.png}', true, '#F4BFCB', now() - interval '1 hour'),
  ('ben a.',    'rugby stripe polo, l',           'fits',    30,  'good',     'doheny steps',        'Red and gold, so basically game-day mandatory.',                     '{uploads/pasted-1792533893712-0.png}', true, '#C5D6E2', now() - interval '2 hours'),
  ('jordan p.', 'nespresso vertuo next',          'dorm',    70,  'like new', 'parkside',            'Descaled last week. Comes with 6 pods to get you through midterms.', '{uploads/pasted-1792533722469-0.png}', true, '#C5D6E2', now() - interval '3 hours'),
  ('zoe h.',    'pink mushroom lamp',             'dorm',    22,  'like new', 'village',             'Pull-chain works, warm bulb included.',                              '{uploads/pasted-1792533820752-0.png}', true, '#EAE3D8', now() - interval '4 hours'),
  ('priya s.',  'pointelle cardigan, pink',       'fits',    28,  'like new', 'leavey library',      'Size s, cropped. Tags removed but never really worn.',               '{uploads/pasted-1792533882376-0.png}', true, '#C5D6E2', now() - interval '5 hours'),
  ('noah r.',   'airpods 4',                      'tech',    90,  'like new', 'vkc',                 'Case, cable, box. Battery still great.',                             '{uploads/pasted-1792534009536-0.png}', true, '#EAE3D8', now() - interval '6 hours'),
  ('lena w.',   'priority cruiser bike',          'bikes',   260, 'good',     'tutor campus center', 'Belt drive, no greasy chain. Medium frame, fits 5''4"–5''10".',      '{uploads/pasted-1792533784119-0.png}', true, '#F4BFCB', now() - interval '8 hours'),
  ('ava l.',    'cable knit cardigan, brown',     'fits',    120, 'like new', 'doheny steps',        'Cashmere blend, size m. Dry cleaned.',                               '{uploads/pasted-1792533908602-0.png}', true, '#F4BFCB', now() - interval '10 hours'),
  ('chris d.',  'jonas brothers, the album (vinyl)', 'tickets', 18, 'like new', 'vkc',              'Played twice. Sleeve has no creases.',                               '{uploads/pasted-1792533734928-0.png}', true, '#EAE3D8', now() - interval '12 hours'),
  ('emma j.',   'ugg ultra mini, w7',             'fits',    85,  'good',     'parkside',            'Chestnut. Sprayed with protector, minimal wear.',                    '{uploads/pasted-1792533948307-0.png}', true, '#C5D6E2', now() - interval '1 day'),
  ('sam t.',    'pleated table lamp, orange',     'dorm',    14,  'like new', 'village',             'Rechargeable, no cord. Lasts about a week.',                         '{uploads/pasted-1792533810844-0.png}', true, '#C5D6E2', now() - interval '1 day 1 hour'),
  ('kai n.',    'jansport backpack, navy',        'fits',    25,  'good',     'leavey library',      'Laptop sleeve, leather bottom. Zippers all good.',                   '{uploads/pasted-1792533869607-0.png}', true, '#F4BFCB', now() - interval '1 day 2 hours'),
  ('marcus l.', 'carbon road bike, 54cm',         'bikes',   480, 'good',     'tutor campus center', 'Electronic shifting, disc brakes. Serviced in August.',              '{uploads/pasted-1792533850527-0.png}', true, '#EAE3D8', now() - interval '2 days'),
  ('mia c.',    'ikea 2-door cabinet, oak',       'dorm',    40,  'good',     'parkside',            'Already assembled. You''ll need a friend and a car.',                '{uploads/pasted-1792533974229-0.png}', true, '#F4BFCB', now() - interval '2 days 2 hours'),
  ('ella f.',   'wuthering heights, hardcover',   'books',   12,  'like new', 'doheny steps',        'The pretty edition. No notes inside.',                               '{uploads/pasted-1792533999929-0.png}', true, '#EAE3D8', now() - interval '3 days'),
  ('dana r.',   'jbl charge 5 speaker',           'tech',    80,  'like new', 'vkc',                 'Loud enough for the whole floor. Waterproof, charger included.',     '{uploads/pasted-1792534025394-0.png}', true, '#C5D6E2', now() - interval '4 days'),
  ('theo b.',   'z lounge chair, oak',            'dorm',    140, 'good',     'village',             'Solid oak frame, grey cushions. Comfiest seat in the apartment.',    '{uploads/pasted-1792533767488-0.png}', true, '#EAE3D8', now() - interval '5 days');
