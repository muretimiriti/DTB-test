'use strict';

const jwt = require('jsonwebtoken');
const Account = require('../models/Account');
const { generateAccountNumber } = require('../utils/accountNumber');
const config = require('../config/env');
const logger = require('../utils/logger');

// POST /api/accounts - Create new account
const createAccount = async (req, res, next) => {
  try {
    const { firstName, lastName, email, phone, pin, initialDeposit } = req.body;

    let accountNumber;
    let exists = true;
    let attempts = 0;
    while (exists && attempts < 10) {
      accountNumber = generateAccountNumber();
      exists = !!(await Account.findOne({ accountNumber }));
      attempts++;
    }
    if (exists) return next(new Error('Could not generate unique account number'));

    const account = await Account.create({
      accountNumber,
      firstName,
      lastName,
      email,
      phone,
      pin,
      balance: initialDeposit > 0 ? initialDeposit : 0,
      transactions:
        initialDeposit > 0
          ? [{ type: 'CREDIT', amount: initialDeposit, balanceAfter: initialDeposit, description: 'Initial deposit' }]
          : [],
    });

    logger.info(`Account created: ${account.accountNumber}`);
    res.status(201).json({ success: true, data: { accountNumber: account.accountNumber } });
  } catch (err) {
    next(err);
  }
};

// POST /api/accounts/login - Authenticate with account number + PIN
const login = async (req, res, next) => {
  try {
    const { accountNumber, pin } = req.body;

    const account = await Account.findOne({ accountNumber })
      .select('+pin +failedPinAttempts +lockedUntil');

    if (!account || !account.isActive) {
      return res.status(401).json({ success: false, message: 'Invalid account number or PIN' });
    }

    const isValid = await account.verifyPin(pin);
    if (!isValid) {
      return res.status(401).json({ success: false, message: 'Invalid account number or PIN' });
    }

    const token = jwt.sign({ id: account._id, accountNumber: account.accountNumber }, config.jwt.secret, {
      expiresIn: config.jwt.expiresIn,
    });

    res.json({ success: true, data: { token, accountNumber: account.accountNumber } });
  } catch (err) {
    if (err.statusCode === 429) return res.status(429).json({ success: false, message: err.message });
    next(err);
  }
};

// GET /api/accounts/:accountNumber - Get account details
const getAccount = async (req, res, next) => {
  try {
    if (req.account.accountNumber !== req.params.accountNumber) {
      return res.status(403).json({ success: false, message: 'Access denied' });
    }
    res.json({ success: true, data: req.account });
  } catch (err) {
    next(err);
  }
};

// POST /api/accounts/:accountNumber/credit - Credit account
const creditAccount = async (req, res, next) => {
  try {
    if (req.account.accountNumber !== req.params.accountNumber) {
      return res.status(403).json({ success: false, message: 'Access denied' });
    }

    const { amount, description } = req.body;
    const numAmount = parseFloat(amount);

    req.account.balance = parseFloat((req.account.balance + numAmount).toFixed(2));
    req.account.transactions.push({
      type: 'CREDIT',
      amount: numAmount,
      balanceAfter: req.account.balance,
      description: description || 'Credit',
    });

    await req.account.save();
    logger.info(`Credit: ${req.account.accountNumber} +${numAmount}`);
    res.json({ success: true, data: { balance: req.account.balance, transaction: req.account.transactions.at(-1) } });
  } catch (err) {
    next(err);
  }
};

// POST /api/accounts/:accountNumber/debit - Debit account
const debitAccount = async (req, res, next) => {
  try {
    if (req.account.accountNumber !== req.params.accountNumber) {
      return res.status(403).json({ success: false, message: 'Access denied' });
    }

    const { amount, description } = req.body;
    const numAmount = parseFloat(amount);

    if (req.account.balance < numAmount) {
      return res.status(400).json({ success: false, message: 'Insufficient funds' });
    }

    req.account.balance = parseFloat((req.account.balance - numAmount).toFixed(2));
    req.account.transactions.push({
      type: 'DEBIT',
      amount: numAmount,
      balanceAfter: req.account.balance,
      description: description || 'Debit',
    });

    await req.account.save();
    logger.info(`Debit: ${req.account.accountNumber} -${numAmount}`);
    res.json({ success: true, data: { balance: req.account.balance, transaction: req.account.transactions.at(-1) } });
  } catch (err) {
    next(err);
  }
};

// PATCH /api/accounts/:accountNumber/profile - Update profile
const updateProfile = async (req, res, next) => {
  try {
    if (req.account.accountNumber !== req.params.accountNumber) {
      return res.status(403).json({ success: false, message: 'Access denied' });
    }

    const allowedFields = ['firstName', 'lastName', 'email', 'phone'];
    allowedFields.forEach((field) => {
      if (req.body[field] !== undefined) {
        req.account[field] = req.body[field];
      }
    });

    await req.account.save();
    logger.info(`Profile updated: ${req.account.accountNumber}`);
    res.json({ success: true, data: req.account });
  } catch (err) {
    next(err);
  }
};

// GET /api/accounts/:accountNumber/transactions - Get transaction history
const getTransactions = async (req, res, next) => {
  try {
    if (req.account.accountNumber !== req.params.accountNumber) {
      return res.status(403).json({ success: false, message: 'Access denied' });
    }

    const page = parseInt(req.query.page, 10) || 1;
    const limit = Math.min(parseInt(req.query.limit, 10) || 20, 100);
    const sorted = [...req.account.transactions].sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));
    const paginated = sorted.slice((page - 1) * limit, page * limit);

    res.json({ success: true, data: { transactions: paginated, total: req.account.transactions.length, page, limit } });
  } catch (err) {
    next(err);
  }
};

module.exports = { createAccount, login, getAccount, creditAccount, debitAccount, updateProfile, getTransactions };
