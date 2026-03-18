'use strict';

const express = require('express');
const { body, param } = require('express-validator');
const router = express.Router();

const {
  createAccount, login, getAccount, creditAccount, debitAccount, updateProfile, getTransactions,
} = require('../controllers/accountController');
const { authenticate } = require('../middleware/auth');
const { authLimiter } = require('../middleware/rateLimiter');
const { validate } = require('../middleware/validate');

const accountNumberParam = param('accountNumber')
  .matches(/^\d{10}$/)
  .withMessage('Invalid account number format');

const pinBody = body('pin')
  .isString()
  .matches(/^\d{4,6}$/)
  .withMessage('PIN must be 4-6 digits');

router.post(
  '/',
  [
    body('firstName').trim().isLength({ min: 2, max: 50 }).escape(),
    body('lastName').trim().isLength({ min: 2, max: 50 }).escape(),
    body('email').isEmail().normalizeEmail(),
    body('phone').matches(/^\+?[1-9]\d{6,14}$/).withMessage('Invalid phone number'),
    pinBody,
    body('initialDeposit').optional().isFloat({ min: 0 }).withMessage('Initial deposit must be non-negative'),
    validate,
  ],
  createAccount
);

router.post(
  '/login',
  authLimiter,
  [
    body('accountNumber').matches(/^\d{10}$/).withMessage('Invalid account number'),
    pinBody,
    validate,
  ],
  login
);

router.use(authenticate);

router.get('/:accountNumber', [accountNumberParam, validate], getAccount);
router.get('/:accountNumber/transactions', [accountNumberParam, validate], getTransactions);

router.post(
  '/:accountNumber/credit',
  [
    accountNumberParam,
    body('amount').isFloat({ min: 0.01, max: 1000000 }).withMessage('Amount must be between 0.01 and 1,000,000'),
    body('description').optional().trim().isLength({ max: 200 }).escape(),
    validate,
  ],
  creditAccount
);

router.post(
  '/:accountNumber/debit',
  [
    accountNumberParam,
    body('amount').isFloat({ min: 0.01, max: 1000000 }).withMessage('Amount must be between 0.01 and 1,000,000'),
    body('description').optional().trim().isLength({ max: 200 }).escape(),
    validate,
  ],
  debitAccount
);

router.patch(
  '/:accountNumber/profile',
  [
    accountNumberParam,
    body('firstName').optional().trim().isLength({ min: 2, max: 50 }).escape(),
    body('lastName').optional().trim().isLength({ min: 2, max: 50 }).escape(),
    body('email').optional().isEmail().normalizeEmail(),
    body('phone').optional().matches(/^\+?[1-9]\d{6,14}$/).withMessage('Invalid phone number'),
    validate,
  ],
  updateProfile
);

module.exports = router;
