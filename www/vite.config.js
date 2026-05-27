import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    headers: {
      // Allow cross-origin isolation for SharedArrayBuffer (not needed here
      // but good practice for WASM workers).
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
    },
  },
  // WASM files are served from public/ so they keep their original name.
  build: {
    target: 'esnext',
  },
  worker: {
    format: 'es',
  },
});
