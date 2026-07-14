-- Leather Supabase schema, RLS, moderation and daily check-in.
-- Apply with Supabase CLI or paste into the SQL editor as the project owner.

create extension if not exists pgcrypto;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create or replace function private.china_today()
returns date language sql stable set search_path = pg_catalog
as $$ select (now() at time zone 'Asia/Shanghai')::date $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  handle text not null,
  display_name text not null default 'Leather 用户',
  avatar_url text,
  bio text not null default '',
  role text not null default 'user' check (role in ('user', 'admin', 'owner')),
  banned_at timestamptz,
  ban_reason text,
  joined_on date not null default private.china_today(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_handle_format check (handle ~ '^[a-z0-9][a-z0-9_-]{2,29}$'),
  constraint profiles_display_name_length check (char_length(display_name) between 1 and 30),
  constraint profiles_bio_length check (char_length(bio) <= 300),
  constraint profiles_avatar_url check (avatar_url is null or (char_length(avatar_url) <= 500 and avatar_url ~ '^https://'))
);
alter table public.profiles alter column display_name set default 'Leather 用户';
create unique index if not exists profiles_handle_lower_uidx on public.profiles(lower(handle));
create index if not exists profiles_role_idx on public.profiles(role);
create index if not exists profiles_banned_idx on public.profiles(banned_at) where banned_at is not null;

create table if not exists public.avatar_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  object_path text not null,
  avatar_url text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewer_id uuid references public.profiles(id) on delete set null,
  review_note text not null default '',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  constraint avatar_requests_object_path_length check (char_length(object_path) between 40 and 240),
  constraint avatar_requests_url_check check (char_length(avatar_url) <= 700 and avatar_url ~ '^https://'),
  constraint avatar_requests_note_length check (char_length(review_note) <= 300)
);
create unique index if not exists avatar_requests_pending_user_uidx on public.avatar_requests(user_id) where status = 'pending';
create index if not exists avatar_requests_status_created_idx on public.avatar_requests(status, created_at);

create or replace function private.is_staff(user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public, pg_catalog
as $$ select exists(select 1 from public.profiles where id = user_id and role in ('admin','owner')) $$;

create or replace function private.is_owner(user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public, pg_catalog
as $$ select exists(select 1 from public.profiles where id = user_id and role = 'owner') $$;

create or replace function private.is_banned(user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public, pg_catalog
as $$ select coalesce((select banned_at is not null from public.profiles where id = user_id), true) $$;

create or replace function private.can_moderate_user(target_id uuid)
returns boolean language sql stable security definer set search_path = public, pg_catalog
as $$
  select case
    when private.is_owner(auth.uid()) then target_id <> auth.uid() and coalesce((select role <> 'owner' from public.profiles where id = target_id), false)
    when private.is_staff(auth.uid()) then coalesce((select role = 'user' from public.profiles where id = target_id), false)
    else false
  end
$$;

grant usage on schema private to anon, authenticated;
grant execute on function private.china_today() to anon, authenticated;
grant execute on function private.is_staff(uuid), private.is_owner(uuid), private.is_banned(uuid), private.can_moderate_user(uuid) to anon, authenticated;

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  summary text not null default '',
  content text not null,
  tags text[] not null default '{}',
  visibility text not null default 'private' check (visibility in ('private','public')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint posts_title_length check (char_length(title) between 1 and 100),
  constraint posts_summary_length check (char_length(summary) <= 240),
  constraint posts_content_length check (char_length(content) between 1 and 60000),
  constraint posts_tags_count check (cardinality(tags) <= 10)
);
create index if not exists posts_public_updated_idx on public.posts(updated_at desc) where visibility = 'public';
create index if not exists posts_user_idx on public.posts(user_id, updated_at desc);

create table if not exists public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  content text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint post_comments_content_length check (char_length(content) between 2 and 1000)
);
create index if not exists post_comments_post_idx on public.post_comments(post_id, created_at);
create index if not exists post_comments_user_idx on public.post_comments(user_id, created_at desc);

create table if not exists public.station_comments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'bug' check (kind in ('bug','suggestion','other')),
  content text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint station_comments_content_length check (char_length(content) between 2 and 1000)
);
create index if not exists station_comments_created_idx on public.station_comments(created_at desc);

create table if not exists public.template_sections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  color text not null default '#2f6b53',
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint template_sections_name_length check (char_length(name) between 1 and 30),
  constraint template_sections_color check (color ~ '^#[0-9a-fA-F]{6}$'),
  constraint template_sections_id_user_unique unique(id, user_id)
);
create index if not exists template_sections_user_idx on public.template_sections(user_id, position);

