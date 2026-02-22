FROM node:22-alpine
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY server/ server/
COPY public/ public/
RUN mkdir -p data
EXPOSE 3800
CMD ["node", "server/index.js"]
