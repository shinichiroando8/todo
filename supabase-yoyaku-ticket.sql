-- 予約チケット 面談予約・支払いアプリ用 (yoyaku-ticket-app-demo.html)
-- 掲示板・研究会アプリと同じプロジェクトに追加するため、テーブル名は yoyaku_ で始める

-- ---------------------------------------------------------------
-- 管理者
-- ---------------------------------------------------------------
create table public.yoyaku_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.yoyaku_admins enable row level security;
-- ポリシーなし = 画面(API)からは読み書きできない。下の関数経由でのみ判定する

create function public.yoyaku_is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.yoyaku_admins where user_id = auth.uid());
$$;

-- 日本時間での面談開始時刻
create function public.yoyaku_slot_start(d date, t text)
returns timestamptz
language sql immutable
as $$
  select (d + t::time) at time zone 'Asia/Tokyo';
$$;

-- ---------------------------------------------------------------
-- メニュー (誰でも読める / 変更は管理者だけ)
-- ---------------------------------------------------------------
create table public.yoyaku_menus (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  duration integer not null check (duration > 0),
  fee integer not null check (fee >= 0),
  description text not null default '',
  sort integer not null default 0
);
alter table public.yoyaku_menus enable row level security;

create policy "menus read"   on public.yoyaku_menus for select to anon, authenticated using (true);
create policy "menus insert" on public.yoyaku_menus for insert to authenticated with check (public.yoyaku_is_admin());
create policy "menus update" on public.yoyaku_menus for update to authenticated using (public.yoyaku_is_admin()) with check (public.yoyaku_is_admin());
create policy "menus delete" on public.yoyaku_menus for delete to authenticated using (public.yoyaku_is_admin());

insert into public.yoyaku_menus (name, duration, fee, description, sort) values
  ('高ストレス相談', 45, 2000, 'ストレスチェックで高ストレスと判定された方のための面談です。心身の状態や働き方についてご相談いただけます。', 1),
  ('復職支援相談', 50, 2000, '休職からの職場復帰に向けて、業務内容や働き方の調整について一緒に整理します。', 2);

