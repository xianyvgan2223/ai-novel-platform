<!--
  AgentAskCard.vue —— Agent 向用户提问的选择卡片
  点选项或提交自定义内容后立即收起，并显示「已提交」，不等服务端回执。
-->
<script setup lang="ts">
import { computed, ref } from 'vue';
import type { AgentAskPart } from '@/stores/agent';

const props = defineProps<{ part: AgentAskPart }>();
const emit = defineEmits<{ (event: 'answer', value: string, done: (ok: boolean) => void): void }>();

const custom = ref('');
const showCustom = ref(false);
const picked = ref('');
const submitting = ref(false);

const waiting = computed(() => props.part.status === 'waiting');
const collapsed = computed(() => !waiting.value || submitting.value || Boolean(picked.value));

function submit(value: string): void {
  const text = value.trim();
  if (!text || !waiting.value || submitting.value) return;
  picked.value = text;
  submitting.value = true;
  showCustom.value = false;
  custom.value = '';
  emit('answer', text, (ok: boolean) => {
    if (!ok) {
      // 提交失败：恢复成可编辑状态，避免卡片卡在「已提交」
      picked.value = '';
      submitting.value = false;
    }
  });
}

function submitCustom(): void {
  submit(custom.value);
}

function onCustomKeydown(event: KeyboardEvent): void {
  // 中文输入法组字时按回车只是上屏，不能当成提交答案
  if (event.isComposing || event.keyCode === 229) return;
  event.preventDefault();
  submitCustom();
}
</script>

<template>
  <div class="ask-card">
    <div class="ask-question">{{ part.question }}</div>

    <template v-if="!collapsed">
      <div class="ask-options">
        <button
          v-for="option in part.options"
          :key="option"
          class="ask-option"
          type="button"
          :disabled="submitting"
          @click="submit(option)"
        >
          {{ option }}
        </button>
      </div>

      <div v-if="showCustom" class="ask-custom">
        <input
          v-model="custom"
          class="ask-input"
          type="text"
          placeholder="输入你自己的答案"
          @keydown.enter="onCustomKeydown"
        />
        <button class="ask-confirm" type="button" @click="submitCustom">确定</button>
      </div>
      <button v-else class="ask-other" type="button" @click="showCustom = true">
        其他（自己输入）
      </button>
    </template>

    <div v-else class="ask-result">
      <template v-if="part.status === 'timeout'">未选择（已超时），Agent 将按默认方案继续</template>
      <template v-else-if="part.status === 'answered'">已选择：{{ part.answer }}</template>
      <template v-else>已提交「{{ picked }}」，等待 Agent 继续…</template>
    </div>
  </div>
</template>

<style scoped>
.ask-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 10px 12px;
  border-radius: 8px;
  background: var(--bg-soft);
  box-shadow: var(--shadow-control);
}

.ask-question {
  font-size: 12.5px;
  font-weight: 600;
  color: var(--ink-1);
  line-height: 1.6;
}

.ask-options {
  display: flex;
  flex-direction: column;
  gap: 5px;
}

.ask-option {
  width: 100%;
  padding: 7px 9px;
  border: none;
  border-radius: 6px;
  background: var(--bg-card);
  color: var(--ink-1);
  font-size: 11.5px;
  text-align: left;
  cursor: pointer;
  box-shadow: var(--shadow-control);
  transition: transform 0.12s ease, color 0.12s ease;
}

.ask-option:hover:not(:disabled) {
  color: var(--ink-1);
  transform: translateY(-1px);
}

.ask-other {
  align-self: flex-start;
  padding: 0;
  border: none;
  background: transparent;
  color: var(--ink-3);
  font-size: 11px;
  text-decoration: underline;
  cursor: pointer;
}

.ask-other:hover {
  color: var(--ink-1);
}

.ask-custom {
  display: flex;
  gap: 6px;
}

.ask-input {
  flex: 1;
  min-width: 0;
  padding: 6px 8px;
  border: none;
  border-radius: 6px;
  background: var(--bg-card);
  color: var(--ink-1);
  font-size: 11.5px;
  outline: none;
  box-shadow: var(--shadow-control);
}

.ask-confirm {
  padding: 6px 10px;
  border: none;
  border-radius: 6px;
  background: var(--brand);
  color: var(--primary-text);
  font-size: 11.5px;
  font-weight: 600;
  cursor: pointer;
}

.ask-result {
  font-size: 11.5px;
  color: var(--ink-3);
}
</style>
