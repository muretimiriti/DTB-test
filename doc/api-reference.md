# API Reference

**Base URL**: `http://localhost:5000/api`
**Content-Type**: `application/json`
**Auth**: Bearer token (JWT) in `Authorization` header for protected routes

## Response Format

All responses follow this structure:
```json
{ "success": true|false, "data": {}, "message": "string" }
```

---

## Public Endpoints

### POST /accounts — Create Account

```
POST /api/accounts
```

**Body**:
| Field | Type | Required | Notes |
|-------|------|----------|-------|
| firstName | string | ✅ | 2–50 chars |
| lastName | string | ✅ | 2–50 chars |
| email | string | ✅ | Valid email, unique |
| phone | string | ✅ | E.164 format |
| pin | string | ✅ | 4–6 digits |
| initialDeposit | number | ❌ | ≥ 0 |

**Response 201**:
```json
{ "success": true, "data": { "accountNumber": "1000123456" } }
```

---

### POST /accounts/login — Authenticate

```
POST /api/accounts/login
```

Rate limited: **5 requests/minute per IP**

**Body**:
```json
{ "accountNumber": "1000123456", "pin": "1234" }
```

**Response 200**:
```json
{
  "success": true,
  "data": { "token": "eyJ...", "accountNumber": "1000123456" }
}
```

**Response 401**: Invalid credentials
**Response 429**: Too many attempts or account locked

---

## Protected Endpoints

All require: `Authorization: Bearer <token>`

### GET /accounts/:accountNumber — Get Account

```
GET /api/accounts/1000123456
Authorization: Bearer <token>
```

**Response 200**:
```json
{
  "success": true,
  "data": {
    "accountNumber": "1000123456",
    "firstName": "Alice",
    "lastName": "Smith",
    "email": "alice@example.com",
    "phone": "+254700000001",
    "balance": 50000,
    "isActive": true,
    "transactions": [...],
    "createdAt": "2024-01-01T00:00:00Z"
  }
}
```

---

### POST /accounts/:accountNumber/credit — Credit Account

```
POST /api/accounts/1000123456/credit
Authorization: Bearer <token>
```

**Body**:
```json
{ "amount": 5000, "description": "Salary" }
```

**Response 200**:
```json
{
  "success": true,
  "data": {
    "balance": 55000,
    "transaction": { "type": "CREDIT", "amount": 5000, "balanceAfter": 55000, ... }
  }
}
```

---

### POST /accounts/:accountNumber/debit — Debit Account

```
POST /api/accounts/1000123456/debit
Authorization: Bearer <token>
```

**Body**:
```json
{ "amount": 1000, "description": "ATM withdrawal" }
```

**Response 400** if balance insufficient.

---

### PATCH /accounts/:accountNumber/profile — Update Profile

```
PATCH /api/accounts/1000123456/profile
Authorization: Bearer <token>
```

**Body** (all fields optional):
```json
{ "firstName": "Alicia", "email": "new@example.com" }
```

---

### GET /accounts/:accountNumber/transactions — Transaction History

```
GET /api/accounts/1000123456/transactions?page=1&limit=20
Authorization: Bearer <token>
```

**Query Params**: `page` (default 1), `limit` (default 20, max 100)

**Response 200**:
```json
{
  "success": true,
  "data": {
    "transactions": [...],
    "total": 45,
    "page": 1,
    "limit": 20
  }
}
```

---

## Error Codes

| HTTP Status | Meaning |
|-------------|---------|
| 400 | Bad request (e.g. insufficient funds) |
| 401 | Unauthenticated |
| 403 | Authenticated but not authorised for this resource |
| 404 | Route not found |
| 409 | Conflict (duplicate email/account number) |
| 413 | Payload too large (>10KB) |
| 422 | Validation error |
| 429 | Rate limited or account locked |
| 500 | Internal server error |
