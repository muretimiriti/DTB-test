'use strict';

const mongoose = require('mongoose');
const bcrypt = require('bcryptjs');
const config = require('../config/env');

const transactionSchema = new mongoose.Schema(
  {
    type: { type: String, enum: ['CREDIT', 'DEBIT'], required: true },
    amount: { type: Number, required: true, min: 0.01 },
    balanceAfter: { type: Number, required: true },
    description: { type: String, maxlength: 200, default: '' },
    timestamp: { type: Date, default: Date.now },
  },
  { _id: true }
);

const accountSchema = new mongoose.Schema(
  {
    accountNumber: {
      type: String,
      unique: true,
      required: true,
      match: /^\d{10}$/,
      index: true,
    },
    firstName: {
      type: String,
      required: true,
      trim: true,
      minlength: 2,
      maxlength: 50,
    },
    lastName: {
      type: String,
      required: true,
      trim: true,
      minlength: 2,
      maxlength: 50,
    },
    email: {
      type: String,
      required: true,
      unique: true,
      lowercase: true,
      trim: true,
      match: /^[^\s@]+@[^\s@]+\.[^\s@]+$/,
    },
    phone: {
      type: String,
      required: true,
      trim: true,
      match: /^\+?[1-9]\d{6,14}$/,
    },
    pin: {
      type: String,
      required: true,
      select: false,
    },
    balance: {
      type: Number,
      default: 0,
      min: 0,
    },
    isActive: {
      type: Boolean,
      default: true,
    },
    transactions: {
      type: [transactionSchema],
      default: [],
    },
    failedPinAttempts: {
      type: Number,
      default: 0,
      select: false,
    },
    lockedUntil: {
      type: Date,
      default: null,
      select: false,
    },
  },
  {
    timestamps: true,
    toJSON: {
      transform(doc, ret) {
        delete ret.pin;
        delete ret.failedPinAttempts;
        delete ret.lockedUntil;
        return ret;
      },
    },
  }
);

accountSchema.pre('save', async function (next) {
  if (!this.isModified('pin')) return next();
  this.pin = await bcrypt.hash(this.pin, config.bcryptRounds);
  next();
});

accountSchema.methods.verifyPin = async function (candidatePin) {
  const now = new Date();
  if (this.lockedUntil && this.lockedUntil > now) {
    const waitSeconds = Math.ceil((this.lockedUntil - now) / 1000);
    throw Object.assign(new Error(`Account locked. Try again in ${waitSeconds}s`), {
      statusCode: 429,
    });
  }

  const isMatch = await bcrypt.compare(candidatePin, this.pin);

  if (!isMatch) {
    this.failedPinAttempts += 1;
    if (this.failedPinAttempts >= 5) {
      this.lockedUntil = new Date(now.getTime() + 15 * 60 * 1000);
      this.failedPinAttempts = 0;
    }
    await this.save();
    return false;
  }

  if (this.failedPinAttempts > 0) {
    this.failedPinAttempts = 0;
    this.lockedUntil = null;
    await this.save();
  }

  return true;
};

module.exports = mongoose.model('Account', accountSchema);
