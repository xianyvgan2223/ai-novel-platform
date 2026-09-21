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
  background: #fff;
  border-radius: var(--r-md);
  padding: 16px 18px 14px;
  box-shadow: var(--shadow-1);
  border: 1px solid var(--line);
  transition: transform 0.16s ease, box-shadow 0.16s ease;
  overflow: hidden;
}

.stat::before {
  content: '';
  position: absolute;
  inset: 0 auto 0 0;
  width: 3px;
  background: var(--tone-color);
  opacity: 0.9;
}

.stat.clickable { cursor: pointer; }
.stat.clickable:hover { transform: translateY(-2px); box-shadow: var(--shadow-2); }

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
}

.stat-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 26px;
  border-radius: 8px;
  background: var(--tone-soft);
  color: var(--tone-color);
  font-size: 14px;
}

.stat-value {
  margin-top: 8px;
  font-size: 30px;
  line-height: 1.1;
  font-weight: 660;
  letter-spacing: -0.8px;
  color: var(--ink-1);
}

.stat-hint {
  margin-top: 6px;
  color: var(--ink-4);
  font-size: 11px;
}

.tone-brand { --tone-color: var(--brand); --tone-soft: var(--brand-soft); }
.tone-violet { --tone-color: var(--violet); --tone-soft: var(--violet-soft); }
.tone-emerald { --tone-color: var(--ok); --tone-soft: var(--ok-soft); }
.tone-amber { --tone-color: var(--warn); --tone-soft: var(--warn-soft); }
.tone-cyan { --tone-color: var(--cyan); --tone-soft: var(--cyan-soft); }
.tone-rose { --tone-color: var(--danger); --tone-soft: var(--danger-soft); }
</style>
