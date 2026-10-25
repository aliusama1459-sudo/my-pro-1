-- Run after the kitchen, inventory, and catering migrations to enable accounts.
create table if not exists public.financial_accounts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  account_type text not null default 'other' check (account_type in ('branch_sales', 'catering_payments', 'cash', 'bank', 'other')),
  linked_branch_name text,
  is_system boolean not null default false,
  opening_balance numeric(14,2) not null default 0 check (opening_balance >= 0),
  current_balance numeric(14,2) not null default 0 check (current_balance >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.account_transactions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.financial_accounts(id) on delete restrict,
  counter_account_id uuid references public.financial_accounts(id) on delete restrict,
  transaction_type text not null check (transaction_type in ('opening_balance', 'income', 'expense', 'transfer_in', 'transfer_out', 'branch_sale', 'catering_payment')),
  amount numeric(14,2) not null check (amount > 0),
  balance_after numeric(14,2) not null check (balance_after >= 0),
  transaction_date date not null default current_date,
  description text not null default '',
  transfer_id uuid,
  source_reference text unique,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists financial_accounts_active_idx on public.financial_accounts(is_active, name);
create index if not exists account_transactions_account_date_idx on public.account_transactions(account_id, transaction_date desc, created_at desc);
create unique index if not exists financial_system_branch_sales_unique on public.financial_accounts(linked_branch_name) where account_type = 'branch_sales' and is_system;
alter table public.financial_accounts enable row level security;
alter table public.account_transactions enable row level security;

drop policy if exists "kitchen roles manage financial accounts" on public.financial_accounts;
create policy "kitchen roles manage financial accounts" on public.financial_accounts for all to authenticated using (public.has_kitchen_access()) with check (public.has_kitchen_access());
drop policy if exists "kitchen roles manage account transactions" on public.account_transactions;
create policy "kitchen roles manage account transactions" on public.account_transactions for all to authenticated using (public.has_kitchen_access()) with check (public.has_kitchen_access());
grant select on public.financial_accounts, public.account_transactions to authenticated;

do $$
begin
  if not exists (select 1 from public.financial_accounts where account_type = 'branch_sales' and linked_branch_name = 'Gulshan') then
    insert into public.financial_accounts(name, account_type, linked_branch_name, is_system) values ('Gulshan Branch Sales', 'branch_sales', 'Gulshan', true);
  end if;
  if not exists (select 1 from public.financial_accounts where account_type = 'catering_payments') then
    insert into public.financial_accounts(name, account_type, is_system) values ('Catering Payments', 'catering_payments', true);
  end if;
end;
$$;

create or replace function public.create_financial_account(
  p_name text,
  p_account_type text,
  p_linked_branch_name text default null,
  p_opening_balance numeric default 0
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to create accounts.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception using message = 'Enter an account name.'; end if;
  if p_account_type not in ('branch_sales', 'catering_payments', 'cash', 'bank', 'other') then raise exception using message = 'Choose a valid account type.'; end if;
  if coalesce(p_opening_balance, 0) < 0 then raise exception using message = 'Opening balance cannot be negative.'; end if;
  if p_account_type = 'branch_sales' and coalesce(trim(p_linked_branch_name), '') = '' then raise exception using message = 'Enter the branch name linked to this sales account.'; end if;
  insert into public.financial_accounts(name, account_type, linked_branch_name, opening_balance, current_balance)
  values (trim(p_name), p_account_type, nullif(trim(p_linked_branch_name), ''), coalesce(p_opening_balance, 0), coalesce(p_opening_balance, 0))
  returning id into new_id;
  if coalesce(p_opening_balance, 0) > 0 then
    insert into public.account_transactions(account_id, transaction_type, amount, balance_after, transaction_date, description, created_by)
    values (new_id, 'opening_balance', p_opening_balance, p_opening_balance, timezone('Asia/Karachi', now())::date, 'Opening balance', auth.uid());
  end if;
  return new_id;
end;
$$;

create or replace function public.adjust_financial_account(
  p_account_id uuid,
  p_action text,
  p_amount numeric,
  p_description text default '',
  p_transaction_date date default current_date
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.financial_accounts%rowtype;
  next_balance numeric(14,2);
  tx_type text;
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to update accounts.'; end if;
  if p_action not in ('add', 'subtract') then raise exception using message = 'Choose add or subtract.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception using message = 'Enter an amount greater than zero.'; end if;
  select * into a from public.financial_accounts where id = p_account_id and is_active for update;
  if not found then raise exception using message = 'Account not found or inactive.'; end if;
  next_balance := a.current_balance + case when p_action = 'add' then p_amount else -p_amount end;
  if next_balance < 0 then raise exception using message = 'This subtraction is greater than the current account balance.'; end if;
  tx_type := case when p_action = 'add' then 'income' else 'expense' end;
  update public.financial_accounts set current_balance = next_balance where id = p_account_id;
  insert into public.account_transactions(account_id, transaction_type, amount, balance_after, transaction_date, description, created_by)
  values (p_account_id, tx_type, p_amount, next_balance, coalesce(p_transaction_date, timezone('Asia/Karachi', now())::date), coalesce(nullif(trim(p_description), ''), p_action), auth.uid());
  return next_balance;
end;
$$;

create or replace function public.transfer_financial_account_amount(
  p_from_account_id uuid,
  p_to_account_id uuid,
  p_amount numeric,
  p_description text default '',
  p_transaction_date date default current_date
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  source_account public.financial_accounts%rowtype;
  target_account public.financial_accounts%rowtype;
  transfer_key uuid := gen_random_uuid();
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to transfer account funds.'; end if;
  if p_from_account_id = p_to_account_id then raise exception using message = 'Choose two different accounts.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception using message = 'Enter an amount greater than zero.'; end if;
  perform 1 from public.financial_accounts where id in (p_from_account_id, p_to_account_id) order by id for update;
  select * into source_account from public.financial_accounts where id = p_from_account_id and is_active;
  select * into target_account from public.financial_accounts where id = p_to_account_id and is_active;
  if source_account.id is null or target_account.id is null then raise exception using message = 'Both accounts must exist and be active.'; end if;
  if source_account.current_balance < p_amount then raise exception using message = 'Transfer amount is greater than the source account balance.'; end if;
  update public.financial_accounts set current_balance = current_balance - p_amount where id = p_from_account_id;
  update public.financial_accounts set current_balance = current_balance + p_amount where id = p_to_account_id;
  insert into public.account_transactions(account_id, counter_account_id, transaction_type, amount, balance_after, transaction_date, description, transfer_id, created_by)
  values
    (p_from_account_id, p_to_account_id, 'transfer_out', p_amount, source_account.current_balance - p_amount, coalesce(p_transaction_date, timezone('Asia/Karachi', now())::date), coalesce(nullif(trim(p_description), ''), 'Transfer to ' || target_account.name), transfer_key, auth.uid()),
    (p_to_account_id, p_from_account_id, 'transfer_in', p_amount, target_account.current_balance + p_amount, coalesce(p_transaction_date, timezone('Asia/Karachi', now())::date), coalesce(nullif(trim(p_description), ''), 'Transfer from ' || source_account.name), transfer_key, auth.uid());
  return transfer_key;
end;
$$;

-- POS can call this function when branch sales are implemented. A unique source reference prevents double-posting a sale.
create or replace function public.record_branch_sale_to_account(
  p_branch_name text,
  p_amount numeric,
  p_sale_reference text,
  p_sale_date date default current_date
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account_id uuid;
  account_row public.financial_accounts%rowtype;
  new_balance numeric(14,2);
  sale_source text := 'branch-sale:' || trim(p_sale_reference);
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to record branch sales.'; end if;
  if coalesce(trim(p_branch_name), '') = '' or coalesce(trim(p_sale_reference), '') = '' then raise exception using message = 'Branch and sale reference are required.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception using message = 'Sale amount must be greater than zero.'; end if;
  perform pg_advisory_xact_lock(hashtext(sale_source)::bigint);
  select at.account_id into v_account_id from public.account_transactions at where at.source_reference = sale_source;
  if v_account_id is not null then return v_account_id; end if;
  select fa.id into v_account_id from public.financial_accounts fa where fa.account_type = 'branch_sales' and fa.linked_branch_name = trim(p_branch_name) and fa.is_active limit 1;
  if v_account_id is null then
    insert into public.financial_accounts(name, account_type, linked_branch_name, is_system)
    values (trim(p_branch_name) || ' Branch Sales', 'branch_sales', trim(p_branch_name), true)
    on conflict (linked_branch_name) where account_type = 'branch_sales' and is_system do nothing;
    select fa.id into v_account_id from public.financial_accounts fa where fa.account_type = 'branch_sales' and fa.linked_branch_name = trim(p_branch_name) and fa.is_active limit 1;
  end if;
  select * into account_row from public.financial_accounts where id = v_account_id for update;
  new_balance := account_row.current_balance + p_amount;
  update public.financial_accounts set current_balance = new_balance where id = v_account_id;
  insert into public.account_transactions(account_id, transaction_type, amount, balance_after, transaction_date, description, source_reference, created_by)
  values (v_account_id, 'branch_sale', p_amount, new_balance, coalesce(p_sale_date, timezone('Asia/Karachi', now())::date), 'Branch sale ' || trim(p_sale_reference), sale_source, auth.uid());
  return v_account_id;
end;
$$;

revoke all on function public.create_financial_account(text, text, text, numeric) from public, anon;
revoke all on function public.adjust_financial_account(uuid, text, numeric, text, date) from public, anon;
revoke all on function public.transfer_financial_account_amount(uuid, uuid, numeric, text, date) from public, anon;
revoke all on function public.record_branch_sale_to_account(text, numeric, text, date) from public, anon;
grant execute on function public.create_financial_account(text, text, text, numeric) to authenticated;
grant execute on function public.adjust_financial_account(uuid, text, numeric, text, date) to authenticated;
grant execute on function public.transfer_financial_account_amount(uuid, uuid, numeric, text, date) to authenticated;
grant execute on function public.record_branch_sale_to_account(text, numeric, text, date) to authenticated;
