-- Leather Algorithm Expedition game-map state, quests and guardian challenges.
-- Visual state is derived from verified training data; clients cannot award progress.

insert into public.training_feature_flags(key,enabled,config,updated_at)
values('training_game_map_v1',true,'{"rollout":"all","scene_version":1,"fallback":"atlas"}'::jsonb,now())
on conflict(key) do update set enabled=excluded.enabled,config=excluded.config,updated_at=excluded.updated_at;

create table if not exists public.training_game_state (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  selected_map text references public.training_maps(code) on delete set null,
  selected_region text references public.map_regions(code) on delete set null,
  seen_unlock_event_ids jsonb not null default '[]'::jsonb check(jsonb_typeof(seen_unlock_event_ids)='array'),
  audio_enabled boolean not null default false,
  effects_quality text not null default 'auto' check(effects_quality in ('auto','high','low')),
  updated_at timestamptz not null default now()
);

create table if not exists public.guardian_challenges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  map_code text not null references public.training_maps(code) on delete cascade,
  problem_id uuid not null references public.problem_catalog(id) on delete restrict,
  model_version integer not null references public.mastery_model_versions(version) on delete restrict,
  generated_at timestamptz not null default now(),
  completed_at timestamptz,
  rerolled_at timestamptz,
  reroll_count integer not null default 0 check(reroll_count between 0 and 20),
  unique(user_id,map_code)
);
create index if not exists guardian_challenges_user_idx on public.guardian_challenges(user_id,generated_at desc);
create unique index if not exists expedition_logs_guardian_once_idx
  on public.expedition_logs(user_id,(detail->>'map')) where type='guardian';

alter table public.training_game_state enable row level security;
alter table public.guardian_challenges enable row level security;

drop policy if exists training_game_state_own_read on public.training_game_state;
create policy training_game_state_own_read on public.training_game_state for select to authenticated using(user_id=(select auth.uid()));
drop policy if exists guardian_challenges_own_read on public.guardian_challenges;
create policy guardian_challenges_own_read on public.guardian_challenges for select to authenticated using(user_id=(select auth.uid()));

revoke all on public.training_game_state,public.guardian_challenges from public,anon,authenticated;
grant select on public.training_game_state,public.guardian_challenges to authenticated;

insert into public.achievement_definitions(code,name,description,icon,sort_order) values
('guardian_plains','平原守门人','完成启程平原综合挑战。','◇',301),
('guardian_bronze','海湾守门人','完成青铜海湾综合挑战。','◇',302),
('guardian_silver','山脉守门人','完成白银山脉综合挑战。','◇',303),
('guardian_gold','荒漠守门人','完成黄金荒漠综合挑战。','◇',304),
('guardian_platinum','天穹守门人','完成铂金天穹综合挑战。','◇',305),
('guardian_master','星域守门人','完成大师星域综合挑战。','◇',306),
('guardian_legend','深渊守门人','完成传奇深渊综合挑战。','◇',307)
on conflict(code) do update set name=excluded.name,description=excluded.description,icon=excluded.icon,sort_order=excluded.sort_order;

create or replace function private.build_training_game_state(target_user uuid)
returns jsonb language sql stable security definer set search_path=public,pg_catalog
as $$
  select jsonb_build_object(
    'selected_map',coalesce(s.selected_map,(select m.code from public.map_unlocks u join public.training_maps m on m.code=u.map_code where u.user_id=target_user order by m.position desc limit 1),'plains'),
    'selected_region',s.selected_region,
    'seen_unlock_event_ids',coalesce(s.seen_unlock_event_ids,'[]'::jsonb),
    'audio_enabled',coalesce(s.audio_enabled,false),
    'effects_quality',coalesce(s.effects_quality,'auto'),
    'updated_at',s.updated_at)
  from (select 1) seed left join public.training_game_state s on s.user_id=target_user;
$$;

