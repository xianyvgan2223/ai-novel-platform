<!-- 设置项标签：说明默认隐藏，悬停问号才显示 -->
<script setup lang="ts">
import { InfoFilled } from '@element-plus/icons-vue';

defineProps<{ text: string }>();
</script>

<template>
  <span class="setting-label">
    <slot />
    <el-tooltip :content="text" placement="top" :show-after="150">
      <el-icon class="setting-info"><InfoFilled /></el-icon>
    </el-tooltip>
  </span>
</template>

<style scoped>
.setting-label {
  display: inline-flex;
  align-items: center;
  gap: 4px;
}

.setting-info {
  font-size: 12px;
  color: var(--ink-4);
  cursor: help;
}

.setting-info:hover {
  color: var(--ink-2);
}
</style>
