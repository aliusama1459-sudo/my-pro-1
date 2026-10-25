-- Run after catering_quotes.sql. Enables one-time full dispatch of a saved quote.
alter table public.dispatches
  add column if not exists catering_quote_id uuid references public.catering_quotes(id) on delete set null;
alter table public.dispatches
  add column if not exists dispatch_group_code text not null default '';
create index if not exists dispatches_catering_quote_idx on public.dispatches(catering_quote_id);
create index if not exists dispatches_group_code_idx on public.dispatches(dispatch_group_code);

create or replace function public.dispatch_catering_quote(
  p_quote_id uuid,
  p_dispatch_date date default current_date
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  q public.catering_quotes%rowtype;
  qitem record;
  recipe public.recipes%rowtype;
  ingredient_line record;
  required_qty numeric(14,3);
  current_qty numeric(14,3);
  multiplier numeric;
  used_qty numeric(14,3);
  line_total numeric(14,2);
  actual_cost numeric(14,2);
  group_code text;
  destination text;
  dispatch_line_code text;
  counter integer := 0;
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception 'Kitchen access is required to dispatch a catering quote.'; end if;
  select * into q from public.catering_quotes where id = p_quote_id for update;
  if not found then raise exception 'Catering quotation not found.'; end if;
  if q.status = 'Dispatched' then raise exception 'This catering quotation has already been dispatched.'; end if;
  if not exists (select 1 from public.catering_quote_items where quote_id = q.id) then raise exception 'This quotation has no menu items.'; end if;

  -- Lock every needed stock item in a stable order and check the combined requirements first.
  for ingredient_line in
    select distinct ri.ingredient_id
    from public.catering_quote_items qi
    join public.recipes r on r.id = qi.recipe_id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
    where qi.quote_id = q.id
    order by ri.ingredient_id
  loop
    select stock_quantity into current_qty from public.ingredients where id = ingredient_line.ingredient_id for update;
    select coalesce(sum(ri.quantity * qi.batch_qty / r.batch_qty), 0) into required_qty
    from public.catering_quote_items qi
    join public.recipes r on r.id = qi.recipe_id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
    where qi.quote_id = q.id and ri.ingredient_id = ingredient_line.ingredient_id;
    if current_qty < required_qty then
      select name, unit into ingredient_line from public.ingredients where id = ingredient_line.ingredient_id;
      raise exception 'Not enough stock for %: need % %, have % %.', ingredient_line.name, round(required_qty, 3), ingredient_line.unit, round(current_qty, 3), ingredient_line.unit;
    end if;
  end loop;

  group_code := 'CD-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  destination := 'Catering: ' || q.customer_name || case when q.event_name <> '' then ' · ' || q.event_name else '' end;
  if q.venue <> '' then destination := destination || ' · ' || q.venue; end if;
  perform set_config('app.inventory_movement_type', 'dispatch', true);
  perform set_config('app.inventory_movement_note', 'Catering dispatch ' || group_code, true);

  for qitem in select * from public.catering_quote_items where quote_id = q.id order by id
  loop
    select * into recipe from public.recipes where id = qitem.recipe_id;
    if not found then raise exception 'A recipe in this quotation no longer exists.'; end if;
    multiplier := qitem.batch_qty / recipe.batch_qty;
    counter := counter + 1;
    dispatch_line_code := group_code || '-' || lpad(counter::text, 2, '0');
    actual_cost := 0;
    insert into public.dispatches(dispatch_code, dispatch_group_code, catering_quote_id, recipe_id, recipe_name, branch_name, batch_qty, batch_unit, dispatch_date, portions, total_cost, status)
    values (dispatch_line_code, group_code, q.id, recipe.id, recipe.name, destination, qitem.batch_qty, recipe.batch_unit, coalesce(p_dispatch_date, current_date), round(recipe.portions * multiplier)::integer, 0, 'Dispatched');

    for ingredient_line in
      select ri.ingredient_id, ri.quantity, i.name, i.unit, i.unit_price
      from public.recipe_ingredients ri join public.ingredients i on i.id = ri.ingredient_id
      where ri.recipe_id = recipe.id order by ri.ingredient_id
    loop
      used_qty := ingredient_line.quantity * multiplier;
      line_total := round((used_qty * ingredient_line.unit_price)::numeric, 2);
      actual_cost := actual_cost + line_total;
      update public.ingredients set stock_quantity = stock_quantity - used_qty where id = ingredient_line.ingredient_id;
      insert into public.dispatch_ingredients(dispatch_id, ingredient_id, ingredient_name, unit, quantity_used, unit_price, line_cost)
      select d.id, ingredient_line.ingredient_id, ingredient_line.name, ingredient_line.unit, used_qty, ingredient_line.unit_price, line_total
      from public.dispatches d where d.dispatch_code = dispatch_line_code;
    end loop;
    update public.dispatches set total_cost = actual_cost where dispatch_code = dispatch_line_code;
  end loop;

  perform set_config('app.inventory_movement_type', '', true);
  perform set_config('app.inventory_movement_note', '', true);
  update public.catering_quotes set status = 'Dispatched' where id = q.id;
  return group_code;
end;
$$;

revoke all on function public.dispatch_catering_quote(uuid, date) from public, anon;
grant execute on function public.dispatch_catering_quote(uuid, date) to authenticated;