create or replace function private.build_training_game_scene(target_user uuid, spectator boolean default false)
returns jsonb language sql stable security definer set search_path=public,private,pg_catalog
as $$
  with model as (select version from public.mastery_model_versions where active order by version desc limit 1),
  nodes as (
    select r.code region_code,r.map_code,r.is_core,coalesce(s.mastery_percent,0) percent,
      case when u.map_code is null then 'undiscovered'
           when coalesce(s.mastery_percent,0)=0 then 'discovered'
           when coalesce(s.mastery_percent,0)<80 then 'in_progress'
           when coalesce(s.mastery_percent,0)<100 then 'strong'
           else 'mastered' end state,
      case when not r.is_core then 0 else
        (case when coalesce(s.mastery_percent,0)>=25 then 1 else 0 end+
         case when coalesce(s.mastery_percent,0)>=50 then 1 else 0 end+
         case when coalesce(s.mastery_percent,0)>=80 then 1 else 0 end+
         case when coalesce(s.mastery_percent,0)>=100 then 1 else 0 end) end stars
    from public.map_regions r
    left join public.map_unlocks u on u.user_id=target_user and u.map_code=r.map_code
    left join public.skill_mastery s on s.user_id=target_user and s.region_code=r.code and s.model_version=(select version from model)
  ), paths as (
    select m.code map_code,coalesce(round(avg(n.percent)),0) progress,
      case when bool_and(n.state='mastered') filter(where n.is_core) then 'mastered'
           when max(n.percent)>0 then 'active' else 'dormant' end state
    from public.training_maps m left join nodes n on n.map_code=m.code group by m.code
  )
  select jsonb_build_object(
    'scene_version',1,
    'spectator_mode',spectator,
    'node_states',coalesce((select jsonb_agg(jsonb_build_object('region_code',region_code,'map_code',map_code,'state',state,'percent',percent,'stars',stars,'core',is_core) order by map_code,region_code) from nodes),'[]'::jsonb),
    'path_states',coalesce((select jsonb_agg(jsonb_build_object('map_code',map_code,'state',state,'progress',progress) order by map_code) from paths),'[]'::jsonb),
    'campfire_temperature',coalesce((select least(100,round(100.0*count(distinct activity_date)/30)) from public.training_daily_stats where user_id=target_user and activity_date>=private.china_today()-89 and platform in ('codeforces','atcoder')),0),
    'map_star_summary',coalesce((select jsonb_object_agg(map_code,jsonb_build_object('earned',earned,'total',total)) from (select map_code,sum(stars) earned,count(*) filter(where is_core)*4 total from nodes group by map_code)x),'{}'::jsonb));
$$;

create or replace function private.complete_training_game_events(target_user uuid)
returns void language plpgsql security definer set search_path=public,private,pg_catalog
as $$
declare v_challenge record;v_map_name text;
begin
  update public.training_recommendations r set completed_at=coalesce(r.completed_at,p.first_accepted_at)
  from public.user_problem_progress p
  where r.user_id=target_user and p.user_id=target_user and p.problem_id=r.problem_id and p.is_solved and r.completed_at is null;

  for v_challenge in
    update public.guardian_challenges g set completed_at=coalesce(g.completed_at,p.first_accepted_at)
    from public.user_problem_progress p
    where g.user_id=target_user and p.user_id=target_user and p.problem_id=g.problem_id and p.is_solved and g.completed_at is null
    returning g.*
  loop
    select name into v_map_name from public.training_maps where code=v_challenge.map_code;
    perform private.award_achievement(target_user,'guardian_'||v_challenge.map_code,v_map_name);
    insert into public.expedition_logs(user_id,type,title,message,detail)
    values(target_user,'guardian','守门人挑战完成：'||v_map_name,'综合挑战已经完成，这座地图留下了永久徽记。',jsonb_build_object('map',v_challenge.map_code,'challenge',v_challenge.id))
    on conflict do nothing;
  end loop;
end $$;

