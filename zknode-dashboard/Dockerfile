FROM node:22-alpine
RUN apk add --no-cache docker-cli openssh-client
COPY vps_key /tmp/vps_key
RUN mkdir -p /root/.ssh && mv /tmp/vps_key /root/.ssh/vps_key && chmod 700 /root/.ssh && chmod 600 /root/.ssh/vps_key
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY server/ ./server/
COPY public/ ./public/
RUN addgroup -S app && adduser -S app -G app
EXPOSE 8080
CMD ["node", "server/index.js"]
