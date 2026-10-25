# Karachi Nasheman Kitchen

The first application section covers kitchen ingredients, recipe costing, dispatches, stock and date-filtered kitchen reports. The web app is responsive and includes install metadata for phones and desktop browsers.

## Run it on your computer

1. Install the current Node.js LTS release if it is not already installed.
2. Open this folder in VS Code.
3. Open **Terminal → New Terminal** and run `npm install`.
4. Run `npm run dev` and open the local address shown in the terminal.

Without Supabase credentials, the site opens in Preview mode with example kitchen data. Preview changes are temporary and reset when the page reloads.

## Connect Supabase

1. Create a Supabase project and keep its database password private.
2. In the Supabase project, open **SQL Editor → New query**. Open `supabase/schema.sql` in VS Code, copy all of it into the query, and click **Run**. It creates the kitchen tables and an atomic dispatch function.
3. Before adding staff, create another SQL query with the contents of `supabase/access_control.sql` and click **Run**. This promotes the existing first account to owner and replaces the initial kitchen policies with role-aware rules. It assumes your account is currently the only Supabase Auth user. Future accounts default to waiter with no branch access until an owner assigns them.
4. To track opening stock, stock additions, adjustments, and dispatch use by date, run `supabase/inventory_history.sql` in a new SQL Editor query.
5. To distinguish food ingredients from general supplies such as cleaning items, run `supabase/inventory_item_types.sql` in a new SQL Editor query. General supplies remain in inventory but are excluded from recipe ingredient choices.
6. To record inventory changes by reason (used, wasted, missing, or restocked), run `supabase/inventory_adjustments.sql` in a new SQL Editor query.
7. To save catering quotations, run `supabase/catering_quotes.sql` in a new SQL Editor query.
8. To dispatch a saved catering quote and deduct its ingredient stock, run `supabase/catering_dispatch.sql` in a new SQL Editor query.
9. To add percentage or fixed discounts and issue a bill after a catering dispatch, run `supabase/catering_discount_bill.sql` in a new SQL Editor query.
10. To add a final discount before closing a dispatched bill, run `supabase/catering_bill_closing.sql` in a new SQL Editor query.
11. To add accounts, transfers, and account history, run `supabase/accounts.sql` in a new SQL Editor query.
12. To add a closed catering bill to the Catering Payments account automatically, run `supabase/catering_bill_account_posting.sql` in a new SQL Editor query.
13. To delete empty accounts or archive accounts with history, run `supabase/account_deletion.sql` in a new SQL Editor query.
14. To manage branches and automatically create a linked Branch Sales account for each new branch, run `supabase/branches.sql` in a new SQL Editor query.
15. To add branch addresses and dine-in table counts, run `supabase/branch_setup.sql` in a new SQL Editor query.
16. To add branch-specific menus and inventory ledgers, run `supabase/branch_menu_inventory.sql` in a new SQL Editor query.
17. To create separate branch inventory items with optional menu links, run `supabase/branch_inventory_items.sql` in a new SQL Editor query.
18. To enable branch POS orders, payment splits, stock deductions, and branch payment accounts, run `supabase/branch_pos.sql` in a new SQL Editor query.
19. To combine card and online receipts into each branch’s Bank payments account, run `supabase/branch_payment_accounts.sql` in a new SQL Editor query.
20. To manage custom branch accounts, adjustments, transfers, and daily expenses, run `supabase/branch_account_management.sql` in a new SQL Editor query.
21. To mirror each branch's active Cash in hand + Bank payments balance into the matching kitchen Branch Sales account, including after expenses and manual account adjustments, run `supabase/branch_cash_bank_balance_mirror.sql` in a new SQL Editor query. This also reconciles existing balances and replaces the earlier closed-bill-only sync if it was installed.
21. Open **Project Settings → API**. Copy the Project URL and the publishable key (older projects may label it `anon`/`public`). Never use or share the `service_role` secret in this web app.
22. In this folder, copy `.env.example` to a new file named `.env`. Replace the example values with your Project URL and publishable key. Keep `.env` private; it is excluded by `.gitignore`.
23. In Supabase, open **Authentication → Users → Add user** and create the first kitchen staff email and password. The access control migration gives the initial account the owner role.
24. Stop and restart the local app with `npm run dev`. Sign in with that staff account. The top right indicator should say **Supabase connected**.

After a Supabase project is connected, add ingredients and recipes in the app. They will be saved in that project. Dispatches are recorded with their ingredient usage and deduct all required stock in one database transaction; if stock is insufficient, the dispatch is rejected without partial deductions. Branch POS, waiter order history, and branch-scoped access are planned for the next sections; create their role accounts only after those screens and access rules are in place.

## Install on a phone or computer

For a proper install link, the app must be hosted on an HTTPS site. Android and desktop users can use the browser's **Install app** command. On iPhone, open the site in Safari, tap **Share → Add to Home Screen**. The Supabase project must be online for shared data and sign-in.

## Current scope

Kitchen management is the first milestone. Branch records and linked sales accounts are now available; branch sales entry and cross-branch reporting will be added with the branch POS section. Recipe batch scaling assumes that ingredient amounts scale proportionally from the saved standard batch. Ingredient cost is an estimate based on the current unit price.
