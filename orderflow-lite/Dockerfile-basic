# Minimal Dockerfile — just enough to build and run OrderFlow-Lite.
# No multi-stage build, no hardening (see the real Dockerfile for that).

FROM node:20-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm install

COPY src ./src
COPY sql ./sql

EXPOSE 3000

CMD ["node", "src/index.js"]
