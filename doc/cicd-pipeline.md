# CI/CD Pipeline & GitOps

## Overview

The pipeline follows a **GitOps model**: the Git repository is the single source of truth. Every change goes through automated quality gates before reaching production.

```
Developer                 Git Remote              CI/CD Runner
    │                          │                       │
    │  git push (feature/)     │                       │
    │─────────────────────────►│                       │
    │                          │  Trigger CI           │
    │                          │──────────────────────►│
    │                          │                       │ 1. Lint & SAST
    │                          │                       │ 2. Unit tests
    │                          │                       │ 3. Integration tests
    │                          │                       │ 4. Coverage check
    │                          │                       │ 5. Docker build
    │                          │                       │ 6. Image scan (Trivy)
    │                          │                       │ 7. Push to registry
    │                          │                       │
    │  PR merged to main       │                       │
    │─────────────────────────►│                       │
    │                          │──────────────────────►│ 8. Deploy to staging
    │                          │                       │ 9. Smoke tests
    │                          │                       │ 10. Deploy to prod (manual gate)
```

## Pipeline Stages

### Stage 1: Code Quality
```bash
# ESLint for frontend
cd frontend && npx eslint src/

# Backend linting (if configured)
cd backend && npx eslint src/
```

### Stage 2: Security Scanning (SAST)
```bash
# npm audit for known vulnerabilities
npm audit --audit-level=high

# Dockerfile linting
hadolint backend/Dockerfile frontend/Dockerfile

# Secret scanning
git secrets --scan  # or truffleHog
```

### Stage 3: Unit Tests
```bash
./scripts/test.sh unit
```
- Backend model tests with in-memory MongoDB
- Frontend component tests with React Testing Library
- **Gate**: All tests must pass

### Stage 4: Integration Tests
```bash
./scripts/test.sh integration
```
- Full API tests with in-memory MongoDB
- Tests auth, transactions, security (NoSQL injection, oversized bodies)
- **Gate**: All tests must pass

### Stage 5: Coverage
```bash
./scripts/test.sh coverage
```
- Backend: 80% line coverage minimum
- Frontend: 60% line coverage minimum

### Stage 6: Docker Build & Scan
```bash
./scripts/build.sh $GIT_COMMIT_SHA

# Vulnerability scan
trivy image banking-backend:$GIT_COMMIT_SHA
trivy image banking-frontend:$GIT_COMMIT_SHA
```

### Stage 7: Push to Registry
```bash
docker tag banking-backend:$SHA $REGISTRY/banking-backend:$SHA
docker push $REGISTRY/banking-backend:$SHA
```

### Stage 8: Deploy
```bash
# Update image tags in compose/k8s manifests
sed -i "s|banking-backend:.*|banking-backend:${SHA}|" docker-compose.yml
./scripts/deploy.sh up
./scripts/health-check.sh
```

## GitHub Actions Workflow (Example)

```yaml
# .github/workflows/ci.yml
name: CI/CD Pipeline

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }

      - name: Install dependencies
        run: |
          cd backend && npm ci
          cd ../frontend && npm ci

      - name: Security audit
        run: |
          cd backend && npm audit --audit-level=high
          cd ../frontend && npm audit --audit-level=high

      - name: Run all tests
        run: ./scripts/test.sh all
        env:
          CI: true

  build:
    needs: test
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - name: Build images
        run: ./scripts/build.sh ${{ github.sha }}

      - name: Scan images
        run: |
          trivy image --exit-code 1 --severity HIGH,CRITICAL banking-backend:${{ github.sha }}

      - name: Push to registry
        run: |
          echo ${{ secrets.REGISTRY_PASSWORD }} | docker login -u ${{ secrets.REGISTRY_USER }} --password-stdin
          docker push banking-backend:${{ github.sha }}
          docker push banking-frontend:${{ github.sha }}

  deploy-staging:
    needs: build
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - name: Deploy to staging
        run: ./scripts/deploy.sh up
```

## GitOps Principles Applied

1. **Declarative**: All infrastructure defined in `docker-compose.yml`
2. **Versioned**: Every change tracked in Git with commit SHA
3. **Automated**: No manual deployment steps before staging
4. **Observable**: Health checks validate every deployment
5. **Auditable**: Git log is the full audit trail

## Branch Strategy

```
main          ←── Protected, requires PR + passing CI
  └── develop ←── Integration branch
        └── feature/xxx  ←── Developer branches
        └── fix/xxx
        └── chore/xxx
```

## Secrets Management in CI

| Secret | Storage |
|--------|---------|
| `MONGO_ROOT_PASSWORD` | CI/CD secrets store (GitHub Secrets / Vault) |
| `MONGO_APP_PASSWORD` | CI/CD secrets store |
| `JWT_SECRET` | CI/CD secrets store |
| `REGISTRY_PASSWORD` | CI/CD secrets store |

**Never** hardcode secrets in any file tracked by Git.
