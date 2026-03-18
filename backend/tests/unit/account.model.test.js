'use strict';

const mongoose = require('mongoose');
const { MongoMemoryServer } = require('mongodb-memory-server');
const Account = require('../../src/models/Account');
const { generateAccountNumber } = require('../../src/utils/accountNumber');

let mongod;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Account.deleteMany({});
});

describe('Account Model - Unit Tests', () => {
  const validAccount = {
    accountNumber: '1000123456',
    firstName: 'John',
    lastName: 'Doe',
    email: 'john.doe@example.com',
    phone: '+254700000000',
    pin: '1234',
    balance: 0,
  };

  describe('Account creation', () => {
    it('should create a valid account', async () => {
      const account = await Account.create(validAccount);
      expect(account.accountNumber).toBe(validAccount.accountNumber);
      expect(account.firstName).toBe(validAccount.firstName);
      expect(account.balance).toBe(0);
      expect(account.isActive).toBe(true);
    });

    it('should hash the PIN on save', async () => {
      const account = await Account.create(validAccount);
      const raw = await Account.findById(account._id).select('+pin');
      expect(raw.pin).not.toBe('1234');
      expect(raw.pin).toMatch(/^\$2[ab]\$/);
    });

    it('should not expose PIN in toJSON', async () => {
      const account = await Account.create(validAccount);
      const json = account.toJSON();
      expect(json.pin).toBeUndefined();
    });

    it('should reject account with duplicate email', async () => {
      await Account.create(validAccount);
      await expect(
        Account.create({ ...validAccount, accountNumber: '1000999999' })
      ).rejects.toThrow();
    });

    it('should reject account with invalid email', async () => {
      await expect(
        Account.create({ ...validAccount, email: 'not-an-email' })
      ).rejects.toThrow();
    });

    it('should reject negative balance', async () => {
      await expect(
        Account.create({ ...validAccount, balance: -100 })
      ).rejects.toThrow();
    });

    it('should reject invalid account number format', async () => {
      await expect(
        Account.create({ ...validAccount, accountNumber: 'ABC123' })
      ).rejects.toThrow();
    });
  });

  describe('PIN verification', () => {
    it('should verify correct PIN', async () => {
      const account = await Account.findById(
        (await Account.create(validAccount))._id
      ).select('+pin +failedPinAttempts +lockedUntil');
      const result = await account.verifyPin('1234');
      expect(result).toBe(true);
    });

    it('should reject incorrect PIN', async () => {
      const account = await Account.findById(
        (await Account.create(validAccount))._id
      ).select('+pin +failedPinAttempts +lockedUntil');
      const result = await account.verifyPin('0000');
      expect(result).toBe(false);
    });

    it('should lock account after 5 failed attempts', async () => {
      const account = await Account.findById(
        (await Account.create(validAccount))._id
      ).select('+pin +failedPinAttempts +lockedUntil');

      for (let i = 0; i < 4; i++) {
        await account.verifyPin('0000');
      }

      await account.verifyPin('0000');

      const fresh = await Account.findById(account._id).select('+lockedUntil');
      expect(fresh.lockedUntil).not.toBeNull();
      expect(fresh.lockedUntil > new Date()).toBe(true);
    });
  });

  describe('generateAccountNumber', () => {
    it('should generate a 10-digit string', () => {
      const num = generateAccountNumber();
      expect(num).toMatch(/^\d{10}$/);
    });

    it('should start with 1000', () => {
      const num = generateAccountNumber();
      expect(num.startsWith('1000')).toBe(true);
    });

    it('should generate unique numbers across calls', () => {
      const numbers = new Set(Array.from({ length: 1000 }, generateAccountNumber));
      expect(numbers.size).toBeGreaterThan(990);
    });
  });
});
