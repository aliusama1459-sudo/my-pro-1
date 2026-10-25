-- Run after inventory_history.sql. Keeps non-food kitchen supplies out of recipes.
alter table public.ingredients
  add column if not exists item_type text not null default 'ingredient';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ingredients_item_type_check') then
    alter table public.ingredients add constraint ingredients_item_type_check check (item_type in ('ingredient', 'supply'));
  end if;
end;
$$;

create or replace function public.require_recipe_ingredient_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.ingredients where id = new.ingredient_id and item_type = 'ingredient') then
    raise exception 'Recipes can only use items marked as recipe ingredients.';
  end if;
  return new;
end;
$$;

drop trigger if exists recipe_ingredients_only_food on public.recipe_ingredients;
create trigger recipe_ingredients_only_food
before insert or update of ingredient_id on public.recipe_ingredients
for each row execute procedure public.require_recipe_ingredient_item();

revoke all on function public.require_recipe_ingredient_item() from public, anon;
