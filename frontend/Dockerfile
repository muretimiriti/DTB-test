# ---- Build Stage ----
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY public/ ./public/
COPY src/ ./src/
ARG REACT_APP_API_URL=http://localhost:5000
ENV REACT_APP_API_URL=$REACT_APP_API_URL
RUN npm run build

# ---- Serve Stage ----
FROM nginx:1.27-alpine AS production
# Remove default nginx static assets
RUN rm -rf /usr/share/nginx/html/*
# Copy built React app
COPY --from=builder /app/build /usr/share/nginx/html
# Copy nginx configuration
COPY nginx.conf /etc/nginx/conf.d/default.conf
# Remove server version header
RUN sed -i 's/# server_tokens/server_tokens/' /etc/nginx/nginx.conf 2>/dev/null || true
# Non-root user (nginx already uses nginx user)
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://localhost/health || exit 1
CMD ["nginx", "-g", "daemon off;"]
