-- Run after accounts.sql to allow safe deletion or archival of accounts.
create or replace function public.delete_financial_account(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.financial_accounts%rowtype;
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to delete accounts.'; end if;
  select * into a from public.financial_accounts where id = p_account_id for update;
  if not found then raise exception using message = 'Account not found.'; end if;
  if a.current_balance <> 0 then raise exception using message = 'Transfer or subtract the remaining balance before deleting this account.'; end if;
  if exists (select 1 from public.account_transactions where account_id = p_account_id or counter_account_id = p_account_id) then
    raise exception using message = 'This account has financial history. Archive it to preserve its records.';
  end if;
  delete from public.financial_accounts where id = p_account_id;
end;
$$;

create or replace function public.archive_financial_account(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.financial_accounts%rowtype;
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to archive accounts.'; end if;
  select * into a from public.financial_accounts where id = p_account_id for update;
  if not found then raise exception using message = 'Account not found.'; end if;
  if a.current_balance <> 0 then raise exception using message = 'Transfer or subtract the remaining balance before archiving this account.'; end if;
  update public.financial_accounts set is_active = false, is_system = false where id = p_account_id;
end;
$$;

create or replace function public.restore_financial_account(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception using message = 'Kitchen access is required to restore accounts.'; end if;
  update public.financial_accounts set is_active = true where id = p_account_id;
  if not found then raise exception using message = 'Account not found.'; end if;
end;
$$;

revoke all on function public.delete_financial_account(uuid) from public, anon;
revoke all on function public.archive_financial_account(uuid) from public, anon;
revoke all on function public.restore_financial_account(uuid) from public, anon;
grant execute on function public.delete_financial_account(uuid) to authenticated;
grant execute on function public.archive_financial_account(uuid) to authenticated;
grant execute on function public.restore_financial_account(uuid) to authenticated;
