<script setup lang="ts">
import type { Component } from 'vue';

const props = withDefaults(
  defineProps<{
    label: string;
    value: number | string;
    hint?: string;
    icon?: Component;
    tone?: 'brand' | 'violet' | 'emerald' | 'amber' | 'cyan' | 'rose';
    clickable?: boolean;
  }>(),
  { tone: 'brand', clickable: false },
);

void props;
</script>

<template>
  <div class="stat" :class="['tone-' + tone, { clickable }]">
    <div class="stat-top">
      <span class="stat-label">{{ label }}</span>
      <span v-if="icon" class="stat-icon"><component :is="icon" /></span>
    </div>
    <div class="stat-value">{{ value }}</div>
    <div v-if="hint" class="stat-hint mono">{{ hint }}</div>
  </div>
</template>

<style scoped>
.stat {
  position: relative;
  background: var(--bg-card);
  border-radius: 0;
  padding: 19px 22px 17px;
  box-shadow: none;
  border: none;
  transition: background 0.16s ease;
  overflow: hidden;
}

.stat.clickable { cursor: pointer; }
.stat.clickable:hover { background: var(--bg-soft); }

.stat-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.stat-label {
  font-size: 12.5px;
  color: var(--ink-3);
  font-weight: 500;
  letter-spacing: 0.4px;
}

.stat-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: auto;
  height: auto;
  border-radius: 0;
  background: transparent;
  color: var(--ink-3);
  font-size: 15px;
}

.stat-value {
  margin-top: 12px;
  font-size: 32px;
  line-height: 1;
  font-weight: 600;
  letter-spacing: -1.2px;
  color: var(--ink-1);
}

.stat-hint {
  margin-top: 9px;
  color: var(--ink-3);
  font-size: 11.5px;
  letter-spacing: 0.2px;
}
</style>