create table if not exists public.templates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  section_id uuid not null,
  title text not null,
  lang text not null default 'C++',
  tags text[] not null default '{}',
  code text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint templates_title_length check (char_length(title) between 1 and 80),
  constraint templates_lang_length check (char_length(lang) between 1 and 30),
  constraint templates_tags_count check (cardinality(tags) <= 12),
  constraint templates_code_length check (char_length(code) <= 200000),
  constraint templates_id_user_unique unique(id, user_id),
  constraint templates_section_owner_fk foreign key(section_id, user_id) references public.template_sections(id, user_id) on delete cascade
);
create index if not exists templates_user_section_idx on public.templates(user_id, section_id, updated_at desc);

create table if not exists public.template_snapshots (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  lang text not null,
  tags text[] not null default '{}',
  code text not null default '',
  created_at timestamptz not null default now(),
  constraint template_snapshots_code_length check (char_length(code) <= 200000),
  constraint template_snapshots_template_owner_fk foreign key(template_id, user_id) references public.templates(id, user_id) on delete cascade
);
create index if not exists template_snapshots_template_idx on public.template_snapshots(template_id, created_at desc);

create table if not exists public.plans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles(id) on delete cascade,
  title text not null default '我的训练计划',
  data jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint plans_title_length check (char_length(title) between 1 and 60),
  constraint plans_data_size check (octet_length(data::text) <= 200000)
);
alter table public.plans alter column title set default '我的训练计划';

create table if not exists public.daily_checkins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  checkin_date date not null default private.china_today(),
  number integer not null check (number between 0 and 999999),
  rarity text not null check (rarity in ('common','uncommon','rare','epic','legendary')),
  rarity_label text not null,
  created_at timestamptz not null default now(),
  unique(user_id, checkin_date)
);
create index if not exists daily_checkins_user_idx on public.daily_checkins(user_id, checkin_date desc);

create table if not exists private.sensitive_terms (
  id bigint generated always as identity primary key,
  category text not null,
  term text not null unique
);

create table if not exists private.moderation_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete set null,
  source_table text not null,
  content_id uuid,
  reason text not null,
  actor_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists moderation_events_user_idx on private.moderation_events(user_id, created_at desc);

insert into private.sensitive_terms(category, term) values
  ('abuse','傻逼'),('abuse','傻比'),('abuse','傻屄'),('abuse','煞笔'),('abuse','沙比'),('abuse','妈的'),('abuse','他妈的'),
  ('abuse','操你妈'),('abuse','草你妈'),('abuse','日你妈'),('abuse','干你娘'),('abuse','幹你娘'),('abuse','去死'),('abuse','脑残'),
  ('adult','色情'),('adult','黄片'),('adult','成人视频'),('adult','裸聊'),('adult','约炮'),('adult','援交'),('adult','嫖娼'),('adult','卖淫'),
  ('adult','强奸'),('adult','乱伦'),('illegal','赌博'),('illegal','博彩'),('illegal','赌球'),('illegal','六合彩'),('illegal','网赌'),
  ('illegal','毒品'),('illegal','冰毒'),('illegal','海洛因'),('illegal','摇头丸'),('illegal','买枪'),('illegal','卖枪'),
  ('illegal','枪支弹药'),('fraud','办假证'),('fraud','刷单返利'),('fraud','洗钱'),('fraud','杀手服务'),
  ('spam','加微信'),('spam','微信号'),('spam','加vx'),('spam','加v信'),('spam','qq号'),('spam','免费领钱'),('spam','快速致富'),
  ('extremism','法轮功'),('extremism','台独'),('extremism','港独'),('extremism','纳粹'),('extremism','恐怖主义'),('extremism','制造炸弹'),
  ('variant','caonima'),('variant','cnm'),('variant','nmsl'),('variant','tamade'),('variant','shabi'),('variant','fuck'),('variant','pornhub')
on conflict(term) do nothing;

create or replace function private.normalize_text(input_text text)
returns text language plpgsql immutable set search_path = pg_catalog
as $$
declare v text := lower(coalesce(input_text, ''));
begin
  v := translate(v, '０１２３４５６７８９', '0123456789');
  v := replace(v, '0', 'o'); v := replace(v, '1', 'i'); v := replace(v, '3', 'e');
  v := replace(v, '4', 'a'); v := replace(v, '5', 's'); v := replace(v, '7', 't');
  v := replace(v, '8', 'b'); v := replace(v, '@', 'a'); v := replace(v, '$', 's');
  return regexp_replace(v, '[^[:alnum:]一-龥]', '', 'g');
end $$;

create or replace function private.content_violation(input_text text)
returns text language plpgsql stable security definer set search_path = private, pg_catalog
as $$
declare v_normal text := private.normalize_text(input_text); v_term record; v_links integer;
begin
  for v_term in select category, term from private.sensitive_terms loop
    if position(private.normalize_text(v_term.term) in v_normal) > 0 then return '敏感内容/' || v_term.category; end if;
  end loop;
  if lower(coalesce(input_text,'')) ~ '(<\s*script|javascript\s*:|on(error|load|click)\s*=|data\s*:\s*text/html|document\s*\.\s*cookie)' then return '疑似脚本注入'; end if;
  if coalesce(input_text,'') ~ '(.)\1{79,}' then return '重复字符资源滥用'; end if;
  select count(*) into v_links from regexp_matches(coalesce(input_text,''), 'https?://', 'gi');
  if v_links > 10 then return '垃圾链接资源滥用'; end if;
  return null;
