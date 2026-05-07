<!--
  Minimal Nuxt 3 root component shipped by dev-strap. This is a "hello,
  devstack" placeholder so the dev server has something to render
  before you write your real UI. Overwrite freely.
-->
<template>
  <div class="devstack-stub">
    <h1>Nuxt is running</h1>
    <p>
      This is the dev-strap stub <code>app.vue</code>. Edit
      <code>frontend/app.vue</code> to start building your app.
    </p>
    <p>
      API base: <code>{{ apiBase }}</code>
    </p>
  </div>
</template>

<script setup lang="ts">
const config = useRuntimeConfig()
const apiBase = config.public.apiBase
</script>

<style scoped>
.devstack-stub {
  font-family: system-ui, sans-serif;
  max-width: 40rem;
  margin: 4rem auto;
  padding: 1.5rem;
  line-height: 1.5;
}
.devstack-stub code {
  background: #f4f4f5;
  padding: 0.1em 0.3em;
  border-radius: 3px;
}
</style>
