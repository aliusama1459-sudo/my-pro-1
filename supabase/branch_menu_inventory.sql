-- Run after branch_setup.sql. Creates independent, branch-specific menus and optional branch stock tracking.

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('owner', 'kitchen_manager', 'branch_manager', 'waiter', 'cashier'));
do $$ begin
  alter table public.profiles add constraint profiles_branch_id_fkey
    foreign key (branch_id) references public.branches(id) on delete set null;
exception when duplicate_object then null; end $$;

create or replace function public.has_branch_access(p_branch_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and (p.role in ('owner', 'kitchen_manager') or p.branch_id = p_branch_id)
  );
$$;

create or replace function public.can_manage_branch(p_branch_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select public.has_kitchen_access() or exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'branch_manager' and p.branch_id = p_branch_id
  );
$$;

create table if not exists public.branch_menu_sections (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  name text not null,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (branch_id, name)
);
create index if not exists branch_menu_sections_order_idx
  on public.branch_menu_sections(branch_id, sort_order, name);

create table if not exists public.branch_menu_items (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  section_id uuid not null references public.branch_menu_sections(id) on delete restrict,
  name text not null,
  unit_label text not null default 'piece',
  sale_price numeric(12,2) not null default 0 check (sale_price >= 0),
  tracks_inventory boolean not null default false,
  is_available boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (branch_id, name)
);

-- Upgrade a table created by the earlier draft of this migration. Preserve
-- existing menu names by turning their old category into a menu section.
alter table public.branch_menu_items add column if not exists section_id uuid;
alter table public.branch_menu_items add column if not exists unit_label text not null default 'piece';
alter table public.branch_menu_items add column if not exists tracks_inventory boolean not null default false;
alter table public.branch_menu_items add column if not exists is_available boolean not null default true;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='branch_menu_items' and column_name='category'
  ) then
    execute $sql$
      insert into public.branch_menu_sections(branch_id,name)
      select distinct branch_id,coalesce(nullif(trim(category),''),'General')
      from public.branch_menu_items on conflict(branch_id,name) do nothing
    $sql$;
    execute $sql$
      update public.branch_menu_items i set section_id=s.id
      from public.branch_menu_sections s
      where s.branch_id=i.branch_id
        and s.name=coalesce(nullif(trim(i.category),''),'General')
        and i.section_id is null
    $sql$;
  else
    insert into public.branch_menu_sections(branch_id,name)
    select distinct branch_id,'General' from public.branch_menu_items
    on conflict(branch_id,name) do nothing;
    update public.branch_menu_items i set section_id=s.id
    from public.branch_menu_sections s
    where s.branch_id=i.branch_id and s.name='General' and i.section_id is null;
  end if;
end;
$$;
alter table public.branch_menu_items alter column section_id set not null;
do $$ begin
  alter table public.branch_menu_items add constraint branch_menu_items_section_id_fkey
    foreign key (section_id) references public.branch_menu_sections(id) on delete restrict;
exception when duplicate_object then null; end $$;

-- Remove recipe-specific fields and the old kitchen-dispatch stock hook.
drop trigger if exists add_branch_stock_from_kitchen_dispatch on public.dispatches;
drop function if exists public.record_branch_dispatch_stock();
drop function if exists public.save_branch_menu_item(uuid,uuid,text,text,text,uuid,text,numeric,boolean);
drop index if exists public.branch_menu_active_idx;
drop index if exists public.branch_menu_recipe_unique;
alter table public.branch_menu_items drop constraint if exists branch_menu_recipe_link_check;
alter table public.branch_menu_items drop column if exists item_type;
alter table public.branch_menu_items drop column if exists recipe_id;
alter table public.branch_menu_items drop column if exists category;

create index if not exists branch_menu_active_idx
  on public.branch_menu_items(branch_id, section_id, is_available, name);

create table if not exists public.branch_inventory (
  menu_item_id uuid primary key references public.branch_menu_items(id) on delete cascade,
  quantity numeric(14,3) not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default now()
);
update public.branch_menu_items i set tracks_inventory=true
where exists(select 1 from public.branch_inventory bi where bi.menu_item_id=i.id)
  and not i.tracks_inventory;

