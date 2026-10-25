-- Run after the kitchen and inventory migrations to enable saved catering quotes.
create table if not exists public.catering_quotes (
  id uuid primary key default gen_random_uuid(),
  quote_number text not null unique,
  customer_name text not null,
  customer_phone text not null default '',
  event_name text not null default '',
  event_date date,
  venue text not null default '',
  notes text not null default '',
  total_cost numeric(14,2) not null default 0,
  profit_amount numeric(14,2) not null default 0,
  quoted_total numeric(14,2) not null default 0,
  status text not null default 'Draft',
  created_at timestamptz not null default now()
);

create table if not exists public.catering_quote_items (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.catering_quotes(id) on delete cascade,
  recipe_id uuid references public.recipes(id) on delete set null,
  recipe_name text not null,
  batch_qty numeric(12,3) not null,
  batch_unit text not null,
  portions integer not null,
  portion_size numeric(12,3) not null,
  portion_unit text not null,
  profit_percent numeric(7,2) not null,
  cost_amount numeric(14,2) not null,
  profit_amount numeric(14,2) not null,
  quoted_price numeric(14,2) not null
);

create index if not exists catering_quotes_created_at_idx on public.catering_quotes(created_at desc);
create index if not exists catering_quotes_event_date_idx on public.catering_quotes(event_date);
create index if not exists catering_quote_items_quote_idx on public.catering_quote_items(quote_id);
alter table public.catering_quotes enable row level security;
alter table public.catering_quote_items enable row level security;

drop policy if exists "kitchen roles read catering quotes" on public.catering_quotes;
create policy "kitchen roles read catering quotes" on public.catering_quotes for select to authenticated using (public.has_kitchen_access());
drop policy if exists "kitchen roles read catering quote items" on public.catering_quote_items;
create policy "kitchen roles read catering quote items" on public.catering_quote_items for select to authenticated using (public.has_kitchen_access());
grant select on public.catering_quotes, public.catering_quote_items to authenticated;

create or replace function public.create_catering_quote(
  p_customer_name text,
  p_customer_phone text,
  p_event_name text,
  p_event_date date,
  p_venue text,
  p_notes text,
  p_items jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  quote_id uuid;
  quote_code text;
  line jsonb;
  rec public.recipes%rowtype;
  line_qty numeric(12,3);
  profit_pct numeric(7,2);
  batch_cost numeric(14,2);
  item_cost numeric(14,2);
  item_profit numeric(14,2);
  item_price numeric(14,2);
  item_portions integer;
  subtotal_cost numeric(14,2) := 0;
  subtotal_profit numeric(14,2) := 0;
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception 'Kitchen access is required to create catering quotes.'; end if;
  if coalesce(trim(p_customer_name), '') = '' then raise exception 'Enter the customer name.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Add at least one catering menu item.'; end if;

  quote_code := 'KN-Q-' || to_char(timezone('Asia/Karachi', now()), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 5));
  insert into public.catering_quotes(quote_number, customer_name, customer_phone, event_name, event_date, venue, notes)
  values (quote_code, trim(p_customer_name), coalesce(trim(p_customer_phone), ''), coalesce(trim(p_event_name), ''), p_event_date, coalesce(trim(p_venue), ''), coalesce(trim(p_notes), ''))
  returning id into quote_id;

  for line in select value from jsonb_array_elements(p_items)
  loop
    select * into rec from public.recipes where id = (line->>'recipe_id')::uuid;
    if not found then raise exception 'A selected recipe no longer exists.'; end if;
    line_qty := (line->>'batch_qty')::numeric;
    profit_pct := (line->>'profit_percent')::numeric;
    if line_qty is null or line_qty <= 0 then raise exception 'Each catering quantity must be greater than zero.'; end if;
    if profit_pct is null or profit_pct < 0 then raise exception 'Profit markup cannot be negative.'; end if;
    select coalesce(sum(ri.quantity * i.unit_price), 0) into batch_cost
    from public.recipe_ingredients ri join public.ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = rec.id;
    item_cost := round(batch_cost * line_qty / rec.batch_qty, 2);
    item_profit := round(item_cost * profit_pct / 100, 2);
    item_price := item_cost + item_profit;
    item_portions := round(rec.portions * line_qty / rec.batch_qty)::integer;
    subtotal_cost := subtotal_cost + item_cost;
    subtotal_profit := subtotal_profit + item_profit;
    insert into public.catering_quote_items(quote_id, recipe_id, recipe_name, batch_qty, batch_unit, portions, portion_size, portion_unit, profit_percent, cost_amount, profit_amount, quoted_price)
    values (quote_id, rec.id, rec.name, line_qty, rec.batch_unit, item_portions, rec.portion_size, rec.portion_unit, profit_pct, item_cost, item_profit, item_price);
  end loop;

  update public.catering_quotes set total_cost = subtotal_cost, profit_amount = subtotal_profit, quoted_total = subtotal_cost + subtotal_profit where id = quote_id;
  return quote_id;
end;
$$;

revoke all on function public.create_catering_quote(text, text, text, date, text, text, jsonb) from public, anon;
grant execute on function public.create_catering_quote(text, text, text, date, text, text, jsonb) to authenticated;
