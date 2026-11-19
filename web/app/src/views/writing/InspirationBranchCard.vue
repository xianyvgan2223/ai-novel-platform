<script setup lang="ts">
import { Check, Delete, EditPen, Star } from '@element-plus/icons-vue';
import RichText from '@/components/RichText.vue';
import type { InspirationBranch } from './inspirationApi';

defineProps<{
  branch: InspirationBranch;
  label: string;
  picked: boolean;
  canPick: boolean;
}>();
const emit = defineEmits<{
  (event: 'choose'): void;
  (event: 'edit'): void;
  (event: 'delete'): void;
  (event: 'pick', value: boolean): void;
}>();
</script>

<template>
  <article class="branch-card" :class="{ chosen: branch.chosen }">
    <div class="branch-head">
      <span class="branch-kind" :class="{ merge: branch.kind === 'merge' }">{{ label }}</span>
      <span v-if="branch.chosen" class="chosen-tag"><el-icon><Star /></el-icon> 已采用</span>
      <span class="branch-chars">{{ branch.content.trim().length }} 字</span>
    </div>

    <div class="branch-body">
      <RichText :text="branch.content" />
    </div>

    <div class="branch-foot">
      <el-checkbox
        v-if="canPick"
        :model-value="picked"
        :disabled="branch.chosen"
        @change="(value) => emit('pick', Boolean(value))"
      >
        参与合并
      </el-checkbox>
      <span v-else class="branch-spacer" />
      <div class="branch-actions">
        <el-button size="small" text :icon="Check" :disabled="branch.chosen" @click="emit('choose')">
          采用
        </el-button>
        <el-button size="small" text :icon="EditPen" @click="emit('edit')">编辑</el-button>
        <el-button size="small" text type="danger" :icon="Delete" @click="emit('delete')">删除</el-button>
      </div>
    </div>
  </article>
</template>

<style scoped>
.branch-card {
  display: flex;
  flex-direction: column;
  min-width: 0;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--bg-card);
  transition: border-color 0.16s ease, box-shadow 0.16s ease;
}

.branch-card:hover { border-color: var(--line-strong); box-shadow: var(--shadow-control); }
.branch-card.chosen { border-color: var(--ink-3); box-shadow: var(--shadow-card); }

.branch-head {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 10px 13px 0;
}

.branch-kind {
  padding: 1px 6px;
  border: 1px solid var(--line);
  border-radius: 5px;
  background: var(--bg-soft);
  color: var(--ink-3);
  font-size: 10.5px;
}

.branch-kind.merge { color: var(--brand); border-color: var(--line-strong); }

.chosen-tag {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  padding: 1px 6px;
  border-radius: 5px;
  background: var(--brand-soft);
  color: var(--brand);
  font-size: 10.5px;
  font-weight: 600;
}

.branch-chars { margin-left: auto; font-size: 10.5px; color: var(--ink-4); }

.branch-body {
  flex: 1;
  padding: 9px 14px 12px;
  font-size: 13px;
  line-height: 1.85;
  color: var(--ink-1);
  max-height: 420px;
  overflow-y: auto;
}

.branch-foot {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding: 7px 10px;
  border-top: 1px solid var(--line);
}

.branch-spacer { flex: 1; }
.branch-actions { display: flex; align-items: center; gap: 2px; flex: 0 0 auto; }
.branch-foot :deep(.el-checkbox) { margin-right: 0; height: 24px; }
</style>