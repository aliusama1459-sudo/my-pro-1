-- Run after branch_inventory_items.sql. Adds branch order taking, bill closure,
-- stock deduction, payment splits, and branch cash/card/online ledgers.

create table if not exists public.branch_accounts (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  name text not null,
  account_type text not null check (account_type in ('cash','card','online','custom')),
  is_system boolean not null default false,
  current_balance numeric(14,2) not null default 0 check (current_balance>=0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (branch_id,name)
);
create unique index if not exists branch_default_accounts_unique
  on public.branch_accounts(branch_id,account_type) where account_type in ('cash','card','online') and is_system;

create table if not exists public.branch_account_transactions (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  account_id uuid not null references public.branch_accounts(id) on delete restrict,
  transaction_type text not null check (transaction_type in ('opening','sale','expense','income','transfer_in','transfer_out','adjustment')),
  amount numeric(14,2) not null check (amount>0),
  balance_after numeric(14,2) not null check (balance_after>=0),
  transaction_date date not null default current_date,
  description text not null default '',
  source_reference text unique,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists branch_account_history_idx
  on public.branch_account_transactions(branch_id,transaction_date desc,created_at desc);

create table if not exists public.branch_orders (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete restrict,
  order_number text not null,
  service_type text not null check (service_type in ('dine_in','takeaway','delivery')),
  table_number integer,
  customer_name text not null default '',
  customer_phone text not null default '',
  delivery_address text not null default '',
  status text not null default 'open' check (status in ('open','closed','cancelled')),
  subtotal numeric(14,2) not null default 0 check (subtotal>=0),
  discount_type text not null default 'none' check (discount_type in ('none','percent','fixed')),
  discount_value numeric(14,2) not null default 0 check (discount_value>=0),
  discount_amount numeric(14,2) not null default 0 check (discount_amount>=0),
  total_amount numeric(14,2) not null default 0 check (total_amount>=0),
  created_by uuid references auth.users(id) on delete set null,
  closed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  unique(branch_id,order_number),
  check ((service_type='dine_in' and table_number is not null) or (service_type<>'dine_in' and table_number is null))
);
create unique index if not exists branch_one_open_order_per_table
  on public.branch_orders(branch_id,table_number) where status='open' and service_type='dine_in';
create index if not exists branch_orders_history_idx
  on public.branch_orders(branch_id,created_at desc);

create table if not exists public.branch_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.branch_orders(id) on delete cascade,
  menu_item_id uuid references public.branch_menu_items(id) on delete set null,
  item_name text not null,
  unit_label text not null,
  quantity numeric(12,3) not null check (quantity>0),
  unit_price numeric(12,2) not null check (unit_price>=0),
  line_total numeric(14,2) not null check (line_total>=0),
  created_at timestamptz not null default now()
);
create index if not exists branch_order_items_order_idx on public.branch_order_items(order_id);

create table if not exists public.branch_order_payments (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  order_id uuid not null references public.branch_orders(id) on delete cascade,
  account_id uuid not null references public.branch_accounts(id) on delete restrict,
  payment_method text not null check (payment_method in ('cash','card','online')),
  amount numeric(14,2) not null check (amount>0),
  created_at timestamptz not null default now()
);
create index if not exists branch_order_payments_order_idx on public.branch_order_payments(order_id);

insert into public.branch_accounts(branch_id,name,account_type,is_system)
select b.id,b.name||' Cash in hand','cash',true from public.branches b
on conflict(branch_id,account_type) where account_type in ('cash','card','online') and is_system do nothing;
insert into public.branch_accounts(branch_id,name,account_type,is_system)
select b.id,b.name||' Card payments','card',true from public.branches b
on conflict(branch_id,account_type) where account_type in ('cash','card','online') and is_system do nothing;
insert into public.branch_accounts(branch_id,name,account_type,is_system)
select b.id,b.name||' Online payments','online',true from public.branches b
on conflict(branch_id,account_type) where account_type in ('cash','card','online') and is_system do nothing;

create or replace function public.seed_branch_payment_accounts()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  insert into public.branch_accounts(branch_id,name,account_type,is_system) values
    (new.id,new.name||' Cash in hand','cash',true),
    (new.id,new.name||' Card payments','card',true),
    (new.id,new.name||' Online payments','online',true)
  on conflict do nothing;
  return new;
end;
$$;
drop trigger if exists add_branch_payment_accounts on public.branches;
create trigger add_branch_payment_accounts after insert on public.branches
for each row execute function public.seed_branch_payment_accounts();

alter table public.branch_accounts enable row level security;
alter table public.branch_account_transactions enable row level security;
alter table public.branch_orders enable row level security;
alter table public.branch_order_items enable row level security;
alter table public.branch_order_payments enable row level security;

drop policy if exists "branch accounts read" on public.branch_accounts;
create policy "branch accounts read" on public.branch_accounts for select to authenticated using (public.has_branch_access(branch_id));
drop policy if exists "branch account managers" on public.branch_accounts;
create policy "branch account managers" on public.branch_accounts for all to authenticated
  using (public.can_manage_branch(branch_id)) with check (public.can_manage_branch(branch_id));
drop policy if exists "branch account transactions read" on public.branch_account_transactions;
create policy "branch account transactions read" on public.branch_account_transactions for select to authenticated using (public.has_branch_access(branch_id));
drop policy if exists "branch account transactions managers" on public.branch_account_transactions;
create policy "branch account transactions managers" on public.branch_account_transactions for all to authenticated
  using (public.can_manage_branch(branch_id)) with check (public.can_manage_branch(branch_id));
drop policy if exists "branch orders access" on public.branch_orders;
drop policy if exists "branch orders read" on public.branch_orders;
create policy "branch orders read" on public.branch_orders for select to authenticated
  using (public.has_branch_access(branch_id));
drop policy if exists "branch order items access" on public.branch_order_items;
drop policy if exists "branch order items read" on public.branch_order_items;
create policy "branch order items read" on public.branch_order_items for select to authenticated
  using (exists(select 1 from public.branch_orders o where o.id=order_id and public.has_branch_access(o.branch_id)));
drop policy if exists "branch order payments access" on public.branch_order_payments;
drop policy if exists "branch order payments read" on public.branch_order_payments;
create policy "branch order payments read" on public.branch_order_payments for select to authenticated
  using (public.has_branch_access(branch_id));
grant select,insert,update,delete on public.branch_accounts to authenticated;
grant select on public.branch_account_transactions,public.branch_orders,public.branch_order_items,public.branch_order_payments to authenticated;

create or replace function public.create_branch_order(
  p_branch_id uuid,
  p_service_type text,
  p_table_number integer,
  p_customer_name text,
  p_customer_phone text,
  p_delivery_address text,
  p_items jsonb
) returns uuid language plpgsql security definer set search_path=public
as $$
declare
  v_order_id uuid;
  v_order_number text;
  v_seats integer;
  v_item jsonb;
  v_menu public.branch_menu_items%rowtype;
  v_qty numeric(12,3);
  v_subtotal numeric(14,2):=0;
begin
  if auth.uid() is null or not public.has_branch_access(p_branch_id) then raise exception using message='You do not have access to this branch.'; end if;
  if p_service_type not in ('dine_in','takeaway','delivery') then raise exception using message='Choose dine-in, takeaway, or delivery.'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception using message='Add at least one menu item.'; end if;
  select dine_in_seats into v_seats from public.branches where id=p_branch_id and is_active;
  if not found then raise exception using message='Branch not found or inactive.'; end if;
  if p_service_type='dine_in' and (p_table_number is null or p_table_number<1 or p_table_number>v_seats) then
    raise exception using message='Choose a valid dine-in table for this branch.';
  end if;
  if p_service_type<>'dine_in' and p_table_number is not null then raise exception using message='Tables are only used for dine-in orders.'; end if;
  if p_service_type='delivery' and coalesce(trim(p_delivery_address),'')='' then raise exception using message='Enter the delivery address.'; end if;

  v_order_number:='KN-'||to_char(timezone('Asia/Karachi',now()),'YYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,5));
  insert into public.branch_orders(branch_id,order_number,service_type,table_number,customer_name,customer_phone,delivery_address,created_by)
    values(p_branch_id,v_order_number,p_service_type,p_table_number,coalesce(trim(p_customer_name),''),coalesce(trim(p_customer_phone),''),coalesce(trim(p_delivery_address),''),auth.uid())
    returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty:=nullif(v_item->>'quantity','')::numeric;
    if v_qty is null or v_qty<=0 then raise exception using message='Enter a valid quantity for every item.'; end if;
    select * into v_menu from public.branch_menu_items
      where id=(v_item->>'menu_item_id')::uuid and branch_id=p_branch_id and is_available;
    if not found then raise exception using message='A menu item is unavailable or does not belong to this branch.'; end if;
    insert into public.branch_order_items(order_id,menu_item_id,item_name,unit_label,quantity,unit_price,line_total)
      values(v_order_id,v_menu.id,v_menu.name,v_menu.unit_label,v_qty,v_menu.sale_price,round(v_qty*v_menu.sale_price,2));
    v_subtotal:=v_subtotal+round(v_qty*v_menu.sale_price,2);
  end loop;
  update public.branch_orders set subtotal=v_subtotal,total_amount=v_subtotal where id=v_order_id;
  return v_order_id;
end;
$$;

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

  -- Check and lock all connected inventory before making any stock changes.
  for v_need in
    select bi.id as inventory_id,bi.name,bi.unit,sum(oi.quantity) as quantity
    from public.branch_order_items oi
    join public.branch_menu_items mi on mi.id=oi.menu_item_id
    join public.branch_inventory_items bi on bi.menu_item_id=mi.id and bi.is_active
    where oi.order_id=p_order_id
    group by bi.id,bi.name,bi.unit
    order by bi.id
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
    where oi.order_id=p_order_id
    group by bi.id,bi.name,bi.unit
    order by bi.id
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
    select * into v_account from public.branch_accounts
      where branch_id=v_order.branch_id and account_type=v_method and is_system and is_active for update;
    if not found then raise exception using message='A default payment account is missing for this branch.'; end if;
    v_next_balance:=v_account.current_balance+v_amount;
    update public.branch_accounts set current_balance=v_next_balance where id=v_account.id;
    insert into public.branch_order_payments(branch_id,order_id,account_id,payment_method,amount)
      values(v_order.branch_id,p_order_id,v_account.id,v_method,v_amount);
    v_index:=v_index+1;
    insert into public.branch_account_transactions(branch_id,account_id,transaction_type,amount,balance_after,description,source_reference,created_by)
      values(v_order.branch_id,v_account.id,'sale',v_amount,v_next_balance,
        'Bill '||v_order.order_number,'branch-order:'||p_order_id::text||':'||v_index,auth.uid());
  end loop;
  return p_order_id;
end;
$$;

revoke all on function public.create_branch_order(uuid,text,integer,text,text,text,jsonb) from public,anon;
revoke all on function public.close_branch_order(uuid,text,numeric,jsonb) from public,anon;
grant execute on function public.create_branch_order(uuid,text,integer,text,text,text,jsonb) to authenticated;
grant execute on function public.close_branch_order(uuid,text,numeric,jsonb) to authenticated;

