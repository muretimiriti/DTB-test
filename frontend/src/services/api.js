import axios from 'axios';

const BASE_URL = process.env.REACT_APP_API_URL || 'http://localhost:5000';

const api = axios.create({
  baseURL: `${BASE_URL}/api`,
  timeout: 15000,
  headers: { 'Content-Type': 'application/json' },
});

api.interceptors.request.use((config) => {
  const token = sessionStorage.getItem('banking_token');
  if (token) config.headers.Authorization = `Bearer ${token}`;
  return config;
});

api.interceptors.response.use(
  (res) => res,
  (err) => {
    const message =
      err.response?.data?.message ||
      err.response?.data?.errors?.[0]?.message ||
      err.message ||
      'An unexpected error occurred';
    return Promise.reject(new Error(message));
  }
);

export const accountService = {
  create: (data) => api.post('/accounts', data),
  login: (accountNumber, pin) => api.post('/accounts/login', { accountNumber, pin }),
  getAccount: (accountNumber) => api.get(`/accounts/${accountNumber}`),
  credit: (accountNumber, amount, description) =>
    api.post(`/accounts/${accountNumber}/credit`, { amount, description }),
  debit: (accountNumber, amount, description) =>
    api.post(`/accounts/${accountNumber}/debit`, { amount, description }),
  updateProfile: (accountNumber, data) => api.patch(`/accounts/${accountNumber}/profile`, data),
  getTransactions: (accountNumber, page = 1, limit = 20) =>
    api.get(`/accounts/${accountNumber}/transactions`, { params: { page, limit } }),
};

export default api;
