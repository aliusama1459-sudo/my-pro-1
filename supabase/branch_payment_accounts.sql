-- Run after branch_pos.sql. Consolidates card and online receipts into the
-- branch Bank payments account; Cash receipts remain in Cash in hand.

alter table public.branch_accounts drop constraint if exists branch_accounts_account_type_check;
alter table public.branch_accounts add constraint branch_accounts_account_type_check
  check (account_type in ('cash','bank','card','online','custom'));
drop index if exists public.branch_default_accounts_unique;
create unique index branch_default_accounts_unique
  on public.branch_accounts(branch_id,account_type)
  where account_type in ('cash','bank') and is_system;

insert into public.branch_accounts(branch_id,name,account_type,is_system)
select b.id,b.name||' Bank payments','bank',true from public.branches b
on conflict(branch_id,name) do nothing;

-- Move old card/online balances into the new bank account and keep the old
-- accounts inactive so older ledger entries remain available for history.
do $$
declare r record; v_total numeric(14,2); v_bank_id uuid;
begin
  for r in select id from public.branches loop
    select id into v_bank_id from public.branch_accounts
      where branch_id=r.id and account_type='bank' and is_system for update;
    select coalesce(sum(current_balance),0) into v_total from public.branch_accounts
      where branch_id=r.id and account_type in ('card','online') and is_system and is_active;
    if v_total>0 then
      update public.branch_accounts set current_balance=current_balance+v_total where id=v_bank_id;
    end if;
    update public.branch_order_payments p set account_id=v_bank_id
      from public.branch_accounts old
      where p.account_id=old.id and old.branch_id=r.id and old.account_type in ('card','online');
    update public.branch_account_transactions t set account_id=v_bank_id
      from public.branch_accounts old
      where t.account_id=old.id and old.branch_id=r.id and old.account_type in ('card','online');
    update public.branch_accounts set current_balance=0,is_active=false
      where branch_id=r.id and account_type in ('card','online') and is_system;
  end loop;
end;
$$;
with balances as (
  select id,sum(case when transaction_type in ('expense','transfer_out') then -amount else amount end)
    over(partition by account_id order by transaction_date,created_at,id) as running_balance
  from public.branch_account_transactions
)
update public.branch_account_transactions t set balance_after=balances.running_balance
from balances where balances.id=t.id;

drop trigger if exists add_branch_payment_accounts on public.branches;
drop function if exists public.seed_branch_payment_accounts();
create function public.seed_branch_payment_accounts()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  insert into public.branch_accounts(branch_id,name,account_type,is_system) values
    (new.id,new.name||' Cash in hand','cash',true),
    (new.id,new.name||' Bank payments','bank',true)
  on conflict do nothing;
  return new;
end;
$$;
create trigger add_branch_payment_accounts after insert on public.branches
for each row execute function public.seed_branch_payment_accounts();

create or replace function public.close_branch_order(
  p_order_id uuid,
  p_discount_type text,
  p_discount_value numeric,
  p_payments jsonb
) returns uuid language plpgsql security definer set search_path=public
as $$
declare
  v_order public.branch_orders%rowtype;
  v_discount numeric(14,2);
  v_total numeric(14,2);
  v_paid numeric(14,2);
  v_payment jsonb;
  v_method text;
  v_account_type text;
  v_amount numeric(14,2);
  v_account public.branch_accounts%rowtype;
  v_next_balance numeric(14,2);
  v_need record;
  v_stock numeric(14,3);
  v_new_stock numeric(14,3);
  v_index integer:=0;
