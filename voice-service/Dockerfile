FROM node:24-slim
WORKDIR /app
RUN npm install -g pnpm@10.33.2
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --prod --frozen-lockfile
COPY src ./src
ENV PORT=8787 DATABASE_PATH=/data/voice.sqlite
EXPOSE 8787
CMD ["node", "src/server.ts"]
