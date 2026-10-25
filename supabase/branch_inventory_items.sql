-- Run after branch_menu_inventory.sql. Adds standalone branch inventory items
-- with an optional link to one item in that branch's menu.

create table if not exists public.branch_inventory_items (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  menu_item_id uuid references public.branch_menu_items(id) on delete set null,
  name text not null,
  category text not null default 'Other',
  unit text not null default 'piece',
  unit_price numeric(12,2) not null default 0 check (unit_price >= 0),
  stock_quantity numeric(14,3) not null default 0 check (stock_quantity >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (branch_id, name),
  unique (menu_item_id)
);
create index if not exists branch_inventory_items_branch_idx
  on public.branch_inventory_items(branch_id, is_active, name);

create table if not exists public.branch_stock_movements (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  inventory_item_id uuid not null references public.branch_inventory_items(id) on delete restrict,
  movement_type text not null check (movement_type in ('opening','restock','used','wasted','missing','sale','adjustment')),
  quantity_change numeric(14,3) not null,
  quantity_after numeric(14,3) not null check (quantity_after >= 0),
  movement_date date not null default current_date,
  note text not null default '',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists branch_stock_movements_date_idx
  on public.branch_stock_movements(branch_id, movement_date desc, created_at desc);

alter table public.branch_inventory_items enable row level security;
alter table public.branch_stock_movements enable row level security;
drop policy if exists "branch inventory items read" on public.branch_inventory_items;
create policy "branch inventory items read" on public.branch_inventory_items for select to authenticated
  using (public.has_branch_access(branch_id));
drop policy if exists "branch inventory items managers" on public.branch_inventory_items;
create policy "branch inventory items managers" on public.branch_inventory_items for all to authenticated
  using (public.can_manage_branch(branch_id)) with check (public.can_manage_branch(branch_id));
drop policy if exists "branch stock movements read" on public.branch_stock_movements;
create policy "branch stock movements read" on public.branch_stock_movements for select to authenticated
  using (public.has_branch_access(branch_id));
drop policy if exists "branch stock movements managers" on public.branch_stock_movements;
create policy "branch stock movements managers" on public.branch_stock_movements for all to authenticated
  using (public.can_manage_branch(branch_id)) with check (public.can_manage_branch(branch_id));
grant select, insert, update, delete on public.branch_inventory_items, public.branch_stock_movements to authenticated;

-- Preserve stock already entered against menu items in the initial inventory draft.
insert into public.branch_inventory_items(branch_id,menu_item_id,name,category,unit,unit_price,stock_quantity)
select m.branch_id,m.id,m.name,'Other',m.unit_label,0,bi.quantity
from public.branch_menu_items m
join public.branch_inventory bi on bi.menu_item_id=m.id
where m.tracks_inventory
on conflict (menu_item_id) do nothing;
insert into public.branch_stock_movements(branch_id,inventory_item_id,movement_type,quantity_change,quantity_after,note)
select i.branch_id,i.id,'opening',i.stock_quantity,i.stock_quantity,'Imported from the earlier branch menu stock setup'
from public.branch_inventory_items i
where i.stock_quantity>0
  and not exists(select 1 from public.branch_stock_movements x where x.inventory_item_id=i.id)
on conflict do nothing;
update public.branch_menu_items set tracks_inventory=false where tracks_inventory;

-- New menu items no longer create inventory automatically. The inventory item
-- is created in Branch Inventory and linked there when desired.
drop function if exists public.save_branch_menu_item(uuid,uuid,uuid,text,text,numeric,boolean,boolean);
create function public.save_branch_menu_item(
  p_branch_id uuid,
  p_item_id uuid,
  p_section_id uuid,
  p_name text,
  p_unit_label text,
  p_sale_price numeric,
  p_is_available boolean default true
) returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid := p_item_id; v_name text := trim(coalesce(p_name,''));
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
      values(p_branch_id,p_section_id,v_name,coalesce(nullif(trim(p_unit_label),''),'piece'),p_sale_price,false,coalesce(p_is_available,true))
      returning id into v_id;
  else
    update public.branch_menu_items set section_id=p_section_id,name=v_name,
      unit_label=coalesce(nullif(trim(p_unit_label),''),'piece'),sale_price=p_sale_price,
      is_available=coalesce(p_is_available,true),updated_at=now()
      where id=v_id and branch_id=p_branch_id;
    if not found then raise exception using message = 'Menu item not found.'; end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.save_branch_inventory_item(
  p_branch_id uuid,
  p_item_id uuid,
  p_name text,
  p_category text,
  p_unit text,
  p_unit_price numeric,
  p_opening_quantity numeric,
  p_menu_item_id uuid default null
) returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid := p_item_id; v_name text := trim(coalesce(p_name,'')); v_qty numeric(14,3);
begin
  if auth.uid() is null or not public.can_manage_branch(p_branch_id) then
    raise exception using message = 'A branch manager or owner is required to manage inventory.';
  end if;
  if v_name = '' or coalesce(trim(p_unit),'') = '' then raise exception using message = 'Enter an item name and unit.'; end if;
  if p_unit_price is null or p_unit_price < 0 then raise exception using message = 'Enter a valid unit price.'; end if;
  if p_opening_quantity is null or p_opening_quantity < 0 then raise exception using message = 'Enter a valid opening quantity.'; end if;
  if p_menu_item_id is not null and not exists(
    select 1 from public.branch_menu_items where id=p_menu_item_id and branch_id=p_branch_id
  ) then raise exception using message = 'Choose a menu item from this branch.'; end if;

  if v_id is null then
    insert into public.branch_inventory_items(branch_id,menu_item_id,name,category,unit,unit_price,stock_quantity)
      values(p_branch_id,p_menu_item_id,v_name,coalesce(nullif(trim(p_category),''),'Other'),
             trim(p_unit),p_unit_price,p_opening_quantity) returning id into v_id;
    if p_opening_quantity>0 then
      insert into public.branch_stock_movements(branch_id,inventory_item_id,movement_type,quantity_change,quantity_after,note,created_by)
        values(p_branch_id,v_id,'opening',p_opening_quantity,p_opening_quantity,'Opening stock',auth.uid());
    end if;
  else
    select stock_quantity into v_qty from public.branch_inventory_items
      where id=v_id and branch_id=p_branch_id for update;
    if not found then raise exception using message = 'Inventory item not found.'; end if;
    update public.branch_inventory_items set menu_item_id=p_menu_item_id,name=v_name,
      category=coalesce(nullif(trim(p_category),''),'Other'),unit=trim(p_unit),
      unit_price=p_unit_price,is_active=true,updated_at=now()
      where id=v_id and branch_id=p_branch_id;
  end if;
  return v_id;
end;
$$;

create or replace function public.adjust_branch_stock(
  p_item_id uuid,
  p_action text,
  p_quantity numeric,
  p_note text default '',
  p_movement_date date default current_date
) returns numeric language plpgsql security definer set search_path = public
as $$
declare v_branch_id uuid; v_current numeric(14,3); v_next numeric(14,3); v_change numeric(14,3);
begin
  select branch_id,stock_quantity into v_branch_id,v_current
    from public.branch_inventory_items where id=p_item_id and is_active for update;
  if v_branch_id is null then raise exception using message = 'Inventory item not found or inactive.'; end if;
  if auth.uid() is null or not public.can_manage_branch(v_branch_id) then
    raise exception using message = 'A branch manager or owner is required to adjust stock.';
  end if;
  if p_action not in ('restock','used','wasted','missing') or p_quantity is null or p_quantity<=0 then
    raise exception using message = 'Choose a reason and enter a quantity greater than zero.';
  end if;
  v_next := case when p_action='restock' then v_current+p_quantity else v_current-p_quantity end;
  if v_next<0 then raise exception using message = 'There is not enough stock for that adjustment.'; end if;
  v_change := v_next-v_current;
  update public.branch_inventory_items set stock_quantity=v_next,updated_at=now() where id=p_item_id;
  insert into public.branch_stock_movements(branch_id,inventory_item_id,movement_type,quantity_change,quantity_after,movement_date,note,created_by)
    values(v_branch_id,p_item_id,p_action,v_change,v_next,coalesce(p_movement_date,current_date),coalesce(p_note,''),auth.uid());
  return v_next;
end;
$$;

create or replace function public.delete_branch_inventory_item(p_item_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_branch_id uuid;
begin
  select branch_id into v_branch_id from public.branch_inventory_items where id=p_item_id;
  if v_branch_id is null then raise exception using message = 'Inventory item not found.'; end if;
  if auth.uid() is null or not public.can_manage_branch(v_branch_id) then
    raise exception using message = 'A branch manager or owner is required to manage inventory.';
  end if;
  if exists(select 1 from public.branch_stock_movements where inventory_item_id=p_item_id) then
    raise exception using message = 'This item has stock history. Keep it and adjust its stock to zero instead.';
  end if;
  delete from public.branch_inventory_items where id=p_item_id;
end;
$$;

revoke all on function public.save_branch_menu_item(uuid,uuid,uuid,text,text,numeric,boolean) from public, anon;
revoke all on function public.save_branch_inventory_item(uuid,uuid,text,text,text,numeric,numeric,uuid) from public, anon;
revoke all on function public.adjust_branch_stock(uuid,text,numeric,text,date) from public, anon;
revoke all on function public.delete_branch_inventory_item(uuid) from public, anon;
grant execute on function public.save_branch_menu_item(uuid,uuid,uuid,text,text,numeric,boolean) to authenticated;
grant execute on function public.save_branch_inventory_item(uuid,uuid,text,text,text,numeric,numeric,uuid) to authenticated;
grant execute on function public.adjust_branch_stock(uuid,text,numeric,text,date) to authenticated;
grant execute on function public.delete_branch_inventory_item(uuid) to authenticated;

