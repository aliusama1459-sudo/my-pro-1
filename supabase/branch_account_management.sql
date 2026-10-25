-- Run after branch_payment_accounts.sql. Enables branch accounts and expense tracking.

create table if not exists public.branch_expenses (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  account_id uuid not null references public.branch_accounts(id) on delete restrict,
  category text not null default 'Other',
  description text not null default '',
  amount numeric(14,2) not null check (amount>0),
  expense_date date not null default current_date,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists branch_expenses_date_idx
  on public.branch_expenses(branch_id,expense_date desc,created_at desc);
alter table public.branch_expenses enable row level security;
drop policy if exists "branch expenses read" on public.branch_expenses;
create policy "branch expenses read" on public.branch_expenses for select to authenticated
  using (public.has_branch_access(branch_id));
drop policy if exists "branch expenses managers" on public.branch_expenses;
create policy "branch expenses managers" on public.branch_expenses for all to authenticated
  using (public.can_manage_branch(branch_id)) with check (public.can_manage_branch(branch_id));
grant select on public.branch_expenses to authenticated;

create or replace function public.create_branch_account(
  p_branch_id uuid,p_name text,p_opening_balance numeric default 0
) returns uuid language plpgsql security definer set search_path=public
as $$
declare v_id uuid; v_name text:=trim(coalesce(p_name,'')); v_opening numeric(14,2):=coalesce(p_opening_balance,0);
begin
  if auth.uid() is null or not public.can_manage_branch(p_branch_id) then raise exception using message='A branch manager or owner is required to create accounts.'; end if;
  if v_name='' then raise exception using message='Enter an account name.'; end if;
  if v_opening<0 then raise exception using message='Opening balance cannot be negative.'; end if;
  insert into public.branch_accounts(branch_id,name,account_type,is_system,current_balance)
    values(p_branch_id,v_name,'custom',false,v_opening) returning id into v_id;
  if v_opening>0 then
    insert into public.branch_account_transactions(branch_id,account_id,transaction_type,amount,balance_after,transaction_date,description,source_reference,created_by)
      values(p_branch_id,v_id,'opening',v_opening,v_opening,timezone('Asia/Karachi',now())::date,'Opening balance','branch-account-opening:'||v_id::text,auth.uid());
  end if;
  return v_id;
end;
$$;

create or replace function public.adjust_branch_account(
  p_account_id uuid,p_action text,p_amount numeric,p_description text default '',p_transaction_date date default current_date
) returns numeric language plpgsql security definer set search_path=public
as $$
declare a public.branch_accounts%rowtype; v_next numeric(14,2); v_type text;
begin
  select * into a from public.branch_accounts where id=p_account_id and is_active for update;
  if not found then raise exception using message='Account not found or inactive.'; end if;
  if auth.uid() is null or not public.can_manage_branch(a.branch_id) then raise exception using message='A branch manager or owner is required to change account balances.'; end if;
  if p_action not in ('add','subtract') or p_amount is null or p_amount<=0 then raise exception using message='Enter an amount greater than zero.'; end if;
  if p_action='subtract' and a.current_balance<p_amount then raise exception using message='There is not enough money in this account.'; end if;
  v_next:=case when p_action='add' then a.current_balance+p_amount else a.current_balance-p_amount end;
  v_type:=case when a.account_type='cash' and p_action='add' then 'sale' when p_action='add' then 'income' else 'adjustment' end;
  update public.branch_accounts set current_balance=v_next where id=p_account_id;
  insert into public.branch_account_transactions(branch_id,account_id,transaction_type,amount,balance_after,transaction_date,description,source_reference,created_by)
    values(a.branch_id,p_account_id,v_type,p_amount,v_next,coalesce(p_transaction_date,timezone('Asia/Karachi',now())::date),
      coalesce(nullif(trim(p_description),''),case when p_action='add' then 'Money added manually' else 'Money subtracted manually' end),
      'branch-account-adjustment:'||gen_random_uuid()::text,auth.uid());
  return v_next;
end;
$$;

create or replace function public.transfer_branch_account(
  p_from_account_id uuid,p_to_account_id uuid,p_amount numeric,p_description text default '',p_transaction_date date default current_date
) returns void language plpgsql security definer set search_path=public
as $$
declare a_from public.branch_accounts%rowtype; a_to public.branch_accounts%rowtype; v_transfer uuid:=gen_random_uuid();
begin
  if p_from_account_id=p_to_account_id then raise exception using message='Choose two different accounts.'; end if;
  perform 1 from public.branch_accounts where id in(p_from_account_id,p_to_account_id) order by id for update;
  select * into a_from from public.branch_accounts where id=p_from_account_id and is_active;
  select * into a_to from public.branch_accounts where id=p_to_account_id and is_active;
  if a_from.id is null or a_to.id is null or a_from.branch_id<>a_to.branch_id then raise exception using message='Choose two active accounts in the same branch.'; end if;
  if auth.uid() is null or not public.can_manage_branch(a_from.branch_id) then raise exception using message='A branch manager or owner is required to transfer funds.'; end if;
  if p_amount is null or p_amount<=0 then raise exception using message='Enter an amount greater than zero.'; end if;
  if a_from.current_balance<p_amount then raise exception using message='There is not enough money in the source account.'; end if;
  update public.branch_accounts set current_balance=current_balance-p_amount where id=a_from.id;
  update public.branch_accounts set current_balance=current_balance+p_amount where id=a_to.id;
  insert into public.branch_account_transactions(branch_id,account_id,transaction_type,amount,balance_after,transaction_date,description,source_reference,created_by)
    values(a_from.branch_id,a_from.id,'transfer_out',p_amount,a_from.current_balance-p_amount,coalesce(p_transaction_date,timezone('Asia/Karachi',now())::date),coalesce(p_description,'Account transfer'),'branch-transfer:'||v_transfer::text||':out',auth.uid()),
          (a_to.branch_id,a_to.id,'transfer_in',p_amount,a_to.current_balance+p_amount,coalesce(p_transaction_date,timezone('Asia/Karachi',now())::date),coalesce(p_description,'Account transfer'),'branch-transfer:'||v_transfer::text||':in',auth.uid());
end;
$$;

create or replace function public.remove_branch_account(p_account_id uuid)
returns text language plpgsql security definer set search_path=public
as $$
declare a public.branch_accounts%rowtype; v_history boolean;
begin
  select * into a from public.branch_accounts where id=p_account_id and is_active for update;
  if not found then raise exception using message='Account not found or inactive.'; end if;
  if auth.uid() is null or not public.can_manage_branch(a.branch_id) then raise exception using message='A branch manager or owner is required to remove accounts.'; end if;
  if a.is_system then raise exception using message='Default payment accounts cannot be removed.'; end if;
  if a.current_balance<>0 then raise exception using message='Transfer or subtract the account balance before removing it.'; end if;
  select exists(select 1 from public.branch_account_transactions where account_id=p_account_id)
      or exists(select 1 from public.branch_expenses where account_id=p_account_id) into v_history;
  if v_history then
    update public.branch_accounts set is_active=false where id=p_account_id;
    return 'archived';
  end if;
  delete from public.branch_accounts where id=p_account_id;
  return 'deleted';
end;
$$;

create or replace function public.restore_branch_account(p_account_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
declare a public.branch_accounts%rowtype;
begin
  select * into a from public.branch_accounts where id=p_account_id for update;
  if not found or a.is_system then raise exception using message='Custom archived account not found.'; end if;
  if auth.uid() is null or not public.can_manage_branch(a.branch_id) then raise exception using message='A branch manager or owner is required to restore accounts.'; end if;
  update public.branch_accounts set is_active=true where id=p_account_id;
end;
$$;

create or replace function public.record_branch_expense(
  p_branch_id uuid,p_account_id uuid,p_category text,p_description text,p_amount numeric,p_expense_date date default current_date
) returns uuid language plpgsql security definer set search_path=public
as $$
declare a public.branch_accounts%rowtype; v_id uuid:=gen_random_uuid(); v_next numeric(14,2);
begin
  if auth.uid() is null or not public.can_manage_branch(p_branch_id) then raise exception using message='A branch manager or owner is required to record branch expenses.'; end if;
  if p_amount is null or p_amount<=0 then raise exception using message='Enter an expense amount greater than zero.'; end if;
  select * into a from public.branch_accounts where id=p_account_id and branch_id=p_branch_id and is_active for update;
  if not found then raise exception using message='Choose an active account in this branch.'; end if;
  if a.current_balance<p_amount then raise exception using message='There is not enough money in the selected account.'; end if;
  v_next:=a.current_balance-p_amount;
  insert into public.branch_expenses(id,branch_id,account_id,category,description,amount,expense_date,created_by)
    values(v_id,p_branch_id,p_account_id,coalesce(nullif(trim(p_category),''),'Other'),coalesce(trim(p_description),''),p_amount,coalesce(p_expense_date,timezone('Asia/Karachi',now())::date),auth.uid());
  update public.branch_accounts set current_balance=v_next where id=p_account_id;
  insert into public.branch_account_transactions(branch_id,account_id,transaction_type,amount,balance_after,transaction_date,description,source_reference,created_by)
    values(p_branch_id,p_account_id,'expense',p_amount,v_next,coalesce(p_expense_date,timezone('Asia/Karachi',now())::date),
      coalesce(nullif(trim(p_description),''),trim(p_category)),'branch-expense:'||v_id::text,auth.uid());
  return v_id;
end;
$$;

revoke all on function public.create_branch_account(uuid,text,numeric) from public,anon;
revoke all on function public.adjust_branch_account(uuid,text,numeric,text,date) from public,anon;
revoke all on function public.transfer_branch_account(uuid,uuid,numeric,text,date) from public,anon;
revoke all on function public.remove_branch_account(uuid) from public,anon;
revoke all on function public.restore_branch_account(uuid) from public,anon;
revoke all on function public.record_branch_expense(uuid,uuid,text,text,numeric,date) from public,anon;
grant execute on function public.create_branch_account(uuid,text,numeric) to authenticated;
grant execute on function public.adjust_branch_account(uuid,text,numeric,text,date) to authenticated;
grant execute on function public.transfer_branch_account(uuid,uuid,numeric,text,date) to authenticated;
grant execute on function public.remove_branch_account(uuid) to authenticated;
grant execute on function public.restore_branch_account(uuid) to authenticated;
grant execute on function public.record_branch_expense(uuid,uuid,text,text,numeric,date) to authenticated;

