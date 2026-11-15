<!--
  AgentTaskCard.vue —— 复杂任务的多步计划清单
  显示「已完成 / 总数」，每一步有状态图标，Agent 调 update_task_step 时实时更新。
-->
<script setup lang="ts">
import { computed, ref } from 'vue';
import { CircleCheck, CircleClose, Loading, Minus } from '@element-plus/icons-vue';
import type { AgentTask } from '@/api/agent';

const props = defineProps<{ task: AgentTask }>();

const expanded = ref(true);

const finished = computed(
  () => props.task.steps.filter((step) => step.status === 'done' || step.status === 'skipped').length,
);
const total = computed(() => props.task.steps.length);
</script>

<template>
  <div class="task-card" :class="{ done: task.status === 'done' }">
    <button class="task-head" type="button" @click="expanded = !expanded">
      <span class="task-dot" :class="{ running: task.status !== 'done' }" />
      <span class="task-title">{{ task.title }}</span>
      <span class="task-progress">{{ finished }}/{{ total }}</span>
      <span class="task-caret">{{ expanded ? '收起' : '展开' }}</span>
    </button>

    <ol v-if="expanded" class="task-steps">
      <li v-for="(step, index) in task.steps" :key="index" :class="step.status">
        <el-icon class="step-icon" :class="{ spin: step.status === 'running' }">
          <Loading v-if="step.status === 'running'" />
          <CircleCheck v-else-if="step.status === 'done'" />
          <CircleClose v-else-if="step.status === 'skipped'" />
          <Minus v-else />
        </el-icon>
        <span class="step-text">{{ step.text }}</span>
      </li>
    </ol>
  </div>
</template>

<style scoped>
.task-card {
  flex: 0 0 auto;
  margin: 0 12px 6px;
  border: none;
  border-radius: 8px;
  background: var(--bg-soft);
  box-shadow: var(--shadow-control);
  overflow: hidden;
}

.task-card.done {
  box-shadow: var(--shadow-card);
}

.task-head {
  display: flex;
  align-items: center;
  gap: 7px;
  width: 100%;
  padding: 7px 10px;
  border: none;
  background: transparent;
  cursor: pointer;
  text-align: left;
  color: var(--ink-1);
}

.task-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--ok);
  flex: 0 0 7px;
}

.task-dot.running {
  background: var(--warning);
  animation: task-pulse 1.2s ease-in-out infinite;
}

@keyframes task-pulse {
  50% {
    opacity: 0.35;
  }
}

.task-title {
  flex: 1;
  min-width: 0;
  font-size: 12px;
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.task-progress {
  font-size: 11px;
  color: var(--ink-3);
  font-variant-numeric: tabular-nums;
}

.task-caret {
  font-size: 10.5px;
  color: var(--ink-4);
}

.task-steps {
  margin: 0;
  padding: 2px 10px 9px 10px;
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 5px;
}

.task-steps li {
  display: flex;
  align-items: flex-start;
  gap: 7px;
  font-size: 11.5px;
  line-height: 1.55;
  color: var(--ink-2);
}

.task-steps li.done .step-text {
  color: var(--ink-3);
  text-decoration: line-through;
}

.task-steps li.skipped .step-text {
  color: var(--ink-4);
  text-decoration: line-through;
}

.step-icon {
  flex: 0 0 auto;
  margin-top: 2px;
  font-size: 12px;
  color: var(--ink-4);
}

.task-steps li.running .step-icon {
  color: var(--warning);
}

.task-steps li.done .step-icon {
  color: var(--ok);
}

.step-icon.spin {
  animation: task-spin 1s linear infinite;
}

@keyframes task-spin {
  to {
    transform: rotate(360deg);
  }
}
</style>
