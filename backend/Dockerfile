# ---- Build Stage ----
FROM node:20-alpine AS deps
WORKDIR /app
# Only copy package files first for better layer caching
COPY package*.json ./
RUN npm ci --only=production && npm cache clean --force

# ---- Production Stage ----
FROM node:20-alpine AS production
# Security: create non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy production dependencies
COPY --from=deps /app/node_modules ./node_modules

# Copy application source
COPY src/ ./src/

# Ownership
RUN chown -R appuser:appgroup /app

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 5000

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD wget -qO- http://localhost:5000/health || exit 1

# Start server
CMD ["node", "src/server.js"]
