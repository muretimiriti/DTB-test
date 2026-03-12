import React, { useState } from 'react';
import { accountService } from '../services/api';

export default function AccountLookup({ onLoginSuccess, onCreateNew }) {
  const [accountNumber, setAccountNumber] = useState('');
  const [pin, setPin] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');

    if (!/^\d{10}$/.test(accountNumber)) {
      setError('Account number must be 10 digits');
      return;
    }
    if (!/^\d{4,6}$/.test(pin)) {
      setError('PIN must be 4-6 digits');
      return;
    }

    setLoading(true);
    try {
      const res = await accountService.login(accountNumber, pin);
      onLoginSuccess(res.data.data.token, res.data.data.accountNumber);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={{ maxWidth: '420px', margin: '3rem auto' }}>
      <div className="card">
        <h2 style={{ marginBottom: '0.25rem', color: 'var(--primary)', fontSize: '1.4rem' }}>
          Account Access
        </h2>
        <p style={{ color: 'var(--text-muted)', fontSize: '0.9rem', marginBottom: '1.5rem' }}>
          Enter your account number and PIN to access your account
        </p>

        {error && <div className="alert alert-error">{error}</div>}

        <form onSubmit={handleSubmit} noValidate>
          <div className="form-group">
            <label className="form-label" htmlFor="accountNumber">
              Account Number
            </label>
            <input
              id="accountNumber"
              type="text"
              className="form-input"
              placeholder="10-digit account number"
              value={accountNumber}
              onChange={(e) => setAccountNumber(e.target.value.replace(/\D/g, '').slice(0, 10))}
              maxLength={10}
              autoComplete="username"
              required
            />
          </div>

          <div className="form-group">
            <label className="form-label" htmlFor="pin">
              PIN
            </label>
            <input
              id="pin"
              type="password"
              className="form-input"
              placeholder="4-6 digit PIN"
              value={pin}
              onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 6))}
              maxLength={6}
              autoComplete="current-password"
              required
            />
          </div>

          <button type="submit" className="btn btn-primary" style={{ width: '100%', marginTop: '0.5rem' }} disabled={loading}>
            {loading ? <><span className="spinner" style={{ marginRight: '0.5rem' }} /> Signing In...</> : 'Sign In'}
          </button>
        </form>

        <hr style={{ margin: '1.5rem 0', borderColor: 'var(--border)' }} />

        <p style={{ textAlign: 'center', color: 'var(--text-muted)', fontSize: '0.9rem' }}>
          Don't have an account?{' '}
          <button
            onClick={onCreateNew}
            style={{ background: 'none', border: 'none', color: 'var(--primary)', fontWeight: 700, cursor: 'pointer', fontSize: '0.9rem' }}
          >
            Open Account
          </button>
        </p>
      </div>
    </div>
  );
}
