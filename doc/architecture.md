# System Architecture

## Overview

The DTB Banking Portal is a three-tier microservice application deployed as Docker containers orchestrated by Docker Compose.

```
┌─────────────────────────────────────────────────────────┐
│                      HOST MACHINE                        │
│                                                          │
│  ┌──────────────┐   frontend_net   ┌──────────────────┐ │
│  │   Browser    │◄────────────────►│   Frontend       │ │
│  │  :3000       │                  │   React + Nginx  │ │
│  └──────────────┘                  │   (port 80)      │ │
│                                    └────────┬─────────┘ │
│                                             │ proxy /api │
│                       frontend_net          ▼            │
│                                    ┌──────────────────┐ │
│                                    │   Backend        │ │
│                                    │   Node/Express   │ │
│                                    │   (port 5000)    │ │
│                                    └────────┬─────────┘ │
│                        backend_net          │            │
│                                             ▼            │
│                                    ┌──────────────────┐ │
│                                    │   MongoDB        │ │
│                                    │   (port 27017)   │ │
│                                    │   NOT exposed    │ │
│                                    └──────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Services

### Frontend (React + Nginx)
- **Technology**: React 18, Nginx 1.27 (Alpine)
- **Port**: 3000 (host) → 80 (container)
- **Network**: `frontend_net` only
- **Build**: Multi-stage — Node 20 compiles React, Nginx serves static files
- **Proxy**: Nginx proxies `/api/*` → backend:5000 (no CORS issues, backend not exposed to host)

### Backend (Node.js + Express)
- **Technology**: Node.js 20, Express 4, JWT auth
- **Port**: 5000 (internal only — not bound to host in production)
- **Networks**: `frontend_net` + `backend_net`
- **Security middleware**: Helmet, CORS, rate limiting, mongo-sanitize, body size limit

### MongoDB
- **Version**: 7.0
- **Port**: 27017 (internal only — never exposed to host)
- **Network**: `backend_net` only
- **Auth**: Root user + least-privilege app user (`app_user` with readWrite on `banking_db`)
- **Persistence**: Named Docker volume `mongo_data`

## Data Model

### Account Document
```
{
  _id:              ObjectId
  accountNumber:    String (10-digit, unique, indexed)
  firstName:        String
  lastName:         String
  email:            String (unique, indexed)
  phone:            String
  pin:              String (bcrypt hash, not returned in API)
  balance:          Number (KES, ≥ 0)
  isActive:         Boolean
  failedPinAttempts: Number (hidden)
  lockedUntil:      Date   (hidden — set after 5 wrong PINs)
  transactions: [{
    type:        "CREDIT" | "DEBIT"
    amount:      Number
    balanceAfter: Number
    description: String
    timestamp:   Date
  }]
  createdAt:    Date
  updatedAt:    Date
}
```

## Network Isolation

| Service  | frontend_net | backend_net | Host-exposed ports |
|----------|:---:|:---:|---|
| Frontend | ✅  | ❌  | 3000 |
| Backend  | ✅  | ✅  | ❌ (internal only) |
| MongoDB  | ❌  | ✅  | ❌ (internal only) |

This ensures MongoDB is unreachable from the browser or internet.

## Request Flow

1. Browser → `GET http://localhost:3000` → Nginx serves `index.html`
2. React app makes API call → `POST http://localhost:3000/api/accounts/login`
3. Nginx proxies `/api/*` → `http://backend:5000/api/*`
4. Express validates request → queries MongoDB
5. MongoDB returns data → Express signs JWT → responds
6. Nginx forwards response to browser
