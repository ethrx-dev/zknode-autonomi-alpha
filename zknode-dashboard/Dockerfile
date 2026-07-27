FROM node:22-alpine
RUN apk add --no-cache docker-cli curl iproute2
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY server/ ./server/
COPY public/ ./public/
EXPOSE 8080
CMD ["node", "server/index.js"]
