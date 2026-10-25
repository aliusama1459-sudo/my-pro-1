-- Run after branches.sql, branch_pos.sql, branch_payment_accounts.sql,
-- and branch_account_management.sql.
-- Keep the kitchen Branch Sales balance equal to the branch's current
-- Cash in hand + Bank payments balances (after expenses and adjustments).

create or replace function public.mirror_branch_cash_bank_to_kitchen_account(p_branch_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account public.financial_accounts%rowtype;
  v_total numeric(14,2);
  v_delta numeric(14,2);
begin
  select a.* into v_account
  from public.financial_accounts a
  left join public.branches b on b.id = p_branch_id
  where a.account_type = 'branch_sales'
    and a.is_active
    and (a.linked_branch_id = p_branch_id
      or (a.linked_branch_id is null and a.linked_branch_name = b.name))
  order by (a.linked_branch_id = p_branch_id) desc, a.created_at, a.id
  limit 1
  for update of a;

  if not found then return; end if;

  select coalesce(sum(current_balance), 0)::numeric(14,2)
  into v_total
  from public.branch_accounts
  where branch_id = p_branch_id
    and account_type in ('cash','bank')
    and is_system
    and is_active;

  v_delta := v_total - v_account.current_balance;
  if v_delta = 0 then return; end if;

  update public.financial_accounts
  set current_balance = v_total
  where id = v_account.id;

  insert into public.account_transactions(
    account_id, transaction_type, amount, balance_after,
    transaction_date, description, source_reference, created_by
  ) values (
    v_account.id,
    case when v_delta > 0 then 'income' else 'expense' end,
    abs(v_delta),
    v_total,
    timezone('Asia/Karachi', now())::date,
    'Cash + Bank balance mirrored from branch',
    'branch-cash-bank-mirror:' || gen_random_uuid()::text,
    auth.uid()
  );
end;
$$;

create or replace function public.on_branch_account_transaction_mirror_kitchen()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.mirror_branch_cash_bank_to_kitchen_account(new.branch_id);
  return new;
end;
$$;

drop trigger if exists mirror_branch_account_transaction_to_kitchen on public.branch_account_transactions;
create trigger mirror_branch_account_transaction_to_kitchen
after insert on public.branch_account_transactions
for each row
execute function public.on_branch_account_transaction_mirror_kitchen();

-- If the earlier bill-total sync migration was installed, the balance mirror
-- replaces its order trigger so the Branch Sales account remains an exact mirror.
drop trigger if exists sync_closed_branch_order_to_kitchen_sales on public.branch_orders;

-- Reconcile every existing branch once. A second run makes no changes if balances match.
do $$
declare r record;
begin
  for r in select id from public.branches order by name loop
    perform public.mirror_branch_cash_bank_to_kitchen_account(r.id);
  end loop;
end;
$$;

revoke all on function public.mirror_branch_cash_bank_to_kitchen_account(uuid) from public, anon, authenticated;
revoke all on function public.on_branch_account_transaction_mirror_kitchen() from public, anon, authenticated;
