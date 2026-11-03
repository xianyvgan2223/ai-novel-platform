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

/** 从首页带过来的意图：edit / convert / chapters，决定点卡片时进入哪个页面 */
const intent = computed(() => String(route.query.intent ?? 'edit'));

const pageTitle = computed(() => {
  if (intent.value === 'convert') return '小事件详写 · 选择作品';
  if (intent.value === 'chapters') return '小事件写作 · 选择作品';
  return '大纲编辑 · 选择作品';
});

const pageDesc = computed(() => {
  if (intent.value === 'convert') return '选一部作品，把大纲拆成小事件并逐个生成正文。';
  if (intent.value === 'chapters') return '选一部作品，进入小事件列表开始写正文。';
  return '选一部作品，编辑大纲正文与事件结构。';
});

const entryLabel = computed(() => {
  if (intent.value === 'convert') return '进入小事件详写';
  if (intent.value === 'chapters') return '进入小事件列表';
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

function open(id: number, action: 'edit' | 'convert' | 'chapters') {
  router.push(`/writing/outline/${id}/${action}`);
}

function primary(id: number) {
  if (intent.value === 'convert') {
    open(id, 'convert');
  } else if (intent.value === 'chapters') {
    open(id, 'chapters');
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
              <span v-if="item.theme">· {{ item.theme }}</span>
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
.outline-list { display: flex; flex-direction: column; gap: 14px; }

.outline-card {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding: 18px 20px;
  margin-bottom: 0;
  cursor: pointer;
  transition: box-shadow 0.15s ease;
}

.outline-card:hover { box-shadow: var(--shadow-pop); }

.oc-main { flex: 1; min-width: 0; }

.oc-title {
  font-size: 15.5px;
  font-weight: 650;
  color: var(--ink-1);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.oc-meta {
  margin-top: 5px;
  font-size: 12px;
  color: var(--ink-3);
  display: flex;
  gap: 4px;
  flex-wrap: wrap;
}

.oc-enter {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 4px;
  font-size: 12.5px;
  font-weight: 600;
  color: var(--brand);
}

.oc-arrow { font-size: 18px; line-height: 1; }
</style>
