// Minimal Nuxt 3 config shipped by dev-strap so `./devstack.sh start`
// succeeds before the user has written any frontend code. Overwrite
// freely.
//
// devServer.host=0.0.0.0 is set in the Dockerfile CMD (`nuxt dev --host`),
// so Nuxt is reachable from outside the container.
//
// In the agentic-dev preset the Nuxt server runs as the FE+BFF; Caddy
// path-routes /api/* to the Go backend and everything else here.
export default defineNuxtConfig({
  devtools: { enabled: false },
  ssr: true,
  // The runtime API base is wired up by dev-strap via NUXT_PUBLIC_API_BASE
  // (see services/frontend.yml). It defaults to '/api'.
  runtimeConfig: {
    public: {
      apiBase: process.env.NUXT_PUBLIC_API_BASE ?? '/api',
    },
  },
})
