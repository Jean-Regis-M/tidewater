import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
// On GitHub Pages the site is served from /tidewater/, locally from /.
export default defineConfig({
  base: process.env.GITHUB_PAGES ? '/tidewater/' : '/',
  plugins: [react()],
})
