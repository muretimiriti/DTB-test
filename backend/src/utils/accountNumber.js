'use strict';

/**
 * Generates a unique 10-digit account number prefixed with '1000'
 * Format: 1000XXXXXX (10 digits total)
 */
const generateAccountNumber = () => {
  const suffix = Math.floor(100000 + Math.random() * 900000).toString();
  return `1000${suffix}`;
};

module.exports = { generateAccountNumber };
