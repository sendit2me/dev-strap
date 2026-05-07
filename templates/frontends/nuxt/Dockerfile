FROM node:22-alpine

WORKDIR /app

# Install dependencies first (layer caching)
COPY package*.json ./
RUN npm install

# Don't COPY source — volume-mounted in dev

# Nuxt dev server
EXPOSE 3000

# --host 0.0.0.0: required for Docker (listen on all interfaces)
CMD ["npx", "nuxt", "dev", "--host", "0.0.0.0"]
