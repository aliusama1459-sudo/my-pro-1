import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
});
const allowedTabs = [
  "branch_dashboard", "branch_menu", "branch_pos", "branch_order_history",
  "branch_accounts", "branch_expenses", "branch_inventory", "branch_reports",
  "branch_account_history",
];
const roleDefaults: Record<string, string[]> = {
  branch_manager: allowedTabs,
  waiter: ["branch_pos", "branch_order_history"],
  cashier: ["branch_pos", "branch_order_history", "branch_accounts"],
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Use POST for staff management." }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ error: "Staff management is not configured on the server." }, 500);

  const authorization = request.headers.get("Authorization");
  if (!authorization) return json({ error: "Sign in as the owner to manage staff." }, 401);
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const admin = createClient(url, serviceKey);
  const { data: authData, error: authError } = await caller.auth.getUser();
  if (authError || !authData.user) return json({ error: "Your sign-in session has expired. Please sign in again." }, 401);

  const { data: ownerProfile, error: ownerError } = await admin
    .from("profiles").select("role").eq("id", authData.user.id).maybeSingle();
  if (ownerError || ownerProfile?.role !== "owner") return json({ error: "Only the kitchen owner can manage staff accounts." }, 403);

  let body: Record<string, unknown>;
  try { body = await request.json(); } catch { return json({ error: "Invalid request." }, 400); }

  if (body.action === "list") {
    const [{ data: profiles, error: profileError }, { data: authUsers, error: usersError }] = await Promise.all([
      admin.from("profiles").select("id,full_name,role,branch_id,branch_permissions,created_at").order("created_at", { ascending: false }),
      admin.auth.admin.listUsers({ page: 1, perPage: 1000 }),
    ]);
    if (profileError || usersError) return json({ error: profileError?.message || usersError?.message || "Could not load staff." }, 500);
    const emailById = new Map((authUsers?.users || []).map((u) => [u.id, u.email || ""]));
    const { data: branches, error: branchError } = await admin.from("branches").select("id,name,is_active").order("name");
    if (branchError) return json({ error: branchError.message }, 500);
    return json({ staff: (profiles || []).map((p) => ({ ...p, email: emailById.get(p.id) || "" })), branches: branches || [] });
  }

  if (body.action !== "create") return json({ error: "Choose a supported staff action." }, 400);
  const fullName = String(body.full_name || "").trim();
  const email = String(body.email || "").trim().toLowerCase();
  const password = String(body.password || "");
  const role = String(body.role || "");
  const branchId = String(body.branch_id || "");
  if (!fullName || !email || !password || !branchId) return json({ error: "Enter a name, email, password, role, and branch." }, 400);
  if (password.length < 8) return json({ error: "Use a password with at least 8 characters." }, 400);
  if (!Object.hasOwn(roleDefaults, role)) return json({ error: "Choose a supported branch designation." }, 400);
  const selectedTabs = Array.isArray(body.permissions)
    ? body.permissions.filter((tab): tab is string => typeof tab === "string" && allowedTabs.includes(tab))
    : roleDefaults[role];
  const permissions = role === "branch_manager" ? allowedTabs : selectedTabs;
  if (!permissions.length) return json({ error: "Select at least one branch tab for this staff member." }, 400);

  const { data: branch, error: branchError } = await admin.from("branches")
    .select("id").eq("id", branchId).eq("is_active", true).maybeSingle();
  if (branchError || !branch) return json({ error: "Choose an active branch." }, 400);

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: fullName },
  });
  if (createError || !created.user) return json({ error: createError?.message || "Could not create the sign-in account." }, 400);

  const { error: profileError } = await admin.from("profiles").upsert({
    id: created.user.id,
    full_name: fullName,
    role,
    branch_id: branchId,
    branch_permissions: permissions,
  });
  if (profileError) {
    await admin.auth.admin.deleteUser(created.user.id);
    return json({ error: `Account setup failed: ${profileError.message}` }, 500);
  }
  return json({ staff: { id: created.user.id, email, full_name: fullName, role, branch_id: branchId, branch_permissions: permissions } }, 201);
});
