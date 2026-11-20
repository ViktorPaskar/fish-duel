-- Fish Duel cloud rooms. Tables are closed to the public API (RLS on, no policies);
-- the app talks only through these functions, and only by knowing the room code.

create table if not exists fd_rooms(
  code text primary key check (code ~ '^[A-Z0-9]{5}$'),
  owner text not null,
  closed boolean not null default false,
  created timestamptz not null default now()
);
create table if not exists fd_players(
  room text not null references fd_rooms(code) on delete cascade,
  pid text not null check (length(pid) < 40),
  name text check (length(name) <= 18),
  avatar text check (length(avatar) < 200000),
  primary key(room, pid)
);
create table if not exists fd_catches(
  room text not null references fd_rooms(code) on delete cascade,
  id text not null check (length(id) < 40),
  pid text not null check (length(pid) < 40),
  data jsonb not null check (length(data::text) < 2000),
  u bigint not null default 0,
  deleted boolean not null default false,
  primary key(room, id)
);
alter table fd_rooms enable row level security;
alter table fd_players enable row level security;
alter table fd_catches enable row level security;
revoke all on fd_rooms, fd_players, fd_catches from anon, authenticated;

-- full room state, or {closed:true} / null
create or replace function fd_state(p_room text) returns jsonb
language sql security definer set search_path = public stable as $$
  select case when r.code is null then null
    when r.closed then jsonb_build_object('closed', true, 'owner', r.owner)
    else jsonb_build_object(
      'owner', r.owner,
      'players', coalesce((select jsonb_agg(jsonb_build_object('pid',p.pid,'name',p.name,'avatar',p.avatar)) from fd_players p where p.room=r.code),'[]'),
      'catches', coalesce((select jsonb_agg(c.data) from fd_catches c where c.room=r.code and not c.deleted),'[]'),
      'deleted', coalesce((select jsonb_agg(c.id) from fd_catches c where c.room=r.code and c.deleted),'[]'))
  end
  from (select 1) x left join fd_rooms r on r.code = p_room;
$$;

-- enter a room; p_create allows creating it (new room or a room from before the cloud)
create or replace function fd_join(p_room text, p_pid text, p_owner text, p_create boolean, p_name text, p_avatar text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from fd_rooms where code=p_room) then
    if not p_create then return null; end if;
    insert into fd_rooms(code, owner) values (p_room, coalesce(nullif(p_owner,''), p_pid)) on conflict do nothing;
  end if;
  if exists(select 1 from fd_rooms where code=p_room and not closed) then
    insert into fd_players(room,pid,name,avatar) values (p_room,p_pid,p_name,p_avatar)
      on conflict (room,pid) do update set name=excluded.name, avatar=excluded.avatar;
  end if;
  return fd_state(p_room);
end $$;

create or replace function fd_player(p_room text, p_pid text, p_name text, p_avatar text)
returns void language sql security definer set search_path = public as $$
  update fd_players set name=p_name, avatar=p_avatar
  where room=p_room and pid=p_pid and exists(select 1 from fd_rooms where code=p_room and not closed);
$$;

-- add or update a catch; only its author may change it, newer edit wins
create or replace function fd_put(p_room text, p_c jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not exists(select 1 from fd_rooms where code=p_room and not closed) then return false; end if;
  insert into fd_catches(room,id,pid,data,u)
    values (p_room, p_c->>'id', p_c->>'pid', p_c, coalesce((p_c->>'u')::bigint,0))
  on conflict (room,id) do update set data=excluded.data, u=excluded.u
    where fd_catches.pid=excluded.pid and not fd_catches.deleted and excluded.u > fd_catches.u;
  return true;
end $$;

create or replace function fd_del(p_room text, p_id text, p_pid text)
returns void language sql security definer set search_path = public as $$
  update fd_catches set deleted=true where room=p_room and id=p_id and pid=p_pid;
$$;

-- owner closes the room: every catch is deleted, the code stays as a tombstone
create or replace function fd_wipe(p_room text, p_pid text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from fd_rooms where code=p_room and owner=p_pid) then return false; end if;
  delete from fd_catches where room=p_room;
  delete from fd_players where room=p_room;
  update fd_rooms set closed=true where code=p_room;
  return true;
end $$;

grant execute on function fd_state(text), fd_join(text,text,text,boolean,text,text), fd_player(text,text,text,text),
  fd_put(text,jsonb), fd_del(text,text,text), fd_wipe(text,text) to anon;
