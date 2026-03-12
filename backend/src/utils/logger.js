'use strict';

const winston = require('winston');
const config = require('../config/env');

const sensitiveFields = ['pin', 'password', 'token', 'authorization'];

const sanitize = winston.format((info) => {
  const msg = JSON.stringify(info);
  const sanitized = sensitiveFields.reduce((acc, field) => {
    const regex = new RegExp(`("${field}"\\s*:\\s*)"[^"]*"`, 'gi');
    return acc.replace(regex, `"${field}":"[REDACTED]"`);
  }, msg);
  return JSON.parse(sanitized);
});

const logger = winston.createLogger({
  level: config.nodeEnv === 'production' ? 'warn' : 'info',
  format: winston.format.combine(
    sanitize(),
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    config.nodeEnv === 'production'
      ? winston.format.json()
      : winston.format.combine(winston.format.colorize(), winston.format.simple())
  ),
  transports: [new winston.transports.Console()],
  silent: config.nodeEnv === 'test',
});

module.exports = logger;
