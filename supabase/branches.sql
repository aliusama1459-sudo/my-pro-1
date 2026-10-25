-- Run after accounts.sql. Every new branch automatically receives one Branch Sales account.
create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  address text not null default '',
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.financial_accounts add column if not exists linked_branch_id uuid references public.branches(id) on delete set null;
create index if not exists branches_active_name_idx on public.branches(is_active, name);
alter table public.branches enable row level security;
drop policy if exists "kitchen roles manage branches" on public.branches;
create policy "kitchen roles manage branches" on public.branches for all to authenticated using (public.has_kitchen_access()) with check (public.has_kitchen_access());
grant select on public.branches to authenticated;

-- Create branch records for branch sales accounts that already exist.
insert into public.branches(name)
select distinct trim(linked_branch_name)
from public.financial_accounts
where account_type = 'branch_sales' and coalesce(trim(linked_branch_name), '') <> ''
on conflict (name) do nothing;

-- Link one canonical sales account per branch, preferring accounts that already have ledger activity.
with ranked as (
  select a.id, b.id as branch_id,
         row_number() over (
           partition by b.id
           order by exists(select 1 from public.account_transactions t where t.account_id = a.id or t.counter_account_id = a.id) desc,
                    (a.current_balance > 0) desc, a.is_system desc, a.created_at, a.id
         ) as rank
  from public.financial_accounts a
  join public.branches b on b.name = trim(a.linked_branch_name)
  where a.account_type = 'branch_sales'
)
update public.financial_accounts a set linked_branch_id = ranked.branch_id
from ranked where ranked.id = a.id and ranked.rank = 1;

create unique index if not exists financial_accounts_one_branch_sales_account
  on public.financial_accounts(linked_branch_id)
  where account_type = 'branch_sales' and linked_branch_id is not null;

create or replace function public.create_branch_with_sales_account(
  p_name text,
  p_address text default ''
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  branch_id uuid;
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to create branches.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception using message = 'Enter a branch name.'; end if;
  insert into public.branches(name, address) values (trim(p_name), coalesce(trim(p_address), '')) returning id into branch_id;
  insert into public.financial_accounts(name, account_type, linked_branch_name, linked_branch_id, is_system)
  values (trim(p_name) || ' Branch Sales', 'branch_sales', trim(p_name), branch_id, true);
  return branch_id;
end;
$$;

-- POS will call this when a sale is recorded. A source reference prevents duplicate posting.
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
  v_branch_id uuid;
  v_account_id uuid;
  v_balance numeric(14,2);
  v_next_balance numeric(14,2);
  v_source text := 'branch-sale:' || trim(p_sale_reference);
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to record branch sales.'; end if;
  if coalesce(trim(p_branch_name), '') = '' or coalesce(trim(p_sale_reference), '') = '' then raise exception using message = 'Branch and sale reference are required.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception using message = 'Sale amount must be greater than zero.'; end if;
  perform pg_advisory_xact_lock(hashtext(v_source)::bigint);
  select account_id into v_account_id from public.account_transactions where source_reference = v_source;
  if v_account_id is not null then return v_account_id; end if;
  select id into v_branch_id from public.branches where name = trim(p_branch_name) and is_active;
  if v_branch_id is null then raise exception using message = 'Create and activate this branch before recording its sales.'; end if;
  select id, current_balance into v_account_id, v_balance
  from public.financial_accounts where linked_branch_id = v_branch_id and account_type = 'branch_sales' and is_active for update;
  if v_account_id is null then raise exception using message = 'This branch has no active sales account linked.'; end if;
  v_next_balance := v_balance + p_amount;
  update public.financial_accounts set current_balance = v_next_balance where id = v_account_id;
  insert into public.account_transactions(account_id, transaction_type, amount, balance_after, transaction_date, description, source_reference, created_by)
  values (v_account_id, 'branch_sale', p_amount, v_next_balance, coalesce(p_sale_date, timezone('Asia/Karachi', now())::date), 'Branch sale ' || trim(p_sale_reference), v_source, auth.uid());
  return v_account_id;
end;
$$;

revoke all on function public.create_branch_with_sales_account(text, text) from public, anon;
revoke all on function public.record_branch_sale_to_account(text, numeric, text, date) from public, anon;
grant execute on function public.create_branch_with_sales_account(text, text) to authenticated;
grant execute on function public.record_branch_sale_to_account(text, numeric, text, date) to authenticated;
