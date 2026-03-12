import React, { useState, useCallback } from 'react';
import Header from './components/Header';
import AccountLookup from './components/AccountLookup';
import CreateAccount from './components/CreateAccount';
import AccountDashboard from './components/AccountDashboard';

const VIEWS = { LOOKUP: 'lookup', CREATE: 'create', DASHBOARD: 'dashboard' };

export default function App() {
  const [view, setView] = useState(VIEWS.LOOKUP);
  const [session, setSession] = useState(null); // { token, accountNumber }

  const handleLoginSuccess = useCallback((token, accountNumber) => {
    sessionStorage.setItem('banking_token', token);
    setSession({ token, accountNumber });
    setView(VIEWS.DASHBOARD);
  }, []);

  const handleLogout = useCallback(() => {
    sessionStorage.removeItem('banking_token');
    setSession(null);
    setView(VIEWS.LOOKUP);
  }, []);

  return (
    <div style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column' }}>
      <Header
        isLoggedIn={!!session}
        accountNumber={session?.accountNumber}
        onLogout={handleLogout}
      />

      <main style={{ flex: 1, padding: '2rem 1rem', maxWidth: '900px', margin: '0 auto', width: '100%' }}>
        {view === VIEWS.LOOKUP && (
          <AccountLookup
            onLoginSuccess={handleLoginSuccess}
            onCreateNew={() => setView(VIEWS.CREATE)}
          />
        )}
        {view === VIEWS.CREATE && (
          <CreateAccount
            onSuccess={() => setView(VIEWS.LOOKUP)}
            onBack={() => setView(VIEWS.LOOKUP)}
          />
        )}
        {view === VIEWS.DASHBOARD && session && (
          <AccountDashboard
            accountNumber={session.accountNumber}
            onLogout={handleLogout}
          />
        )}
      </main>
    </div>
  );
}