begin
  select * into v_order from public.branch_orders where id=p_order_id for update;
  if not found then raise exception using message='Order not found.'; end if;
  if auth.uid() is null or not public.has_branch_access(v_order.branch_id) then raise exception using message='You do not have access to this branch.'; end if;
  if v_order.status<>'open' then raise exception using message='This order is already closed.'; end if;
  if p_discount_type not in ('none','percent','fixed') or p_discount_value is null or p_discount_value<0 then
    raise exception using message='Enter a valid discount.';
  end if;
  if p_discount_type='percent' and p_discount_value>100 then raise exception using message='Discount cannot exceed 100 percent.'; end if;
  v_discount:=case when p_discount_type='percent' then round(v_order.subtotal*p_discount_value/100,2)
                   when p_discount_type='fixed' then p_discount_value else 0 end;
  if v_discount>v_order.subtotal then raise exception using message='Discount cannot exceed the bill subtotal.'; end if;
  v_total:=v_order.subtotal-v_discount;
  if jsonb_typeof(coalesce(p_payments,'[]'::jsonb))<>'array' then raise exception using message='Payment split must be a list.'; end if;
  select coalesce(sum((value->>'amount')::numeric),0) into v_paid
    from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) as payments(value)
    where coalesce((value->>'amount')::numeric,0)>0;
  if abs(v_paid-v_total)>0.01 then raise exception using message='Payment amounts must equal the final bill total.'; end if;
  if v_total>0 and not exists(select 1 from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) as payments(value) where (value->>'amount')::numeric>0) then
    raise exception using message='Enter at least one payment amount.';
  end if;

  for v_need in
    select bi.id as inventory_id,bi.name,bi.unit,sum(oi.quantity) as quantity
    from public.branch_order_items oi
    join public.branch_menu_items mi on mi.id=oi.menu_item_id
    join public.branch_inventory_items bi on bi.menu_item_id=mi.id and bi.is_active
    where oi.order_id=p_order_id group by bi.id,bi.name,bi.unit order by bi.id
  loop
    select stock_quantity into v_stock from public.branch_inventory_items where id=v_need.inventory_id for update;
    if v_stock<v_need.quantity then
      raise exception using message=format('Not enough %s stock: need %s %s, have %s.',v_need.name,v_need.quantity,v_need.unit,v_stock);
    end if;
  end loop;

  for v_need in
    select bi.id as inventory_id,bi.name,bi.unit,sum(oi.quantity) as quantity
    from public.branch_order_items oi
    join public.branch_menu_items mi on mi.id=oi.menu_item_id
    join public.branch_inventory_items bi on bi.menu_item_id=mi.id and bi.is_active
    where oi.order_id=p_order_id group by bi.id,bi.name,bi.unit order by bi.id
  loop
    update public.branch_inventory_items set stock_quantity=stock_quantity-v_need.quantity,updated_at=now()
      where id=v_need.inventory_id returning stock_quantity into v_new_stock;
    insert into public.branch_stock_movements(branch_id,inventory_item_id,movement_type,quantity_change,quantity_after,movement_date,note,created_by)
      values(v_order.branch_id,v_need.inventory_id,'sale',-v_need.quantity,v_new_stock,timezone('Asia/Karachi',now())::date,'Sold on bill '||v_order.order_number,auth.uid());
  end loop;

  update public.branch_orders set discount_type=p_discount_type,discount_value=p_discount_value,
    discount_amount=v_discount,total_amount=v_total,status='closed',closed_by=auth.uid(),closed_at=now()
    where id=p_order_id;

  for v_payment in select value from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) loop
    v_method:=v_payment->>'method';
    v_amount:=coalesce((v_payment->>'amount')::numeric,0);
    if v_amount<=0 then continue; end if;
    if v_method not in ('cash','card','online') then raise exception using message='Choose cash, card, or online payment.'; end if;
    v_account_type:=case when v_method='cash' then 'cash' else 'bank' end;
    select * into v_account from public.branch_accounts
      where branch_id=v_order.branch_id and account_type=v_account_type and is_system and is_active for update;
    if not found then raise exception using message='A default payment account is missing for this branch.'; end if;
    v_next_balance:=v_account.current_balance+v_amount;
    update public.branch_accounts set current_balance=v_next_balance where id=v_account.id;
    insert into public.branch_order_payments(branch_id,order_id,account_id,payment_method,amount)
      values(v_order.branch_id,p_order_id,v_account.id,v_method,v_amount);
    v_index:=v_index+1;
    insert into public.branch_account_transactions(branch_id,account_id,transaction_type,amount,balance_after,transaction_date,description,source_reference,created_by)
      values(v_order.branch_id,v_account.id,'sale',v_amount,v_next_balance,timezone('Asia/Karachi',now())::date,
        'Bill '||v_order.order_number,'branch-order:'||p_order_id::text||':'||v_index,auth.uid());
  end loop;
  return p_order_id;
end;
$$;
revoke all on function public.close_branch_order(uuid,text,numeric,jsonb) from public,anon;
grant execute on function public.close_branch_order(uuid,text,numeric,jsonb) to authenticated;

