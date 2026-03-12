import React, { useState } from 'react';
import { accountService } from '../services/api';

export default function TransactionModal({ type, accountNumber, onDone, onClose }) {
  const [amount, setAmount] = useState('');
  const [description, setDescription] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const isCredit = type === 'credit';
  const title = isCredit ? 'Credit Account' : 'Debit Account';

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');
    const num = parseFloat(amount);
    if (isNaN(num) || num <= 0) { setError('Enter a valid positive amount'); return; }
    if (num > 1000000) { setError('Amount cannot exceed 1,000,000'); return; }

    setLoading(true);
    try {
      if (isCredit) {
        await accountService.credit(accountNumber, num, description);
      } else {
        await accountService.debit(accountNumber, num, description);
      }
      onDone();
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="overlay" onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal">
        <div className="modal-header">
          <span className="modal-title">{title}</span>
          <button className="modal-close" onClick={onClose} aria-label="Close">×</button>
        </div>

        {error && <div className="alert alert-error">{error}</div>}

        <form onSubmit={handleSubmit} noValidate>
          <div className="form-group">
            <label className="form-label">Amount (KES) *</label>
            <input
              className="form-input"
              type="number"
              min="0.01"
              step="0.01"
              max="1000000"
              placeholder="0.00"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              autoFocus
              required
            />
          </div>
          <div className="form-group">
            <label className="form-label">Description (optional)</label>
            <input
              className="form-input"
              type="text"
              maxLength={200}
              placeholder="e.g. Rent payment"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
            />
          </div>
          <div style={{ display: 'flex', gap: '0.75rem' }}>
            <button type="button" className="btn btn-outline" style={{ flex: 1 }} onClick={onClose} disabled={loading}>
              Cancel
            </button>
            <button type="submit" className={`btn ${isCredit ? 'btn-success' : 'btn-danger'}`} style={{ flex: 1 }} disabled={loading}>
              {loading ? <><span className="spinner" style={{ marginRight: '0.5rem' }} /> Processing...</> : title}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
