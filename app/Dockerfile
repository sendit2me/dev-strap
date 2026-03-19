FROM node:22-alpine

WORKDIR /app

# Install dependencies (layer caching)
COPY package*.json ./
RUN npm install

# Copy source
COPY . .

# Trust the devstack CA certificate for HTTPS mock interception
# The ca.crt is mounted at runtime via docker-compose volume
# NODE_EXTRA_CA_CERTS is set in the environment

EXPOSE 3000
CMD ["node", "--watch", "src/index.js"]
