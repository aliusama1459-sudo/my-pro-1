-- Run after inventory_item_types.sql to record why stock was changed.
alter table public.inventory_movements
  drop constraint if exists inventory_movements_movement_type_check;
alter table public.inventory_movements
  add constraint inventory_movements_movement_type_check
  check (movement_type in ('opening', 'restock', 'adjustment', 'dispatch', 'used', 'wasted', 'missing'));

create or replace function public.adjust_inventory_stock(
  p_ingredient_id uuid,
  p_movement_type text,
  p_quantity numeric,
  p_note text default ''
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  item public.ingredients%rowtype;
  delta numeric(14,3);
  next_quantity numeric(14,3);
  note_text text;
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception 'Kitchen access is required to adjust inventory.'; end if;
  if p_movement_type not in ('used', 'wasted', 'missing', 'restock') then raise exception 'Choose used, wasted, missing, or restocked.'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'Enter a quantity greater than zero.'; end if;
  select * into item from public.ingredients where id = p_ingredient_id for update;
  if not found then raise exception 'Inventory item not found.'; end if;
  delta := case when p_movement_type = 'restock' then p_quantity else -p_quantity end;
  next_quantity := item.stock_quantity + delta;
  if next_quantity < 0 then raise exception 'Not enough stock for %: current stock is % %.', item.name, item.stock_quantity, item.unit; end if;
  note_text := coalesce(nullif(trim(p_note), ''), case p_movement_type when 'used' then 'Used' when 'wasted' then 'Wasted' when 'missing' then 'Missing stock' else 'Stock added' end);
  perform set_config('app.inventory_movement_type', p_movement_type, true);
  perform set_config('app.inventory_movement_note', note_text, true);
  update public.ingredients set stock_quantity = next_quantity where id = p_ingredient_id;
  perform set_config('app.inventory_movement_type', '', true);
  perform set_config('app.inventory_movement_note', '', true);
  return next_quantity;
end;
$$;

revoke all on function public.adjust_inventory_stock(uuid, text, numeric, text) from public, anon;
grant execute on function public.adjust_inventory_stock(uuid, text, numeric, text) to authenticated;
