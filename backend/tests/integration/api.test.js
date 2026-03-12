'use strict';

const mongoose = require('mongoose');
const { MongoMemoryServer } = require('mongodb-memory-server');
const request = require('supertest');
const app = require('../../src/server');
const Account = require('../../src/models/Account');

let mongod;
let token;
let accountNumber;

const testAccount = {
  firstName: 'Alice',
  lastName: 'Smith',
  email: 'alice.smith@example.com',
  phone: '+254711000001',
  pin: '4321',
  initialDeposit: 5000,
};

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  process.env.MONGODB_URI = mongod.getUri();
  process.env.JWT_SECRET = 'test_secret_at_least_32_chars_long_1234';
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(async () => {
  await Account.deleteMany({});
  // Create and login
  const createRes = await request(app).post('/api/accounts').send(testAccount);
  accountNumber = createRes.body.data.accountNumber;
  const loginRes = await request(app).post('/api/accounts/login').send({
    accountNumber,
    pin: testAccount.pin,
  });
  token = loginRes.body.data.token;
});

describe('Health check', () => {
  it('GET /health returns ok', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });
});

describe('POST /api/accounts - Create Account', () => {
  it('should create a new account', async () => {
    const res = await request(app).post('/api/accounts').send({
      firstName: 'Bob',
      lastName: 'Jones',
      email: 'bob.jones@example.com',
      phone: '+254722000002',
      pin: '5678',
    });
    expect(res.status).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.data.accountNumber).toMatch(/^\d{10}$/);
  });

  it('should reject duplicate email', async () => {
    const res = await request(app).post('/api/accounts').send(testAccount);
    expect(res.status).toBe(409);
  });

  it('should reject invalid email', async () => {
    const res = await request(app).post('/api/accounts').send({ ...testAccount, email: 'bad-email', pin: '1111' });
    expect(res.status).toBe(422);
  });

  it('should reject short PIN', async () => {
    const res = await request(app).post('/api/accounts').send({ ...testAccount, email: 'new@ex.com', pin: '12' });
    expect(res.status).toBe(422);
  });

  it('should not expose PIN in response', async () => {
    const res = await request(app).post('/api/accounts').send({
      firstName: 'Bob', lastName: 'Jones', email: 'bob2@ex.com', phone: '+254722000003', pin: '9999',
    });
    expect(JSON.stringify(res.body)).not.toContain('9999');
  });
});

describe('POST /api/accounts/login - Login', () => {
  it('should login with valid credentials', async () => {
    const res = await request(app).post('/api/accounts/login').send({ accountNumber, pin: testAccount.pin });
    expect(res.status).toBe(200);
    expect(res.body.data.token).toBeDefined();
  });

  it('should reject wrong PIN', async () => {
    const res = await request(app).post('/api/accounts/login').send({ accountNumber, pin: '0000' });
    expect(res.status).toBe(401);
  });

  it('should reject non-existent account', async () => {
    const res = await request(app).post('/api/accounts/login').send({ accountNumber: '9999999999', pin: '1234' });
    expect(res.status).toBe(401);
  });
});

describe('GET /api/accounts/:accountNumber - Get Account', () => {
  it('should get account with valid token', async () => {
    const res = await request(app)
      .get(`/api/accounts/${accountNumber}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.data.accountNumber).toBe(accountNumber);
    expect(res.body.data.balance).toBe(5000);
  });

  it('should reject without token', async () => {
    const res = await request(app).get(`/api/accounts/${accountNumber}`);
    expect(res.status).toBe(401);
  });

  it('should reject access to another account', async () => {
    const otherRes = await request(app).post('/api/accounts').send({
      firstName: 'Eve', lastName: 'Hacker', email: 'eve@ex.com', phone: '+254733000004', pin: '1111',
    });
    const otherNum = otherRes.body.data.accountNumber;
    const res = await request(app)
      .get(`/api/accounts/${otherNum}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(403);
  });
});

describe('POST /api/accounts/:accountNumber/credit', () => {
  it('should credit account', async () => {
    const res = await request(app)
      .post(`/api/accounts/${accountNumber}/credit`)
      .set('Authorization', `Bearer ${token}`)
      .send({ amount: 1000, description: 'Test credit' });
    expect(res.status).toBe(200);
    expect(res.body.data.balance).toBe(6000);
  });

  it('should reject zero amount', async () => {
    const res = await request(app)
      .post(`/api/accounts/${accountNumber}/credit`)
      .set('Authorization', `Bearer ${token}`)
      .send({ amount: 0 });
    expect(res.status).toBe(422);
  });
});

describe('POST /api/accounts/:accountNumber/debit', () => {
  it('should debit account', async () => {
    const res = await request(app)
      .post(`/api/accounts/${accountNumber}/debit`)
      .set('Authorization', `Bearer ${token}`)
      .send({ amount: 1000, description: 'Test debit' });
    expect(res.status).toBe(200);
    expect(res.body.data.balance).toBe(4000);
  });

  it('should reject debit exceeding balance', async () => {
    const res = await request(app)
      .post(`/api/accounts/${accountNumber}/debit`)
      .set('Authorization', `Bearer ${token}`)
      .send({ amount: 99999 });
    expect(res.status).toBe(400);
  });
});

describe('PATCH /api/accounts/:accountNumber/profile', () => {
  it('should update profile', async () => {
    const res = await request(app)
      .patch(`/api/accounts/${accountNumber}/profile`)
      .set('Authorization', `Bearer ${token}`)
      .send({ firstName: 'Alicia', phone: '+254700000099' });
    expect(res.status).toBe(200);
    expect(res.body.data.firstName).toBe('Alicia');
  });

  it('should reject invalid email update', async () => {
    const res = await request(app)
      .patch(`/api/accounts/${accountNumber}/profile`)
      .set('Authorization', `Bearer ${token}`)
      .send({ email: 'not-valid' });
    expect(res.status).toBe(422);
  });
});

describe('GET /api/accounts/:accountNumber/transactions', () => {
  it('should return transactions', async () => {
    await request(app)
      .post(`/api/accounts/${accountNumber}/credit`)
      .set('Authorization', `Bearer ${token}`)
      .send({ amount: 500 });
    const res = await request(app)
      .get(`/api/accounts/${accountNumber}/transactions`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.data.transactions.length).toBeGreaterThan(0);
  });
});

describe('Security tests', () => {
  it('should reject NoSQL injection in login', async () => {
    const res = await request(app)
      .post('/api/accounts/login')
      .send({ accountNumber: { $gt: '' }, pin: { $gt: '' } });
    expect(res.status).toBe(422);
  });

  it('should return 404 for unknown routes', async () => {
    const res = await request(app).get('/api/nonexistent');
    expect(res.status).toBe(404);
  });

  it('should reject oversized body', async () => {
    const bigPayload = { firstName: 'A'.repeat(100000) };
    const res = await request(app)
      .post('/api/accounts')
      .send(bigPayload);
    expect([400, 413, 422]).toContain(res.status);
  });
});
