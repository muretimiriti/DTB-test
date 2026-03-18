'use strict';

const generateAccountNumber = () => {
  const suffix = Math.floor(100000 + Math.random() * 900000).toString();
  return `1000${suffix}`;
};

module.exports = { generateAccountNumber };
