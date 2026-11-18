-- Example first migration: one table + one seed row so there is something to
-- query. Rename/replace with your real schema (timestamped filename, UTC).

create table public.items (
  id bigint generated always as identity primary key,
  name text not null unique
);

insert into public.items (name) values ('hello from local supabase');
