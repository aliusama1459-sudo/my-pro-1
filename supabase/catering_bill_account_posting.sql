-- Run after accounts.sql. Closing a catering bill records its full amount as received.
create or replace function public.post_closed_catering_bill_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  acct_id uuid;
  acct_balance numeric(14,2);
  next_balance numeric(14,2);
  reference text;
  payment_date date;
begin
  if new.bill_status <> 'Closed' or old.bill_status is not distinct from new.bill_status then return new; end if;
  if coalesce(new.bill_total, 0) <= 0 then return new; end if;
  reference := 'catering-bill:' || coalesce(new.bill_number, new.quote_number);
  perform pg_advisory_xact_lock(hashtext(reference)::bigint);
  if exists (select 1 from public.account_transactions where source_reference = reference) then return new; end if;

  select id, current_balance into acct_id, acct_balance
  from public.financial_accounts
  where account_type = 'catering_payments' and is_active
  order by is_system desc, created_at
  limit 1
  for update;
  if acct_id is null then
    insert into public.financial_accounts(name, account_type, is_system)
    values ('Catering Payments', 'catering_payments', true)
    returning id, current_balance into acct_id, acct_balance;
  end if;
  next_balance := acct_balance + new.bill_total;
  update public.financial_accounts set current_balance = next_balance where id = acct_id;
  payment_date := coalesce(timezone('Asia/Karachi', new.bill_closed_at)::date, timezone('Asia/Karachi', now())::date);
  insert into public.account_transactions(account_id, transaction_type, amount, balance_after, transaction_date, description, source_reference, created_by)
  values (acct_id, 'catering_payment', new.bill_total, next_balance, payment_date, 'Payment received for catering bill ' || coalesce(new.bill_number, new.quote_number), reference, auth.uid());
  return new;
end;
$$;

revoke all on function public.post_closed_catering_bill_payment() from public, anon;
drop trigger if exists catering_bill_post_payment on public.catering_quotes;
create trigger catering_bill_post_payment
after update of bill_status on public.catering_quotes
for each row
when (old.bill_status is distinct from new.bill_status and new.bill_status = 'Closed')
execute procedure public.post_closed_catering_bill_payment();

-- Backfill closed bills created before this automatic account posting was installed.
do $$
declare
  q record;
  acct_id uuid;
  acct_balance numeric(14,2);
  next_balance numeric(14,2);
  reference text;
  payment_date date;
begin
  for q in
    select id, quote_number, bill_number, bill_total, bill_closed_at
    from public.catering_quotes
    where status = 'Dispatched' and bill_status = 'Closed' and bill_total > 0
    order by bill_closed_at, id
  loop
    reference := 'catering-bill:' || coalesce(q.bill_number, q.quote_number);
    if exists (select 1 from public.account_transactions where source_reference = reference) then continue; end if;
    select id, current_balance into acct_id, acct_balance
    from public.financial_accounts
    where account_type = 'catering_payments' and is_active
    order by is_system desc, created_at
    limit 1
    for update;
    if acct_id is null then
      insert into public.financial_accounts(name, account_type, is_system)
      values ('Catering Payments', 'catering_payments', true)
      returning id, current_balance into acct_id, acct_balance;
    end if;
    next_balance := acct_balance + q.bill_total;
    update public.financial_accounts set current_balance = next_balance where id = acct_id;
    payment_date := coalesce(timezone('Asia/Karachi', q.bill_closed_at)::date, timezone('Asia/Karachi', now())::date);
    insert into public.account_transactions(account_id, transaction_type, amount, balance_after, transaction_date, description, source_reference)
    values (acct_id, 'catering_payment', q.bill_total, next_balance, payment_date, 'Payment received for catering bill ' || coalesce(q.bill_number, q.quote_number), reference);
  end loop;
end;
$$;
