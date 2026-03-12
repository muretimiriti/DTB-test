'use strict';

const jwt = require('jsonwebtoken');
const config = require('../config/env');
const Account = require('../models/Account');

const authenticate = async (req, res, next) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ success: false, message: 'Authentication required' });
    }

    const token = authHeader.split(' ')[1];
    let decoded;
    try {
      decoded = jwt.verify(token, config.jwt.secret);
    } catch (err) {
      return res.status(401).json({ success: false, message: 'Invalid or expired token' });
    }

    const account = await Account.findById(decoded.id).select('+isActive');
    if (!account || !account.isActive) {
      return res.status(401).json({ success: false, message: 'Account not found or inactive' });
    }

    req.account = account;
    next();
  } catch (err) {
    next(err);
  }
};

module.exports = { authenticate };
