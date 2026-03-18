
db = db.getSiblingDB('banking_db');

db.createUser({
  user: process.env.MONGO_APP_USER || 'app_user',
  pwd: process.env.MONGO_APP_PASSWORD || 'changeme',
  roles: [
    { role: 'readWrite', db: 'banking_db' },
  ],
});

db.accounts.createIndex({ accountNumber: 1 }, { unique: true });
db.accounts.createIndex({ email: 1 }, { unique: true });
db.accounts.createIndex({ isActive: 1 });

print('MongoDB initialized: banking_db ready');