create or replace function private.refresh_guardian_challenges(target_user uuid)
returns void language plpgsql security definer set search_path=public,private,pg_catalog
as $$
declare v_model integer;v_map record;v_problem uuid;
begin
  select version into v_model from public.mastery_model_versions where active order by version desc limit 1;
  perform private.complete_training_game_events(target_user);
  for v_map in
    select m.code from public.training_maps m join public.map_unlocks u on u.user_id=target_user and u.map_code=m.code
    where not exists(select 1 from public.map_regions r left join public.skill_mastery s on s.user_id=target_user and s.region_code=r.code and s.model_version=v_model where r.map_code=m.code and r.is_core and coalesce(s.mastery_percent,0)<100)
      and not exists(select 1 from public.guardian_challenges g where g.user_id=target_user and g.map_code=m.code)
    order by m.position
  loop
    select c.id into v_problem from public.problem_catalog c
    where c.map_code=v_map.code and c.is_available and c.normalized_difficulty is not null
      and exists(select 1 from public.problem_skill_tags t join public.map_region_skills rs on rs.skill_code=t.skill_code join public.map_regions r on r.code=rs.region_code where t.problem_id=c.id and t.confidence>=.7 and r.map_code=v_map.code)
      and not exists(select 1 from public.user_problem_progress p where p.user_id=target_user and p.problem_id=c.id and p.is_solved)
    order by c.normalized_difficulty desc,c.id limit 1;
    if v_problem is not null then
      insert into public.guardian_challenges(user_id,map_code,problem_id,model_version) values(target_user,v_map.code,v_problem,v_model) on conflict do nothing;
    end if;
  end loop;
end $$;

