# Security Controls & Hardening

## Threat Model

| Threat | Control |
|--------|---------|
| Brute-force PIN | 5-attempt lockout (15 min), auth rate limiter (5 req/min) |
| SQL/NoSQL injection | `express-mongo-sanitize`, `express-validator` input sanitisation |
| XSS | React's built-in escaping, CSP headers, `helmet` |
| Sensitive data exposure | PIN never returned in API, hashed with bcrypt (rounds=12) |
| JWT tampering | `jsonwebtoken` HS256 with 64-char secret, 1h expiry |
| Overprivileged DB access | Separate app user with `readWrite` only on `banking_db` |
| Container escape | `no-new-privileges`, non-root user in all containers |
| Large payload attacks | 10 KB body size limit on Express |
| Misconfigured CORS | Explicit allowlist; empty-origin (direct) denied in production |
| Information leakage | Production error messages sanitised; Winston redacts sensitive fields |
| HTTP header fingerprinting | `helmet` removes `X-Powered-By`, sets security headers |

## Authentication & Authorisation

### Authentication Flow
```
Client                 Backend                 MongoDB
  │                       │                       │
  │  POST /login           │                       │
  │  {accountNumber, pin}  │                       │
  │──────────────────────►│                       │
  │                       │  findOne({accNum})     │
  │                       │──────────────────────►│
  │                       │◄──────────────────────│
  │                       │  bcrypt.compare(pin)  │
  │                       │  (constant-time)       │
  │                       │                       │
  │  200 {token: JWT}      │                       │
  │◄──────────────────────│                       │
  │                       │                       │
  │  GET /accounts/:num    │                       │
  │  Authorization: Bearer │                       │
  │──────────────────────►│                       │
  │                       │  jwt.verify(token)    │
  │                       │  ownership check       │
  │  200 {account data}    │                       │
  │◄──────────────────────│                       │
```

### Ownership Enforcement
Every protected endpoint checks `req.account.accountNumber === req.params.accountNumber`.
A valid JWT for account A cannot access account B — returns 403.

## PIN Security
- Minimum 4 digits, maximum 6 digits
- Hashed with `bcryptjs` (salt rounds = 12, ~300ms per hash)
- Never stored or logged in plaintext
- `select: false` on schema — never returned unless explicitly requested
- Account locked for 15 minutes after 5 consecutive failures

## Input Validation
All inputs validated with `express-validator` before business logic:
- Account number: `/^\d{10}$/`
- PIN: `/^\d{4,6}$/`
- Email: RFC 5322 compliant, normalised to lowercase
- Phone: E.164 format `/^\+?[1-9]\d{6,14}$/`
- Amounts: Float 0.01–1,000,000
- All string fields: `.trim().escape()` to prevent XSS

## HTTP Security Headers (via Helmet)
```
Content-Security-Policy: default-src 'self'; script-src 'self'; ...
X-Frame-Options: SAMEORIGIN
X-Content-Type-Options: nosniff
X-XSS-Protection: 1; mode=block
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: camera=(), microphone=(), geolocation=()
```

## Docker Security
- **Non-root users**: `appuser` in backend, `nginx` in frontend
- **Read-only filesystem**: `read_only: true` with `tmpfs` for writable paths
- **No new privileges**: `security_opt: no-new-privileges:true`
- **Network isolation**: MongoDB unreachable from host or browser
- **Minimal base images**: Alpine variants to reduce attack surface
- **No secrets in images**: All secrets passed via environment variables

## Secrets Management
- All secrets in `.env` file (never committed — in `.gitignore`)
- `.env.example` contains only placeholder values
- JWT_SECRET validated at startup (min 32 chars)
- Docker Compose uses `${VAR:?error}` syntax — fails fast if secrets missing

## Rate Limiting
| Endpoint | Limit |
|----------|-------|
| `POST /api/accounts/login` | 5 req/min per IP |
| All other endpoints | 100 req/min per IP |

## Security Checklist

- [x] Passwords/PINs hashed with bcrypt (rounds ≥ 12)
- [x] JWT with short expiry (1h)
- [x] PIN brute-force lockout
- [x] Input validation on all endpoints
- [x] NoSQL injection prevention
- [x] HTTP security headers
- [x] CORS allowlist
- [x] Rate limiting
- [x] Non-root containers
- [x] Read-only container filesystem
- [x] Secrets via environment variables only
- [x] MongoDB not exposed to host
- [x] Backend not exposed to host (proxied via Nginx)
- [x] Sensitive log fields redacted
- [x] Body size limit (10 KB)
- [ ] HTTPS (add TLS termination at reverse proxy / load balancer in production)
- [ ] Secrets rotation (use Vault or cloud secret manager in production)
- [ ] Container image scanning (add Trivy in CI pipeline)
