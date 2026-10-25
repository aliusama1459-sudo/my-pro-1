-- Run after branches.sql. Adds basic branch settings used by the branch workspace.
alter table public.branches
  add column if not exists dine_in_seats integer not null default 0
    check (dine_in_seats >= 0);

drop function if exists public.create_branch_with_sales_account(text, text);
create function public.create_branch_with_sales_account(
  p_name text,
  p_address text default '',
  p_dine_in_seats integer default 0
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  branch_id uuid;
  clean_name text := trim(coalesce(p_name, ''));
begin
  if auth.uid() is null or not public.has_kitchen_access() then
    raise exception using message = 'Kitchen access is required to create branches.';
  end if;
  if clean_name = '' then raise exception using message = 'Enter a branch name.'; end if;
  if p_dine_in_seats is null or p_dine_in_seats < 0 then
    raise exception using message = 'Table count cannot be less than zero.';
  end if;
  insert into public.branches(name, address, dine_in_seats)
    values (clean_name, coalesce(trim(p_address), ''), p_dine_in_seats)
    returning id into branch_id;
  insert into public.financial_accounts(name, account_type, linked_branch_name, linked_branch_id, is_system)
    values (clean_name || ' Branch Sales', 'branch_sales', clean_name, branch_id, true);
  return branch_id;
end;
$$;

create or replace function public.update_branch_details(
  p_branch_id uuid,
  p_name text,
  p_address text default '',
  p_dine_in_seats integer default 0
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  old_name text;
  clean_name text := trim(coalesce(p_name, ''));
begin
  if auth.uid() is null or not public.has_kitchen_access() then
    raise exception using message = 'Kitchen access is required to update branch settings.';
  end if;
  if clean_name = '' then raise exception using message = 'Enter a branch name.'; end if;
  if p_dine_in_seats is null or p_dine_in_seats < 0 then
    raise exception using message = 'Table count cannot be less than zero.';
  end if;

  select name into old_name from public.branches where id = p_branch_id and is_active for update;
  if old_name is null then raise exception using message = 'Branch not found or inactive.'; end if;

  update public.branches
    set name = clean_name,
        address = coalesce(trim(p_address), ''),
        dine_in_seats = p_dine_in_seats
    where id = p_branch_id;

  if old_name <> clean_name then
    update public.financial_accounts
      set name = clean_name || ' Branch Sales', linked_branch_name = clean_name
      where linked_branch_id = p_branch_id and account_type = 'branch_sales';
    update public.dispatches set branch_name = clean_name where branch_name = old_name;
  end if;
end;
$$;

revoke all on function public.create_branch_with_sales_account(text, text, integer) from public, anon;
grant execute on function public.create_branch_with_sales_account(text, text, integer) to authenticated;
revoke all on function public.update_branch_details(uuid, text, text, integer) from public, anon;
grant execute on function public.update_branch_details(uuid, text, text, integer) to authenticated;