end $$;

create or replace function private.ban_for_violation(target_id uuid, source_name text, source_id uuid, violation text, actor uuid default null)
returns void language plpgsql security definer set search_path = public, private, pg_catalog
as $$
begin
  if target_id is null or private.is_owner(target_id) then return; end if;
  perform set_config('app.privileged_profile_write','true',true);
  update public.profiles set banned_at = coalesce(banned_at, now()), ban_reason = left(violation, 500), updated_at = now() where id = target_id;
  insert into private.moderation_events(user_id, source_table, content_id, reason, actor_id) values(target_id, source_name, source_id, violation, actor);
end $$;

create or replace function private.guard_write()
returns trigger language plpgsql security definer set search_path = public, private, pg_catalog
as $$
declare v_user uuid; v_size integer; v_count integer; v_rate integer; v_limit integer := tg_argv[1]::integer; v_total integer := tg_argv[2]::integer;
begin
  v_user := nullif(to_jsonb(new)->>'user_id','')::uuid;
  if v_user is null or v_user <> auth.uid() or private.is_banned(v_user) then return null; end if;
  v_size := octet_length(to_jsonb(new)::text);
  if v_size > tg_argv[0]::integer
     or (tg_table_name = 'posts' and (char_length(to_jsonb(new)->>'title') > 100 or char_length(to_jsonb(new)->>'summary') > 240 or char_length(to_jsonb(new)->>'content') > 60000 or jsonb_array_length(to_jsonb(new)->'tags') > 10))
     or (tg_table_name in ('post_comments','station_comments') and char_length(to_jsonb(new)->>'content') > 1000)
     or (tg_table_name = 'template_sections' and char_length(to_jsonb(new)->>'name') > 30)
     or (tg_table_name = 'templates' and (char_length(to_jsonb(new)->>'title') > 80 or char_length(to_jsonb(new)->>'code') > 200000 or jsonb_array_length(to_jsonb(new)->'tags') > 12))
     or (tg_table_name = 'template_snapshots' and char_length(to_jsonb(new)->>'code') > 200000)
     or (tg_table_name = 'plans' and octet_length((to_jsonb(new)->'data')::text) > 200000) then
    perform private.ban_for_violation(v_user, tg_table_name, new.id, '超大输入资源攻击', v_user); return null;
  end if;
  if tg_op = 'INSERT' then
    execute format('select count(*) from %I.%I where user_id = $1 and created_at > now() - interval ''10 minutes''', tg_table_schema, tg_table_name) into v_rate using v_user;
    if v_rate >= v_limit then perform private.ban_for_violation(v_user, tg_table_name, new.id, '高频写入资源攻击', v_user); return null; end if;
    execute format('select count(*) from %I.%I where user_id = $1', tg_table_schema, tg_table_name) into v_count using v_user;
    if v_count >= v_total then return null; end if;
  end if;
  return new;
end $$;

create or replace function private.moderate_written_content()
returns trigger language plpgsql security definer set search_path = public, private, pg_catalog
as $$
declare v_user uuid := nullif(to_jsonb(new)->>'user_id','')::uuid; v_reason text;
begin
  v_reason := private.content_violation(to_jsonb(new)::text);
  if v_reason is not null then
    execute format('delete from %I.%I where id = $1', tg_table_schema, tg_table_name) using new.id;
    perform private.ban_for_violation(v_user, tg_table_name, new.id, v_reason, v_user);
  end if;
  return null;
end $$;

create or replace function private.protect_profile_fields()
returns trigger language plpgsql security definer set search_path = public, private, pg_catalog
as $$
begin
  if tg_op = 'UPDATE' and session_user not in ('postgres','supabase_admin') and coalesce(current_setting('app.privileged_profile_write', true),'false') <> 'true' then
    new.id := old.id; new.role := old.role; new.banned_at := old.banned_at; new.ban_reason := old.ban_reason; new.joined_on := old.joined_on; new.created_at := old.created_at;
    new.avatar_url := old.avatar_url;
    if old.role = 'owner' then new.handle := old.handle; end if;
  end if;
  if lower(new.handle) = 'leather-handbag' and new.role <> 'owner' then raise exception 'reserved handle'; end if;
  new.updated_at := now(); return new;
end $$;

