# Setup Guide

## Prerequisites

| Tool | Minimum Version | Check |
|------|----------------|-------|
| Node.js | 18.x | `node -v` |
| npm | 9.x | `npm -v` |
| Docker | 24.x | `docker -v` |
| Docker Compose | 2.x | `docker compose version` |
| Git | 2.x | `git -v` |

## Local Development Setup

### 1. Clone and setup

```bash
git clone <repo-url> DTB-tets
cd DTB-tets
chmod +x scripts/*.sh
./scripts/setup.sh
```

`setup.sh` will:
- Check all prerequisites
- Copy `.env.example` → `.env` and auto-generate a JWT secret
- Install backend `node_modules`
- Install frontend `node_modules`

### 2. Configure environment

Edit `.env` and set **strong passwords** for:
```bash
MONGO_ROOT_PASSWORD=your_strong_root_password
MONGO_APP_PASSWORD=your_strong_app_password
```

The JWT_SECRET is auto-generated. You can verify it:
```bash
grep JWT_SECRET .env
```

### 3. Build Docker images

```bash
./scripts/build.sh
```

### 4. Start the stack

```bash
./scripts/deploy.sh up
```

Services start in dependency order: MongoDB → Backend → Frontend

### 5. Load demo data (optional)

```bash
./scripts/seed.sh
```

This creates 4 demo accounts with known PINs for testing.

### 6. Access the application

Open **http://localhost:3000**

## Running Tests

```bash
# All tests
./scripts/test.sh

# Backend only
./scripts/test.sh backend

# Frontend only
./scripts/test.sh frontend

# Unit tests only
./scripts/test.sh unit

# Integration tests only
./scripts/test.sh integration

# With coverage report
./scripts/test.sh coverage
```

## Useful Commands

```bash
# View logs
./scripts/deploy.sh logs
./scripts/deploy.sh logs backend
./scripts/deploy.sh logs frontend

# Check service status
./scripts/deploy.sh status

# Run health checks
./scripts/health-check.sh

# Stop stack
./scripts/deploy.sh down

# Stop and remove all data (DESTRUCTIVE)
./scripts/deploy.sh clean
```

## Development Mode (with hot-reload)

```bash
# Start with dev overrides
docker-compose -f docker-compose.yml -f docker-compose.dev.yml up
```

This enables:
- Backend: nodemon auto-reload on file changes
- Frontend: React dev server with HMR
- MongoDB port exposed on host for GUI tools (MongoDB Compass)

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `MONGO_APP_PASSWORD is required` | Ensure `.env` has all required variables |
| Backend container restarts | Check `docker logs banking_backend` for startup errors |
| `Cannot connect to MongoDB` | Wait for MongoDB healthcheck to pass (~40s on first start) |
| Port 3000 already in use | Set `FRONTEND_PORT=3001` in `.env` |
| Tests fail with connection errors | `mongodb-memory-server` downloads on first run — check internet |