create or replace function public.update_training_game_state(
  selected_map_code text default null,selected_region_code text default null,
  audio_enabled_value boolean default null,effects_quality_value text default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_catalog
as $$
declare v_user uuid:=auth.uid();v_region_map text;
begin
  if v_user is null then raise exception 'authentication required'; end if;
  if selected_map_code is not null and not exists(select 1 from public.training_maps where code=selected_map_code) then raise exception 'invalid map'; end if;
  if selected_region_code is not null then
    select map_code into v_region_map from public.map_regions where code=selected_region_code;
    if v_region_map is null then raise exception 'invalid region'; end if;
    if selected_map_code is not null and v_region_map<>selected_map_code then raise exception 'region does not belong to map'; end if;
  end if;
  if effects_quality_value is not null and effects_quality_value not in ('auto','high','low') then raise exception 'invalid effects quality'; end if;
  insert into public.training_game_state(user_id,selected_map,selected_region,audio_enabled,effects_quality)
  values(v_user,selected_map_code,selected_region_code,coalesce(audio_enabled_value,false),coalesce(effects_quality_value,'auto'))
  on conflict(user_id) do update set
    selected_map=coalesce(excluded.selected_map,training_game_state.selected_map),
    selected_region=coalesce(excluded.selected_region,training_game_state.selected_region),
    audio_enabled=coalesce(audio_enabled_value,training_game_state.audio_enabled),
    effects_quality=coalesce(effects_quality_value,training_game_state.effects_quality),updated_at=now();
  return private.build_training_game_state(v_user);
end $$;

create or replace function public.mark_unlock_event_seen(event_id text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_catalog
as $$
declare v_user uuid:=auth.uid();v_map text:=replace(event_id,'map:','');
begin
  if v_user is null then raise exception 'authentication required'; end if;
  if not exists(select 1 from public.map_unlocks where user_id=v_user and map_code=v_map) then raise exception 'unknown unlock event'; end if;
  insert into public.training_game_state(user_id,seen_unlock_event_ids) values(v_user,jsonb_build_array('map:'||v_map))
  on conflict(user_id) do update set seen_unlock_event_ids=(select jsonb_agg(distinct x) from jsonb_array_elements(training_game_state.seen_unlock_event_ids||jsonb_build_array('map:'||v_map))x),updated_at=now();
  return private.build_training_game_state(v_user);
end $$;

create or replace function public.get_guardian_challenge(map_code_value text)
returns jsonb language sql stable security definer set search_path=public,pg_catalog
as $$
  select coalesce((select jsonb_build_object('id',g.id,'map_code',g.map_code,'generated_at',g.generated_at,'completed_at',g.completed_at,'rerolled_at',g.rerolled_at,'reroll_count',g.reroll_count,
    'problem',jsonb_build_object('id',c.id,'platform',c.platform,'title',c.title,'url',c.url,'difficulty',c.normalized_difficulty))
    from public.guardian_challenges g join public.problem_catalog c on c.id=g.problem_id where g.user_id=auth.uid() and g.map_code=map_code_value),'{}'::jsonb);
$$;

create or replace function public.reroll_guardian_challenge(map_code_value text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_catalog
as $$
declare v_user uuid:=auth.uid();v_old public.guardian_challenges;v_problem uuid;
begin
  if v_user is null then raise exception 'authentication required'; end if;
  select * into v_old from public.guardian_challenges where user_id=v_user and map_code=map_code_value for update;
  if not found then raise exception 'guardian challenge unavailable'; end if;
  if v_old.completed_at is not null then raise exception 'completed challenge cannot be replaced'; end if;
  if v_old.rerolled_at is not null and v_old.rerolled_at>now()-interval '24 hours' then raise exception 'guardian reroll is cooling down'; end if;
  select c.id into v_problem from public.problem_catalog c where c.map_code=map_code_value and c.is_available and c.normalized_difficulty is not null and c.id<>v_old.problem_id
    and exists(select 1 from public.problem_skill_tags t where t.problem_id=c.id and t.confidence>=.7)
    and not exists(select 1 from public.user_problem_progress p where p.user_id=v_user and p.problem_id=c.id and p.is_solved)
    order by c.normalized_difficulty desc,c.id limit 1;
  if v_problem is null then raise exception 'no alternate guardian challenge available'; end if;
  update public.guardian_challenges set problem_id=v_problem,rerolled_at=now(),reroll_count=reroll_count+1 where id=v_old.id;
  return public.get_guardian_challenge(map_code_value);
end $$;

-- Preserve completed recommendations when refreshing today's three slots.
create or replace function private.refresh_training_recommendations(target_user uuid)
returns void language plpgsql security definer set search_path=public,private,pg_catalog
as $$
declare v_model integer;v_map text;v_region text;v_problem uuid;v_slot text;v_reason text;v_score numeric;
begin
  perform private.complete_training_game_events(target_user);
  select version into v_model from public.mastery_model_versions where active order by version desc limit 1;
  select m.code into v_map from public.map_unlocks u join public.training_maps m on m.code=u.map_code where u.user_id=target_user order by m.position desc limit 1;
  v_map:=coalesce(v_map,'plains');

  foreach v_slot in array array['weakness','progress','explore'] loop
    if exists(select 1 from public.training_recommendations where user_id=target_user and recommendation_date=private.china_today() and slot=v_slot and completed_at is not null) then continue; end if;
    v_problem:=null;v_region:=null;
    if v_slot='weakness' then
      select s.region_code into v_region from public.skill_mastery s join public.map_regions r on r.code=s.region_code where s.user_id=target_user and s.model_version=v_model and s.assessment='weakness' order by s.mastery_percent,s.evidence desc limit 1;
      if v_region is null then select s.region_code into v_region from public.skill_mastery s join public.map_regions r on r.code=s.region_code where s.user_id=target_user and s.model_version=v_model and r.map_code=v_map and r.is_core order by s.mastery_percent,s.evidence limit 1; end if;
      v_reason:='补齐可靠弱项，并增加该算法据点的有效证据。';v_score:=1;
    elsif v_slot='progress' then
      select s.region_code into v_region from public.skill_mastery s join public.map_regions r on r.code=s.region_code where s.user_id=target_user and s.model_version=v_model and r.map_code=v_map and r.is_core order by s.mastery_percent,s.evidence limit 1;
      v_reason:='推进当前地图，优先修复尚未点亮的核心据点。';v_score:=.9;
    else
      select r.code into v_region from public.map_regions r where r.map_code=v_map and not r.is_core order by r.position limit 1;
      v_reason:='探索可选遗迹，保持训练内容的新鲜感。';v_score:=.5;
    end if;
    select c.id into v_problem from public.problem_catalog c
    where c.is_available and (v_slot='weakness' or c.map_code=v_map)
      and (v_region is null or exists(select 1 from public.problem_skill_tags t join public.map_region_skills rs on rs.skill_code=t.skill_code where t.problem_id=c.id and t.confidence>=.7 and rs.region_code=v_region))
      and not exists(select 1 from public.user_problem_progress p where p.user_id=target_user and p.problem_id=c.id and p.is_solved)
      and not exists(select 1 from public.training_recommendations old where old.user_id=target_user and old.problem_id=c.id and old.skipped_at>now()-interval '7 days')
      and not exists(select 1 from public.training_recommendations today where today.user_id=target_user and today.recommendation_date=private.china_today() and today.problem_id=c.id)
    order by abs(coalesce(c.normalized_difficulty,1000)-coalesce((select hard_problem_average from public.user_ability_estimates where user_id=target_user),1000)),c.id limit 1;
    if v_problem is not null then
      insert into public.training_recommendations(user_id,recommendation_date,slot,problem_id,region_code,reason,score)
      values(target_user,private.china_today(),v_slot,v_problem,v_region,v_reason,v_score)
      on conflict(user_id,recommendation_date,slot) do update set problem_id=excluded.problem_id,region_code=excluded.region_code,reason=excluded.reason,score=excluded.score,skipped_at=null,completed_at=null,created_at=now()
      where training_recommendations.completed_at is null;
    end if;
  end loop;
end $$;

create or replace function public.refresh_training_user(target_user uuid)
returns void language plpgsql security definer set search_path=private,public,pg_catalog
as $$
declare v_model integer;
begin
  if current_user not in ('postgres','service_role','supabase_admin') then raise exception 'service role required'; end if;
  perform private.refresh_training_aggregates(target_user);
  perform private.refresh_training_mastery(target_user);
  select version into v_model from public.mastery_model_versions where active order by version desc limit 1;
  perform private.refresh_ability_unlocks(target_user,v_model);
  perform private.refresh_training_recommendations(target_user);
  perform private.refresh_guardian_challenges(target_user);
end $$;

create or replace function public.get_my_training_dashboard()
returns jsonb language plpgsql stable security definer set search_path=public,private,pg_catalog
as $$
declare v_user uuid:=auth.uid();v_result jsonb;v_model integer;v_scene jsonb;v_game jsonb;
begin
  if v_user is null then raise exception 'authentication required'; end if;
  select version into v_model from public.mastery_model_versions where active limit 1;
  v_scene:=private.build_training_game_scene(v_user,false);v_game:=private.build_training_game_state(v_user);
  select jsonb_build_object(
    'generated_at',now(),'data_through',(select max(data_through) from public.external_accounts where user_id=v_user and platform in ('codeforces','atcoder')),
    'model_version',v_model,'classification_coverage',coalesce((select round(100.0*count(*) filter(where exists(select 1 from public.problem_skill_tags t where t.problem_id=p.problem_id and t.confidence>=.7))/nullif(count(*),0)) from public.user_problem_progress p where p.user_id=v_user and p.is_solved),0),
    'summary',jsonb_build_object('solved',(select count(*) from public.user_problem_progress where user_id=v_user and is_solved),'attempts',(select coalesce(sum(attempt_count),0) from public.user_problem_progress where user_id=v_user),'active_days',(select count(distinct activity_date) from public.training_daily_stats where user_id=v_user),'freshness',v_scene->'campfire_temperature','maps_unlocked',(select count(*) from public.map_unlocks where user_id=v_user)),
    'ability_estimate',private.build_ability_estimate(v_user),'accounts',private.build_training_accounts(v_user),'maps',private.build_training_map(v_user),
    'game_state',v_game,'scene_version',1,'node_states',v_scene->'node_states','path_states',v_scene->'path_states','campfire_temperature',v_scene->'campfire_temperature','map_star_summary',v_scene->'map_star_summary',
    'unseen_unlock_events',coalesce((select jsonb_agg(jsonb_build_object('event_id','map:'||u.map_code,'map_code',u.map_code,'unlocked_at',u.unlocked_at,'reason',u.detail->>'reason','detail',u.detail) order by u.unlocked_at) from public.map_unlocks u where u.user_id=v_user and not (v_game->'seen_unlock_event_ids' ? ('map:'||u.map_code))),'[]'::jsonb),
    'privacy',coalesce((select to_jsonb(p)-'user_id' from public.training_privacy p where p.user_id=v_user),'{}'::jsonb),
    'logs',coalesce((select jsonb_agg(x order by (x->>'created_at')::timestamptz desc) from (select jsonb_build_object('id',id,'type',type,'title',title,'message',message,'detail',detail,'created_at',created_at) x from public.expedition_logs where user_id=v_user order by created_at desc limit 20)q),'[]'::jsonb)
  ) into v_result;return v_result;
end $$;

create or replace function public.get_training_map(target_user uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_catalog
as $$
declare v_public boolean;v_spectator boolean:=auth.uid() is distinct from target_user;v_scene jsonb;
begin
  select map_public into v_public from public.training_privacy where user_id=target_user;
  if v_spectator and not coalesce(v_public,true) then return jsonb_build_object('locked',true,'maps',null,'spectator_mode',true); end if;
  v_scene:=private.build_training_game_scene(target_user,v_spectator);
  return jsonb_build_object('locked',false,'maps',private.build_training_map(target_user),'generated_at',now(),'model_version',(select version from public.mastery_model_versions where active limit 1),
    'scene_version',1,'node_states',v_scene->'node_states','path_states',v_scene->'path_states','spectator_mode',v_spectator,'campfire_temperature',v_scene->'campfire_temperature','map_star_summary',v_scene->'map_star_summary');
end $$;

drop function if exists public.get_training_recommendations(integer);
create function public.get_training_recommendations(limit_count integer default 3)
returns table(id uuid,slot text,reason text,score numeric,problem_id uuid,platform text,external_problem_id text,title text,url text,difficulty integer,map_code text,region_code text,skipped_at timestamptz,completed_at timestamptz,status text)
language sql stable security definer set search_path=public,private,pg_catalog
as $$
  select r.id,r.slot,r.reason,r.score,c.id,c.platform,c.external_problem_id,c.title,c.url,c.normalized_difficulty,c.map_code,r.region_code,r.skipped_at,r.completed_at,
    case when r.completed_at is not null then 'completed' when r.skipped_at is not null then 'skipped' else 'available' end
  from public.training_recommendations r join public.problem_catalog c on c.id=r.problem_id where r.user_id=auth.uid() and r.recommendation_date=private.china_today()
  order by case r.slot when 'weakness' then 1 when 'progress' then 2 else 3 end limit least(greatest(coalesce(limit_count,3),1),10);
$$;

grant execute on function public.update_training_game_state(text,text,boolean,text),public.mark_unlock_event_seen(text),public.get_guardian_challenge(text),public.reroll_guardian_challenge(text),public.get_training_recommendations(integer) to authenticated;
revoke execute on function private.build_training_game_state(uuid),private.build_training_game_scene(uuid,boolean),private.complete_training_game_events(uuid),private.refresh_guardian_challenges(uuid) from public,anon,authenticated;

comment on table public.training_game_state is 'Private cross-device cosmetic state for the Algorithm Expedition game map.';
comment on table public.guardian_challenges is 'Server-selected optional map challenges completed only by verified synchronized AC data.';
