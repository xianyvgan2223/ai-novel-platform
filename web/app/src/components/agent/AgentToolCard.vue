<!--
  AgentToolCard.vue —— 一次工具调用的可视卡片
  折叠态只显示「工具名 + 结果摘要 + 耗时」；展开后能看到完整入参与返回，
  对齐 DeepSeek harness 的「调用可见」体验。
-->
<script setup lang="ts">
import { computed, ref } from 'vue';
import { CircleCheck, CircleClose, Loading } from '@element-plus/icons-vue';
import type { AgentToolPart } from '@/stores/agent';

const props = defineProps<{ part: AgentToolPart }>();

const expanded = ref(false);

const TOOL_LABELS: Record<string, string> = {
  get_overview: '查看数据概览',
  list_data: '查询数据表',
  get_row: '查看记录详情',
  search_rag: '检索情节素材',
  rag_status: '素材库状态',
  generate_outline: '生成大纲',
  list_outlines: '列出大纲',
  generate_chapter: '生成章节',
};

const label = computed(() => TOOL_LABELS[props.part.name] ?? props.part.name);

const statusText = computed(() => {
  if (props.part.status === 'running') return '执行中';
  if (props.part.status === 'ok') return '完成';
  return '失败';
});

const elapsedText = computed(() => {
  const ms = props.part.elapsedMs ?? 0;
  if (!ms) return '';
  return ms >= 1000 ? (ms / 1000).toFixed(1) + 's' : ms + 'ms';
});

function pretty(value: unknown): string {
  if (value === undefined || value === null) return '';
  try {
    const text = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
    return text.length > 6000 ? text.slice(0, 6000) + '\n…（已截断）' : text;
  } catch {
    return String(value);
  }
}

const argsText = computed(() => pretty(props.part.args));
const resultText = computed(() => pretty(props.part.data));
</script>

<template>
  <div class="tool-card" :class="part.status">
    <button class="tool-head" type="button" @click="expanded = !expanded">
      <el-icon class="tool-icon" :class="{ spin: part.status === 'running' }">
        <Loading v-if="part.status === 'running'" />
        <CircleClose v-else-if="part.status === 'error'" />
        <CircleCheck v-else />
      </el-icon>

      <span class="tool-main">
        <span class="tool-name">{{ label }}</span>
        <span v-if="part.summary" class="tool-summary">{{ part.summary }}</span>
        <span v-else-if="part.error" class="tool-summary error">{{ part.error }}</span>
      </span>

      <span class="tool-meta mono">
        <span v-if="elapsedText">{{ elapsedText }}</span>
        <span class="tool-status">{{ statusText }}</span>
        <span class="tool-caret">{{ expanded ? '收起' : '详情' }}</span>
      </span>
    </button>

    <div v-if="expanded" class="tool-body">
      <div class="tool-section">
        <div class="tool-section-title">调用参数</div>
        <pre class="tool-pre">{{ argsText || '（无参数）' }}</pre>
      </div>
      <div class="tool-section">
        <div class="tool-section-title">返回内容</div>
        <pre class="tool-pre">{{ part.status === 'error' ? part.error : (resultText || '（等待返回）') }}</pre>
      </div>
    </div>
  </div>
</template>

<style scoped>
.tool-card {
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--bg-soft);
  overflow: hidden;
}

.tool-card.error {
  border-color: var(--danger);
}

.tool-head {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  padding: 8px 10px;
  border: none;
  background: transparent;
  text-align: left;
  cursor: pointer;
  color: var(--ink-1);
}

.tool-head:hover {
  background: var(--bg-card);
}

.tool-icon {
  flex: 0 0 auto;
  font-size: 14px;
  color: var(--ink-3);
}

.tool-card.ok .tool-icon {
  color: var(--ok);
}

.tool-card.error .tool-icon {
  color: var(--danger);
}

.tool-icon.spin {
  animation: tool-spin 1s linear infinite;
}

@keyframes tool-spin {
  to {
    transform: rotate(360deg);
  }
}

.tool-main {
  display: flex;
  flex-direction: column;
  gap: 1px;
  min-width: 0;
  flex: 1;
}

.tool-name {
  font-size: 12px;
  font-weight: 600;
  color: var(--ink-1);
}

.tool-summary {
  font-size: 11px;
  color: var(--ink-3);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.tool-summary.error {
  color: var(--danger);
}

.tool-meta {
  display: flex;
  align-items: center;
  gap: 6px;
  flex: 0 0 auto;
  font-size: 10.5px;
  color: var(--ink-4);
}

.tool-status {
  padding: 1px 5px;
  border-radius: 4px;
  border: 1px solid var(--line-strong);
}

.tool-caret {
  color: var(--ink-3);
}

.tool-body {
  border-top: 1px solid var(--line);
  padding: 8px 10px 10px;
  background: var(--bg-card);
}

.tool-section + .tool-section {
  margin-top: 8px;
}

.tool-section-title {
  font-size: 10.5px;
  font-weight: 600;
  color: var(--ink-3);
  margin-bottom: 4px;
}

.tool-pre {
  margin: 0;
  max-height: 220px;
  overflow: auto;
  padding: 8px;
  border-radius: 6px;
  background: var(--bg-soft);
  border: 1px solid var(--line);
  font-family: var(--font-mono, ui-monospace, monospace);
  font-size: 11px;
  line-height: 1.55;
  color: var(--ink-2);
  white-space: pre-wrap;
  word-break: break-word;
}
</style>