-- ---------------------------------------------------------------
-- 空き枠 (誰でも読める / 追加と 空き⇔休止 の切替は管理者だけ。予約済みへの変更は予約の関数だけ)
-- ---------------------------------------------------------------
create table public.yoyaku_slots (
  id uuid primary key default gen_random_uuid(),
  slot_date date not null,
  slot_time text not null check (slot_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  status text not null default 'open' check (status in ('open', 'booked', 'blocked')),
  unique (slot_date, slot_time)
);
alter table public.yoyaku_slots enable row level security;

create policy "slots read"   on public.yoyaku_slots for select to anon, authenticated using (true);
create policy "slots insert" on public.yoyaku_slots for insert to authenticated
  with check (public.yoyaku_is_admin() and status in ('open', 'blocked'));
create policy "slots update" on public.yoyaku_slots for update to authenticated
  using (public.yoyaku_is_admin() and status <> 'booked')
  with check (public.yoyaku_is_admin() and status in ('open', 'blocked'));

-- 今日から10日分の標準の枠(10:00 / 14:00 / 19:00)を用意する。何度呼んでも重複しない
create function public.yoyaku_ensure_slots()
returns void
language sql security definer
set search_path = public
as $$
  insert into public.yoyaku_slots (slot_date, slot_time)
  select d::date, t
    from generate_series((now() at time zone 'Asia/Tokyo')::date,
                         (now() at time zone 'Asia/Tokyo')::date + 9, interval '1 day') as d,
         unnest(array['10:00', '14:00', '19:00']) as t
  on conflict (slot_date, slot_time) do nothing;
$$;

select public.yoyaku_ensure_slots();

-- ---------------------------------------------------------------
-- 予約 (個人情報を含むので、読み取りは管理者だけ。一般の人は下の関数経由)
-- カードは「ブランドと下4桁」だけを受け取る。カード番号・有効期限・コードは送られず、保存もされない
-- ---------------------------------------------------------------
create sequence public.yoyaku_reservation_no_seq;

create table public.yoyaku_reservations (
  id uuid primary key default gen_random_uuid(),
  no text not null default lpad(nextval('public.yoyaku_reservation_no_seq')::text, 5, '0'),
  menu_id uuid not null references public.yoyaku_menus(id),
  slot_id uuid not null references public.yoyaku_slots(id),
  res_date date not null,
  res_time text not null,
  name text not null check (char_length(name) between 1 and 50),
  email text not null check (char_length(email) between 3 and 200 and email like '%@%'),
  fee integer not null check (fee >= 0),
  card_brand text not null default '' check (char_length(card_brand) <= 30),
  card_last4 text not null check (card_last4 ~ '^[0-9]{4}$'),
  status text not null default 'confirmed' check (status in ('confirmed', 'cancelled')),
  created_at timestamptz not null default now()
);
alter table public.yoyaku_reservations enable row level security;

create policy "reservations admin read" on public.yoyaku_reservations for select to authenticated using (public.yoyaku_is_admin());

-- 予約する (料金はメニューの金額をサーバー側で決める)
create function public.yoyaku_book(
  p_menu_id uuid, p_slot_id uuid, p_name text, p_email text, p_card_brand text, p_card_last4 text
)
returns public.yoyaku_reservations
language plpgsql security definer
set search_path = public
as $$
declare
  m public.yoyaku_menus;
  s public.yoyaku_slots;
  r public.yoyaku_reservations;
begin
  select * into m from public.yoyaku_menus where id = p_menu_id;
  if not found then raise exception 'メニューが見つかりません'; end if;

  select * into s from public.yoyaku_slots where id = p_slot_id for update;
  if not found then raise exception '日時が見つかりません'; end if;
  if s.status <> 'open' then raise exception 'この枠は既に埋まっています。日時を選び直してください'; end if;
  if public.yoyaku_slot_start(s.slot_date, s.slot_time) < now() then
    raise exception '過ぎた日時は予約できません';
  end if;

  update public.yoyaku_slots set status = 'booked' where id = s.id;

  insert into public.yoyaku_reservations
    (menu_id, slot_id, res_date, res_time, name, email, fee, card_brand, card_last4)
  values
    (m.id, s.id, s.slot_date, s.slot_time, btrim(p_name), btrim(p_email), m.fee, coalesce(p_card_brand, ''), p_card_last4)
  returning * into r;
  return r;
end;
$$;

-- 自分の予約の確認 (予約ID = 推測できないランダムな UUID を知っている人だけ)
create function public.yoyaku_get_reservations(p_ids uuid[])
returns setof public.yoyaku_reservations
language sql stable security definer
set search_path = public
as $$
  select * from public.yoyaku_reservations where id = any(p_ids) limit 50;
$$;

-- キャンセル (面談開始の3時間前まで)
create function public.yoyaku_cancel(p_id uuid)
returns public.yoyaku_reservations
language plpgsql security definer
set search_path = public
as $$
declare
  r public.yoyaku_reservations;
begin
  select * into r from public.yoyaku_reservations where id = p_id for update;
  if not found then raise exception '予約が見つかりません'; end if;
  if r.status <> 'confirmed' then raise exception 'この予約は既にキャンセルされています'; end if;
  if public.yoyaku_slot_start(r.res_date, r.res_time) - interval '3 hours' <= now() then
    raise exception '変更・キャンセルの受付期限(面談開始の3時間前)を過ぎています';
  end if;

  update public.yoyaku_reservations set status = 'cancelled' where id = r.id returning * into r;
  update public.yoyaku_slots set status = 'open' where id = r.slot_id and status = 'booked';
  return r;
end;
$$;

-- 日程変更 (面談開始の3時間前まで)
create function public.yoyaku_reschedule(p_id uuid, p_new_slot_id uuid)
returns public.yoyaku_reservations
language plpgsql security definer
set search_path = public
as $$
declare
  r public.yoyaku_reservations;
  s public.yoyaku_slots;
begin
  select * into r from public.yoyaku_reservations where id = p_id for update;
  if not found then raise exception '予約が見つかりません'; end if;
  if r.status <> 'confirmed' then raise exception 'キャンセル済みの予約は変更できません'; end if;
  if public.yoyaku_slot_start(r.res_date, r.res_time) - interval '3 hours' <= now() then
    raise exception '変更・キャンセルの受付期限(面談開始の3時間前)を過ぎています';
  end if;
  if r.slot_id = p_new_slot_id then return r; end if;

  select * into s from public.yoyaku_slots where id = p_new_slot_id for update;
  if not found then raise exception '日時が見つかりません'; end if;
  if s.status <> 'open' then raise exception 'この枠は既に埋まっています'; end if;
  if public.yoyaku_slot_start(s.slot_date, s.slot_time) < now() then
    raise exception '過ぎた日時は選べません';
  end if;

  update public.yoyaku_slots set status = 'open' where id = r.slot_id and status = 'booked';
  update public.yoyaku_slots set status = 'booked' where id = s.id;
  update public.yoyaku_reservations
     set slot_id = s.id, res_date = s.slot_date, res_time = s.slot_time
   where id = r.id returning * into r;
  return r;
end;
$$;

-- 管理者によるキャンセル扱い (時間の制限なし)
create function public.yoyaku_admin_cancel(p_id uuid)
returns public.yoyaku_reservations
language plpgsql security definer
set search_path = public
as $$
declare
  r public.yoyaku_reservations;
begin
  if not public.yoyaku_is_admin() then raise exception '管理権限がありません'; end if;
  update public.yoyaku_reservations set status = 'cancelled' where id = p_id returning * into r;
  if not found then raise exception '予約が見つかりません'; end if;
  update public.yoyaku_slots set status = 'open' where id = r.slot_id and status = 'booked';
  return r;
end;
$$;

-- 予約チケットの管理操作に2段階認証(TOTP)を必須にする
-- 管理者の判定(yoyaku_is_admin)に「2段階認証を済ませたログイン(aal2)であること」を加える。
-- 予約一覧の閲覧・空き枠の変更・管理者キャンセルなど、管理者用のポリシーと関数はすべてこの関数を使っているため、
-- パスワードだけのログインでは何もできなくなる。

-- 管理者として登録されているか(2段階認証の状態は問わない)。
-- 画面側で「権限なし」と「2段階認証の登録・入力が必要」を見分けるために使う
create function public.yoyaku_is_admin_user()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.yoyaku_admins where user_id = auth.uid());
$$;

create or replace function public.yoyaku_is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.yoyaku_admins where user_id = auth.uid())
     and coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;
