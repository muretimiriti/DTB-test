import React, { useState } from 'react';
import { accountService } from '../services/api';

const INITIAL = { firstName: '', lastName: '', email: '', phone: '', pin: '', confirmPin: '', initialDeposit: '' };

export default function CreateAccount({ onSuccess, onBack }) {
  const [form, setForm] = useState(INITIAL);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');

  const update = (field) => (e) => setForm((f) => ({ ...f, [field]: e.target.value }));

  const validate = () => {
    if (form.firstName.trim().length < 2) return 'First name must be at least 2 characters';
    if (form.lastName.trim().length < 2) return 'Last name must be at least 2 characters';
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(form.email)) return 'Invalid email address';
    if (!/^\+?[1-9]\d{6,14}$/.test(form.phone)) return 'Invalid phone number (e.g. +254700000000)';
    if (!/^\d{4,6}$/.test(form.pin)) return 'PIN must be 4-6 digits';
    if (form.pin !== form.confirmPin) return 'PINs do not match';
    if (form.initialDeposit && parseFloat(form.initialDeposit) < 0) return 'Initial deposit cannot be negative';
    return null;
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');
    setSuccess('');
    const err = validate();
    if (err) { setError(err); return; }

    setLoading(true);
    try {
      const payload = {
        firstName: form.firstName.trim(),
        lastName: form.lastName.trim(),
        email: form.email.trim(),
        phone: form.phone.trim(),
        pin: form.pin,
      };
      if (form.initialDeposit) payload.initialDeposit = parseFloat(form.initialDeposit);

      const res = await accountService.create(payload);
      setSuccess(`Account created! Your account number is: ${res.data.data.accountNumber}`);
      setForm(INITIAL);
      setTimeout(() => onSuccess(), 3000);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={{ maxWidth: '520px', margin: '2rem auto' }}>
      <div className="card">
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', marginBottom: '1.5rem' }}>
          <button onClick={onBack} style={{ background: 'none', border: 'none', cursor: 'pointer', fontSize: '1.2rem', color: 'var(--primary)' }}>←</button>
          <h2 style={{ color: 'var(--primary)', fontSize: '1.3rem' }}>Open New Account</h2>
        </div>

        {error && <div className="alert alert-error">{error}</div>}
        {success && <div className="alert alert-success">{success}</div>}

        <form onSubmit={handleSubmit} noValidate>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '0.75rem' }}>
            <div className="form-group">
              <label className="form-label">First Name *</label>
              <input className="form-input" type="text" value={form.firstName} onChange={update('firstName')} maxLength={50} required />
            </div>
            <div className="form-group">
              <label className="form-label">Last Name *</label>
              <input className="form-input" type="text" value={form.lastName} onChange={update('lastName')} maxLength={50} required />
            </div>
          </div>

          <div className="form-group">
            <label className="form-label">Email Address *</label>
            <input className="form-input" type="email" value={form.email} onChange={update('email')} autoComplete="email" required />
          </div>

          <div className="form-group">
            <label className="form-label">Phone Number *</label>
            <input className="form-input" type="tel" placeholder="+254700000000" value={form.phone} onChange={update('phone')} required />
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '0.75rem' }}>
            <div className="form-group">
              <label className="form-label">PIN (4-6 digits) *</label>
              <input className="form-input" type="password" value={form.pin} onChange={(e) => update('pin')({ target: { value: e.target.value.replace(/\D/g, '').slice(0, 6) } })} maxLength={6} autoComplete="new-password" required />
            </div>
            <div className="form-group">
              <label className="form-label">Confirm PIN *</label>
              <input className="form-input" type="password" value={form.confirmPin} onChange={(e) => update('confirmPin')({ target: { value: e.target.value.replace(/\D/g, '').slice(0, 6) } })} maxLength={6} autoComplete="new-password" required />
            </div>
          </div>

          <div className="form-group">
            <label className="form-label">Initial Deposit (optional)</label>
            <input className="form-input" type="number" min="0" step="0.01" placeholder="0.00" value={form.initialDeposit} onChange={update('initialDeposit')} />
          </div>

          <button type="submit" className="btn btn-primary" style={{ width: '100%', marginTop: '0.5rem' }} disabled={loading}>
            {loading ? <><span className="spinner" style={{ marginRight: '0.5rem' }} /> Creating Account...</> : 'Create Account'}
          </button>
        </form>
      </div>
    </div>
  );
}
