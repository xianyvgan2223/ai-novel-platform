<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { ElMessage } from 'element-plus';
import { MagicStick } from '@element-plus/icons-vue';
import type { Row } from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import { loadAllChapters, loadOutlines, statsOf } from './novelApi';

const route = useRoute();
const router = useRouter();

const outlines = ref<Row[]>([]);
const chapters = ref<Row[]>([]);
const loading = ref(false);

/** 从首页带过来的意图：edit / convert / chapters / view / read，决定点卡片时进入哪个页面 */
const intent = computed(() => String(route.query.intent ?? 'edit'));

const pageTitle = computed(() => {
  if (intent.value === 'convert') return '小事件详写 · 选择作品';
  if (intent.value === 'chapters') return '小事件写作 · 选择作品';
  if (intent.value === 'view') return '查看已有大纲 · 选择作品';
  if (intent.value === 'read') return '查看已有正文 · 选择作品';
  return '大纲编辑 · 选择作品';
});

const pageDesc = computed(() => {
  if (intent.value === 'convert') return '选一部作品，把大纲拆成小事件并逐个生成正文。';
  if (intent.value === 'chapters') return '选一部作品，进入小事件列表开始写正文。';
  if (intent.value === 'view') return '选一部作品，只读查看大纲正文与事件结构。';
  if (intent.value === 'read') return '选一部作品，按小事件翻看已写好的正文。';
  return '选一部作品，编辑大纲正文与事件结构。';
});

const entryLabel = computed(() => {
  if (intent.value === 'convert') return '进入小事件详写';
  if (intent.value === 'chapters') return '进入小事件列表';
  if (intent.value === 'view') return '查看大纲';
  if (intent.value === 'read') return '查看正文';
  return '进入大纲编辑';
});

async function load() {
  loading.value = true;
  try {
    outlines.value = await loadOutlines();
    chapters.value = await loadAllChapters();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

function chaptersOf(id: number): Row[] {
  return chapters.value.filter((item) => Number(item.outline_id) === id);
}

function stats(id: number) {
  return statsOf(chaptersOf(id));
}

function open(id: number, action: 'edit' | 'convert' | 'chapters' | 'view' | 'read') {
  router.push(`/writing/outline/${id}/${action}`);
}

function primary(id: number) {
  if (intent.value === 'convert') {
    open(id, 'convert');
  } else if (intent.value === 'chapters') {
    open(id, 'chapters');
  } else if (intent.value === 'view') {
    open(id, 'view');
  } else if (intent.value === 'read') {
    open(id, 'read');
  } else {
    open(id, 'edit');
  }
}

onMounted(load);
</script>

<template>
  <div class="page">
    <PageHeader :title="pageTitle" :desc="pageDesc" back="/writing">
      <template #actions>
        <el-button type="primary" :icon="MagicStick" @click="router.push('/writing/outline/generate')">
          生成新作品大纲
        </el-button>
      </template>
    </PageHeader>

    <div v-loading="loading">
      <div v-if="!outlines.length && !loading" class="card empty-hint">
        当前设备还没有作品，先点右上角「生成新作品大纲」。
      </div>

      <div v-else class="outline-list">
        <article
          v-for="item in outlines"
          :key="String(item.id)"
          class="card outline-card"
          @click="primary(Number(item.id))"
        >
          <div class="oc-main">
            <div class="oc-title">{{ item.title || '未命名作品' }}</div>
            <div class="oc-meta">
              <span>{{ item.genre || '未设类型' }}</span>
              <span v-if="item.theme" class="oc-theme">· {{ item.theme }}</span>
              <span>· {{ stats(Number(item.id)).minor }} 个小事件</span>
              <span>· 已写 {{ stats(Number(item.id)).written }}</span>
            </div>
          </div>
          <div class="oc-enter">
            {{ entryLabel }}<span class="oc-arrow">›</span>
          </div>
        </article>
      </div>
    </div>
  </div>
</template>

<style scoped>
.outline-list { display: flex; flex-direction: column; gap: 10px; }

.outline-card {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 18px;
  padding: 17px 20px;
  margin-bottom: 0;
  cursor: pointer;
  transition: border-color 0.16s ease, background 0.16s ease;
}

.outline-card:hover { border-color: var(--ink-4); background: var(--bg-soft); }

.oc-main { flex: 1; min-width: 0; }

.oc-title {
  font-size: 15px;
  font-weight: 550;
  letter-spacing: 0.1px;
  color: var(--ink-1);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.oc-meta {
  margin-top: 5px;
  font-size: 12.5px;
  color: var(--ink-3);
  display: flex;
  align-items: center;
  gap: 5px;
  min-width: 0;
}

.oc-theme {
  max-width: 520px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--ink-3);
}

.oc-enter {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 5px;
  font-size: 12.5px;
  font-weight: 500;
  color: var(--ink-2);
  white-space: nowrap;
}

.oc-arrow { font-size: 15px; line-height: 1; color: var(--ink-4); transition: transform 0.16s ease; }
.outline-card:hover .oc-arrow { transform: translateX(2px); color: var(--ink-1); }

@media (max-width: 760px) {
  .oc-theme { max-width: 38vw; }
  .oc-enter { font-size: 0; }
  .oc-arrow { font-size: 16px; }
}
</style>