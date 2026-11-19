<!-- 思考过程：生成中自动展开，思考结束（后续正文/工具卡到达）后自动收起，仍可手动展开 -->
<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { ArrowDown, ArrowRight } from '@element-plus/icons-vue';

const props = defineProps<{ text: string; streaming?: boolean }>();

const expanded = ref(Boolean(props.streaming));

watch(
  () => props.streaming,
  (value) => {
    // 思考结束时自动收起；新一轮思考开始时再展开
    expanded.value = Boolean(value);
  },
);

const chars = computed(() => props.text.length);
</script>

<template>
  <div class="thinking">
    <button class="thinking-head" type="button" @click="expanded = !expanded">
      <el-icon class="thinking-caret">
        <ArrowDown v-if="expanded" />
        <ArrowRight v-else />
      </el-icon>
      <span class="thinking-title">思考过程</span>
      <span class="thinking-meta">{{ chars }} 字{{ streaming ? ' · 进行中' : '' }}</span>
    </button>
    <div v-if="expanded" class="thinking-body">{{ text }}</div>
  </div>
</template>

<style scoped>
.thinking {
  border-radius: 8px;
  background: var(--bg-soft);
  box-shadow: var(--shadow-control);
  overflow: hidden;
}

.thinking-head {
  display: flex;
  align-items: center;
  gap: 6px;
  width: 100%;
  padding: 6px 10px;
  border: none;
  background: transparent;
  color: var(--ink-3);
  cursor: pointer;
  text-align: left;
}

.thinking-caret {
  font-size: 11px;
}

.thinking-title {
  font-size: 11.5px;
  font-weight: 600;
}

.thinking-meta {
  margin-left: auto;
  font-size: 10.5px;
  color: var(--ink-4);
}

.thinking-body {
  max-height: 260px;
  overflow-y: auto;
  padding: 0 10px 9px;
  font-size: 11.5px;
  line-height: 1.65;
  color: var(--ink-3);
  white-space: pre-wrap;
  word-break: break-word;
}
</style>
