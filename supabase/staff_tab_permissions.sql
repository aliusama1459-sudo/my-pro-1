-- Per-staff branch tab access. Run after staff_access_security.sql.
alter table public.profiles
  add column if not exists branch_permissions text[] not null
  default array['branch_pos','branch_order_history']::text[];

create or replace function public.has_branch_tab_access(p_branch_id uuid, p_tab text)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and (
        p.role in ('owner','kitchen_manager')
        or (p.branch_id = p_branch_id and p.role = 'branch_manager')
        or (p.branch_id = p_branch_id and p_tab = any(coalesce(p.branch_permissions, array[]::text[])))
      )
  );
$$;

-- Menu data is needed in both Menu and POS.
drop policy if exists "branch sections read" on public.branch_menu_sections;
create policy "branch sections read" on public.branch_menu_sections for select to authenticated
  using (public.has_branch_tab_access(branch_id,'branch_menu') or public.has_branch_tab_access(branch_id,'branch_pos'));
drop policy if exists "branch menu read" on public.branch_menu_items;
create policy "branch menu read" on public.branch_menu_items for select to authenticated
  using (public.has_branch_tab_access(branch_id,'branch_menu') or public.has_branch_tab_access(branch_id,'branch_pos'));

-- POS staff can see only menu-linked stock needed to take orders.
drop policy if exists "branch inventory managers and POS read" on public.branch_inventory_items;
create policy "branch inventory managers and POS read" on public.branch_inventory_items for select to authenticated
  using (
    public.has_branch_tab_access(branch_id,'branch_inventory')
    or (menu_item_id is not null and public.has_branch_tab_access(branch_id,'branch_menu'))
    or (menu_item_id is not null and public.has_branch_tab_access(branch_id,'branch_pos'))
  );
drop policy if exists "branch inventory read" on public.branch_inventory;
create policy "branch inventory read" on public.branch_inventory for select to authenticated
  using (exists (
    select 1 from public.branch_menu_items m where m.id=menu_item_id
      and (public.has_branch_tab_access(m.branch_id,'branch_inventory') or public.has_branch_tab_access(m.branch_id,'branch_pos'))
  ));
drop policy if exists "branch stock movements managers read" on public.branch_stock_movements;
drop policy if exists "branch stock movements read" on public.branch_stock_movements;
create policy "branch stock movements read" on public.branch_stock_movements for select to authenticated
  using (public.has_branch_tab_access(branch_id,'branch_inventory'));
drop policy if exists "branch inventory movements read" on public.branch_inventory_movements;
create policy "branch inventory movements read" on public.branch_inventory_movements for select to authenticated
  using (public.has_branch_tab_access(branch_id,'branch_inventory'));

-- Financial and expense data is returned only when the corresponding tabs are assigned.
drop policy if exists "branch accounts managers read" on public.branch_accounts;
drop policy if exists "branch accounts read" on public.branch_accounts;
create policy "branch accounts read" on public.branch_accounts for select to authenticated
  using (
    public.has_branch_tab_access(branch_id,'branch_accounts')
    or public.has_branch_tab_access(branch_id,'branch_account_history')
    or public.has_branch_tab_access(branch_id,'branch_expenses')
    or public.has_branch_tab_access(branch_id,'branch_reports')
  );
drop policy if exists "branch account transactions managers read" on public.branch_account_transactions;
drop policy if exists "branch account transactions read" on public.branch_account_transactions;
create policy "branch account transactions read" on public.branch_account_transactions for select to authenticated
  using (
    public.has_branch_tab_access(branch_id,'branch_accounts')
    or public.has_branch_tab_access(branch_id,'branch_account_history')
    or public.has_branch_tab_access(branch_id,'branch_reports')
  );
drop policy if exists "branch expenses managers read" on public.branch_expenses;
drop policy if exists "branch expenses read" on public.branch_expenses;
create policy "branch expenses read" on public.branch_expenses for select to authenticated
  using (
    public.has_branch_tab_access(branch_id,'branch_expenses')
    or public.has_branch_tab_access(branch_id,'branch_reports')
    or public.has_branch_tab_access(branch_id,'branch_dashboard')
  );

-- Order data is limited to tabs that need it: dashboard, POS, history, or reports.
drop policy if exists "branch orders read" on public.branch_orders;
create policy "branch orders read" on public.branch_orders for select to authenticated
  using (
    public.has_branch_tab_access(branch_id,'branch_dashboard')
    or public.has_branch_tab_access(branch_id,'branch_pos')
    or public.has_branch_tab_access(branch_id,'branch_order_history')
    or public.has_branch_tab_access(branch_id,'branch_reports')
  );
drop policy if exists "branch order items read" on public.branch_order_items;
create policy "branch order items read" on public.branch_order_items for select to authenticated
  using (exists (
    select 1 from public.branch_orders o where o.id=order_id and (
      public.has_branch_tab_access(o.branch_id,'branch_dashboard')
      or public.has_branch_tab_access(o.branch_id,'branch_pos')
      or public.has_branch_tab_access(o.branch_id,'branch_order_history')
      or public.has_branch_tab_access(o.branch_id,'branch_reports')
    )
  ));
drop policy if exists "branch order payments read" on public.branch_order_payments;
create policy "branch order payments read" on public.branch_order_payments for select to authenticated
  using (
    public.has_branch_tab_access(branch_id,'branch_pos')
    or public.has_branch_tab_access(branch_id,'branch_order_history')
    or public.has_branch_tab_access(branch_id,'branch_reports')
  );

-- SECURITY DEFINER POS RPCs must also honor a staff member's POS tab grant.
create or replace function public.require_branch_pos_tab()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if auth.uid() is null or not public.has_branch_tab_access(new.branch_id,'branch_pos') then
    raise exception using message='Order taking access is not assigned for this branch.';
  end if;
  return new;
end;
$$;
drop trigger if exists require_branch_pos_tab on public.branch_orders;
create trigger require_branch_pos_tab
  before insert or update of status on public.branch_orders
  for each row execute function public.require_branch_pos_tab();

revoke all on function public.has_branch_tab_access(uuid,text) from public, anon;
grant execute on function public.has_branch_tab_access(uuid,text) to authenticated;
revoke all on function public.require_branch_pos_tab() from public, anon;
