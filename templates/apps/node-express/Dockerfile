FROM node:22-alpine

WORKDIR /app

# Install dependencies first (layer caching)
COPY package*.json ./
RUN npm install

# Copy source
COPY . .

# Default: run with file watching via --watch (Node 22+)
# Override in docker-compose if you prefer nodemon
EXPOSE 3000
CMD ["node", "--watch", "src/index.js"]
