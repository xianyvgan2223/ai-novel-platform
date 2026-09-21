<script setup lang="ts">
defineProps<{
  title: string;
  desc?: string;
}>();
</script>

<template>
  <div class="page-head">
    <div>
      <h1 class="page-title">{{ title }}</h1>
      <p v-if="desc" class="page-desc">{{ desc }}</p>
    </div>
    <div class="page-actions">
      <slot name="actions" />
    </div>
  </div>
</template>
