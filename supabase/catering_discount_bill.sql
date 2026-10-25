-- Run after catering_dispatch.sql to support discounts and a bill after dispatch.
alter table public.catering_quotes add column if not exists discount_type text not null default 'none';
alter table public.catering_quotes add column if not exists discount_value numeric(12,2) not null default 0;
alter table public.catering_quotes add column if not exists discount_amount numeric(14,2) not null default 0;
alter table public.catering_quotes add column if not exists bill_number text;
alter table public.catering_quotes add column if not exists billed_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'catering_quotes_discount_type_check') then
    alter table public.catering_quotes add constraint catering_quotes_discount_type_check check (discount_type in ('none', 'percent', 'fixed'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'catering_quotes_discount_value_check') then
    alter table public.catering_quotes add constraint catering_quotes_discount_value_check check (discount_value >= 0 and discount_amount >= 0);
  end if;
end;
$$;

create unique index if not exists catering_quotes_bill_number_idx on public.catering_quotes(bill_number) where bill_number is not null;

drop function if exists public.create_catering_quote(text, text, text, date, text, text, jsonb);
create or replace function public.create_catering_quote(
  p_customer_name text,
  p_customer_phone text,
  p_event_name text,
  p_event_date date,
  p_venue text,
  p_notes text,
  p_items jsonb,
  p_discount_type text default 'none',
  p_discount_value numeric default 0
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
  gross_total numeric(14,2);
  discount_total numeric(14,2) := 0;
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to create catering quotes.'; end if;
  if coalesce(trim(p_customer_name), '') = '' then raise exception using message = 'Enter the customer name.'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception using message = 'Add at least one catering menu item.'; end if;
  if p_discount_type not in ('none', 'percent', 'fixed') then raise exception using message = 'Choose a valid discount type.'; end if;
  if coalesce(p_discount_value, 0) < 0 then raise exception using message = 'Discount cannot be negative.'; end if;
  if p_discount_type = 'percent' and p_discount_value > 100 then raise exception using message = 'Discount percentage cannot exceed 100 percent.'; end if;

  quote_code := 'KN-Q-' || to_char(timezone('Asia/Karachi', now()), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 5));
  insert into public.catering_quotes(quote_number, customer_name, customer_phone, event_name, event_date, venue, notes, discount_type, discount_value)
  values (quote_code, trim(p_customer_name), coalesce(trim(p_customer_phone), ''), coalesce(trim(p_event_name), ''), p_event_date, coalesce(trim(p_venue), ''), coalesce(trim(p_notes), ''), p_discount_type, coalesce(p_discount_value, 0))
  returning id into quote_id;

  for line in select value from jsonb_array_elements(p_items)
  loop
    select * into rec from public.recipes where id = (line->>'recipe_id')::uuid;
    if not found then raise exception using message = 'A selected recipe no longer exists.'; end if;
    line_qty := (line->>'batch_qty')::numeric;
    profit_pct := (line->>'profit_percent')::numeric;
    if line_qty is null or line_qty <= 0 then raise exception using message = 'Each catering quantity must be greater than zero.'; end if;
    if profit_pct is null or profit_pct < 0 then raise exception using message = 'Profit markup cannot be negative.'; end if;
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

  gross_total := subtotal_cost + subtotal_profit;
  if p_discount_type = 'percent' then discount_total := round(gross_total * coalesce(p_discount_value, 0) / 100, 2);
  elsif p_discount_type = 'fixed' then discount_total := least(gross_total, coalesce(p_discount_value, 0));
  end if;
  update public.catering_quotes set total_cost = subtotal_cost, profit_amount = subtotal_profit, discount_amount = discount_total, quoted_total = gross_total - discount_total where id = quote_id;
  return quote_id;
end;
$$;

revoke all on function public.create_catering_quote(text, text, text, date, text, text, jsonb, text, numeric) from public, anon;
grant execute on function public.create_catering_quote(text, text, text, date, text, text, jsonb, text, numeric) to authenticated;

create or replace function public.assign_catering_bill_number()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'Dispatched' and old.status is distinct from new.status and new.bill_number is null then
    new.bill_number := 'KN-BILL-' || to_char(timezone('Asia/Karachi', now()), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 5));
    new.billed_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists catering_quote_assign_bill on public.catering_quotes;
create trigger catering_quote_assign_bill
before update of status on public.catering_quotes
for each row execute procedure public.assign_catering_bill_number();
