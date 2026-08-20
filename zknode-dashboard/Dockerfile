FROM node:22-alpine
RUN apk add --no-cache docker-cli
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm install --omit=dev
COPY server/ ./server/
COPY public/ ./public/
RUN addgroup -S app && adduser -S app -G app
USER app
EXPOSE 8080
CMD ["node", "server/index.js"]
