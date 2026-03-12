import React, { useState, useEffect, useCallback } from 'react';
import { accountService } from '../services/api';
import TransactionModal from './TransactionModal';
import EditProfile from './EditProfile';

export default function AccountDashboard({ accountNumber, onLogout }) {
  const [account, setAccount] = useState(null);
  const [transactions, setTransactions] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [modal, setModal] = useState(null); // 'credit' | 'debit' | 'profile'

  const fetchAccount = useCallback(async () => {
    try {
      const [accRes, txRes] = await Promise.all([
        accountService.getAccount(accountNumber),
        accountService.getTransactions(accountNumber),
      ]);
      setAccount(accRes.data.data);
      setTransactions(txRes.data.data.transactions);
      setError('');
    } catch (err) {
      if (err.message.includes('expired') || err.message.includes('Authentication')) {
        onLogout();
      } else {
        setError(err.message);
      }
    } finally {
      setLoading(false);
    }
  }, [accountNumber, onLogout]);

  useEffect(() => { fetchAccount(); }, [fetchAccount]);

  const handleTransactionDone = () => {
    setModal(null);
    fetchAccount();
  };

  if (loading) {
    return (
      <div style={{ display: 'flex', justifyContent: 'center', marginTop: '4rem' }}>
        <span className="spinner" style={{ width: '40px', height: '40px', borderColor: 'var(--primary)', borderTopColor: 'transparent' }} />
      </div>
    );
  }

  if (error) return <div className="alert alert-error" style={{ maxWidth: '500px', margin: '2rem auto' }}>{error}</div>;
  if (!account) return null;

  return (
    <div>
      {/* Balance Card */}
      <div className="card" style={{ background: 'var(--primary)', color: '#fff', marginBottom: '1.5rem', border: 'none' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: '1rem' }}>
          <div>
            <p style={{ opacity: 0.8, fontSize: '0.85rem', marginBottom: '0.25rem' }}>Account Balance</p>
            <p style={{ fontSize: '2.5rem', fontWeight: 800 }}>
              KES {account.balance.toLocaleString('en-KE', { minimumFractionDigits: 2 })}
            </p>
            <p style={{ opacity: 0.75, fontSize: '0.85rem', marginTop: '0.5rem' }}>
              {account.firstName} {account.lastName} • {account.accountNumber}
            </p>
          </div>
          <div style={{ display: 'flex', gap: '0.75rem', flexWrap: 'wrap' }}>
            <button className="btn btn-success btn-sm" onClick={() => setModal('credit')}>+ Credit</button>
            <button className="btn btn-danger btn-sm" onClick={() => setModal('debit')}>- Debit</button>
            <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,0.15)', color: '#fff' }} onClick={() => setModal('profile')}>Edit Profile</button>
          </div>
        </div>
      </div>

      {/* Account Details */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: '1rem', marginBottom: '1.5rem' }}>
        {[
          { label: 'Full Name', value: `${account.firstName} ${account.lastName}` },
          { label: 'Email', value: account.email },
          { label: 'Phone', value: account.phone },
          { label: 'Status', value: account.isActive ? '✅ Active' : '🔴 Inactive' },
        ].map((item) => (
          <div key={item.label} className="card" style={{ padding: '1rem' }}>
            <p style={{ color: 'var(--text-muted)', fontSize: '0.78rem', fontWeight: 700, textTransform: 'uppercase', marginBottom: '0.25rem' }}>{item.label}</p>
            <p style={{ fontWeight: 600, fontSize: '0.95rem' }}>{item.value}</p>
          </div>
        ))}
      </div>

      {/* Transaction History */}
      <div className="card">
        <h3 style={{ marginBottom: '1rem', color: 'var(--primary)' }}>Transaction History</h3>
        {transactions.length === 0 ? (
          <p style={{ color: 'var(--text-muted)', textAlign: 'center', padding: '2rem 0' }}>No transactions yet</p>
        ) : (
          <div style={{ overflowX: 'auto' }}>
            <table>
              <thead>
                <tr>
                  <th>Type</th>
                  <th>Amount</th>
                  <th>Balance After</th>
                  <th>Description</th>
                  <th>Date</th>
                </tr>
              </thead>
              <tbody>
                {transactions.map((tx) => (
                  <tr key={tx._id}>
                    <td><span className={`badge badge-${tx.type.toLowerCase()}`}>{tx.type}</span></td>
                    <td style={{ color: tx.type === 'CREDIT' ? 'var(--success)' : 'var(--danger)', fontWeight: 700 }}>
                      {tx.type === 'CREDIT' ? '+' : '-'} KES {tx.amount.toLocaleString('en-KE', { minimumFractionDigits: 2 })}
                    </td>
                    <td>KES {tx.balanceAfter.toLocaleString('en-KE', { minimumFractionDigits: 2 })}</td>
                    <td style={{ color: 'var(--text-muted)' }}>{tx.description || '—'}</td>
                    <td style={{ color: 'var(--text-muted)', whiteSpace: 'nowrap', fontSize: '0.85rem' }}>
                      {new Date(tx.timestamp).toLocaleString('en-KE')}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Modals */}
      {(modal === 'credit' || modal === 'debit') && (
        <TransactionModal
          type={modal}
          accountNumber={accountNumber}
          onDone={handleTransactionDone}
          onClose={() => setModal(null)}
        />
      )}
      {modal === 'profile' && (
        <EditProfile
          account={account}
          onDone={handleTransactionDone}
          onClose={() => setModal(null)}
        />
      )}
    </div>
  );
}
