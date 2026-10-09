import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  define: {
    __BUILD_TIME__: JSON.stringify(new Date().toISOString()),
    __APP_VERSION__: JSON.stringify(process.env.npm_package_version || ''),
  },
  // Rust-криптография грузит .wasm через new URL(..., import.meta.url);
  // предварительная сборка зависимостей в dev-режиме это ломает.
  optimizeDeps: { exclude: ['@matrix-org/matrix-sdk-crypto-wasm'] },
  build: { target: 'es2022' },
  server: { port: 5173 },
});
