import React, { useEffect, useState } from 'react';
import { Check, LoaderCircle, ShieldCheck, UserPlus, Users } from 'lucide-react';
import { supabase } from './supabase';

const roleLabels = { owner: 'Owner', kitchen_manager: 'Kitchen manager', branch_manager: 'Branch manager', waiter: 'Waiter', cashier: 'Cashier' };
const branchTabs = [
  ['branch_dashboard', 'Branch overview'], ['branch_menu', 'Menu'], ['branch_pos', 'Order taking POS'],
  ['branch_order_history', 'Order history'], ['branch_accounts', 'Accounts'], ['branch_expenses', 'Expenses'],
  ['branch_inventory', 'Inventory'], ['branch_reports', 'Reports'], ['branch_account_history', 'Account history'],
];
const tabIds = branchTabs.map(([id]) => id);
const defaultPermissions = {
  branch_manager: tabIds,
  waiter: ['branch_pos', 'branch_order_history'],
  cashier: ['branch_pos', 'branch_order_history', 'branch_accounts'],
};

export default function StaffAccessPage({ branches }) {
  const [staff, setStaff] = useState([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');
  const [form, setForm] = useState({ full_name: '', email: '', password: '', role: 'waiter', branch_id: branches[0]?.id || '', permissions: defaultPermissions.waiter });
  const set = (key, value) => setForm((current) => ({ ...current, [key]: value }));

  async function loadStaff() {
    setLoading(true);
    setError('');
    const { data, error: invokeError } = await supabase.functions.invoke('manage-staff', { body: { action: 'list' } });
    if (invokeError) setError(invokeError.message || 'Could not load staff.');
    else setStaff(data?.staff || []);
    setLoading(false);
  }
  useEffect(() => { loadStaff(); }, []);
  useEffect(() => { if (!form.branch_id && branches[0]?.id) set('branch_id', branches[0].id); }, [branches]);

  function changeRole(role) {
    setForm((current) => ({ ...current, role, permissions: defaultPermissions[role] || defaultPermissions.waiter }));
  }
  function togglePermission(permission) {
    setForm((current) => {
      const permissions = current.permissions.includes(permission)
        ? current.permissions.filter((item) => item !== permission)
        : [...current.permissions, permission];
      return { ...current, permissions };
    });
  }

  async function createStaff(event) {
    event.preventDefault();
    setSaving(true);
    setError('');
    setNotice('');
    const { data, error: invokeError } = await supabase.functions.invoke('manage-staff', { body: { action: 'create', ...form } });
    if (invokeError) {
      const detail = invokeError.context?.json ? await invokeError.context.json().catch(() => null) : null;
      setError(detail?.error || invokeError.message || 'Could not create this staff account.');
    } else {
      setNotice(`${form.full_name} can now sign in with the email and password you set.`);
      setForm((current) => ({ ...current, full_name: '', email: '', password: '' }));
      await loadStaff();
    }
    setSaving(false);
  }

  return <div className="staff-access-page">
    <section className="staff-access-hero"><div className="staff-access-icon"><ShieldCheck size={22}/></div><div><span>STAFF & ACCESS</span><h2>Manage staff accounts</h2><p>Create a sign-in, assign a branch, and choose which tabs each designation can open.</p></div></section>
    <div className="staff-access-grid">
      <section className="panel staff-create-panel"><div className="staff-panel-heading"><div><UserPlus size={19}/></div><section><h3>Add a staff member</h3><p>Passwords are used only to create the account and are not shown later.</p></section></div>
        <form onSubmit={createStaff} className="staff-create-form">
          <label className="field"><span>Full name</span><input className="input" value={form.full_name} onChange={(e) => set('full_name', e.target.value)} autoComplete="name" required maxLength={100}/></label>
          <label className="field"><span>Sign-in ID (email)</span><input className="input" type="email" value={form.email} onChange={(e) => set('email', e.target.value)} autoComplete="off" required/></label>
          <label className="field"><span>Temporary password</span><input className="input" type="password" value={form.password} onChange={(e) => set('password', e.target.value)} autoComplete="new-password" minLength={8} required/><small>At least 8 characters. Give it to the staff member privately.</small></label>
          <label className="field"><span>Designation</span><select className="input" value={form.role} onChange={(e) => changeRole(e.target.value)}><option value="branch_manager">Branch manager</option><option value="cashier">Cashier</option><option value="waiter">Waiter</option></select></label>
          <label className="field"><span>Assigned branch</span><select className="input" value={form.branch_id} onChange={(e) => set('branch_id', e.target.value)} required><option value="" disabled>Choose a branch</option>{branches.map((branch) => <option key={branch.id} value={branch.id}>{branch.name}</option>)}</select></label>
          <fieldset className="staff-permissions"><legend>Tabs this person can open</legend><p>{form.role === 'branch_manager' ? 'Branch managers have access to every tab.' : 'Choose the tabs this staff member can open. Only branch managers can edit menus, stock, accounts, or expenses. POS access allows taking and closing orders.'}</p><div className="staff-permission-list">{branchTabs.map(([id, label]) => <label className="staff-permission-option" key={id}><input type="checkbox" checked={form.permissions.includes(id)} disabled={form.role === 'branch_manager'} onChange={() => togglePermission(id)}/><span>{label}</span></label>)}</div></fieldset>
          {error && <div className="inline-alert staff-error">{error}</div>}{notice && <div className="staff-success"><Check size={16}/>{notice}</div>}
          <button className="btn btn-primary staff-submit" disabled={saving || !branches.length || !form.permissions.length}>{saving ? <><LoaderCircle size={16} className="staff-spinner"/> Creating account...</> : <><UserPlus size={16}/> Create staff account</>}</button>
        </form>
      </section>
      <section className="panel staff-list-panel"><div className="staff-panel-heading"><div><Users size={19}/></div><section><h3>Staff accounts</h3><p>Branch, designation, and tab access</p></section><button type="button" className="btn btn-soft staff-refresh" onClick={loadStaff}>Refresh</button></div>
        {loading ? <div className="staff-empty"><LoaderCircle size={18} className="staff-spinner"/> Loading staff...</div> : staff.length ? <div className="staff-list">{staff.map((person) => <article className="staff-card" key={person.id}><div className="staff-person-avatar">{(person.full_name || person.email || 'S').slice(0,1).toUpperCase()}</div><div className="staff-person-main"><strong>{person.full_name || 'Staff member'}</strong><span>{person.email || person.id}</span><small>{branches.find((b) => b.id === person.branch_id)?.name || (person.role === 'owner' || person.role === 'kitchen_manager' ? 'Kitchen access' : 'Branch not assigned')} · {(person.branch_permissions || []).length} tabs</small></div><span className={`staff-role-badge role-${person.role}`}>{roleLabels[person.role] || person.role}</span></article>)}</div> : <div className="staff-empty"><Users size={22}/><b>No staff accounts listed</b><span>Create branch staff accounts using the form.</span></div>}
      </section>
    </div>
  </div>;
}

