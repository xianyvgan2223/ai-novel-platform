<script setup lang="ts">
import { useRouter } from 'vue-router';
import { ArrowLeft } from '@element-plus/icons-vue';

const props = defineProps<{
  title: string;
  desc?: string;
  /** 返回到哪个路由；不传则退回浏览器上一页 */
  back?: string;
}>();

const router = useRouter();

function goBack() {
  if (props.back) {
    router.push(props.back);
  } else {
    router.back();
  }
}
</script>

<template>
  <div class="page-head">
    <div class="head-left">
      <button v-if="back" type="button" class="back-btn" @click="goBack">
        <el-icon><ArrowLeft /></el-icon>
        <span>返回</span>
      </button>
      <div class="head-text">
        <h1 class="page-title">{{ title }}</h1>
        <p v-if="desc" class="page-desc">{{ desc }}</p>
      </div>
    </div>
    <div class="page-actions">
      <slot name="actions" />
    </div>
  </div>
</template>

<style scoped>
.head-left {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  min-width: 0;
}

.head-text { min-width: 0; }

.back-btn {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  margin-top: 3px;
  padding: 6px 10px 6px 8px;
  border: 1px solid var(--line);
  border-radius: 9px;
  background: #fff;
  color: var(--ink-2);
  font-size: 12.5px;
  cursor: pointer;
  transition: background 0.15s ease, border-color 0.15s ease;
}

.back-btn:hover {
  background: var(--bg-soft);
  border-color: var(--line-strong);
  color: var(--ink-1);
}
</style>
