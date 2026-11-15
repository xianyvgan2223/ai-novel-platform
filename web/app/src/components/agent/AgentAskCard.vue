<!--
  AgentAskCard.vue —— Agent 向用户提问的选择卡片
  用户点选项即可继续；也可以切到「其他」自己输入。
-->
<script setup lang="ts">
import { computed, ref } from 'vue';
import type { AgentAskPart } from '@/stores/agent';

const props = defineProps<{ part: AgentAskPart }>();
const emit = defineEmits<{ (event: 'answer', value: string): void }>();

const custom = ref('');
const showCustom = ref(false);

const waiting = computed(() => props.part.status === 'waiting');

function choose(value: string): void {
  if (!waiting.value || !value.trim()) return;
  emit('answer', value.trim());
}

function submitCustom(): void {
  const value = custom.value.trim();
  if (!value) return;
  showCustom.value = false;
  custom.value = '';
  emit('answer', value);
}
</script>

<template>
  <div class="ask-card">
    <div class="ask-question">{{ part.question }}</div>

    <template v-if="waiting">
      <div class="ask-options">
        <button
          v-for="option in part.options"
          :key="option"
          class="ask-option"
          type="button"
          @click="choose(option)"
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
          @keydown.enter.prevent="submitCustom"
        />
        <button class="ask-confirm" type="button" @click="submitCustom">确定</button>
      </div>
      <button v-else class="ask-other" type="button" @click="showCustom = true">
        其他（自己输入）
      </button>
    </template>

    <div v-else class="ask-result">
      <template v-if="part.status === 'answered'">已选择：{{ part.answer }}</template>
      <template v-else>未选择（已超时），Agent 将按默认方案继续</template>
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

.ask-option:hover {
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
  background: var(--brand, #0fdc78);
  color: var(--brand-on, #004d26);
  font-size: 11.5px;
  font-weight: 600;
  cursor: pointer;
}

.ask-result {
  font-size: 11.5px;
  color: var(--ink-3);
}
</style>
