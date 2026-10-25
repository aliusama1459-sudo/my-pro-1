-- Staff account security: branch managers get their assigned branch; waiters get POS and order history only.
-- Run this once in the Supabase SQL editor before deploying manage-staff.

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('owner','kitchen_manager','branch_manager','waiter','cashier'));

create or replace function public.has_branch_access(p_branch_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and (p.role in ('owner','kitchen_manager') or p.branch_id = p_branch_id)
  );
$$;

create or replace function public.can_manage_branch(p_branch_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select public.has_kitchen_access() or exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'branch_manager' and p.branch_id = p_branch_id
  );
$$;

-- Keep payments/orders available to assigned branch staff for POS and order history,
-- while limiting financial, expense, and stock movement details to managers.
drop policy if exists "branch inventory items read" on public.branch_inventory_items;
create policy "branch inventory managers and POS read" on public.branch_inventory_items for select to authenticated
  using (public.can_manage_branch(branch_id) or (menu_item_id is not null and public.has_branch_access(branch_id)));

drop policy if exists "branch accounts read" on public.branch_accounts;
create policy "branch accounts managers read" on public.branch_accounts for select to authenticated
  using (public.can_manage_branch(branch_id));
drop policy if exists "branch account transactions read" on public.branch_account_transactions;
create policy "branch account transactions managers read" on public.branch_account_transactions for select to authenticated
  using (public.can_manage_branch(branch_id));
drop policy if exists "branch expenses read" on public.branch_expenses;
create policy "branch expenses managers read" on public.branch_expenses for select to authenticated
  using (public.can_manage_branch(branch_id));
drop policy if exists "branch stock movements read" on public.branch_stock_movements;
create policy "branch stock movements managers read" on public.branch_stock_movements for select to authenticated
  using (public.can_manage_branch(branch_id));

revoke all on function public.has_branch_access(uuid) from public, anon;
grant execute on function public.has_branch_access(uuid) to authenticated;
revoke all on function public.can_manage_branch(uuid) from public, anon;
grant execute on function public.can_manage_branch(uuid) to authenticated;
