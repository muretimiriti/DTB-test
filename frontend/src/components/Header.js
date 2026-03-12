import React from 'react';

export default function Header({ isLoggedIn, accountNumber, onLogout }) {
  return (
    <header
      style={{
        background: 'var(--primary)',
        color: '#fff',
        padding: '0 1.5rem',
        height: '60px',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        boxShadow: '0 2px 8px rgba(0,0,0,0.2)',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
        <span style={{ fontSize: '1.5rem' }}>🏦</span>
        <span style={{ fontWeight: 800, fontSize: '1.15rem', letterSpacing: '0.5px' }}>
          DTB Banking Portal
        </span>
      </div>

      {isLoggedIn && (
        <div style={{ display: 'flex', alignItems: 'center', gap: '1rem' }}>
          <span style={{ fontSize: '0.85rem', opacity: 0.85 }}>
            Account: <strong>{accountNumber}</strong>
          </span>
          <button
            onClick={onLogout}
            className="btn btn-outline btn-sm"
            style={{ color: '#fff', borderColor: 'rgba(255,255,255,0.6)' }}
          >
            Logout
          </button>
        </div>
      )}
    </header>
  );
}
