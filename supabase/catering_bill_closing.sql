-- Run after catering_discount_bill.sql to allow a final bill discount before closing.
alter table public.catering_quotes add column if not exists bill_status text not null default 'Not billed';
alter table public.catering_quotes add column if not exists bill_discount_type text not null default 'none';
alter table public.catering_quotes add column if not exists bill_discount_value numeric(12,2) not null default 0;
alter table public.catering_quotes add column if not exists bill_discount_amount numeric(14,2) not null default 0;
alter table public.catering_quotes add column if not exists bill_total numeric(14,2) not null default 0;
alter table public.catering_quotes add column if not exists bill_closed_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'catering_quotes_bill_status_check') then
    alter table public.catering_quotes add constraint catering_quotes_bill_status_check check (bill_status in ('Not billed', 'Open', 'Closed'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'catering_quotes_bill_discount_type_check') then
    alter table public.catering_quotes add constraint catering_quotes_bill_discount_type_check check (bill_discount_type in ('none', 'percent', 'fixed'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'catering_quotes_bill_discount_value_check') then
    alter table public.catering_quotes add constraint catering_quotes_bill_discount_value_check check (bill_discount_value >= 0 and bill_discount_amount >= 0 and bill_total >= 0);
  end if;
end;
$$;

update public.catering_quotes
set bill_status = case when status = 'Dispatched' then 'Open' else 'Not billed' end,
    bill_total = quoted_total
where bill_status = 'Not billed';

create or replace function public.assign_catering_bill_number()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'Dispatched' and old.status is distinct from new.status then
    if new.bill_number is null then
      new.bill_number := 'KN-BILL-' || to_char(timezone('Asia/Karachi', now()), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 5));
      new.billed_at := now();
    end if;
    if new.bill_status = 'Not billed' then
      new.bill_status := 'Open';
      new.bill_total := new.quoted_total;
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.update_catering_bill_discount(
  p_quote_id uuid,
  p_discount_type text,
  p_discount_value numeric
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  q public.catering_quotes%rowtype;
  amount numeric(14,2);
  next_total numeric(14,2);
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to update a catering bill.'; end if;
  if p_discount_type not in ('none', 'percent', 'fixed') then raise exception using message = 'Choose a valid bill discount type.'; end if;
  if coalesce(p_discount_value, 0) < 0 then raise exception using message = 'Bill discount cannot be negative.'; end if;
  if p_discount_type = 'percent' and p_discount_value > 100 then raise exception using message = 'Bill discount percentage cannot exceed 100 percent.'; end if;
  select * into q from public.catering_quotes where id = p_quote_id for update;
  if not found or q.status <> 'Dispatched' then raise exception using message = 'Only a dispatched catering quote can be billed.'; end if;
  if q.bill_status <> 'Open' then raise exception using message = 'This bill is already closed.'; end if;
  if p_discount_type = 'percent' then amount := round(q.quoted_total * coalesce(p_discount_value, 0) / 100, 2);
  elsif p_discount_type = 'fixed' then amount := least(q.quoted_total, coalesce(p_discount_value, 0));
  else amount := 0;
  end if;
  next_total := q.quoted_total - amount;
  update public.catering_quotes
  set bill_discount_type = p_discount_type,
      bill_discount_value = coalesce(p_discount_value, 0),
      bill_discount_amount = amount,
      bill_total = next_total
  where id = p_quote_id;
  return next_total;
end;
$$;

create or replace function public.close_catering_bill(p_quote_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  closed_time timestamptz;
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to close a catering bill.'; end if;
  update public.catering_quotes
  set bill_status = 'Closed', bill_closed_at = now()
  where id = p_quote_id and status = 'Dispatched' and bill_status = 'Open'
  returning bill_closed_at into closed_time;
  if closed_time is null then raise exception using message = 'This bill is not open or has already been closed.'; end if;
  return closed_time;
end;
$$;

revoke all on function public.update_catering_bill_discount(uuid, text, numeric) from public, anon;
revoke all on function public.close_catering_bill(uuid) from public, anon;
grant execute on function public.update_catering_bill_discount(uuid, text, numeric) to authenticated;
grant execute on function public.close_catering_bill(uuid) to authenticated;