create table if not exists public.branch_inventory_movements (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  menu_item_id uuid not null references public.branch_menu_items(id) on delete restrict,
  movement_type text not null check (movement_type in ('restock', 'adjustment', 'sale')),
  quantity_change numeric(14,3) not null,
  quantity_after numeric(14,3) not null check (quantity_after >= 0),
  movement_date date not null default current_date,
  note text not null default '',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists branch_inventory_movement_report_idx
  on public.branch_inventory_movements(branch_id, movement_date desc, created_at desc);

alter table public.branch_menu_sections enable row level security;
alter table public.branch_menu_items enable row level security;
alter table public.branch_inventory enable row level security;
alter table public.branch_inventory_movements enable row level security;

drop policy if exists "branch sections read" on public.branch_menu_sections;
create policy "branch sections read" on public.branch_menu_sections for select to authenticated
  using (public.has_branch_access(branch_id));
drop policy if exists "branch sections managers" on public.branch_menu_sections;
create policy "branch sections managers" on public.branch_menu_sections for all to authenticated
  using (public.can_manage_branch(branch_id)) with check (public.can_manage_branch(branch_id));

drop policy if exists "branch menu read" on public.branch_menu_items;
create policy "branch menu read" on public.branch_menu_items for select to authenticated
  using (public.has_branch_access(branch_id));
drop policy if exists "branch menu managers" on public.branch_menu_items;
create policy "branch menu managers" on public.branch_menu_items for all to authenticated
  using (public.can_manage_branch(branch_id)) with check (public.can_manage_branch(branch_id));

drop policy if exists "branch inventory read" on public.branch_inventory;
create policy "branch inventory read" on public.branch_inventory for select to authenticated
  using (exists (select 1 from public.branch_menu_items m where m.id=menu_item_id and public.has_branch_access(m.branch_id)));
drop policy if exists "branch inventory managers" on public.branch_inventory;
create policy "branch inventory managers" on public.branch_inventory for all to authenticated
  using (exists (select 1 from public.branch_menu_items m where m.id=menu_item_id and public.can_manage_branch(m.branch_id)))
  with check (exists (select 1 from public.branch_menu_items m where m.id=menu_item_id and public.can_manage_branch(m.branch_id)));

drop policy if exists "branch inventory movements read" on public.branch_inventory_movements;
create policy "branch inventory movements read" on public.branch_inventory_movements for select to authenticated
  using (public.has_branch_access(branch_id));
drop policy if exists "branch inventory movements managers" on public.branch_inventory_movements;
create policy "branch inventory movements managers" on public.branch_inventory_movements for all to authenticated
  using (public.can_manage_branch(branch_id)) with check (public.can_manage_branch(branch_id));

drop policy if exists "branch roles read own branch" on public.branches;
create policy "branch roles read own branch" on public.branches for select to authenticated
  using (public.has_branch_access(id));
drop policy if exists "kitchen roles manage branches" on public.branches;
create policy "kitchen roles manage branches" on public.branches for all to authenticated
  using (public.has_kitchen_access()) with check (public.has_kitchen_access());

grant select, insert, update, delete on public.branch_menu_sections, public.branch_menu_items,
  public.branch_inventory, public.branch_inventory_movements to authenticated;
revoke all on function public.has_branch_access(uuid) from public, anon;
grant execute on function public.has_branch_access(uuid) to authenticated;
revoke all on function public.can_manage_branch(uuid) from public, anon;
grant execute on function public.can_manage_branch(uuid) to authenticated;

create or replace function public.save_branch_menu_section(
  p_branch_id uuid, p_section_id uuid, p_name text
) returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid := p_section_id; v_name text := trim(coalesce(p_name,''));
begin
  if auth.uid() is null or not public.can_manage_branch(p_branch_id) then
    raise exception using message = 'A branch manager or owner is required to manage menu sections.';
  end if;
  if v_name = '' then raise exception using message = 'Enter a section name.'; end if;
  if v_id is null then
    insert into public.branch_menu_sections(branch_id,name)
      values (p_branch_id,v_name) returning id into v_id;
  else
    update public.branch_menu_sections set name=v_name
      where id=v_id and branch_id=p_branch_id;
    if not found then raise exception using message = 'Menu section not found.'; end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.delete_branch_menu_section(p_section_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_branch_id uuid;
begin
  select branch_id into v_branch_id from public.branch_menu_sections where id=p_section_id;
  if v_branch_id is null then raise exception using message = 'Menu section not found.'; end if;
  if auth.uid() is null or not public.can_manage_branch(v_branch_id) then
    raise exception using message = 'A branch manager or owner is required to manage menu sections.';
  end if;
  if exists(select 1 from public.branch_menu_items where section_id=p_section_id) then
    raise exception using message = 'Move or remove the section items before deleting this section.';
  end if;
  delete from public.branch_menu_sections where id=p_section_id;
end;
$$;

create or replace function public.save_branch_menu_item(
  p_branch_id uuid,
  p_item_id uuid,
  p_section_id uuid,
  p_name text,
  p_unit_label text,
  p_sale_price numeric,
  p_tracks_inventory boolean,
  p_is_available boolean default true
) returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid := p_item_id; v_name text := trim(coalesce(p_name,'')); v_old_tracks boolean;
begin
  if auth.uid() is null or not public.can_manage_branch(p_branch_id) then
    raise exception using message = 'A branch manager or owner is required to edit the menu.';
  end if;
  if v_name = '' then raise exception using message = 'Enter a menu item name.'; end if;
  if p_sale_price is null or p_sale_price < 0 then raise exception using message = 'Enter a valid price.'; end if;
  if not exists(select 1 from public.branch_menu_sections where id=p_section_id and branch_id=p_branch_id and is_active) then
    raise exception using message = 'Choose a section in this branch menu.';
  end if;
  if v_id is null then
    insert into public.branch_menu_items(branch_id,section_id,name,unit_label,sale_price,tracks_inventory,is_available)
      values (p_branch_id,p_section_id,v_name,coalesce(nullif(trim(p_unit_label),''),'piece'),p_sale_price,coalesce(p_tracks_inventory,false),coalesce(p_is_available,true))
      returning id into v_id;
    if coalesce(p_tracks_inventory,false) then
      insert into public.branch_inventory(menu_item_id,quantity) values (v_id,0);
    end if;
  else
    select tracks_inventory into v_old_tracks from public.branch_menu_items where id=v_id and branch_id=p_branch_id for update;
    if not found then raise exception using message = 'Menu item not found.'; end if;
    if v_old_tracks and not coalesce(p_tracks_inventory,false)
       and exists(select 1 from public.branch_inventory_movements where menu_item_id=v_id) then
      raise exception using message = 'This item has inventory history. Keep inventory tracking enabled.';
    end if;
    update public.branch_menu_items set section_id=p_section_id,name=v_name,
      unit_label=coalesce(nullif(trim(p_unit_label),''),'piece'),sale_price=p_sale_price,
      tracks_inventory=coalesce(p_tracks_inventory,false),is_available=coalesce(p_is_available,true),updated_at=now()
      where id=v_id and branch_id=p_branch_id;
    if coalesce(p_tracks_inventory,false) then
      insert into public.branch_inventory(menu_item_id,quantity) values(v_id,0) on conflict(menu_item_id) do nothing;
    else
      delete from public.branch_inventory where menu_item_id=v_id;
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.delete_branch_menu_item(p_item_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_branch_id uuid;
begin
  select branch_id into v_branch_id from public.branch_menu_items where id=p_item_id;
  if v_branch_id is null then raise exception using message = 'Menu item not found.'; end if;
  if auth.uid() is null or not public.can_manage_branch(v_branch_id) then
    raise exception using message = 'A branch manager or owner is required to remove menu items.';
  end if;
  if exists(select 1 from public.branch_inventory_movements where menu_item_id=p_item_id) then
    raise exception using message = 'This item has inventory history. Turn off availability instead of deleting it.';
  end if;
  delete from public.branch_menu_items where id=p_item_id;
end;
$$;

create or replace function public.adjust_branch_inventory(
  p_menu_item_id uuid, p_action text, p_quantity numeric, p_note text, p_movement_date date default current_date
) returns numeric language plpgsql security definer set search_path = public
as $$
declare v_branch_id uuid; v_current numeric(14,3); v_next numeric(14,3); v_change numeric(14,3);
begin
  select branch_id into v_branch_id from public.branch_menu_items
    where id=p_menu_item_id and tracks_inventory for update;
  if v_branch_id is null then raise exception using message = 'This menu item is not connected to branch inventory.'; end if;
  if auth.uid() is null or not public.can_manage_branch(v_branch_id) then
    raise exception using message = 'A branch manager or owner is required to adjust stock.';
  end if;
  if p_action not in ('add','remove','set') or p_quantity is null or p_quantity < 0 then
    raise exception using message = 'Enter a valid inventory quantity.';
  end if;
  insert into public.branch_inventory(menu_item_id,quantity) values(p_menu_item_id,0) on conflict(menu_item_id) do nothing;
  select quantity into v_current from public.branch_inventory where menu_item_id=p_menu_item_id for update;
  v_next := case when p_action='add' then v_current+p_quantity when p_action='remove' then v_current-p_quantity else p_quantity end;
  if v_next < 0 then raise exception using message = 'There is not enough stock for that change.'; end if;
  v_change := v_next-v_current;
  update public.branch_inventory set quantity=v_next,updated_at=now() where menu_item_id=p_menu_item_id;
  if v_change <> 0 then
    insert into public.branch_inventory_movements(branch_id,menu_item_id,movement_type,quantity_change,quantity_after,note,movement_date,created_by)
      values(v_branch_id,p_menu_item_id,case when v_change>0 then 'restock' else 'adjustment' end,v_change,v_next,coalesce(p_note,''),coalesce(p_movement_date,current_date),auth.uid());
  end if;
  return v_next;
end;
$$;

revoke all on function public.save_branch_menu_section(uuid,uuid,text) from public, anon;
revoke all on function public.delete_branch_menu_section(uuid) from public, anon;
revoke all on function public.save_branch_menu_item(uuid,uuid,uuid,text,text,numeric,boolean,boolean) from public, anon;
revoke all on function public.delete_branch_menu_item(uuid) from public, anon;
revoke all on function public.adjust_branch_inventory(uuid,text,numeric,text,date) from public, anon;
grant execute on function public.save_branch_menu_section(uuid,uuid,text) to authenticated;
grant execute on function public.delete_branch_menu_section(uuid) to authenticated;
grant execute on function public.save_branch_menu_item(uuid,uuid,uuid,text,text,numeric,boolean,boolean) to authenticated;
grant execute on function public.delete_branch_menu_item(uuid) to authenticated;
grant execute on function public.adjust_branch_inventory(uuid,text,numeric,text,date) to authenticated;

