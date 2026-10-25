-- Run after schema.sql. This assigns the existing first account as owner and
-- defaults any future Auth account to a waiter with no branch access.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  role text not null default 'waiter' check (role in ('owner', 'kitchen_manager', 'branch_manager', 'waiter')),
  branch_id uuid,
  created_at timestamptz not null default now()
);

-- The first account was just created for setup. This bootstrap promotes the
-- existing account(s); run this before inviting any staff users.
insert into public.profiles (id, full_name, role)
select id, coalesce(raw_user_meta_data->>'full_name', ''), 'owner'
from auth.users
on conflict (id) do update set role = 'owner';

create or replace function public.is_kitchen_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'owner');
$$;

create or replace function public.has_kitchen_access()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('owner', 'kitchen_manager'));
$$;

alter table public.profiles enable row level security;
drop policy if exists "profile owner reads own profile" on public.profiles;
drop policy if exists "owner manages profiles" on public.profiles;
create policy "profile owner reads own profile" on public.profiles for select to authenticated using (id = auth.uid() or public.is_kitchen_owner());
create policy "owner manages profiles" on public.profiles for all to authenticated using (public.is_kitchen_owner()) with check (public.is_kitchen_owner());
grant select, insert, update, delete on public.profiles to authenticated;

drop policy if exists "signed in kitchen staff manage ingredients" on public.ingredients;
create policy "kitchen roles manage ingredients" on public.ingredients for all to authenticated using (public.has_kitchen_access()) with check (public.has_kitchen_access());
drop policy if exists "signed in kitchen staff manage recipes" on public.recipes;
create policy "kitchen roles manage recipes" on public.recipes for all to authenticated using (public.has_kitchen_access()) with check (public.has_kitchen_access());
drop policy if exists "signed in kitchen staff manage recipe ingredients" on public.recipe_ingredients;
create policy "kitchen roles manage recipe ingredients" on public.recipe_ingredients for all to authenticated using (public.has_kitchen_access()) with check (public.has_kitchen_access());
drop policy if exists "signed in kitchen staff manage dispatches" on public.dispatches;
create policy "kitchen roles manage dispatches" on public.dispatches for all to authenticated using (public.has_kitchen_access()) with check (public.has_kitchen_access());
drop policy if exists "signed in kitchen staff manage dispatch ingredients" on public.dispatch_ingredients;
create policy "kitchen roles manage dispatch ingredients" on public.dispatch_ingredients for all to authenticated using (public.has_kitchen_access()) with check (public.has_kitchen_access());

create or replace function public.assign_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''), 'waiter')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
  after insert on auth.users
  for each row execute procedure public.assign_new_user_profile();

create or replace function public.record_kitchen_dispatch(
  p_recipe_id uuid,
  p_branch_name text,
  p_batch_qty numeric,
  p_dispatch_date date default current_date
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.recipes%rowtype;
  d_id uuid;
  d_code text;
  multiplier numeric;
  portion_count integer;
  total numeric(14,2) := 0;
  line record;
  current_stock numeric;
  used_qty numeric;
  line_total numeric(14,2);
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception 'Kitchen access is required to record a dispatch.'; end if;
  if p_batch_qty is null or p_batch_qty <= 0 then raise exception 'Dispatch quantity must be greater than zero.'; end if;
  if coalesce(trim(p_branch_name), '') = '' then raise exception 'Choose a destination branch.'; end if;

  select * into r from public.recipes where id = p_recipe_id;
  if not found then raise exception 'Recipe not found.'; end if;
  multiplier := p_batch_qty / r.batch_qty;
  portion_count := round(r.portions * multiplier)::integer;
  d_code := 'D-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  for line in
    select ri.ingredient_id, ri.quantity, i.name, i.unit, i.unit_price
    from public.recipe_ingredients ri join public.ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = p_recipe_id order by ri.ingredient_id for update of i
  loop
    used_qty := line.quantity * multiplier;
    select stock_quantity into current_stock from public.ingredients where id = line.ingredient_id;
    if current_stock < used_qty then raise exception 'Not enough stock for %: need % %, have % %.', line.name, round(used_qty, 3), line.unit, round(current_stock, 3), line.unit; end if;
    total := total + round((used_qty * line.unit_price)::numeric, 2);
  end loop;

  insert into public.dispatches(dispatch_code, recipe_id, recipe_name, branch_name, batch_qty, batch_unit, dispatch_date, portions, total_cost)
  values (d_code, r.id, r.name, trim(p_branch_name), p_batch_qty, r.batch_unit, coalesce(p_dispatch_date, current_date), portion_count, total)
  returning id into d_id;

  for line in
    select ri.ingredient_id, ri.quantity, i.name, i.unit, i.unit_price
    from public.recipe_ingredients ri join public.ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = p_recipe_id order by ri.ingredient_id for update of i
  loop
    used_qty := line.quantity * multiplier;
    line_total := round((used_qty * line.unit_price)::numeric, 2);
    update public.ingredients set stock_quantity = stock_quantity - used_qty where id = line.ingredient_id;
    insert into public.dispatch_ingredients(dispatch_id, ingredient_id, ingredient_name, unit, quantity_used, unit_price, line_cost)
    values (d_id, line.ingredient_id, line.name, line.unit, used_qty, line.unit_price, line_total);
  end loop;
  return d_id;
end;
$$;

revoke all on function public.record_kitchen_dispatch(uuid, text, numeric, date) from public, anon;
grant execute on function public.record_kitchen_dispatch(uuid, text, numeric, date) to authenticated;
revoke all on function public.is_kitchen_owner() from public, anon;
revoke all on function public.has_kitchen_access() from public, anon;
grant execute on function public.is_kitchen_owner(), public.has_kitchen_access() to authenticated;
