FROM node:20-alpine

# docker-cli：用來對 target 容器下 docker exec；python3/make/g++：node-pty 編譯用
RUN apk add --no-cache docker-cli bash python3 make g++

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY src ./src

EXPOSE 3000
CMD ["npm", "start"]