create or replace function private.moderate_profile()
returns trigger language plpgsql security definer set search_path = public, private, pg_catalog
as $$
declare v_reason text;
begin
  if char_length(new.display_name) > 30 or char_length(new.bio) > 300 or char_length(new.handle) > 30 then v_reason := '超大资料输入资源攻击';
  else v_reason := private.content_violation(concat_ws(' ', new.handle, new.display_name, new.bio)); end if;
  if v_reason is not null and new.role <> 'owner' then
    new.handle := 'user_' || substr(replace(new.id::text,'-',''),1,12); new.display_name := '已封禁用户'; new.bio := ''; new.avatar_url := null;
    new.banned_at := coalesce(new.banned_at, now()); new.ban_reason := v_reason;
    if tg_op = 'INSERT' then
      insert into private.moderation_events(user_id, source_table, reason, actor_id) values(null, 'profiles', v_reason || ' / user=' || new.id::text, new.id);
    else
      insert into private.moderation_events(user_id, source_table, reason, actor_id) values(new.id, 'profiles', v_reason, new.id);
    end if;
  end if;
  return new;
end $$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, pg_catalog
as $$
declare v_base text; v_handle text; v_name text;
begin
  v_base := lower(coalesce(new.raw_user_meta_data->>'user_name', split_part(new.email,'@',1), 'user'));
  v_base := regexp_replace(v_base, '[^a-z0-9_-]', '', 'g');
  if char_length(v_base) < 3 or v_base = 'leather-handbag' then v_base := 'user_' || substr(replace(new.id::text,'-',''),1,8); end if;
  v_handle := left(v_base, 20) || '_' || substr(replace(new.id::text,'-',''),1,6);
  v_name := left(coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'),''), nullif(trim(new.raw_user_meta_data->>'name'),''), nullif(split_part(new.email,'@',1),''), 'Leather 用户'), 30);
  -- OAuth provider avatars are not trusted until the user uploads one for staff review.
  insert into public.profiles(id, handle, display_name, avatar_url) values(new.id, v_handle, v_name, null);
  return new;
end $$;

create or replace function private.audit_staff_delete()
returns trigger language plpgsql security definer set search_path = public, private, pg_catalog
as $$
begin
  if auth.uid() is not null and auth.uid() <> old.user_id and private.is_staff(auth.uid()) then
    insert into private.moderation_events(user_id, source_table, content_id, reason, actor_id)
    values(old.user_id, tg_table_name, old.id, '管理员删除内容', auth.uid());
  end if;
  return old;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
drop trigger if exists a_protect_profile_fields on public.profiles;
create trigger a_protect_profile_fields before update on public.profiles for each row execute function private.protect_profile_fields();
drop trigger if exists z_moderate_profile on public.profiles;
create trigger z_moderate_profile before insert or update on public.profiles for each row execute function private.moderate_profile();

do $$
declare item record;
begin
  for item in select * from (values
    ('posts', 260000, 10, 200), ('post_comments', 12000, 30, 2000), ('station_comments', 12000, 20, 500),
    ('template_sections', 4000, 50, 200), ('templates', 820000, 100, 1000), ('template_snapshots', 820000, 150, 5000), ('plans', 220000, 20, 1)
  ) as x(tbl, bytes, rate_limit, total_limit)
  loop
    execute format('drop trigger if exists a_guard_write on public.%I', item.tbl);
    execute format('create trigger a_guard_write before insert or update on public.%I for each row execute function private.guard_write(%L,%L,%L)', item.tbl, item.bytes, item.rate_limit, item.total_limit);
    execute format('drop trigger if exists z_moderate_content on public.%I', item.tbl);
    execute format('create trigger z_moderate_content after insert or update on public.%I for each row execute function private.moderate_written_content()', item.tbl);
    execute format('drop trigger if exists y_audit_staff_delete on public.%I', item.tbl);
    execute format('create trigger y_audit_staff_delete after delete on public.%I for each row execute function private.audit_staff_delete()', item.tbl);
  end loop;
end $$;

create or replace function private.rate_checkin(number_value integer)
returns table(rarity text, label text) language plpgsql immutable set search_path = pg_catalog
as $$
declare s text := lpad(number_value::text, 6, '0');
begin
  if s ~ '^([0-9])\1{5}$' or s in ('012345','123456','234567','345678','456789','987654','876543','765432','654321','543210') then return query select 'legendary','传说';
  elsif s = reverse(s) or substring(s,1,3) = substring(s,4,3) or s ~ '^([0-9])\1{3,}' then return query select 'epic','史诗';
  elsif s ~ '([0-9])\1{2}' or s ~ '000$' or s ~ '^([0-9])\1([0-9])\2([0-9])\3$' then return query select 'rare','稀有';
  elsif s ~ '([0-9])\1' or s ~ '00$' or s ~ '(012|123|234|345|456|567|678|789|987|876|765|654|543|432|321|210)' then return query select 'uncommon','少见';
  else return query select 'common','普通'; end if;
end $$;

create or replace function public.daily_checkin()
returns public.daily_checkins language plpgsql security definer set search_path = public, private, pg_catalog
as $$
declare v_user uuid := auth.uid(); v_day date := private.china_today(); v_bytes bytea; v_raw bigint; v_number integer; v_rarity text; v_label text; v_row public.daily_checkins;
begin
  if v_user is null then raise exception 'authentication required'; end if;
  if private.is_banned(v_user) then raise exception 'account banned'; end if;
  select * into v_row from public.daily_checkins where user_id = v_user and checkin_date = v_day;
  if found then return v_row; end if;
  loop
    v_bytes := extensions.gen_random_bytes(4);
    v_raw := get_byte(v_bytes,0)::bigint * 16777216 + get_byte(v_bytes,1)::bigint * 65536 + get_byte(v_bytes,2)::bigint * 256 + get_byte(v_bytes,3)::bigint;
    exit when v_raw < 4294000000; -- rejection sampling avoids modulo bias
  end loop;
  v_number := (v_raw % 1000000)::integer;
  select rarity, label into v_rarity, v_label from private.rate_checkin(v_number);
  insert into public.daily_checkins(user_id, checkin_date, number, rarity, rarity_label) values(v_user, v_day, v_number, v_rarity, v_label) returning * into v_row;
  return v_row;
end $$;

create or replace function public.enforce_text_policy(input_text text, source_name text default 'client_input')
returns boolean language plpgsql security definer set search_path = public, private, pg_catalog
as $$
declare v_user uuid := auth.uid(); v_reason text;
begin
  if v_user is null or private.is_banned(v_user) then return false; end if;
  if octet_length(coalesce(input_text,'')) > 650000 then v_reason := '超大输入资源攻击';
  else v_reason := private.content_violation(input_text); end if;
  if v_reason is not null then
    perform private.ban_for_violation(v_user, left(coalesce(source_name,'client_input'),80), null, v_reason, v_user);
    return false;
  end if;
  return true;
end $$;

create or replace view public.public_profile_stats as
select p.id, p.handle, p.display_name, p.avatar_url, p.bio, p.role, p.joined_on,
       coalesce(c.total,0)::integer as checkin_count,
       (5 * coalesce(c.total,0) - greatest(0, (private.china_today() - p.joined_on) - coalesce(c.past,0)))::integer as score,
       c.last_checkin_date,
       case when p.role in ('admin','owner') then 'purple'
            when (5 * coalesce(c.total,0) - greatest(0, (private.china_today() - p.joined_on) - coalesce(c.past,0))) < 0 then 'gray'
            when (5 * coalesce(c.total,0) - greatest(0, (private.china_today() - p.joined_on) - coalesce(c.past,0))) < 5 then 'blue'
            when (5 * coalesce(c.total,0) - greatest(0, (private.china_today() - p.joined_on) - coalesce(c.past,0))) < 10 then 'green'
            when (5 * coalesce(c.total,0) - greatest(0, (private.china_today() - p.joined_on) - coalesce(c.past,0))) < 30 then 'orange'
            else 'red' end as name_color
from public.profiles p
left join lateral (
  select count(*) as total, count(*) filter(where d.checkin_date < private.china_today()) as past, max(d.checkin_date) as last_checkin_date
  from public.daily_checkins d where d.user_id = p.id
) c on true
where p.banned_at is null;

create or replace function public.get_my_profile()
returns table(
  id uuid, handle text, display_name text, avatar_url text, bio text, role text,
  banned_at timestamptz, ban_reason text, joined_on date, created_at timestamptz, updated_at timestamptz
)
language sql stable security definer set search_path = public, pg_catalog
as $$
  select p.id, p.handle, p.display_name, p.avatar_url, p.bio, p.role,
         p.banned_at, p.ban_reason, p.joined_on, p.created_at, p.updated_at
  from public.profiles p
  where p.id = auth.uid()
$$;

create or replace function public.update_my_profile(p_display_name text, p_handle text, p_bio text)
returns void language plpgsql security definer set search_path = public, private, pg_catalog
as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'authentication required'; end if;
  if private.is_banned(v_user) then raise exception 'account banned'; end if;
  update public.profiles
  set display_name = trim(coalesce(p_display_name,'')),
      handle = lower(trim(coalesce(p_handle,''))),
      bio = trim(coalesce(p_bio,'')),
      updated_at = now()
  where profiles.id = v_user;
end $$;

create or replace function public.submit_avatar_request(p_object_path text, p_avatar_url text)
returns public.avatar_requests language plpgsql security definer set search_path = public, private, pg_catalog
as $$
declare v_user uuid := auth.uid(); v_row public.avatar_requests; v_recent integer;
begin
  if v_user is null then raise exception 'authentication required'; end if;
  if private.is_banned(v_user) then raise exception 'account banned'; end if;
  if p_object_path !~ ('^' || v_user::text || '/[0-9a-f-]{36}\.(png|jpg|webp|gif)$')
     or char_length(p_object_path) > 240
     or p_avatar_url !~ '^https://'
     or char_length(p_avatar_url) > 700
     or position('/storage/v1/object/public/avatars/' || p_object_path in p_avatar_url) = 0 then
    raise exception 'invalid avatar object';
  end if;
  select count(*) into v_recent from public.avatar_requests
  where user_id = v_user and created_at > now() - interval '1 day';
  if v_recent >= 10 then raise exception 'too many avatar requests'; end if;
  update public.avatar_requests
  set status = 'rejected', review_note = '用户已提交新头像', reviewed_at = now()
  where user_id = v_user and status = 'pending';
  insert into public.avatar_requests(user_id, object_path, avatar_url)
  values(v_user, p_object_path, p_avatar_url)
  returning * into v_row;
  return v_row;
end $$;

create or replace function public.review_avatar_request(request_id uuid, is_approved boolean, note text default '')
returns text language plpgsql security definer set search_path = public, private, pg_catalog
as $$
declare v_req public.avatar_requests; v_target_role text; v_note text := left(trim(coalesce(note,'')),300);
begin
  select * into v_req from public.avatar_requests where id = request_id and status = 'pending' for update;
  if not found then raise exception 'avatar request not found'; end if;
  select p.role into v_target_role from public.profiles p where p.id = v_req.user_id;
  if not private.is_owner(auth.uid())
     and not (private.is_staff(auth.uid()) and v_target_role = 'user' and v_req.user_id <> auth.uid()) then
    raise exception 'forbidden';
  end if;
  if coalesce(is_approved,false) then
    perform set_config('app.privileged_profile_write','true',true);
    update public.profiles set avatar_url = v_req.avatar_url, updated_at = now() where id = v_req.user_id;
  end if;
  update public.avatar_requests
  set status = case when coalesce(is_approved,false) then 'approved' else 'rejected' end,
      reviewer_id = auth.uid(), review_note = v_note, reviewed_at = now()
  where id = v_req.id;
  insert into private.moderation_events(user_id, source_table, content_id, reason, actor_id)
  values(v_req.user_id, 'avatar_requests', v_req.id,
         case when coalesce(is_approved,false) then '头像审核通过' else '头像审核拒绝：' || coalesce(nullif(v_note,''),'未填写原因') end,
         auth.uid());
  return v_req.object_path;
end $$;

create or replace function public.admin_list_users(search_query text default '')
returns table(
  id uuid, handle text, display_name text, avatar_url text, bio text, role text, joined_on date,
  score integer, checkin_count integer, name_color text
)
language plpgsql stable security definer set search_path = public, private, pg_catalog
as $$
declare v_search text := lower(trim(coalesce(search_query,''))); v_handle text;
begin
  if not private.is_staff(auth.uid()) then raise exception 'forbidden'; end if;
  v_handle := regexp_replace(v_search, '^@', '');
  return query
  select s.id, s.handle, s.display_name, s.avatar_url, s.bio, s.role, s.joined_on,
         s.score, s.checkin_count, s.name_color
  from public.public_profile_stats s
  where v_search = '' or position(v_search in lower(s.display_name)) > 0 or position(v_handle in lower(s.handle)) > 0
  order by s.role = 'owner' desc, s.role = 'admin' desc, s.score desc, s.display_name
  limit 100;
end $$;

create or replace function public.owner_list_banned_users(limit_count integer default 100)
returns table(
  id uuid, handle text, display_name text, avatar_url text, role text,
  banned_at timestamptz, ban_reason text
)
language plpgsql stable security definer set search_path = public, private, pg_catalog
as $$
begin
  if not private.is_owner(auth.uid()) then raise exception 'forbidden'; end if;
  return query
  select p.id, p.handle, p.display_name, p.avatar_url, p.role, p.banned_at, p.ban_reason
  from public.profiles p
  where p.banned_at is not null
  order by p.banned_at desc
  limit least(greatest(limit_count,1),500);
end $$;

create or replace function public.admin_ban_user(target_id uuid, reason text)
returns void language plpgsql security definer set search_path = public, private, pg_catalog
as $$
begin
  if not private.can_moderate_user(target_id) then raise exception 'forbidden'; end if;
  perform set_config('app.privileged_profile_write','true',true);
  update public.profiles set banned_at = now(), ban_reason = left(coalesce(nullif(trim(reason),''),'管理员封禁'),500), updated_at = now() where id = target_id;
  insert into private.moderation_events(user_id, source_table, reason, actor_id) values(target_id, 'profiles', '管理员封禁：'||left(coalesce(reason,''),400), auth.uid());
end $$;

create or replace function public.owner_unban_user(target_id uuid)
returns void language plpgsql security definer set search_path = public, private, pg_catalog
as $$
begin
  if not private.is_owner(auth.uid()) or private.is_owner(target_id) then raise exception 'forbidden'; end if;
  perform set_config('app.privileged_profile_write','true',true);
  update public.profiles set banned_at = null, ban_reason = null, updated_at = now() where id = target_id;
  insert into private.moderation_events(user_id, source_table, reason, actor_id) values(target_id, 'profiles', '站长解封', auth.uid());
end $$;

create or replace function public.owner_set_admin(target_id uuid, enabled boolean)
returns void language plpgsql security definer set search_path = public, private, pg_catalog
as $$
begin
  if not private.is_owner(auth.uid()) or private.is_owner(target_id) or target_id = auth.uid() then raise exception 'forbidden'; end if;
  perform set_config('app.privileged_profile_write','true',true);
  update public.profiles set role = case when enabled then 'admin' else 'user' end, updated_at = now() where id = target_id;
  insert into private.moderation_events(user_id, source_table, reason, actor_id) values(target_id, 'profiles', case when enabled then '授权管理员' else '解除管理员' end, auth.uid());
end $$;

create or replace function public.get_moderation_events(limit_count integer default 100)
returns table(id uuid, user_id uuid, source_table text, content_id uuid, reason text, actor_id uuid, created_at timestamptz)
language plpgsql security definer set search_path = public, private, pg_catalog
as $$
begin
  if not private.is_staff(auth.uid()) then raise exception 'forbidden'; end if;
  return query select e.id,e.user_id,e.source_table,e.content_id,e.reason,e.actor_id,e.created_at from private.moderation_events e order by e.created_at desc limit least(greatest(limit_count,1),500);
end $$;

grant execute on function public.daily_checkin(), public.enforce_text_policy(text,text),
  public.get_my_profile(), public.update_my_profile(text,text,text), public.submit_avatar_request(text,text),
  public.review_avatar_request(uuid,boolean,text), public.admin_list_users(text), public.owner_list_banned_users(integer),
  public.admin_ban_user(uuid,text), public.owner_unban_user(uuid), public.owner_set_admin(uuid,boolean), public.get_moderation_events(integer)
to authenticated;
grant select on public.public_profile_stats to anon, authenticated;

alter table public.profiles enable row level security;
alter table public.avatar_requests enable row level security;
alter table public.posts enable row level security;
alter table public.post_comments enable row level security;
alter table public.station_comments enable row level security;
alter table public.template_sections enable row level security;
alter table public.templates enable row level security;
alter table public.template_snapshots enable row level security;
alter table public.plans enable row level security;
alter table public.daily_checkins enable row level security;

drop policy if exists profiles_self_or_staff_select on public.profiles;
create policy profiles_self_or_staff_select on public.profiles for select to authenticated using(id = auth.uid() or private.is_staff(auth.uid()));
drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles for update to authenticated using(id = auth.uid() and not private.is_banned(auth.uid())) with check(id = auth.uid());

drop policy if exists avatar_requests_read on public.avatar_requests;
create policy avatar_requests_read on public.avatar_requests for select to authenticated
using(user_id = auth.uid() or private.is_staff(auth.uid()));

drop policy if exists posts_read on public.posts;
create policy posts_read on public.posts for select to anon, authenticated using(visibility = 'public' or user_id = auth.uid() or private.is_staff(auth.uid()));
drop policy if exists posts_insert on public.posts;
create policy posts_insert on public.posts for insert to authenticated with check(user_id = auth.uid() and not private.is_banned(auth.uid()));
drop policy if exists posts_update on public.posts;
create policy posts_update on public.posts for update to authenticated using(user_id = auth.uid() and not private.is_banned(auth.uid())) with check(user_id = auth.uid());
drop policy if exists posts_delete on public.posts;
create policy posts_delete on public.posts for delete to authenticated using(user_id = auth.uid() or private.can_moderate_user(user_id));

drop policy if exists post_comments_read on public.post_comments;
create policy post_comments_read on public.post_comments for select to anon, authenticated using(user_id = auth.uid() or private.is_staff(auth.uid()) or exists(select 1 from public.posts p where p.id = post_id and p.visibility = 'public'));
drop policy if exists post_comments_insert on public.post_comments;
create policy post_comments_insert on public.post_comments for insert to authenticated with check(user_id = auth.uid() and not private.is_banned(auth.uid()) and exists(select 1 from public.posts p where p.id = post_id and p.visibility = 'public'));
drop policy if exists post_comments_update on public.post_comments;
create policy post_comments_update on public.post_comments for update to authenticated using(user_id = auth.uid() and not private.is_banned(auth.uid())) with check(user_id = auth.uid());
drop policy if exists post_comments_delete on public.post_comments;
create policy post_comments_delete on public.post_comments for delete to authenticated using(user_id = auth.uid() or private.can_moderate_user(user_id));

drop policy if exists station_comments_read on public.station_comments;
create policy station_comments_read on public.station_comments for select to anon, authenticated using(true);
drop policy if exists station_comments_insert on public.station_comments;
create policy station_comments_insert on public.station_comments for insert to authenticated with check(user_id = auth.uid() and not private.is_banned(auth.uid()));
drop policy if exists station_comments_update on public.station_comments;
create policy station_comments_update on public.station_comments for update to authenticated using(user_id = auth.uid() and not private.is_banned(auth.uid())) with check(user_id = auth.uid());
drop policy if exists station_comments_delete on public.station_comments;
create policy station_comments_delete on public.station_comments for delete to authenticated using(user_id = auth.uid() or private.can_moderate_user(user_id));

do $$
declare tbl text;
begin
  foreach tbl in array array['template_sections','templates','template_snapshots','plans'] loop
    execute format('drop policy if exists %I on public.%I', tbl||'_read', tbl);
    execute format('create policy %I on public.%I for select to authenticated using(user_id = auth.uid() or private.is_staff(auth.uid()))', tbl||'_read', tbl);
    execute format('drop policy if exists %I on public.%I', tbl||'_insert', tbl);
    execute format('create policy %I on public.%I for insert to authenticated with check(user_id = auth.uid() and not private.is_banned(auth.uid()))', tbl||'_insert', tbl);
    execute format('drop policy if exists %I on public.%I', tbl||'_update', tbl);
    execute format('create policy %I on public.%I for update to authenticated using(user_id = auth.uid() and not private.is_banned(auth.uid())) with check(user_id = auth.uid())', tbl||'_update', tbl);
    execute format('drop policy if exists %I on public.%I', tbl||'_delete', tbl);
    execute format('create policy %I on public.%I for delete to authenticated using(user_id = auth.uid() or private.can_moderate_user(user_id))', tbl||'_delete', tbl);
  end loop;
end $$;

drop policy if exists daily_checkins_read on public.daily_checkins;
create policy daily_checkins_read on public.daily_checkins for select to authenticated using(user_id = auth.uid() or private.is_staff(auth.uid()));

revoke all privileges on public.profiles from anon, authenticated;
revoke all privileges on public.avatar_requests from anon, authenticated;
grant select on public.avatar_requests to authenticated;
grant select on public.posts, public.post_comments, public.station_comments to anon;
grant select,insert,update,delete on public.posts, public.post_comments, public.station_comments, public.template_sections, public.templates, public.template_snapshots, public.plans to authenticated;
grant select on public.daily_checkins to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('avatars','avatars',true,2097152,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict(id) do update set public=true,file_size_limit=2097152,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists avatar_public_read on storage.objects;
create policy avatar_public_read on storage.objects for select to public using(bucket_id='avatars');
drop policy if exists avatar_owner_insert on storage.objects;
create policy avatar_owner_insert on storage.objects for insert to authenticated with check(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text and not private.is_banned(auth.uid()));
drop policy if exists avatar_owner_update on storage.objects;
create policy avatar_owner_update on storage.objects for update to authenticated using(bucket_id='avatars' and owner_id=auth.uid()::text) with check(bucket_id='avatars' and owner_id=auth.uid()::text);
drop policy if exists avatar_owner_delete on storage.objects;
create policy avatar_owner_delete on storage.objects for delete to authenticated using(bucket_id='avatars' and owner_id=auth.uid()::text);
drop policy if exists avatar_reviewer_delete on storage.objects;
create policy avatar_reviewer_delete on storage.objects for delete to authenticated
using(bucket_id='avatars' and private.is_staff(auth.uid()) and exists(
  select 1 from public.avatar_requests r where r.object_path = storage.objects.name and r.status = 'rejected'
));

revoke all on all tables in schema private from public, anon, authenticated;
revoke all on all sequences in schema private from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.china_today(), private.is_staff(uuid), private.is_owner(uuid), private.is_banned(uuid), private.can_moderate_user(uuid) to anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.daily_checkin(), public.enforce_text_policy(text,text),
  public.get_my_profile(), public.update_my_profile(text,text,text), public.submit_avatar_request(text,text),
  public.review_avatar_request(uuid,boolean,text), public.admin_list_users(text), public.owner_list_banned_users(integer),
  public.admin_ban_user(uuid,text), public.owner_unban_user(uuid), public.owner_set_admin(uuid,boolean), public.get_moderation_events(integer)
from public, anon;
grant execute on function public.daily_checkin(), public.enforce_text_policy(text,text),
  public.get_my_profile(), public.update_my_profile(text,text,text), public.submit_avatar_request(text,text),
  public.review_avatar_request(uuid,boolean,text), public.admin_list_users(text), public.owner_list_banned_users(integer),
  public.admin_ban_user(uuid,text), public.owner_unban_user(uuid), public.owner_set_admin(uuid,boolean), public.get_moderation_events(integer)
to authenticated;

-- SECURITY-CRITICAL MANUAL STEP AFTER YOUR FIRST SIGN-IN:
-- Replace YOUR_AUTH_UUID with your own Authentication -> Users UUID and run as project owner.
-- Never identify the owner only by a user-editable name.
-- update public.profiles
-- set role='owner', handle='leather-handbag', display_name='leather-handbag', updated_at=now()
-- where id='YOUR_AUTH_UUID';
