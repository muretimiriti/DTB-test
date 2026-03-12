# DTB Banking Portal

A secure, containerised banking microservice application built for a GitOps-enabled CI/CD capstone project.

---

## What It Does

The portal lets bank staff or customers:

- **Look up** an existing account by account number and PIN
- **Open** a new account (name, email, phone, initial deposit)
- **View** account balance, profile details, and transaction history
- **Credit** or **debit** an account
- **Edit** profile information (name, email, phone)

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Frontend | React 18, Nginx 1.27 (Alpine) |
| Backend | Node.js 20, Express 4 |
| Database | MongoDB 7.0 |
| Auth | JWT (HS256, 1-hour expiry) + bcrypt PIN hashing |
| Containers | Docker, Docker Compose |

---

## Project Structure

```
DTB-tets/
├── frontend/                   # React SPA served by Nginx
│   ├── public/
│   │   └── index.html
│   ├── src/
│   │   ├── components/
│   │   │   ├── Header.js           # Top navigation bar
│   │   │   ├── AccountLookup.js    # Login form (account number + PIN)
│   │   │   ├── CreateAccount.js    # New account registration form
│   │   │   ├── AccountDashboard.js # Balance card + transaction table
│   │   │   ├── TransactionModal.js # Credit / debit modal
│   │   │   └── EditProfile.js      # Profile update modal
│   │   ├── services/
│   │   │   └── api.js              # Axios client with JWT interceptor
│   │   ├── App.js                  # View router (lookup → create → dashboard)
│   │   ├── index.js
│   │   └── index.css               # CSS design tokens + utility classes
│   ├── nginx.conf                  # SPA routing, API proxy, security headers
│   ├── Dockerfile                  # Multi-stage: Node build → Nginx serve
│   └── package.json
│
├── backend/                    # Express REST API
│   ├── src/
│   │   ├── config/
│   │   │   ├── database.js         # Mongoose connection
│   │   │   └── env.js              # Validated environment variables
│   │   ├── controllers/
│   │   │   └── accountController.js  # Business logic for all account ops
│   │   ├── middleware/
│   │   │   ├── auth.js             # JWT verification + ownership check
│   │   │   ├── validate.js         # express-validator rules
│   │   │   ├── rateLimiter.js      # IP-based rate limiting
│   │   │   └── errorHandler.js     # Centralised error responses
│   │   ├── models/
│   │   │   └── Account.js          # Mongoose schema (PIN hidden, indexed)
│   │   ├── routes/
│   │   │   └── accountRoutes.js    # Route definitions
│   │   ├── utils/
│   │   │   ├── accountNumber.js    # 10-digit account number generator
│   │   │   └── logger.js           # Winston logger (redacts sensitive fields)
│   │   └── server.js               # Express app setup + startup
│   ├── tests/
│   │   ├── unit/
│   │   │   └── account.model.test.js   # Model & utility unit tests
│   │   └── integration/
│   │       └── api.test.js             # Full API integration tests
│   ├── Dockerfile                  # Multi-stage: deps → production
│   └── package.json
│
├── scripts/                    # Bash automation scripts
│   ├── setup.sh                # Prerequisites check + .env generation
│   ├── build.sh                # Docker image builds
│   ├── deploy.sh               # Stack lifecycle (up / down / logs / clean)
│   ├── test.sh                 # Run unit, integration, or coverage tests
│   ├── health-check.sh         # Verify all services are healthy
│   ├── seed.sh                 # Load demo accounts into the database
│   └── mongo-init.js           # MongoDB init: create app user + indexes
│
├── doc/                        # Project documentation
│   ├── README.md               # ← You are here
│   ├── architecture.md         # System design, network diagram, data model
│   ├── security.md             # Threat model, controls, hardening checklist
│   ├── setup.md                # Step-by-step local development guide
│   ├── api-reference.md        # REST endpoint reference with examples
│   └── cicd-pipeline.md        # CI/CD stages, GitOps workflow, GitHub Actions
│
├── docker-compose.yml          # Production stack (isolated networks)
├── docker-compose.dev.yml      # Dev overrides (hot-reload, exposed ports)
├── .env.example                # Environment variable template
└── .gitignore
```

---

## Quick Start

### Prerequisites

- Docker 24+ and Docker Compose 2+
- Node.js 18+ (for running tests locally without Docker)
- Git

### 1. Clone and initialise

```bash
git clone <repo-url> DTB-tets
cd DTB-tets
chmod +x scripts/*.sh
./scripts/setup.sh
```

`setup.sh` checks prerequisites, copies `.env.example` → `.env`, and auto-generates a JWT secret.

### 2. Set passwords

Edit `.env` and replace the placeholder passwords:

```bash
MONGO_ROOT_PASSWORD=your_strong_root_password
MONGO_APP_PASSWORD=your_strong_app_password
```

### 3. Build and start

```bash
./scripts/build.sh          # build Docker images
./scripts/deploy.sh up      # start MongoDB → Backend → Frontend
```

### 4. (Optional) Load demo data

```bash
./scripts/seed.sh
```

| Account Number | PIN  | Name           | Balance     |
|---------------|------|----------------|-------------|
| 1000000001    | 1234 | Alice Johnson  | KES 50,000  |
| 1000000002    | 2345 | Bob Smith      | KES 120,000 |
| 1000000003    | 3456 | Carol Williams | KES 8,500   |
| 1000000004    | 4567 | David Omondi   | KES 0       |

### 5. Open the app

**http://localhost:3000**

---

## Running Tests

```bash
./scripts/test.sh           # all tests
./scripts/test.sh unit       # unit tests only
./scripts/test.sh integration # integration tests only
./scripts/test.sh coverage   # with coverage report
./scripts/test.sh backend    # backend tests only
./scripts/test.sh frontend   # frontend tests only
```

---

## Key Security Controls

| Control | Implementation |
|---------|---------------|
| PIN hashing | bcrypt with 12 rounds |
| Brute-force protection | 5-attempt lockout (15 min) |
| Authentication | JWT, 1-hour expiry, ownership-checked per request |
| Input validation | express-validator on all endpoints |
| NoSQL injection | express-mongo-sanitize |
| HTTP headers | Helmet (CSP, X-Frame-Options, etc.) |
| Rate limiting | 5 req/min (auth), 100 req/min (general) |
| Network isolation | MongoDB never exposed to host; backend behind Nginx proxy |
| Container hardening | Non-root user, read-only filesystem, no-new-privileges |

See [security.md](security.md) for the full threat model and checklist.

---

## Other Docs

| Document | Read when you want to... |
|----------|--------------------------|
| [architecture.md](architecture.md) | Understand how services connect |
| [setup.md](setup.md) | Troubleshoot the local environment |
| [api-reference.md](api-reference.md) | Call the REST API directly |
| [security.md](security.md) | Audit the security posture |
| [cicd-pipeline.md](cicd-pipeline.md) | Set up the CI/CD pipeline |
