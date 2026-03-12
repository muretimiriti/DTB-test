import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import AccountLookup from './AccountLookup';
import { accountService } from '../services/api';

jest.mock('../services/api', () => ({
  accountService: {
    login: jest.fn(),
  },
}));

describe('AccountLookup', () => {
  const mockOnLoginSuccess = jest.fn();
  const mockOnCreateNew = jest.fn();

  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('renders account lookup form', () => {
    render(<AccountLookup onLoginSuccess={mockOnLoginSuccess} onCreateNew={mockOnCreateNew} />);
    expect(screen.getByLabelText(/account number/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/pin/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /sign in/i })).toBeInTheDocument();
  });

  it('shows error for invalid account number', async () => {
    render(<AccountLookup onLoginSuccess={mockOnLoginSuccess} onCreateNew={mockOnCreateNew} />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText(/account number/i), '123');
    await user.type(screen.getByLabelText(/pin/i), '1234');
    await user.click(screen.getByRole('button', { name: /sign in/i }));
    expect(screen.getByText(/10 digits/i)).toBeInTheDocument();
  });

  it('calls login service on valid submit', async () => {
    accountService.login.mockResolvedValue({ data: { data: { token: 'tok', accountNumber: '1000000001' } } });
    render(<AccountLookup onLoginSuccess={mockOnLoginSuccess} onCreateNew={mockOnCreateNew} />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText(/account number/i), '1000000001');
    await user.type(screen.getByLabelText(/pin/i), '1234');
    await user.click(screen.getByRole('button', { name: /sign in/i }));
    await waitFor(() => expect(mockOnLoginSuccess).toHaveBeenCalledWith('tok', '1000000001'));
  });

  it('shows error message on login failure', async () => {
    accountService.login.mockRejectedValue(new Error('Invalid account number or PIN'));
    render(<AccountLookup onLoginSuccess={mockOnLoginSuccess} onCreateNew={mockOnCreateNew} />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText(/account number/i), '1000000001');
    await user.type(screen.getByLabelText(/pin/i), '9999');
    await user.click(screen.getByRole('button', { name: /sign in/i }));
    await waitFor(() => expect(screen.getByText(/Invalid account number or PIN/i)).toBeInTheDocument());
  });

  it('calls onCreateNew when open account link is clicked', async () => {
    render(<AccountLookup onLoginSuccess={mockOnLoginSuccess} onCreateNew={mockOnCreateNew} />);
    await userEvent.setup().click(screen.getByText(/open account/i));
    expect(mockOnCreateNew).toHaveBeenCalled();
  });
});
